#!/usr/bin/env python3
"""Exercise the actual manual instant-state gate helper and audit every public slot route."""
from pathlib import Path
import os
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "src/savestate.cpp").read_text()
header = (root / "src/savestate.h").read_text()


def function_body(text: str, marker: str) -> str:
    start = text.index(marker)
    brace = text.index("{", start)
    depth = 0
    for at in range(brace, len(text)):
        if text[at] == "{":
            depth += 1
        elif text[at] == "}":
            depth -= 1
            if depth == 0:
                return text[start:at + 1]
    raise AssertionError(f"unterminated function: {marker}")


gate = function_body(source, "bool reject_disabled_manual_state(")
auto_save = function_body(source, "bool request_auto_save(int index)")
auto_load = function_body(source, "void request_auto_load(int index)")
routes = [
    "void request_save_full(int slot, std::function<void(bool, const std::string&)> done)",
    "void request_save_full(int slot)",
    "void request_save_portable(int slot)",
    "void request_save(int slot, std::function<void(bool ok, const std::string& why)> done)",
    "void request_load_full(int slot, std::function<void(bool, const std::string&)> done)",
]
for route in routes:
    body = function_body(source, route)
    assert "slot < 1 || slot > kSlots" in body or "request_load_full_impl(slot,std::move(done),false)" in body, route
    if "request_load_full(int slot" in route:
        assert "request_load_full_impl(slot,std::move(done),false)" in body
    else:
        assert "reject_disabled_manual_state(" in body, route
assert "!automatic && reject_disabled_manual_state(done)" in function_body(source, "static void request_load_full_impl(")
portable_load = function_body(source, "void request_load_portable_file(const std::string& path)")
assert "if (reject_disabled_manual_state({})) return;" in portable_load
manual_load = function_body(source, "void request_load(int slot)")
assert "request_load_portable_file(slot_path(slot, pstate::kExtension))" in manual_load
assert "request_load_full(slot, nullptr)" in manual_load
assert "bool instant_states_enabled()" in header and "void set_instant_states_enabled(bool on)" in header
assert "ordinary game saves" in header and "automatic crash-recovery" in header
assert "internal" in header and "manual slot APIs reject 101..103" in header
crashrec = (root / "src/crashrec.cpp").read_text()
assert "ss::internal::request_auto_save(g_next)" in crashrec
assert "ss::internal::request_auto_load(g_replay)" in crashrec
assert "request_load_full_impl(crashrec::kAutoBase+index,{},true)" in auto_load
assert "unlink(" not in gate and "remove(" not in gate and "filesystem" not in gate

program = r'''
#include <atomic>
#include <cassert>
#include <cstdarg>
#include <cstdio>
#include <functional>
#include <string>
namespace ss {
std::atomic<bool> g_instant_states_enabled{true};
int notices = 0;
void message(const char*, ...) { ++notices; }
namespace save_request { enum class Kind { Full }; }
int queued_slot=0, queue_calls=0;
bool queue_accept=true;
bool enqueue_save(int slot, save_request::Kind, std::function<void(bool,const std::string&)>, bool=false) {
    ++queue_calls; queued_slot=slot; return queue_accept;
}
namespace crashrec { constexpr int kAutoBase=100, kAutoSlots=3; }
''' + gate + r'''
int auto_load_slot=0, auto_load_calls=0;
bool auto_load_flag=false;
void request_load_full_impl(int slot, std::function<void(bool, const std::string&)>, bool automatic) {
    ++auto_load_calls; auto_load_slot=slot; auto_load_flag=automatic;
}
namespace internal {
''' + auto_save + r'''
''' + auto_load + r'''
}
}
int main() {
    int callbacks = 0;
    bool result = ss::reject_disabled_manual_state([&](bool ok, const std::string&) {
        ++callbacks; assert(ok);
    });
    assert(!result && callbacks == 0 && ss::notices == 0); // old default remains enabled

    ss::g_instant_states_enabled = false;
    std::string saved_reason;
    result = ss::reject_disabled_manual_state([&](bool ok, const std::string& why) {
        ++callbacks; assert(!ok); saved_reason = why;
    });
    assert(result && callbacks == 1 && saved_reason == "instant saves are disabled" && ss::notices == 1);
    result = ss::reject_disabled_manual_state({});
    assert(result && callbacks == 1 && ss::notices == 2); // fire-and-forget route is also rejected
    assert(ss::internal::request_auto_save(2));
    assert(ss::queued_slot == 102 && ss::queue_calls == 1 && callbacks == 1 && ss::notices == 2);
    assert(!ss::internal::request_auto_save(4) && ss::queue_calls == 1);
    ss::queue_accept=false;
    assert(!ss::internal::request_auto_save(3) && ss::queue_calls == 2); // crashrec can retry a busy enqueue
    ss::internal::request_auto_load(3);
    assert(ss::auto_load_calls == 1 && ss::auto_load_slot == 103 && ss::auto_load_flag);
    ss::internal::request_auto_load(0);
    assert(ss::auto_load_calls == 1); // no user/manual slot can be passed as an auto index
    ss::g_instant_states_enabled = true;
    result = ss::reject_disabled_manual_state([&](bool ok, const std::string&) { ++callbacks; assert(ok); });
    assert(!result && callbacks == 1 && ss::notices == 2);
}
'''

with tempfile.TemporaryDirectory(prefix="wwhd-instant-state-gate-") as temp:
    cpp = Path(temp) / "gate.cpp"
    exe = Path(temp) / "gate"
    cpp.write_text(program)
    subprocess.run(shlex.split(os.environ.get("CXX", "clang++")) +
                   ["-std=c++20", "-Wall", "-Wextra", "-UNDEBUG", str(cpp), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
print("PASS: enabled/disabled request gate, exactly-once refusal callback, bounded crashrec auto enqueue, and manual full/portable routes guarded")
