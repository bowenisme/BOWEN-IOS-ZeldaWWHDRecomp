#pragma once
#include <algorithm>
#include <cmath>

namespace ios {
// Host real time stays independent of game speed and restored guest snapshots.
class PlayTimeCounter {
    double total_ = 0, session_ = 0, anchor_ = 0;
    bool running_ = false;
    double pending(double now) const {
        return running_ && std::isfinite(now) ? std::max(0.0, now - anchor_) : 0;
    }
public:
    explicit PlayTimeCounter(double saved = 0) : total_(std::isfinite(saved) && saved >= 0 ? saved : 0) {}
    void set_running(bool running, double now) {
        if (!std::isfinite(now) || now < 0) return;
        now = std::max(now, anchor_);
        const double elapsed = pending(now);
        total_ += elapsed; session_ += elapsed;
        anchor_ = now; running_ = running;
    }
    double total(double now) const { return total_ + pending(now); }
    double session(double now) const { return session_ + pending(now); }
    double checkpoint(double now) { set_running(running_, now); return total_; }
};
}
