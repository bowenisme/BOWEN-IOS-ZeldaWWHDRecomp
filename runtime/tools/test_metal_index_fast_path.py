#!/usr/bin/env python3
"""Exercise the index fast-path safety gate without building the Metal app."""

from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
DRAW = (ROOT / "runtime/src/gfx/metal_draw.mm").read_text()
MAIN = (ROOT / "runtime/src/gfx/metal_main.mm").read_text()

assert 'getenv("WWHD_METAL_U16_INDEX")' in DRAW
assert 'setting && strcmp(setting, "1") == 0' in DRAW
assert 'getenv("WWHD_METAL_PATH_STATS")' in DRAW
assert 'getenv("WWHD_METAL_PATH_STATS")' in MAIN
assert "indexType:MTLIndexTypeUInt16" in DRAW
assert "Upload u = upload(mem::ptr(indexAddr), count * 2, true);" in DRAW
assert "g_invalidate_surface_visits.fetch_add" in MAIN
assert "g_u16_triangle_candidates" in DRAW

compiler = shutil.which("c++") or shutil.which("clang++")
assert compiler, "a host C++ compiler is required for this local safety test"

harness = r"""
#include "runtime/src/gfx/metal_index_fast_path.h"
using gfx::metal_index::direct_u16_triangle;
static_assert(direct_u16_triangle(4, 0, 0x1000, 3, true, false, false));
static_assert(direct_u16_triangle(4, 0, 0x1000, gfx::metal_index::kMaxDirectCount, true, false, false));
static_assert(!direct_u16_triangle(4, 0, 0x1000, gfx::metal_index::kMaxDirectCount + 1, true, false, false));
static_assert(!direct_u16_triangle(4, 0, 0, 3, true, false, false));
static_assert(!direct_u16_triangle(4, 0, 0x1000, 0, true, false, false));
static_assert(!direct_u16_triangle(5, 0, 0x1000, 3, true, false, false));
static_assert(!direct_u16_triangle(6, 0, 0x1000, 3, true, false, false));
static_assert(!direct_u16_triangle(4, 1, 0x1000, 3, true, false, false));
static_assert(!direct_u16_triangle(4, 4, 0x1000, 3, true, false, false));
static_assert(!direct_u16_triangle(4, 0, 0x1000, 3, false, false, false));
static_assert(!direct_u16_triangle(4, 0, 0x1000, 3, true, true, false));
static_assert(!direct_u16_triangle(4, 0, 0x1000, 3, true, false, true));
static_assert(!direct_u16_triangle(4, 0, 0x1000, 0x80000000u, true, false, false));
int main() {}
"""

with tempfile.TemporaryDirectory(prefix="metal-index-fast-path-") as temp:
    cpp = Path(temp) / "test.cpp"
    exe = Path(temp) / "test"
    cpp.write_text(harness)
    subprocess.run([compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", "-I", str(ROOT), str(cpp), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)

print("metal index fast-path safety test passed")
