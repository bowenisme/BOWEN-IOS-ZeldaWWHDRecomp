// Stable controller polls must not allocate a ReleaseGate node on every tick.
#include "overlay/release_gate.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <new>

static size_t allocations;
void* operator new(size_t n) {
    ++allocations;
    if (void* p=std::malloc(n?n:1)) return p;
    throw std::bad_alloc();
}
void operator delete(void* p) noexcept { std::free(p); }
void operator delete(void* p,size_t) noexcept { std::free(p); }

int main() {
    overlay::DeviceGates<int> gates;
    std::vector<std::pair<int,overlay::PadValues>> devices{{1,{}},{2,{}}};
    float raw[input_map::kPadCount],game[input_map::kPadCount];
    gates.combine(devices,false,raw,game);
    allocations=0;
    for (int tick=0;tick<10000;++tick) {
        devices[0].second[input_map::kPadA]=tick%2;
        gates.combine(devices,tick%3==0,raw,game);
    }
    assert(allocations==0);
    devices.push_back({3,{}});
    allocations=0;
    gates.combine(devices,false,raw,game);
    assert(allocations==1 && gates.size()==3);
    devices.erase(devices.begin());
    allocations=0;
    gates.combine(devices,false,raw,game);
    assert(allocations==0 && gates.size()==2);
    std::puts("input_poll_allocation_test: 10000 stable polls, zero gate allocations; hotplug passed");
}
