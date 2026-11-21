#!/usr/bin/env python3
"""Exercise the actual load/finish bodies with synthetic threads and restore hooks.

No guest executable, snapshot files, device, or runtime build is needed.
"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile


source = (Path(__file__).resolve().parents[1] / "src/savestate.cpp").read_text()
load = source[source.index("enum class LoadResult"):source.index("// ---------------------------------------------------------------- portable states")]
save_start = source.index('bool do_save(int slot, uint64_t request_id)')
save_guard_start = source.index('    if(!fs_ss_can_snapshot(why))',save_start)
save_guard = source[save_guard_start:source.index('    gx2_ss_drain();',save_guard_start)]
service = source[source.index("void service(Cpu* c)"):]
finish = service[service.index("    std::shared_ptr<Snapshot> s;"):service.index("\n}  // namespace ss")]

stubs = r'''
#include <atomic>
#include <cassert>
#include <chrono>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
void test_log(const char*, ...) {}
#define LOG(...) test_log(__VA_ARGS__)
enum { kSecThreads, kSecAllocs, kSecDispatch, kSecHeaps, kSecAudio, kSecGx2, kSecFiles };
struct Reader { unsigned u32() { return 0; } };
struct Snapshot {
    struct { char area[8] = {}; } h;
    int slot = 3;
    int guest_mods = 0;
    std::function<void(bool, const std::string&)> done;
    Reader section(int) const { return {}; }
};
bool freeze_ok = true, layout_ok_test = true, chains_ok = true;
bool settle_ok = false, settle_pending = false;
int settle_calls = 0;
bool live_files_safe=true,snapshot_files_safe=true;
int save_reports=0,captures=0;
int restores = 0, thaws = 0, callbacks = 0;
bool callback_ok = false;
std::string callback_why;
std::mutex g_mu;
std::shared_ptr<Snapshot> g_load_ready;
const Snapshot* g_check = nullptr;
std::atomic<bool> g_loading{false};
int g_attempts = 0;
std::atomic<unsigned long long> g_last_load_frame{11}, g_last_load_step{12};
std::atomic<unsigned> g_last_load_counter{13};
std::vector<std::string> dumps;
constexpr int dump = 2;
namespace mods { void fast_forward_reset() {} void lock_on_reset() {} }
namespace threads {
bool quiesce(int, std::string& why, int, int) { why = "synthetic busy"; return freeze_ok; }
void thaw() { ++thaws; if (settle_pending) { chains_ok = true; settle_pending = false; } }
}
bool fs_ss_can_snapshot(std::string& why) { if(!live_files_safe)why="game save in progress"; return live_files_safe; }
bool fs_ss_check(Reader,std::string& why) { if(!snapshot_files_safe)why="snapshot contains an unfinished game save"; return snapshot_files_safe; }
void report_done(int,bool ok,const std::string& why) { assert(!ok&&why=="game save in progress"); ++save_reports; }
void threads_ss_targets(Reader) {}
void gx2_ss_drain() {}
bool check_allocs(Reader, std::string& why) { why = "layout mismatch"; return layout_ok_test; }
bool check_dispatch(Reader, std::string&) { return true; }
bool mem_ss_check(Reader, std::string&) { return true; }
bool ax_ss_check(Reader, std::string&) { return true; }
bool gx2_ss_check(Reader, std::string&) { return true; }
bool threads_ss_check(Reader, std::string& why) { why = "chain mismatch"; return chains_ok; }
bool threads_ss_settle_offline(Reader) { ++settle_calls; settle_pending = settle_ok; return settle_ok; }
void restore_memory(const Snapshot&) { ++restores; }
namespace mem { void raise_runtime_top(unsigned) {} }
void mem_ss_load(Reader&) {} void fs_ss_load(Reader&) {} void ax_ss_load(Reader&) {}
void gx2_ss_load(Reader&) {} void threads_ss_load(Reader&) {}
namespace guestmods {
void state_loaded() {}
bool different_mods(int, int) { return false; }
int enabled_mods() { return 0; }
}
namespace interp { void ss_reset() {} unsigned long long logic_steps() { return 102; } }
namespace aspect { void ss_reset() {} }
namespace button_glyphs { void ss_reset() {} }
namespace rumble { void reset() {} }
namespace controller_reapply { void request(const char*) {} }
namespace render {
unsigned long long frame_count() { return 101; }
void request_tv_dump(const std::string& path, int) { dumps.push_back(path); }
}
unsigned GD(unsigned a) { return a; }
unsigned ld32(unsigned) { return 103; }
bool is_auto(int) { return false; }
std::string slot_label(int) { return "Slot 3"; }
std::string area_label(const char*) { return "sea"; }
void append_mod_warning(bool) {}
void message(const char*, ...) {}
'''
tests = r'''
void start() {
    g_load_ready = std::make_shared<Snapshot>();
    std::weak_ptr<Snapshot> old = g_load_ready;
    g_load_ready->done = [old](bool ok, const std::string& why) {
        ++callbacks; callback_ok = ok; callback_why = why;
        assert(old.expired()); // payload released before callback
        assert(!g_loading && !g_load_ready && g_attempts == 0);
        assert(g_mu.try_lock()); g_mu.unlock(); // callback outside the request mutex
    };
    g_loading = true;
}
void unchanged() {
    assert(g_last_load_frame == 11 && g_last_load_step == 12 && g_last_load_counter == 13);
    assert(restores == 0 && dumps.empty());
}
int main() {
    chains_ok = false; start();
    for (int i = 1; i < 30; ++i) {
        finish_service();
        assert(g_loading && g_load_ready && callbacks == 0 && g_attempts == i);
        unchanged();
    }
    finish_service(); // final chain refusal cleans up, without success effects
    assert(callbacks == 1 && !callback_ok && callback_why == "chain mismatch");
    unchanged(); assert(!g_loading && !g_load_ready && !g_check);
    finish_service(); assert(callbacks == 1); // exactly once

    freeze_ok = false; start();
    for (int i = 0; i < 30; ++i) finish_service();
    assert(callbacks == 2 && !callback_ok && callback_why == "game busy:synthetic busy");
    unchanged();

    freeze_ok = true; layout_ok_test = false; start(); finish_service();
    assert(callbacks == 3 && !callback_ok && callback_why == "layout mismatch");
    unchanged();

    assert(settle_calls == 29); // never settle after busy/layout refusal or on the last retry
    layout_ok_test = true; chains_ok = true; start(); finish_service();
    assert(callbacks == 4 && callback_ok && callback_why.empty());
    assert(restores == 1 && g_last_load_frame == 101 && g_last_load_step == 102 && g_last_load_counter == 103);
    assert(dumps.size() == 2 && !g_loading && !g_load_ready && !g_check);
    finish_service(); assert(callbacks == 4 && restores == 1);

    // A failed subsequent load preserves the last genuinely successful load markers.
    chains_ok = false; start();
    for (int i = 0; i < 30; ++i) finish_service();
    assert(callbacks == 5 && !callback_ok && restores == 1 && dumps.size() == 2);
    assert(g_last_load_frame == 101 && g_last_load_step == 102 && g_last_load_counter == 103);

    // Re-entrant callbacks may queue a new request; old cleanup must not erase it.
    chains_ok = true; start();
    g_load_ready->done = [](bool ok, const std::string&) { assert(ok); start(); };
    finish_service(); assert(g_loading && g_load_ready);
    finish_service(); assert(callbacks == 6 && callback_ok && !g_loading);
    const int restored=restores;
    live_files_safe=false; start();
    for(int i=0;i<29;++i) { finish_service(); assert(g_loading&&restores==restored); }
    finish_service(); assert(!g_loading&&!callback_ok&&callback_why=="game save in progress"&&restores==restored);
    live_files_safe=true; snapshot_files_safe=false; start(); finish_service();
    assert(!g_loading&&!callback_ok&&callback_why=="snapshot contains an unfinished game save"&&restores==restored);
    snapshot_files_safe=true;
    const int before_settle = settle_calls, before_restore = restores, before_callback = callbacks;
    chains_ok=false; settle_ok=true; start(); finish_service();
    assert(settle_calls==before_settle+1 && restores==before_restore && callbacks==before_callback);
    assert(g_loading && g_attempts==1); // enqueue/normal exit is not yet a successful restore
    finish_service();
    assert(restores==before_restore+1 && callbacks==before_callback+1 && callback_ok && !g_loading);
    settle_ok=false;
    live_files_safe=false; g_attempts=0;
    for(int i=0;i<29;++i)assert(!save_preflight());
    assert(save_preflight()&&save_reports==1&&captures==0);
    live_files_safe=true; g_attempts=0; assert(save_preflight()&&captures==1);
}
'''

with tempfile.TemporaryDirectory(prefix="wwhd-load-result-") as temp:
    cpp = Path(temp) / "test.cpp"
    exe = Path(temp) / "test"
    cpp.write_text(stubs + load + "\nbool save_preflight() { int slot=1; uint64_t request_id=1; std::string why;\n" + save_guard +
                   "\n++captures; return true; }\nvoid finish_service() {\n" + finish + tests)
    subprocess.run(shlex.split(os.environ.get("CXX", "clang++")) +
                   ["-std=c++20", "-Wall", "-Wextra", "-UNDEBUG", str(cpp), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
print("PASS: retry, busy/layout/chain refusal, success markers, dumps, callback lifetime and re-entry; live/save-snapshot writer refusal before restore/capture")
