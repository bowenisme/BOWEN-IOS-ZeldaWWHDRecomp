#!/usr/bin/env python3
"""Compile the production replay policy for mobile/desktop and guard the early exit."""
from pathlib import Path
import os
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "runtime/src/gfx/metal_draw.mm").read_text()
start = source.index("static bool replay_shader_recipes() {")
end = source.index("\n}", start) + 2
policy = source[start:end]
cache = source[source.index("static void cache_load() {"):]
guard = cache[:cache.index("    std::string path = cache_path();")]
assert "if (!replay_shader_recipes())" in guard
assert "g_cache_disabled = true;" in guard and "return;" in guard
assert cache.index("return;") < cache.index("fopen(") < cache.index("headstart_load();")
assert cache.index("return;") < cache.index('fopen(path.c_str(), "ab")')

compiler = shlex.split(os.environ.get("CXX", "c++"))
with tempfile.TemporaryDirectory(prefix="ios-cache-policy-") as folder:
    cpp = Path(folder) / "policy.cpp"
    exe = Path(folder) / "policy"
    cpp.write_text("#include <cassert>\n" + policy + "\nint main() {\n"
                   "#ifdef WWHD_IOS\nassert(!replay_shader_recipes());\n"
                   "#else\nassert(replay_shader_recipes());\n#endif\n}\n")
    for defines in ([], ["-DWWHD_IOS=1"]):
        subprocess.run(compiler + ["-std=c++17", "-Wall", "-Wextra", "-Werror"] + defines +
                       [str(cpp), "-o", str(exe)], check=True)
        subprocess.run([str(exe)], check=True)
print("PASS: iOS skips historical shader/PSO replay and recording; desktop policy unchanged")
