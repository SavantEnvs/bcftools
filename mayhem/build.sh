#!/usr/bin/env bash
#
# mayhem/build.sh — build bcftools' fuzz targets and its test suite. Runs in the commit image as
# `mayhem` in /mayhem; offline and re-runnable. htslib is not a submodule: the Dockerfile cached a
# pinned build of it under /opt/toolchains/deps/htslib-develop-387a173 (static libhts.a, bgzip, tabix).
#
# Outputs:
#   /mayhem/bcftools-asan        sanitized bcftools CLI          (Mayhemfile_bcftools: `stats @@`)
#   /mayhem/fuzz_vcmp_set_ref    libFuzzer harness over vcmp.c   (+ -standalone reproducer)
#   /mayhem/fuzz_regidx          libFuzzer harness over regidx.c (regions/BED lists; + -standalone)
#   /mayhem/filter_expr          file-input driver over filter.c (-i/-e expressions)
#   (bcftools-asan also serves Mayhemfile_csq_gff `csq -g @@` and Mayhemfile_convert_tsv2vcf)
#   /mayhem/bcftools, plugins/*.so, test/test-*   normal-flags build the suite runs (mayhem/test.sh)
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

HTS=/opt/toolchains/deps/htslib-develop-387a173
HTS_LIBS="-lbz2 -llzma -ldeflate -lz -lm -lpthread"
HTS_LIB="$HTS/lib/libhts.a $HTS_LIBS"

write_config() {  # write_config <dir> <plugins yes|no> [extra objects linked into bcftools]
    cat > "$1/config.mk" <<EOF
PLUGINS_ENABLED = $2
HTSDIR = $HTS
HTSLIB_CPPFLAGS = -I$HTS/include
HTSLIB_LDFLAGS = -L$HTS/lib
HTSLIB_LIB = ${3:-} $HTS_LIB
BGZIP = $HTS/bin/bgzip
TABIX = $HTS/bin/tabix
EOF
}

# 1) The test build: project's NORMAL flags, in tree, with plugins (what test.sh runs).
write_config "$SRC" yes
make -j"$MAYHEM_JOBS" CC="$CC" CFLAGS="-g -O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" \
    bcftools test/test-rbuf test/test-regidx plugins

# 2) The fuzz build: a sanitized copy of the tracked sources outside the test tree (mayhem/build-fuzz
#    is gitignored by mayhem/.gitignore).
F="$SRC/mayhem/build-fuzz"
rm -rf "$F" && mkdir -p "$F"
git ls-files -z -- . ':!test' ':!doc' ':!mayhem' | while IFS= read -r -d '' f; do
    [ -e "$f" ] || continue
    mkdir -p "$F/$(dirname "$f")" && cp -p "$f" "$F/$f"
done
# Leak detection off at build time (SPEC §6.2 item 15); compiled once, linked into every binary.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$F/lsan_off.o"
write_config "$F" yes "$F/lsan_off.o"   # plugin loader linked in; the plugin .so files are not built here
# -DHTS_ALLOW_UNALIGNED=0: upstream's own sanitizer CI setting (htslib's inline unaligned loads).
( cd "$F" && make -j"$MAYHEM_JOBS" CC="$CC" \
    CFLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS -DHTS_ALLOW_UNALIGNED=0" \
    LDFLAGS="$SANITIZER_FLAGS" bcftools )
cp -f "$F/bcftools" /mayhem/bcftools-asan

# 3) libFuzzer harnesses + standalone reproducers. Each libFuzzer binary links its own copy of the
#    fuzzed source built with SanCov (-fsanitize=fuzzer-no-link) so the fuzzer gets coverage from the
#    code it fuzzes; bcftools-asan and the -standalone reproducers keep the plain sanitized objects.
#    regidx.o comes before libhts.a, so bcftools' regidx_* (not htslib's same-named copy) is linked.
HARN_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -DHTS_ALLOW_UNALIGNED=0 -I$F -I$HTS/include"
for src in vcmp regidx; do
    $CC -O1 $HARN_FLAGS -fsanitize=fuzzer-no-link -c "$F/$src.c" -o "$F/$src-fuzz.o"
done
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$F/standalone_main.o"
$CXX $HARN_FLAGS $LIB_FUZZING_ENGINE "$SRC/mayhem/fuzz_vcmp_set_ref.cpp" "$F/vcmp-fuzz.o" "$F/lsan_off.o" \
    $HTS_LIB -o /mayhem/fuzz_vcmp_set_ref
$CXX $HARN_FLAGS "$SRC/mayhem/fuzz_vcmp_set_ref.cpp" "$F/standalone_main.o" "$F/vcmp.o" "$F/lsan_off.o" \
    $HTS_LIB -o /mayhem/fuzz_vcmp_set_ref-standalone
$CC $HARN_FLAGS -c "$SRC/mayhem/fuzz_regidx.c" -o "$F/fuzz_regidx.o"
$CXX $HARN_FLAGS $LIB_FUZZING_ENGINE "$F/fuzz_regidx.o" "$F/regidx-fuzz.o" "$F/lsan_off.o" \
    $HTS_LIB -o /mayhem/fuzz_regidx
$CXX $HARN_FLAGS "$F/fuzz_regidx.o" "$F/standalone_main.o" "$F/regidx.o" "$F/lsan_off.o" \
    $HTS_LIB -o /mayhem/fuzz_regidx-standalone

# 4) filter.c reports bad expressions via error() -> exit(), so it is a file-input target: a small
#    driver linked against the sanitized filter.o (+ the bcftools objects it calls into).
$CC $HARN_FLAGS -c "$SRC/mayhem/filter_expr.c" -o "$F/filter_expr.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$F/filter_expr.o" "$F/filter.o" "$F/version.o" "$F/regidx.o" \
    "$F/smpl_ilist.o" "$F/lsan_off.o" $HTS_LIB -o /mayhem/filter_expr
