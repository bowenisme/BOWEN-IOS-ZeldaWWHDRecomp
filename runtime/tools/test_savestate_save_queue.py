#!/usr/bin/env python3
"""Exercise the production save-request queue across interleavings and concurrent callers."""
from pathlib import Path
import os
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
program = r'''
#include "savestate_save_queue.h"
#include <atomic>
#include <cassert>
#include <string>
#include <thread>
#include <vector>

using ss::save_request::Kind;
using ss::save_request::Queue;

void auto_then_manual() {
    Queue q;
    bool ui_saving = true;
    int manual_calls = 0;
    std::string why;
    assert(q.submit(101, Kind::Full, {}, why));
    auto automatic = q.current();
    assert(automatic && automatic->slot == 101);
    q.wait_for_completion(automatic->id);
    assert(!q.current()); // a full snapshot already dispatched to its writer must not be captured again
    std::thread submit([&] {
        assert(q.submit(1, Kind::Full, [&](bool ok, const std::string& error) {
            ++manual_calls;
            assert(ok && error.empty());
            assert(q.outstanding() == 0); // completion callback runs after the queue lock is released
            ui_saving = false;
        }, why));
    });
    submit.join();
    assert(q.outstanding() == 2 && manual_calls == 0 && ui_saving);
    assert(q.complete(automatic->id, true, ""));
    auto manual = q.current();
    assert(manual && manual->slot == 1 && manual->kind == Kind::Full);
    q.wait_for_completion(manual->id);
    assert(q.complete(manual->id, true, ""));
    assert(!q.complete(manual->id, true, ""));
    assert(manual_calls == 1 && !ui_saving && q.outstanding() == 0);
}

void manual_then_auto() {
    Queue q;
    int manual_calls = 0;
    std::string why;
    assert(q.submit(2, Kind::Full, [&](bool ok, const std::string&) {
        ++manual_calls;
        assert(ok && q.outstanding() == 1);
    }, why));
    auto manual = q.current();
    assert(manual && manual->slot == 2);
    q.wait_for_completion(manual->id);
    assert(q.submit(102, Kind::Full, {}, why));
    assert(!q.current());
    assert(q.complete(manual->id, true, ""));
    assert(manual_calls == 1);
    auto automatic = q.current();
    assert(automatic && automatic->slot == 102);
    q.wait_for_completion(automatic->id);
    assert(q.complete(automatic->id, true, ""));
    assert(q.outstanding() == 0);
}

void manual_during_save_and_ui_release() {
    Queue q;
    bool ui_saving = false;
    int first = 0, second = 0;
    std::string why;
    assert(q.submit(1, Kind::Full, [&](bool ok, const std::string&) {
        ++first; assert(ok);
    }, why));
    auto active = q.current();
    assert(active && active->slot == 1);
    q.wait_for_completion(active->id);
    ui_saving = true;
    assert(q.submit(5, Kind::Full, [&](bool ok, const std::string& error) {
        ++second; assert(ok && error.empty());
        assert(q.outstanding() == 0);
        ui_saving = false;
    }, why));
    assert(q.complete(active->id, true, ""));
    assert(first == 1 && second == 0 && ui_saving);
    auto queued = q.current();
    assert(queued && queued->slot == 5);
    q.wait_for_completion(queued->id);
    std::thread writer([&] { assert(q.complete(queued->id, true, "")); });
    writer.join();
    assert(second == 1 && !ui_saving && q.outstanding() == 0);
}

void bounded_rejection_and_reentry() {
    Queue q;
    std::string why;
    for (int slot = 1; slot <= 4; ++slot)
        assert(q.submit(slot, Kind::Full, {}, why));
    int rejected = 0;
    bool ui_saving = true;
    assert(!q.submit(5, Kind::Full, [&](bool ok, const std::string& error) {
        ++rejected; assert(!ok && error == "another save is pending");
        assert(q.outstanding() == Queue::kMaxOutstanding);
        ui_saving = false;
    }, why));
    assert(rejected == 1 && !ui_saving && why == "another save is pending");

    auto first = q.current();
    assert(first && first->slot == 1);
    bool reentered = false;
    // A completion callback can submit a new request without re-entering the queue lock.
    Queue reentrant;
    assert(reentrant.submit(7, Kind::Full, [&](bool ok, const std::string&) {
        assert(ok && reentrant.outstanding() == 0);
        std::string nested_why;
        reentered = reentrant.submit(8, Kind::Portable, {}, nested_why);
    }, why));
    auto current = reentrant.current();
    assert(current);
    reentrant.wait_for_completion(current->id);
    assert(reentrant.complete(current->id, true, ""));
    auto next = reentrant.current();
    assert(reentered && next && next->slot == 8 && next->kind == Kind::Portable);
    assert(reentrant.complete(next->id, true, ""));
}

void writer_completes_before_service_marks_it_in_flight() {
    Queue q;
    std::string why;
    int completed = 0;
    assert(q.submit(1, Kind::Full, [&](bool ok, const std::string&) { assert(ok); ++completed; }, why));
    auto first = q.current();
    assert(first && first->slot == 1);
    assert(q.submit(2, Kind::Full, {}, why));
    assert(q.complete(first->id, true, "")); // background writer wins the race
    q.wait_for_completion(first->id);         // service's stale mark must not affect the new request
    auto next = q.current();
    assert(completed == 1 && next && next->slot == 2);
    q.wait_for_completion(next->id);
    assert(q.complete(next->id, true, ""));
}

void simultaneous_producers() {
    Queue q;
    std::atomic<int> ready{0};
    std::atomic<bool> go{false};
    int callbacks = 0;
    int completing_slot = 0;
    auto producer = [&](int slot) {
        ++ready;
        while (!go.load()) std::this_thread::yield();
        std::string why;
        assert(q.submit(slot, Kind::Full, [&, slot](bool ok, const std::string&) {
            assert(ok); ++callbacks;
            assert(slot == completing_slot);
            assert(q.outstanding() <= 1);
        }, why));
    };
    std::thread a(producer, 3), b(producer, 4);
    while (ready.load() != 2) std::this_thread::yield();
    go = true;
    a.join(); b.join();
    assert(q.outstanding() == 2);
    for (int i = 0; i < 2; ++i) {
        auto current = q.current();
        assert(current && (current->slot == 3 || current->slot == 4));
        completing_slot = current->slot;
        q.wait_for_completion(current->id);
        assert(q.complete(current->id, true, ""));
    }
    assert(callbacks == 2 && q.outstanding() == 0);
}

int main() {
    auto_then_manual();
    manual_then_auto();
    manual_during_save_and_ui_release();
    bounded_rejection_and_reentry();
    writer_completes_before_service_marks_it_in_flight();
    simultaneous_producers();
}
'''

savestate = (root / "src/savestate.cpp").read_text()
assert '#include "savestate_save_queue.h"' in savestate
assert "save_request::Queue g_save_requests;" in savestate
assert "if (const auto save = g_save_requests.current())" in savestate
assert "do_save(save->slot, save->id)" in savestate
assert "g_save_requests.wait_for_completion(save->id)" in savestate
assert "do_portable_save(c, save->slot, save->id)" in savestate
assert "std::atomic<int> g_save_req{0};" not in savestate and "int g_done_slot" not in savestate

with tempfile.TemporaryDirectory(prefix="wwhd-save-queue-") as temp:
    cpp, exe = Path(temp) / "queue.cpp", Path(temp) / "queue"
    cpp.write_text(program)
    subprocess.run(shlex.split(os.environ.get("CXX", "clang++")) + [
        "-std=c++20", "-Wall", "-Wextra", "-Werror", "-UNDEBUG", "-pthread",
        "-I", str(root / "src"), str(cpp), "-o", str(exe)
    ], check=True)
    subprocess.run([str(exe)], check=True, timeout=10)
print("PASS: auto/manual ordering, queued manual completion and UI release, bounded rejection, callback re-entry, and concurrent producers")
