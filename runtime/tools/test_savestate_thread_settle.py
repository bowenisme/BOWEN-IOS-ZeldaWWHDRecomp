#!/usr/bin/env python3
"""Save a thread section, then exercise restoration checks in a fresh host process."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="wwhd-thread-settle-") as temp:
    exe = Path(temp) / "test"
    state = Path(temp) / "threads.bin"
    strip = ["-Wl,-dead_strip"] if sys.platform == "darwin" else ["-Wl,--gc-sections", "-ldl"]
    cmd = shlex.split(os.environ.get("CXX", "clang++")) + [
        "-x", "c++", "-std=c++17", "-O1", "-g", "-fno-omit-frame-pointer", "-DWWHD_IOS",
        "-ffunction-sections", "-fdata-sections", "-pthread",
        "-I" + str(root / "runtime/include"), "-I" + str(root / "runtime/src"),
        str(root / "runtime/tools/savestate_thread_settle_test.cpp"),
        str(root / "runtime/src/guest_addr_identity.c"),
        *strip, "-o", str(exe),
    ]
    subprocess.run(cmd, check=True)
    for mode in ("capture", "load"):
        subprocess.run([str(exe), mode, str(state)], check=True, timeout=15)
