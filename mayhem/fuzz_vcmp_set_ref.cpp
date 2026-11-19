#include <stdint.h>
#include <stddef.h>
#include <string>
#include <vector>

#include <fuzzer/FuzzedDataProvider.h>
extern "C" {
    #include "vcmp.h"
}

// Allele-list comparison from bcftools' vcmp: set_ref + find_allele + A/R-value mapping.
// vcmp_map_ARvalues() requires number == nals2 (Number=R) or nals2-1 (Number=A), nals >= 1.
extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    FuzzedDataProvider provider(data, size);
    std::vector<std::string> a1, a2;
    int n1 = 1 + provider.ConsumeIntegralInRange<int>(0, 4);
    int n2 = 1 + provider.ConsumeIntegralInRange<int>(0, 4);
    bool number_r = provider.ConsumeBool();
    a1.push_back(provider.ConsumeRandomLengthString(1000));
    a2.push_back(provider.ConsumeRandomLengthString(1000));
    for (int i = 1; i < n1; i++) a1.push_back(provider.ConsumeRandomLengthString(40));
    for (int i = 1; i < n2; i++) a2.push_back(provider.ConsumeRandomLengthString(40));

    std::vector<char*> p1, p2;
    for (auto &s : a1) p1.push_back(&s[0]);
    for (auto &s : a2) p2.push_back(&s[0]);

    vcmp_t *vcmp = vcmp_init();
    int *map = vcmp_map_ARvalues(vcmp, number_r ? n2 : n2 - 1, n1, p1.data(), n2, p2.data());
    if (map)
    {
        int nmap;
        vcmp_map_dipGvalues(vcmp, &nmap);
    }
    vcmp_destroy(vcmp);
    return 0;
}
