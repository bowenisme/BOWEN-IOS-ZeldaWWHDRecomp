// Standalone: clang++ -std=c++17 -fobjc-arc -framework Foundation -framework Metal
// runtime/tools/metal_rt_probe_test.mm -o /tmp/wwhd-metal-rt-probe
#include "../src/gfx/metal_rt_probe.inc"
#include <cstdio>

static bool validator_test() {
    using namespace gfx::rt_probe;
    Hit good[] = {{2, .25f, .5f, 0}, {-1, 0, 0, UINT32_MAX},
        {std::sqrt(8.0f) - .001f, .25f, .5f, 0}, {-1, 0, 0, UINT32_MAX}};
    if (!valid_results(good)) return false;
    auto saved = good[2];
    good[2].distance = 2; // wrong reflected direction or distance
    if (valid_results(good)) return false;
    good[2] = saved;
    good[2].u = NAN;
    if (valid_results(good)) return false;
    good[2] = saved;
    good[2].primitive = UINT32_MAX;
    if (valid_results(good)) return false;
    good[2] = saved;
    good[1] = good[0];
    if (valid_results(good)) return false;
    std::memset(good, 0xcd, sizeof(good));
    return !valid_results(good);
}

int main(int argc, const char* argv[]) {
    if (!validator_test()) return 1;
    if (argc == 2 && !std::strcmp(argv[1], "--validator-only")) {
        std::puts("RT readback validator: passed");
        return 0;
    }
    @autoreleasepool {
        NSDictionary* report = gfx::rt_probe::run(MTLCreateSystemDefaultDevice());
        NSError* error = nil;
        NSData* json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
        if (!json) { std::fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
        std::fwrite(json.bytes, 1, json.length, stdout);
        std::putchar('\n');
        if ([report[@"status"] isEqual:@"passed"]) return 0;
        return [report[@"status"] isEqual:@"unsupported"] ? 77 : 1;
    }
}
