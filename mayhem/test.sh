#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

HTS=/opt/toolchains/deps/htslib-develop-387a173
for exe in bcftools plugins test/test-rbuf test/test-regidx "$HTS/bin/bgzip" "$HTS/bin/tabix"; do
    [ -e "$exe" ] || { echo "missing $exe: mayhem/build.sh did not build it" >&2; exit 2; }
done

# The unit-test programs: each is one test (exit status = verdict).
passed=0; failed=0
for t in test/test-rbuf test/test-regidx; do
    if "./$t"; then passed=$((passed+1)); else failed=$((failed+1)); echo "FAILED: $t" >&2; fi
done

# test.pl diffs each bcftools command's output against the golden files in test/ (plugins included).
out=$(REF_PATH=: ./test/test.pl --plugins --exec bgzip="$HTS/bin/bgzip" --exec tabix="$HTS/bin/tabix" \
        --htsdir="$HTS" 2>&1)
rc=$?
printf '%s\n' "$out" | grep -B7 '^\.\. failed' | cut -c1-400
printf '%s\n' "$out" | tail -n 8
p=$(printf '%s\n' "$out" | sed -n 's/^ *passed  \.\. *//p' | tail -1)
f=$(printf '%s\n' "$out" | sed -n 's/^ *failed  \.\. *//p' | tail -1)
if [ -z "$p" ] || [ -z "$f" ]; then   # test.pl died before printing its summary
    p=0; f=1
fi

# A test whose golden file is not in the tree can only "fail" (upstream a3db9ba2 added the
# fill-tags.func.samples*.out tests to test.pl without the .out files). Those are skipped, not failed;
# every other mismatch still counts. test.pl wrote the actual output next to the missing golden file.
skipped=$(printf '%s\n' "$out" | perl -ne '
    if (/^\t(\/\S+)\.new$/) { $g = $1; next }
    if (/^\.\. failed \.\.\./ && defined $g) { $n++ if !-e $g; }
    $g = undef if /^\S/ && !/^\.\. failed/;
    END { print $n+0 }')
for g in $(printf '%s\n' "$out" | sed -n 's/^\t\(\/.*\)\.new$/\1/p' | sort -u); do
    [ -e "$g" ] || rm -f "$g.new"
done
[ "$skipped" -le "$f" ] || skipped=$f
f=$((f - skipped))
[ "$rc" -eq 0 ] || [ "$f" -gt 0 ] || [ "$skipped" -gt 0 ] || f=1
emit_ctrf "bcftools-test.pl" $((passed+p)) $((failed+f)) "$skipped"
