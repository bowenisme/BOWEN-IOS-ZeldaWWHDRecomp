#!/usr/bin/env python3
"""Compile and exercise the production cache-safety predicate without building the app."""

from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "runtime/src/gfx/metal_draw.mm"
text = SOURCE.read_text()

match = re.search(
    r"static bool prepared_texture_cacheable\(Surface\* s, Surface\* const\* colors, Surface\* depth\) \{.*?\n\}",
    text,
    re.S,
)
assert match, "production cache-safety predicate not found"
assert "prepared_texture_cacheable(s, colors, depth)" in text
assert "preparedValid[unit] ? prepared[unit] : sampled_texture(tw, dec->textureUsesDepthCompare[unit])" in text
assert "sh->dec->textureRenderTargetIndex[unit] == 255" in text

compiler = shutil.which("c++") or shutil.which("clang++")
assert compiler, "a host C++ compiler is required for this small extraction test"

harness = r"""
#include <cassert>
struct Surface { unsigned addr, mipAddr, mips; };
""" + match.group(0) + r"""
int main() {
    Surface color{0x1000, 0x4000, 1}, depth{0x2000, 0, 1};
    Surface* targets[8] = {&color};
    Surface ordinary{0x3000, 0, 1};
    Surface sameAddress{0x1000, 0, 1};
    Surface mipChain{0x5000, 0, 4};
    Surface mipAlias{0x6000, 0x1000, 1};
    Surface depthAlias{0x2000, 0, 1};
    assert(prepared_texture_cacheable(&ordinary, targets, &depth));
    assert(!prepared_texture_cacheable(nullptr, targets, &depth));
    assert(!prepared_texture_cacheable(&color, targets, &depth));
    assert(!prepared_texture_cacheable(&sameAddress, targets, &depth));
    assert(!prepared_texture_cacheable(&mipChain, targets, &depth));
    assert(!prepared_texture_cacheable(&mipAlias, targets, &depth));
    assert(!prepared_texture_cacheable(&depthAlias, targets, &depth));
    Surface* noColors[8] = {};
    assert(prepared_texture_cacheable(&ordinary, noColors, nullptr));
}
"""

with tempfile.TemporaryDirectory(prefix="metal-prepared-textures-") as temp:
    cpp = Path(temp) / "test.cpp"
    exe = Path(temp) / "test"
    cpp.write_text(harness)
    subprocess.run([compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", str(cpp), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)

print("metal prepared texture extraction test passed")
