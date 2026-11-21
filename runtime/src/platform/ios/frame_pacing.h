// iOS refresh hints and displayed-frame accounting, independent of UIKit/Metal for local tests.
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>

namespace ios::pacing {
inline int target_output_fps(int mode, int interpolation_fps, unsigned clock_rate, bool fast_forward) {
    // Fast-forward suspends both interpolated frames and true60 half steps.
    const int base = fast_forward ? 30 : mode == 2 ? 60 : mode == 1 ? interpolation_fps : 30;
    return base * int(std::clamp(clock_rate, 1u, 4u));
}
inline int refresh_request(int target, int maximum) {
    return std::clamp(target, 1, std::max(1, maximum));
}
struct PresentedTimes {
    uint64_t valid = 0, unique = 0, invalid = 0, nonIncreasing = 0, intervals = 0;
    double last = 0, intervalSeconds = 0, lastIntervalSeconds = 0;
    void add(double time) {
        if (!std::isfinite(time) || time <= 0) { ++invalid; return; }
        ++valid;
        // Callbacks alone do not prove presentation: zero, repeats and out-of-order times
        // must not inflate displayed FPS. Keep the last increasing display timestamp.
        if (time <= last) { ++nonIncreasing; return; }
        if (last > 0) {
            lastIntervalSeconds = time - last;
            intervalSeconds += lastIntervalSeconds;
            ++intervals;
        }
        last = time;
        ++unique;
    }
};
inline double displayed_fps(const PresentedTimes& before, const PresentedTimes& after) {
    const double seconds = after.intervalSeconds - before.intervalSeconds;
    return after.intervals > before.intervals && seconds > 0
        ? double(after.intervals - before.intervals) / seconds : -1;
}
}
