#!/usr/bin/env python3
"""Extract and exercise the production Metal function-reuse guards."""

from pathlib import Path
import os
import shlex
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "runtime/src/gfx/metal_draw.mm"


def function(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for end in range(brace, len(source)):
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
            if depth == 0:
                return source[start : end + 1]
    raise ValueError(f"unterminated production function: {signature}")


source = SOURCE.read_text(encoding="utf-8")
production = "\n".join(
    function(source, signature)
    for signature in ("static bool function_reuse_matches(", "static bool function_reuse_enabled(")
)

harness = r"""
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <unordered_map>
enum { CS_PENDING, CS_READY, CS_FAILED };
""" + production + r"""

int main() {
    constexpr uint64_t options = 0x1234;
    assert(function_reuse_matches("same source", "same source", CS_READY, CS_READY, true, true,
                                  options, options, false));

    // Force unequal sources into the same hash bucket; full source comparison must reject the collision.
    std::unordered_multimap<uint64_t, const char*> bucket;
    bucket.emplace(7, "different source");
    bool reusedCollision = false;
    auto [first, last] = bucket.equal_range(7);
    for (auto it = first; it != last; ++it)
        reusedCollision |= function_reuse_matches(it->second, "same source", CS_READY, CS_READY,
                                                   true, true, options, options, false);
    assert(!reusedCollision);

    assert(!function_reuse_matches("same source", "same source", CS_PENDING, CS_READY, true, true,
                                   options, options, false));
    assert(!function_reuse_matches("same source", "same source", CS_FAILED, CS_READY, true, true,
                                   options, options, false));
    assert(!function_reuse_matches("same source", "same source", CS_READY, CS_READY, true, false,
                                   options, options, false));
    assert(!function_reuse_matches("same source", "same source", CS_READY, CS_READY, true, true,
                                   options, options + 1, false));
    assert(!function_reuse_matches("same source", "same source", CS_READY, CS_READY, true, true,
                                   options, options, true));

    unsetenv("WWHD_METAL_FUNCTION_REUSE");
    unsetenv("WWHD_TEST_FAIL_COMPILES");
    unsetenv("WWHD_MSL_NONCE");
#if TARGET_OS_IPHONE
    assert(function_reuse_enabled());
#else
    assert(!function_reuse_enabled());
#endif
    setenv("WWHD_METAL_FUNCTION_REUSE", "0", 1);
    assert(!function_reuse_enabled());
    setenv("WWHD_METAL_FUNCTION_REUSE", "1", 1);
    assert(function_reuse_enabled());
    unsetenv("WWHD_METAL_FUNCTION_REUSE");
    setenv("WWHD_TEST_FAIL_COMPILES", "0", 1);
    assert(!function_reuse_enabled());
    unsetenv("WWHD_TEST_FAIL_COMPILES");
    setenv("WWHD_MSL_NONCE", "probe", 1);
    assert(!function_reuse_enabled());
}
"""


compiler = shlex.split(os.environ.get("CXX", ""))
if not compiler:
    compiler = [shutil.which("c++") or shutil.which("clang++") or "c++"]

with tempfile.TemporaryDirectory(prefix="metal-function-reuse-") as temp:
    cpp = Path(temp) / "test.cpp"
    exe = Path(temp) / "test"
    cpp.write_text(harness, encoding="utf-8")
    subprocess.run(compiler + ["-std=c++17", "-Wall", "-Wextra", "-Werror", str(cpp), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)

print("Metal function-reuse production guards passed")
