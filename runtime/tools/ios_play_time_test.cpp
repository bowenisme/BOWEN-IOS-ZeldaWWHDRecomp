#include "../src/platform/ios/play_time.h"
#include <cassert>
#include <cstdio>
#include <limits>

int main() {
    ios::PlayTimeCounter time(120);
    assert(time.total(1000) == 120 && time.session(1000) == 0); // not started, including smoke boot
    time.set_running(true, 10);
    assert(time.total(20) == 130 && time.session(20) == 10);
    assert(time.checkpoint(20) == 130);
    assert(time.checkpoint(20) == 130); // repeated checkpoint must not double-count
    assert(time.checkpoint(35) == 145 && time.session(35) == 25);
    time.set_running(false, 40);
    assert(time.checkpoint(40) == 150);
    time.set_running(false, 90); // resign-active followed by termination
    assert(time.total(100) == 150 && time.session(100) == 30);
    time.set_running(true, 100);
    assert(time.total(125) == 175 && time.session(125) == 55); // background gap excluded
    assert(time.total(125) == 175); // querying UI does not consume/re-add elapsed time
    ios::PlayTimeCounter restarted(time.checkpoint(125));
    assert(restarted.total(500) == 175 && restarted.session(500) == 0);
    restarted.set_running(true, 500);
    assert(restarted.checkpoint(530) == 205 && restarted.session(530) == 30);
    // No guest frame counter, fast-forward multiplier, FPS mode, or save-state participates.
    restarted.set_running(true, 520); // defensive handling of a non-increasing timestamp
    assert(restarted.total(531) == 206);
    restarted.set_running(true, std::numeric_limits<double>::quiet_NaN());
    assert(restarted.total(531) == 206);
    assert(ios::PlayTimeCounter(-1).total(100) == 0);
    assert(ios::PlayTimeCounter(std::numeric_limits<double>::infinity()).total(100) == 0);
    assert(ios::PlayTimeCounter(std::numeric_limits<double>::quiet_NaN()).total(100) == 0);
    std::puts("ios_play_time_test: active segments, checkpoints, restart and invalid values passed");
}
