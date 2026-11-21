// SPDX-License-Identifier: MPL-2.0
#pragma once
#include "../../interp.h"
#include "../../mods/fast_forward.h"
#include "../../input.h"
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>

namespace ios {
inline bool runtime_test_enabled() {
    const char* value = std::getenv("WWHD_IOS_RUNTIME_TEST");
    return value && std::strcmp(value, "1") == 0;
}
inline bool runtime_test_free_sea(const char* stage, unsigned event, bool linkReady) {
    return stage && std::strncmp(stage, "sea", 8) == 0 && linkReady && event == 0;
}
// Host publishes the 4x phase origin; the input thread never reads mutable plan state.
inline std::atomic<double> runtime_test_move_start{-1};
inline bool runtime_test_script_input(input::PadState& pad, uint32_t timedButtons,
                                      const char* stage, unsigned event, bool linkReady, double hostSeconds) {
    bool moved = false;
    if (runtime_test_enabled()) {
        const bool free = runtime_test_free_sea(stage, event, linkReady);
        if (free) timedButtons &= ~input::kA; // filter the scripted contribution, never the physical buttons
        const double start = runtime_test_move_start.load();
        if (free && start >= 0 && hostSeconds >= start + 4 && hostSeconds < start + 5 &&
            mods::fast_forward_active() && mods::fast_forward_latched() && pad.lx == 0 && pad.ly == 0) {
            pad.lx = .8f; // one horizontal 1-host-second pulse, only while the 4x boost is actually active
            moved = true;
        }
    }
    pad.buttons |= timedButtons;
    return moved;
}
// Opt-in, host-clock test only. Call from the main thread; never persists settings.
class RuntimeTestPlan {
public:
    enum class Phase { Disabled, AdvanceStory, Normal60, Global2, Global3, Global4, Recovered60, Complete };
    struct State {
        Phase phase;
        const char* name;
        double startedAt, elapsed;
        bool complete;
    };
private:
    bool enabled_ = runtime_test_enabled();
    Phase phase_ = Phase::Disabled;
    double started_ = 0, last_ = 0, ready_since_ = -1;
    int saved_fps_ = 60, saved_mode_ = 0;
    unsigned saved_rate_ = 2;
    bool saved_global_ = false, saved_enabled_ = false;

    void enter(Phase phase, double now) {
        phase_ = phase;
        started_ = now;
        runtime_test_move_start = phase == Phase::Global4 ? now : -1;
        if (phase == Phase::Complete) {
            mods::set_fast_forward_latched(false);
            mods::set_fast_forward_global(saved_global_);
            mods::set_fast_forward_rate(saved_rate_);
            mods::set_fast_forward(saved_enabled_);
            interp::set_fps(saved_fps_);
            interp::set_mode(saved_mode_);
            return;
        }
        interp::set_fps(60);
        interp::set_mode(1); // 30 Hz logic + interpolation; boost disables interpolation via its usual gate
        const unsigned rate = phase == Phase::Global2 ? 2 : phase == Phase::Global3 ? 3 : 4;
        const bool boost = phase == Phase::AdvanceStory || phase == Phase::Global2 ||
                           phase == Phase::Global3 || phase == Phase::Global4;
        mods::set_fast_forward_global(true);
        mods::set_fast_forward_rate(rate);
        mods::set_fast_forward_latched(boost);
        if (!boost) mods::set_fast_forward(false); // physical trigger cannot contaminate baseline
    }
    State state() const {
        const char* names[] = {"disabled", "advance-story-4x", "normal-60fps-30hz", "global-2x",
                               "global-3x", "global-4x", "recovered-60fps-30hz", "complete"};
        return {phase_, names[unsigned(phase_)], started_, last_ - started_, phase_ == Phase::Complete};
    }
public:
    State tick(const char* stage, unsigned event, bool linkReady, double hostSeconds) {
        if (!enabled_ || !std::isfinite(hostSeconds) || hostSeconds < last_) return state();
        last_ = hostSeconds;
        if (phase_ == Phase::Disabled) {
            saved_fps_ = interp::fps(); saved_mode_ = interp::mode();
            saved_rate_ = mods::fast_forward_rate(); saved_global_ = mods::fast_forward_global();
            saved_enabled_ = mods::fast_forward();
            enter(Phase::AdvanceStory, hostSeconds);
        }
        if (phase_ == Phase::AdvanceStory) {
            const bool ready = stage && *stage && std::strncmp(stage, "Name", 8) &&
                               std::strncmp(stage, "sea_T", 8) && linkReady && event == 0;
            if (!ready) ready_since_ = -1;
            else if (ready_since_ < 0) ready_since_ = hostSeconds;
            else if (hostSeconds - ready_since_ >= 3) enter(Phase::Normal60, hostSeconds);
        } else if (phase_ != Phase::Complete && hostSeconds - started_ >= (phase_ == Phase::Normal60 ? 30 : 20)) {
            // Start each phase when it is actually applied; delayed host callbacks never skip a measurement.
            enter(Phase(unsigned(phase_) + 1), hostSeconds);
        }
        return state();
    }
};

inline RuntimeTestPlan::State runtime_test_tick(const char* stage, unsigned event, bool linkReady, double hostSeconds) {
    static RuntimeTestPlan plan;
    return plan.tick(stage, event, linkReady, hostSeconds);
}
} // namespace ios
