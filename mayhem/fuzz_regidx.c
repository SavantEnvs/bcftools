// libFuzzer harness over bcftools' region index (regidx.c): the parser behind every -r/-R/-t/-T
// regions list and regions/BED file (bcftools view/query/stats/csq/... call regidx_init on them).
//
// The first input byte picks the line parser the way regidx_init() does from a file name
// (.bed -> regidx_parse_bed, .vcf -> regidx_parse_vcf, otherwise regidx_parse_tab), plus
// regidx_parse_reg (CHROM:FROM-TO strings) and the comma-separated -r list (regidx_insert_list).
// The rest is the file/list text. Every region is then iterated and queried back, which
// exercises the sort/merge/index code. No state is kept between inputs: each call builds and
// destroys its own regidx_t/regitr_t.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "regidx.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size < 1) return -1;
    uint8_t mode = data[0] % 5;
    // regidx_init_string()/regidx_insert_list() take a NUL-terminated string.
    char *str = (char *) malloc(size);
    memcpy(str, data + 1, size - 1);
    str[size - 1] = 0;

    regidx_t *idx = NULL;
    switch (mode)
    {
        case 0: idx = regidx_init_string(str, regidx_parse_bed, NULL, 0, NULL); break;
        case 1: idx = regidx_init_string(str, regidx_parse_tab, NULL, 0, NULL); break;
        case 2: idx = regidx_init_string(str, regidx_parse_reg, NULL, 0, NULL); break;
        case 3: idx = regidx_init_string(str, regidx_parse_vcf, NULL, 0, NULL); break;
        default:
            idx = regidx_init(NULL, regidx_parse_reg, NULL, 0, NULL);
            if (idx && regidx_insert_list(idx, str, ',') < 0) { regidx_destroy(idx); idx = NULL; }
            break;
    }
    if (idx)
    {
        regidx_nregs(idx);
        int nseq = 0;
        char **seqs = regidx_seq_names(idx, &nseq);
        regitr_t *itr = regitr_init(idx);
        while (regitr_loop(itr))
        {
            // Query each region back, which must find at least itself.
            regitr_t *q = regitr_init(NULL);
            if (regidx_overlap(idx, itr->seq, itr->beg, itr->end, q))
                while (regitr_overlap(q)) {}
            regitr_destroy(q);
        }
        regitr_destroy(itr);
        for (int i = 0; i < nseq; i++)
            regidx_seq_nregs(idx, seqs[i]);
        regidx_destroy(idx);
    }
    free(str);
    return 0;
}
