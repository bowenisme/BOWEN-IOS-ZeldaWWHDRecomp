#!/usr/bin/env python3
"""Compile/run the production fast-forward state machine without CMake or a device."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile


runtime = Path(__file__).resolve().parents[1]
cxx = shlex.split(os.environ.get("CXX", "clang++"))
cc = shlex.split(os.environ.get("CC", "clang"))
flags = ["-std=c++20", "-Wall", "-Wextra", "-Werror", "-UNDEBUG",
         "-I" + str(runtime / "src"), "-I" + str(runtime / "include")]
env = {k: v for k, v in os.environ.items() if not k.startswith("WWHD_MOD_F")}


def run(args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


with tempfile.TemporaryDirectory(prefix="wwhd-fast-forward-") as temp:
    temp = Path(temp)
    clock = temp / "clock-test"
    run(cxx + flags + [runtime / "tools/fast_forward_test.cpp", "-o", clock])
    run([clock], env=env)
    plan = temp / "plan-test"
    run(cxx + flags + [runtime / "tools/fast_forward_plan_test.cpp", "-o", plan])
    run([plan], env=env)
    print("Opt-in runtime plan host-clock checks passed")
    identity = temp / "guest_addr_identity.o"
    run(cc + ["-I" + str(runtime / "include"), "-c", runtime / "src/guest_addr_identity.c", "-o", identity])
    for ios in (False, True):
        binary = temp / ("ios-test" if ios else "desktop-test")
        run(cxx + flags + (["-DWWHD_IOS"] if ios else []) + [
            runtime / "tools/fast_forward_runtime_test.cpp",
            runtime / "src/mods/fast_forward.cpp", runtime / "src/game_clock.cpp",
            identity, "-o", binary])
        run([binary], env=env)
        for rate, button, expected_rate, expected_button in (
                ("nan", "0x8000", "2", "0x40"),
                ("5", "0xffffffffffffffff", "2", "0x40")):
            startup = dict(env, WWHD_MOD_FAST_FORWARD="0", WWHD_MOD_FF_RATE=rate,
                           WWHD_MOD_FF_BUTTON=button, WWHD_MOD_FF_MUTE="1")
            run([binary, "--startup", "0", expected_rate, expected_button, "1", "0"], env=startup)
        for setting, expected in ((None, "0"), ("0", "0"), ("1", "1"),
                                  ("nan", "0"), ("-1", "0"), ("4294967296", "0")):
            startup = dict(env, WWHD_MOD_FAST_FORWARD="1", WWHD_MOD_FF_RATE="3",
                           WWHD_MOD_FF_BUTTON="0x20", WWHD_MOD_FF_MUTE="0")
            if setting is not None:
                startup["WWHD_MOD_FF_GLOBAL"] = setting
            run([binary, "--startup", "1", "3", "0x20", "0", expected], env=startup)
        print(("iOS" if ios else "Desktop") + " production fast-forward + startup checks passed")
