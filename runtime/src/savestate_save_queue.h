#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <new>
#include <optional>
#include <string>
#include <utility>

namespace ss::save_request {

enum class Kind { Full, Portable };

struct Current {
    uint64_t id;
    int slot;
    Kind kind;
};

class Queue {
public:
    static constexpr size_t kMaxOutstanding = 4;
    using Done = std::function<void(bool, const std::string&)>;

    bool submit(int slot, Kind kind, Done done, std::string& why) {
        try {
            {
                std::lock_guard<std::mutex> lock(mutex_);
                if (pending_.size() + (active_ ? 1u : 0u) < kMaxOutstanding) {
                    pending_.push_back({next_id_, slot, kind, done});
                    ++next_id_;
                    return true;
                }
                why = "another save is pending";
            }
        } catch (const std::bad_alloc&) {
            why = "not enough memory to queue save";
        }
        if (done) done(false, why);
        return false;
    }

    std::optional<Current> current() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!active_ && !pending_.empty()) {
            active_.emplace(std::move(pending_.front()));
            pending_.pop_front();
        }
        if (!active_ || active_->waiting_for_completion) return std::nullopt;
        return Current{active_->id, active_->slot, active_->kind};
    }

    void wait_for_completion(uint64_t id) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (active_ && active_->id == id) active_->waiting_for_completion = true;
    }

    bool complete(uint64_t id, bool ok, const std::string& why) {
        Done done;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!active_ || active_->id != id) return false;
            done = std::move(active_->done);
            active_.reset();
        }
        if (done) done(ok, why);
        return true;
    }

    size_t outstanding() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return pending_.size() + (active_ ? 1u : 0u);
    }

private:
    struct Request {
        uint64_t id;
        int slot;
        Kind kind;
        Done done;
        bool waiting_for_completion = false;
    };

    mutable std::mutex mutex_;
    std::deque<Request> pending_;
    std::optional<Request> active_;
    uint64_t next_id_ = 1;
};

}  // namespace ss::save_request
