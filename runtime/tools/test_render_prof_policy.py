#!/usr/bin/env python3
"""Compile extracted render_prof production functions and check policy/accounting behavior."""
from __future__ import annotations

import os
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path


SOURCE = Path(__file__).resolve().parents[1] / "src" / "render_prof.cpp"


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


PRELUDE = r"""
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace perf {
unsigned render_frames = 0;
void render_frame() { ++render_frames; }
}

namespace rprof {
enum Phase : int { kShader, kDrawPhases = 11 };
enum Upload : int { kUpOther, kUpVertex, kUpIndex, kUpUbo, kUpUniformVars, kUpTexture, kUploadKinds };
enum Wait : int { kWaitGpu, kWaitAcquire, kWaitPresent, kWaits };
enum Sync : int { kSyncDrawDone, kSyncCopySurface, kSyncFlip, kSyncOther, kSyncs };
struct Window {
    uint64_t phaseNs[kDrawPhases]{};
    uint64_t waitNs[kWaits]{}, waitCount[kWaits]{};
    uint64_t idleNs = 0;
    uint64_t draws = 0, drawsSame = 0, drawsFast = 0, drawsOther = 0;
};
struct ShaderStats {
    uint64_t variants = 0, newPrograms = 0, unusedOnly = 0;
    std::map<std::string, uint64_t> groups;
};
Window W;
ShaderStats shaderStats;
uint64_t frameUpload[kUploadKinds]{};
std::array<std::vector<std::pair<uint64_t, uint64_t>>, kUploadKinds> reads;
std::vector<uint32_t> otherRegs(0x10000);
std::atomic<uint64_t> syncNs[kSyncs]{}, syncCount[kSyncs]{};
std::atomic<uint64_t> wbWalkNs{0}, wbWalks{0}, wbCount{0}, wbBytes{0}, wbReadNs{0};
uint64_t g_mark = 0;
int g_upload_kind = kUpOther;
uint32_t g_reg_dirty = 0;
bool enabled();
"""

FUNCTIONS = (
    "bool enabled()",
    "uint64_t now_ns()",
    "void mark_slow(Phase p)",
    "void add_upload(uint64_t bytes)",
    "void add_upload(Upload kind, uint64_t bytes)",
    "void guest_read_slow(Upload kind, uint32_t addr, uint64_t size)",
    "void add_wait(Wait w, uint64_t ns)",
    "void add_idle(uint64_t ns)",
    "void note_other_reg(uint32_t reg)",
    "void classify_draw()",
    "void shader_variant(bool newProgram, bool onlyUnusedUnits, const char* const* groups, int groupCount)",
    "void add_write_back(uint64_t walkNs, uint32_t surfaces, uint64_t bytes, uint64_t readNs)",
    "void add_sync(Sync site, uint64_t ns)",
    "static bool begin_profile_frame()",
)

MAIN = r"""
}

int main(int argc, char** argv) {
    using namespace rprof;
    const bool expected = argc > 1 && std::strcmp(argv[1], "1") == 0;
    if (enabled() != expected) return 1;
    if (argc < 3 || std::strcmp(argv[2], "counters") != 0) return 0;

    g_mark = 1;
    g_reg_dirty = 2;
    g_upload_kind = kUpVertex;
    mark_slow(kShader);
    add_upload(5);
    add_upload(kUpIndex, 7);
    guest_read_slow(kUpVertex, 0x100, 4);
    add_wait(kWaitGpu, 11);
    add_idle(13);
    note_other_reg(3);
    classify_draw();
    const char* groups[] = {"test"};
    shader_variant(true, true, groups, 1);
    add_write_back(3, 2, 4, 5);
    add_sync(kSyncFlip, 8);

    if (expected) {
        if (!W.phaseNs[kShader] || frameUpload[kUpVertex] != 5 || frameUpload[kUpIndex] != 7) return 2;
        if (reads[kUpVertex].size() != 1 || W.waitNs[kWaitGpu] != 11 || W.waitCount[kWaitGpu] != 1) return 3;
        if (W.idleNs != 13 || otherRegs[3] != 1 || W.draws != 1 || W.drawsOther != 1) return 4;
        if (shaderStats.variants != 1 || shaderStats.newPrograms != 1 || shaderStats.unusedOnly != 1 ||
            shaderStats.groups["test"] != 1) return 5;
        if (wbWalkNs.load() != 3 || wbWalks.load() != 1 || wbCount.load() != 2 ||
            wbBytes.load() != 4 || wbReadNs.load() != 5) return 6;
        if (syncNs[kSyncFlip].load() != 8 || syncCount[kSyncFlip].load() != 1) return 7;
    } else {
        if (now_ns() != 0 || W.phaseNs[kShader] || g_mark != 1) return 8;
        if (frameUpload[kUpVertex] || frameUpload[kUpIndex] || !reads[kUpVertex].empty()) return 9;
        if (W.waitNs[kWaitGpu] || W.waitCount[kWaitGpu] || W.idleNs) return 10;
        if (otherRegs[3] || W.draws || W.drawsSame || W.drawsFast || W.drawsOther || g_reg_dirty != 2) return 11;
        if (shaderStats.variants || shaderStats.newPrograms || shaderStats.unusedOnly || !shaderStats.groups.empty()) return 12;
        if (wbWalkNs.load() || wbWalks.load() || wbCount.load() || wbBytes.load() || wbReadNs.load()) return 13;
        if (syncNs[kSyncFlip].load() || syncCount[kSyncFlip].load()) return 14;
    }

    const bool collected = begin_profile_frame();
    if (perf::render_frames != 1 || collected != expected) return 15;
    return 0;
}
"""


def main() -> None:
    source = SOURCE.read_text(encoding="utf-8")
    extracted = "\n".join(function(source, signature) for signature in FUNCTIONS)
    frame_end = function(source, "void frame_end(bool hold)")
    if frame_end.index("begin_profile_frame()") > frame_end.index("if (!profile) return;"):
        raise AssertionError("the independent performance sampler must run before the profiler gate")
    if frame_end.index("if (!profile) return;") > frame_end.index("g_track_unique = (++frameCounter % 16) == 0;"):
        raise AssertionError("disabled profiling must return before enabling unique guest-read tracking")

    compiler = shlex.split(os.environ.get("CXX", ""))
    if not compiler:
        candidate = shutil.which("clang++") or shutil.which("c++")
        if not candidate:
            raise RuntimeError("a C++ compiler (clang++ or c++) is required")
        compiler = [candidate]

    with tempfile.TemporaryDirectory(prefix="render-prof-policy-") as directory:
        harness = Path(directory) / "policy.cpp"
        harness.write_text(PRELUDE + extracted + MAIN, encoding="utf-8")
        for platform, define in (("ios", "-DWWHD_IOS=1"), ("desktop", None)):
            binary = Path(directory) / f"policy-{platform}"
            command = [*compiler, "-std=c++17", "-O0", str(harness), "-o", str(binary)]
            if define:
                command.insert(len(compiler) + 2, define)
            subprocess.run(command, check=True)
            cases = ((None, platform == "desktop"), ("0", False), ("1", True))
            for setting, expected in cases:
                env = os.environ.copy()
                env.pop("WWHD_PROFILE", None)
                if setting is not None:
                    env["WWHD_PROFILE"] = setting
                subprocess.run([str(binary), "1" if expected else "0"], env=env, check=True)
            env = os.environ.copy()
            env["WWHD_PROFILE"] = "0"
            subprocess.run([str(binary), "0", "counters"], env=env, check=True)
            env["WWHD_PROFILE"] = "1"
            subprocess.run([str(binary), "1", "counters"], env=env, check=True)

    print("render_prof policy and disabled-accounting checks passed (iOS, desktop)")


if __name__ == "__main__":
    main()
