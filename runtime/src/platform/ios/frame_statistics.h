// Actual displayed-frame intervals. No allocation/sorting on the presentation callback.
#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <vector>

namespace ios::pacing {
struct FrameStatistics {
    unsigned samples = 0, longFrames = 0, catchUpPairs = 0;
    double seconds = 0, fps = -1, low1 = -1, low01 = -1;
    double currentMs = -1, averageMs = -1, p99Ms = -1, p999Ms = -1, maximumMs = -1;
    double minimumFPS = -1, maximumFPS = -1;
    std::array<double, 120> graph{}; // peak interval per bin, last 10 seconds; zero means no sample
};
class FrameHistory {
    struct Frame { double end = 0, ms = 0; };
    static constexpr unsigned capacity = 8192; // covers 60 s even at the iPad's 120 Hz limit
    std::array<Frame, capacity> frames_{};
    unsigned begin_ = 0, count_ = 0;
    uint64_t generation_ = 0;
    double last_ = 0;
public:
    void reset() { begin_ = count_ = 0; last_ = 0; }
    void add(double time, uint64_t generation) {
        if (generation != generation_) { reset(); generation_ = generation; }
        if (!std::isfinite(time) || time <= 0 || time <= last_) return;
        if (last_ > 0) {
            if (count_ == capacity) { begin_ = (begin_ + 1) % capacity; --count_; }
            frames_[(begin_ + count_++) % capacity] = {time, (time - last_) * 1000};
            while (count_ && frames_[begin_].end < time - 60) {
                begin_ = (begin_ + 1) % capacity; --count_;
            }
        }
        last_ = time;
    }
    FrameStatistics summarize(double now, int targetFPS) const {
        FrameStatistics s;
        // Do not display stale lows as current performance while presentation is stopped.
        if (!count_ || !std::isfinite(now) || now < last_ || now - last_ > 2.5) return s;
        std::vector<double> sorted;
        sorted.reserve(count_);
        double sum = 0, previousMs = 0;
        const double budget = 1000.0 / std::max(1, targetFPS);
        for (unsigned i = 0; i < count_; ++i) {
            const auto& f = frames_[(begin_ + i) % capacity];
            if (f.end < now - 60) continue;
            sorted.push_back(f.ms); sum += f.ms; s.currentMs = f.ms;
            if(previousMs>budget*1.25 && f.ms<budget*.75) ++s.catchUpPairs;
            previousMs=f.ms;
            if (f.ms > budget * 1.5) ++s.longFrames;
            if (f.end >= now - 10) {
                const unsigned bin = std::min(119u, unsigned((f.end - (now - 10)) * 12));
                s.graph[bin] = std::max(s.graph[bin], f.ms);
            }
        }
        s.samples = unsigned(sorted.size());
        if (!s.samples) return s;
        s.seconds = sum / 1000; s.averageMs = sum / s.samples; s.fps = 1000 / s.averageMs;
        std::sort(sorted.begin(), sorted.end());
        s.maximumMs = sorted.back(); s.minimumFPS = 1000 / sorted.back(); s.maximumFPS = 1000 / sorted.front();
        auto percentile = [&](double p) { return sorted[std::min(s.samples - 1, unsigned(std::ceil(s.samples * p)) - 1)]; };
        auto low = [&](unsigned denominator) {
            if (s.samples < denominator) return -1.0;
            const unsigned n = (s.samples + denominator - 1) / denominator;
            double tail = 0;
            for (unsigned i = s.samples - n; i < s.samples; ++i) tail += sorted[i];
            return 1000 * n / tail;
        };
        s.low1 = low(100); s.low01 = low(1000);
        if (s.samples >= 100) s.p99Ms = percentile(.99);
        if (s.samples >= 1000) s.p999Ms = percentile(.999);
        return s;
    }
};
} // namespace ios::pacing
