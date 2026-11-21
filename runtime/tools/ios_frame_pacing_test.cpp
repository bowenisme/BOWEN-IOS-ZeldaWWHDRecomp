#include "../src/platform/ios/frame_pacing.h"
#include <cassert>
#include <cstdio>
#include <limits>
using namespace ios::pacing;
int main() {
    assert(target_output_fps(0, 120, 1, false) == 30);
    assert(target_output_fps(1, 60, 1, false) == 60);
    assert(target_output_fps(1, 120, 1, false) == 120);
    for (unsigned rate : {2u, 3u, 4u}) {
        assert(target_output_fps(1, 120, rate, true) == 30 * int(rate));
        assert(target_output_fps(0, 60, rate, true) == 30 * int(rate));
    }
    assert(target_output_fps(2, 120, 1, false) == 60);
    assert(target_output_fps(2, 120, 2, true) == 60);
    assert(refresh_request(120, 60) == 60);
    assert(refresh_request(120, 120) == 120);
    assert(refresh_request(60, 120) == 60);
    assert(refresh_request(30, 120) == 30);
    PresentedTimes times;
    const auto empty = times;
    times.add(0); times.add(-1); times.add(std::numeric_limits<double>::quiet_NaN());
    times.add(std::numeric_limits<double>::infinity());
    assert(times.invalid == 4 && times.valid == 0 && displayed_fps(empty, times) == -1);
    times.add(10);
    assert(displayed_fps(empty, times) == -1);
    times.add(10); times.add(9);
    assert(times.valid == 3 && times.unique == 1 && times.nonIncreasing == 2);
    for (int i = 1; i <= 120; ++i) times.add(10 + i / 120.0);
    assert(times.intervals == 120 && times.unique == 121);
    assert(std::abs(displayed_fps(empty, times) - 120) < 1e-8);
    const auto before = times;
    for (int i = 1; i <= 60; ++i) times.add(11 + i / 60.0);
    assert(std::abs(displayed_fps(before, times) - 60) < 1e-8);
    assert(displayed_fps(times, times) == -1); // no new display evidence
    times.add(13); // missed display time is included, rather than claiming 60/120
    assert(displayed_fps(before, times) < 60);
    std::puts("ios_frame_pacing_test: all checks passed");
}
