// Synthetic host time drives the actual opt-in plan; no device or game memory.
#include "platform/ios/runtime_test.h"
#include <cassert>
#include <initializer_list>
#include <limits>

namespace {
int fps = 240, mode = 2;
unsigned rate = 3, changes = 0;
bool enabled = true, global = false, armed = true;
bool boost_active = true;
}
namespace interp {
int fps() { return ::fps; } int mode() { return ::mode; }
void set_fps(int value) { ::fps = value; ++changes; }
void set_mode(int value) { ::mode = value; ++changes; }
}
namespace mods {
bool fast_forward() { return enabled; }
bool fast_forward_active() { return boost_active; }
bool fast_forward_latched() { return armed; }
bool fast_forward_global() { return global; }
unsigned fast_forward_rate() { return rate; }
void set_fast_forward(bool value) { enabled = value; ++changes; }
void set_fast_forward_global(bool value) { global = value; ++changes; }
void set_fast_forward_rate(unsigned value) { rate = value; ++changes; }
void set_fast_forward_latched(bool value) { armed = value; if (value) enabled = true; ++changes; }
}
int main() {
    using Plan = ios::RuntimeTestPlan;
    using Phase = Plan::Phase;
    unsetenv("WWHD_IOS_RUNTIME_TEST");
    for (const char* value : {"", "0", "true", "2"}) {
        setenv("WWHD_IOS_RUNTIME_TEST", value, 1);
        Plan disabled;
        assert(disabled.tick("sea", 0, true, 100).phase == Phase::Disabled && changes == 0);
        input::PadState pad;
        ios::runtime_test_script_input(pad, input::kA | input::kB, "sea", 0, true, 104);
        assert(pad.buttons == (input::kA | input::kB) && pad.ly == 0);
    }
    unsetenv("WWHD_IOS_RUNTIME_TEST");
    Plan disabled;
    assert(disabled.tick("sea", 0, true, 100).phase == Phase::Disabled && changes == 0);
    setenv("WWHD_IOS_RUNTIME_TEST", "1", 1);
    // Filter only timed A while ordinary sea gameplay is ready; keep title/intro/dialogue input.
    for (const char* stage : std::initializer_list<const char*>{"sea_T", "Name", "sea_E", "", nullptr}) {
        input::PadState pad;
        ios::runtime_test_script_input(pad, input::kA, stage, 0, true, 104);
        assert(pad.buttons == input::kA);
    }
    for (unsigned event : {1u, 2u, 3u}) {
        input::PadState pad;
        ios::runtime_test_script_input(pad, input::kA, "sea", event, true, 104);
        assert(pad.buttons == input::kA);
    }
    input::PadState no_link;
    ios::runtime_test_script_input(no_link, input::kA, "sea", 0, false, 104);
    assert(no_link.buttons == input::kA);
    input::PadState free;
    ios::runtime_test_script_input(free, input::kA | input::kB, "sea", 0, true, 104);
    assert(free.buttons == input::kB);
    input::PadState physical;
    physical.buttons = input::kA | input::kX;
    ios::runtime_test_script_input(physical, input::kA | input::kB, "sea", 0, true, 104);
    assert(physical.buttons == (input::kA | input::kX | input::kB));
    Plan plan;
    assert(plan.tick("Name", 0, true, 100).phase == Phase::AdvanceStory);
    assert(enabled && global && armed && rate == 4 && fps == 60 && mode == 1);
    assert(plan.tick("sea_T", 0, true, 200).phase == Phase::AdvanceStory);
    assert(plan.tick("sea", 0, false, 201).phase == Phase::AdvanceStory);
    assert(plan.tick("sea", 0, true, 202).phase == Phase::AdvanceStory);
    assert(plan.tick("sea", 1, true, 204).phase == Phase::AdvanceStory); // interrupted readiness
    plan.tick("sea", 0, true, 205);
    assert(plan.tick("sea", 0, true, 207).phase == Phase::AdvanceStory);
    assert(plan.tick("sea", 0, true, 208).phase == Phase::Normal60);
    assert(!enabled && !armed && fps == 60 && mode == 1);
    const auto stable = changes;
    assert(plan.tick("sea", 0, true, 237).phase == Phase::Normal60 && changes == stable);
    assert(plan.tick("sea", 0, true, 238).phase == Phase::Global2);
    assert(enabled && global && armed && rate == 2);
    assert(plan.tick("sea", 0, true, 257).phase == Phase::Global2);
    assert(plan.tick("sea", 0, true, 258).phase == Phase::Global3 && rate == 3);
    assert(plan.tick("sea", 0, true, 278).phase == Phase::Global4 && rate == 4);
    for (double now : {281.99, 282., 282.99, 283., 284., 290.}) {
        input::PadState pad;
        const bool moved = ios::runtime_test_script_input(pad, input::kA, "sea", 0, true, now);
        assert(moved == (now >= 282 && now < 283));
        assert(pad.lx == (moved ? .8f : 0) && pad.ly == 0);
        assert(pad.buttons == 0);
    }
    for (unsigned event : {1u, 2u}) {
        input::PadState pad;
        ios::runtime_test_script_input(pad, input::kA, "sea", event, true, 282);
        assert(pad.lx == 0 && pad.ly == 0 && pad.buttons == input::kA);
    }
    input::PadState held;
    held.lx = -.1f;
    ios::runtime_test_script_input(held, 0, "sea", 0, true, 282);
    assert(held.lx == -.1f && held.ly == 0); // never replace a real/controller/script stick
    boost_active = false;
    input::PadState blocked;
    ios::runtime_test_script_input(blocked, 0, "sea", 0, true, 282);
    assert(blocked.lx == 0 && blocked.ly == 0);
    boost_active = true; armed = false;
    ios::runtime_test_script_input(blocked, 0, "sea", 0, true, 282);
    assert(blocked.lx == 0 && blocked.ly == 0); // reset/focus loss must stop the fixture too
    armed = true;
    assert(plan.tick("sea", 0, true, 298).phase == Phase::Recovered60);
    assert(!armed && !enabled && mode == 1 && fps == 60);
    assert(ios::runtime_test_move_start.load() == -1);
    assert(!plan.tick("sea", 0, true, 317).complete);
    const auto done = plan.tick("sea", 0, true, 318);
    assert(done.complete && done.phase == Phase::Complete && done.startedAt == 318);
    assert(!armed && enabled && !global && rate == 3 && fps == 240 && mode == 2);
    const auto finished_changes = changes;
    plan.tick("sea", 0, true, 9999);
    plan.tick("sea", 0, true, std::numeric_limits<double>::quiet_NaN());
    plan.tick("sea", 0, true, 1);
    assert(changes == finished_changes); // completion is inert, invalid/backwards time ignored
    input::PadState after;
    ios::runtime_test_script_input(after, 0, "sea", 0, true, 282);
    assert(after.lx == 0 && after.ly == 0); // no movement after completion, even with stale input timestamps

    // A delayed callback applies one new phase, guaranteeing its full measured duration.
    Plan delayed;
    delayed.tick("sea", 0, true, 1000);
    delayed.tick("sea", 0, true, 1003);
    const auto phase = delayed.tick("sea", 0, true, 5000);
    assert(phase.phase == Phase::Global2 && phase.startedAt == 5000 && phase.elapsed == 0);
    assert(delayed.tick("sea", 0, true, 5019).phase == Phase::Global2);
    assert(delayed.tick("sea", 0, true, 5020).phase == Phase::Global3);
}
