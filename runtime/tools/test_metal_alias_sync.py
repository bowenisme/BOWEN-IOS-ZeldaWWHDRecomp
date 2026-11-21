#!/usr/bin/env python3
"""Check that alternating format views don't invent writes or hide actual new content."""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / "runtime/src/gfx/metal_surfaces.mm").read_text()
start = source.index("static void mark_alias_synchronized(")
end = source.index("\n}", start) + 2
production = source[start:end]
assert "mark_alias_synchronized(s, newest, s->tex.mipmapLevelCount == newest->tex.mipmapLevelCount);" in source
header = (ROOT / "runtime/src/gfx/metal.h").read_text()
start = header.index("inline void mark_gpu_written(")
write = header[start:header.index("\n", start)]

harness = r'''
#include <cassert>
#include <cstdint>
struct Surface {
    bool gpuWritten = false;
    uint64_t writeSeq = 0, writtenBackSeq = 0;
};
uint64_t sequence = 0;
uint64_t next_write_seq() { return ++sequence; }
''' + write + "\n" + production + r'''
int main() {
    Surface linear, srgb, third;
    mark_gpu_written(&linear);
    mark_alias_synchronized(&srgb,&linear,true);
    assert(srgb.gpuWritten && srgb.writeSeq==linear.writeSeq && sequence==1);
    // The real adoption loop compares writeSeq to reject a view that is not newer.
    for (int i=0;i<100;++i) {
        if (srgb.writeSeq>linear.writeSeq) mark_alias_synchronized(&linear,&srgb,true);
        if (linear.writeSeq>srgb.writeSeq) mark_alias_synchronized(&srgb,&linear,true);
    }
    assert(sequence==1 && linear.writeSeq==srgb.writeSeq);
    mark_alias_synchronized(&third,&srgb,true);
    assert(third.writeSeq==1 && sequence==1);

    // A real render creates a new version; both stale aliases must see it.
    linear.writtenBackSeq=linear.writeSeq;
    mark_gpu_written(&srgb);
    assert(srgb.writeSeq>linear.writeSeq);
    mark_alias_synchronized(&linear,&srgb,true);
    mark_alias_synchronized(&third,&linear,true);
    assert(sequence==2 && linear.writeSeq==2 && third.writeSeq==2);
    assert(linear.writtenBackSeq!=linear.writeSeq); // readback must not be suppressed

    // Different mip counts only copy their common levels: preserve the previous conservative rule.
    mark_alias_synchronized(&third,&linear,false);
    assert(sequence==3 && third.gpuWritten && third.writeSeq>linear.writeSeq);
}
'''
with tempfile.TemporaryDirectory(prefix="wwhd-alias-sync-") as temp:
    cpp, exe = Path(temp) / "test.cpp", Path(temp) / "test"
    cpp.write_text(harness)
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                    str(cpp), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
print("Metal alias version regression passed")
