#!/usr/bin/env python3
"""Run the actual portable-load request bodies with the instant-state master off and on."""
from pathlib import Path
import os
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "src/savestate.cpp").read_text()


def function_body(marker: str) -> str:
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 0
    for at in range(brace, len(source)):
        if source[at] == "{":
            depth += 1
        elif source[at] == "}":
            depth -= 1
            if depth == 0:
                return source[start:at + 1]
    raise AssertionError(marker)


portable = function_body("void request_load_portable_file(const std::string& path)")
manual = function_body("void request_load(int slot)")
program = r'''
#include <cassert>
#include <atomic>
#include <cstdarg>
#include <cstddef>
#include <cstdio>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
namespace pstate {
constexpr const char* kExtension=".wwstate";
struct State { std::string runtime; int guest_mods=0; };
}
namespace build { const char* version() { return "test"; } const char* commit() { return "abc"; } }
namespace guestmods {
constexpr const char* kModWarning="mods differ";
int enabled_mods() { return 0; }
bool different_mods(int,int) { return false; }
}
namespace ss {
constexpr int kSlots=5;
struct PendingPortable { std::shared_ptr<pstate::State> s; int slot=0; std::string path; };
std::atomic<bool> g_instant_states_enabled{true};
std::mutex g_mu;
PendingPortable g_pload;
int notices=0, reads=0;
bool portable_slot=true;
void LOG(const char*, ...) {}
void message(const char*, ...) { ++notices; }
std::string slot_path(int slot,const char*) { return "slot"+std::to_string(slot)+".wwstate"; }
bool newer_is_portable(int) { return portable_slot; }
bool read_portable(const std::string&,pstate::State& state,std::string&) {
    ++reads; state.runtime="test (abc)"; return true;
}
bool reject_disabled_manual_state(const std::function<void(bool,const std::string&)>& done) {
    if(g_instant_states_enabled.load())return false;
    constexpr char reason[]="instant saves are disabled";
    message("%s",reason); if(done)done(false,reason); return true;
}
void request_load_full(int,std::nullptr_t) {}
''' + portable + "\n" + manual + r'''
}
int main() {
    ss::request_load(1);
    assert(ss::reads==1 && ss::notices==0);
    assert(ss::g_pload.s && ss::g_pload.slot==1 && ss::g_pload.path=="slot1.wwstate");
    ss::g_instant_states_enabled=false;
    ss::request_load(1); // slot API delegates to the portable file API, so refusal is reported once
    assert(ss::reads==1 && ss::notices==1);
    ss::request_load_portable_file("external.wwstate");
    assert(ss::reads==1 && ss::notices==2); // direct public portable path is also gated before reading
    ss::portable_slot=false;
    ss::request_load(1); // full slot API retains its separate backend gate
    assert(ss::reads==1 && ss::notices==2);
}
'''

with tempfile.TemporaryDirectory(prefix="wwhd-portable-load-gate-") as temp:
    cpp, exe = Path(temp) / "gate.cpp", Path(temp) / "gate"
    cpp.write_text(program)
    subprocess.run(shlex.split(os.environ.get("CXX", "clang++")) + [
        "-std=c++20", "-Wall", "-Wextra", "-Werror", "-UNDEBUG", str(cpp), "-o", str(exe)
    ], check=True)
    subprocess.run([str(exe)], check=True)
print("PASS: portable slot and direct-file loads honor the manual instant-state gate once before reading")
