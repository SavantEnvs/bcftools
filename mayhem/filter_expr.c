// File-input driver over bcftools' filter-expression engine (filter.c): the tokenizer, parser and
// evaluator behind every -i/--include and -e/--exclude expression (view, query, filter, stats,
// norm, +plugins, ...). Usage: filter_expr <expression-file>.
//
// filter_init() reports a malformed expression through error(), which exit()s, so this is a
// file-input target (one input per process) rather than a libFuzzer harness. The expression is
// the whole file. It is compiled against a fixed header and evaluated on fixed records that carry
// INFO/FORMAT fields of every type, so the evaluator, not only the parser, is reached.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <htslib/vcf.h>
#include <htslib/kstring.h>
#include "filter.h"

static const char *hdr_txt =
    "##fileformat=VCFv4.3\n"
    "##contig=<ID=1,length=1000000>\n"
    "##contig=<ID=chrX,length=1000000>\n"
    "##FILTER=<ID=PASS,Description=\"All filters passed\">\n"
    "##FILTER=<ID=q10,Description=\"Quality below 10\">\n"
    "##INFO=<ID=DP,Number=1,Type=Integer,Description=\"Depth\">\n"
    "##INFO=<ID=AF,Number=A,Type=Float,Description=\"Allele frequency\">\n"
    "##INFO=<ID=AC,Number=A,Type=Integer,Description=\"Allele count\">\n"
    "##INFO=<ID=AN,Number=1,Type=Integer,Description=\"Allele number\">\n"
    "##INFO=<ID=DB,Number=0,Type=Flag,Description=\"dbSNP\">\n"
    "##INFO=<ID=STR,Number=.,Type=String,Description=\"Strings\">\n"
    "##INFO=<ID=CSQ,Number=.,Type=String,Description=\"Consequence\">\n"
    "##INFO=<ID=RVAL,Number=R,Type=Float,Description=\"Per-allele values\">\n"
    "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">\n"
    "##FORMAT=<ID=DP,Number=1,Type=Integer,Description=\"Depth\">\n"
    "##FORMAT=<ID=GQ,Number=1,Type=Integer,Description=\"Genotype quality\">\n"
    "##FORMAT=<ID=AD,Number=R,Type=Integer,Description=\"Allelic depths\">\n"
    "##FORMAT=<ID=PL,Number=G,Type=Integer,Description=\"Phred likelihoods\">\n"
    "##FORMAT=<ID=GP,Number=G,Type=Float,Description=\"Genotype probabilities\">\n"
    "##FORMAT=<ID=FT,Number=1,Type=String,Description=\"Sample filter\">\n"
    "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS1\tS2\tS3\n";

static const char *recs_txt[] = {
    "1\t100\trs1\tA\tC,GT\t50\tPASS\tDP=30;AF=0.25,0.5;AC=1,2;AN=6;DB;STR=a,bb;CSQ=missense|GENE1|T1,synonymous|GENE2|T2;RVAL=0.1,0.2,0.3"
    "\tGT:DP:GQ:AD:PL:GP:FT\t0/1:10:30:5,5,0:10,0,20,30,40,50:0.1,0.8,0.1,0,0,0:PASS"
    "\t1|2:.:99:0,3,4:.:.:lowq\t./.:5:.:.:0,10,100,10,100,100:.:.",
    "chrX\t5000\t.\tACGT\tA,<DEL>,*\t.\tq10\tDP=3;STR=x"
    "\tGT:DP\t1\t0/3\t.",
};

int main(int argc, char **argv)
{
    if (argc != 2) { fprintf(stderr, "usage: %s <expression-file>\n", argv[0]); return 2; }
    FILE *fp = fopen(argv[1], "rb");
    if (!fp) { perror(argv[1]); return 2; }
    kstring_t expr = {0, 0, NULL};
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) kputsn(buf, n, &expr);
    fclose(fp);
    if (!expr.s) kputs("", &expr);

    bcf_hdr_t *hdr = bcf_hdr_init("r");
    if (bcf_hdr_parse(hdr, (char *) hdr_txt) != 0 || bcf_hdr_sync(hdr) != 0) abort();
    bcf1_t *rec = bcf_init();

    filter_t *flt = filter_init(hdr, expr.s);
    for (size_t i = 0; i < sizeof(recs_txt) / sizeof(*recs_txt); i++)
    {
        kstring_t line = {0, 0, NULL};
        kputs(recs_txt[i], &line);
        if (vcf_parse(&line, hdr, rec) != 0) abort();
        free(line.s);
        const uint8_t *smpl_pass = NULL;
        filter_test(flt, rec, &smpl_pass);
    }
    filter_destroy(flt);
    bcf_destroy(rec);
    bcf_hdr_destroy(hdr);
    free(expr.s);
    return 0;
}
