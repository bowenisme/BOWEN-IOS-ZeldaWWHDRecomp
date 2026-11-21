#!/usr/bin/env python3
"""Exercise production encoder lifetime code with real Metal copies, draws and commits."""

from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / "runtime/src/gfx/metal_main.mm").read_text()


def function(text, signature):
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 0
    for end in range(brace, len(text)):
        depth += (text[end] == "{") - (text[end] == "}")
        if depth == 0:
            return text[start:end + 1]
    raise AssertionError(signature)


# Direct render entry points must also close a blit opened by a screenshot at swap time.
present = (ROOT / "runtime/src/gfx/metal_present.inc").read_text()
for signature in ("static void compose_tv(", "static void compose_drc(", "static void screenshot_screen("):
    body = function(present, signature)
    assert body.index("end_encoder();") < body.index("renderCommandEncoderWithDescriptor:")
assert "end_encoder();\n        ::mods::draw_overlay" in source

production = "\n".join(function(source, s) for s in (
    "void end_encoder()", "static bool encoder_stats_enabled()",
    "id<MTLBlitCommandEncoder> blit_encoder()", "void flush()", "void wait_idle()"))
surfaces = (ROOT / "runtime/src/gfx/metal_surfaces.mm").read_text()
production += "\n" + "\n".join(function(surfaces, s) for s in (
    "static void mark_alias_synchronized(", "static Surface* adopt_newer_alias("))

harness = r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unordered_map>
#include <vector>
namespace gfx {
enum class Convert { NONE };
struct Surface {
    id<MTLTexture> tex;
    uint32_t addr=0,format=0;
    bool formatViews=true,gpuWritten=false,isDepth=false;
    uint64_t writeSeq=0;
    struct { bool compressed=false; Convert convert=Convert::NONE; uint32_t hostBytesPerBlock=4; } fmt;
};
uint64_t version=0;
uint64_t next_write_seq() { return ++version; }
void mark_gpu_written(Surface* s) { s->gpuWritten=true; s->writeSeq=next_write_seq(); }
void rt_reflections_before_read(Surface*,const char*) {}
struct Renderer {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLCommandBuffer> cmd;
    id<MTLRenderCommandEncoder> enc;
    id<MTLBlitCommandEncoder> blit;
    void* passColor[8]{};
    void* passDepth = nullptr;
    bool binding=false;
    std::unordered_multimap<uint32_t,std::unique_ptr<Surface>> surfaces;
} R;
uint32_t g_draws_since_commit = 0;
uint64_t blitRequests = 0, blitPasses = 0;
void pool_retire(id<MTLCommandBuffer>) {}
void track_gpu_time(id<MTLCommandBuffer>) {}
id<MTLCommandBuffer> command_buffer() {
    if (!R.cmd) R.cmd = [R.queue commandBuffer];
    return R.cmd;
}
''' + production + r'''
}
using namespace gfx;
static void completed(id<MTLCommandBuffer> cmd) {
    [cmd waitUntilCompleted];
    if (cmd.status != MTLCommandBufferStatusCompleted) {
        fprintf(stderr,"Metal command failed: %s\n",cmd.error.description.UTF8String);
        abort();
    }
}
static id<MTLTexture> texture(bool srgb=false) {
    auto d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:srgb?MTLPixelFormatRGBA8Unorm_sRGB:MTLPixelFormatRGBA8Unorm
        width:4 height:4 mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;
    auto t = [R.device newTextureWithDescriptor:d];
    assert(t); return t;
}
static void begin_clear(id<MTLTexture> t) {
    end_encoder();
    auto p = [MTLRenderPassDescriptor renderPassDescriptor];
    p.colorAttachments[0].texture = t;
    p.colorAttachments[0].loadAction = MTLLoadActionClear;
    p.colorAttachments[0].storeAction = MTLStoreActionStore;
    p.colorAttachments[0].clearColor = MTLClearColorMake(1,0,0,1);
    R.enc = [command_buffer() renderCommandEncoderWithDescriptor:p];
    assert(R.enc);
}
static void read(id<MTLTexture> t, id<MTLBuffer> buffer) {
    [blit_encoder() copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(4,4,1) toBuffer:buffer destinationOffset:0
        destinationBytesPerRow:256 destinationBytesPerImage:1024];
}
int main() { @autoreleasepool {
    R.device = MTLCreateSystemDefaultDevice();
    if (!R.device) { puts("Metal device unavailable"); return 77; }
    R.queue = [R.device newCommandQueue];
    const bool batch = strcmp(getenv("WWHD_METAL_BLIT_BATCH"),"0") != 0;
    std::vector<unsigned char> pattern(4096);
    for (unsigned i=0;i<pattern.size();++i) pattern[i] = (i*19+7)&255;
    auto a = [R.device newBufferWithBytes:pattern.data() length:pattern.size() options:MTLResourceStorageModeShared];
    auto b = [R.device newBufferWithLength:pattern.size() options:MTLResourceStorageModePrivate];
    auto c = [R.device newBufferWithLength:pattern.size() options:MTLResourceStorageModeShared];
    assert(a && b && c);
    for (unsigned i=0;i<4;++i) {
        [blit_encoder() copyFromBuffer:a sourceOffset:i*1024 toBuffer:b destinationOffset:i*1024 size:1024];
        [blit_encoder() copyFromBuffer:b sourceOffset:i*1024 toBuffer:c destinationOffset:i*1024 size:1024];
    }
    assert(blitRequests==8 && blitPasses==(batch?1u:8u));
    auto first = R.cmd; flush();
    assert(!R.cmd && !R.enc && !R.blit); completed(first);
    assert(!memcmp(c.contents,pattern.data(),pattern.size()));

    // Upload -> alias copy -> scan copy -> readback share a pass, including dependent resources.
    auto t1=texture(), t2=texture(), t3=texture();
    auto out=[R.device newBufferWithLength:1024 options:MTLResourceStorageModeShared];
    [blit_encoder() copyFromBuffer:a sourceOffset:0 sourceBytesPerRow:256 sourceBytesPerImage:1024
        sourceSize:MTLSizeMake(4,4,1) toTexture:t1 destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0,0,0)];
    for (auto pair : {std::pair<id<MTLTexture>,id<MTLTexture>>{t1,t2},{t2,t3}})
        [blit_encoder() copyFromTexture:pair.first sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(4,4,1) toTexture:pair.second destinationSlice:0 destinationLevel:0
            destinationOrigin:MTLOriginMake(0,0,0)];
    read(t3,out); wait_idle();
    assert(!R.cmd && !R.blit);
    for (unsigned y=0;y<4;++y) assert(!memcmp((char*)out.contents+y*256,pattern.data()+y*256,16));

    // Call the real alias candidate loop: equal content must not ping-pong copies or versions.
    auto linear=std::make_unique<Surface>(), srgb=std::make_unique<Surface>();
    linear->tex=t1; srgb->tex=texture(true);
    linear->addr=srgb->addr=0x1000; linear->format=0x1A; srgb->format=0x41A;
    Surface* lin=linear.get(); Surface* rgb=srgb.get();
    R.surfaces.emplace(0x1000,std::move(linear)); R.surfaces.emplace(0x1000,std::move(srgb));
    mark_gpu_written(lin);
    auto requests=blitRequests;
    adopt_newer_alias(rgb);
    assert(blitRequests==requests+1 && version==1);
    for(int i=0;i<100;++i) { adopt_newer_alias(lin); adopt_newer_alias(rgb); }
    assert(blitRequests==requests+1 && version==1);
    read(rgb->tex,out); wait_idle();
    for(unsigned y=0;y<4;++y) assert(!memcmp((char*)out.contents+y*256,pattern.data()+y*256,16));
    begin_clear(lin->tex); mark_gpu_written(lin);
    requests=blitRequests;
    adopt_newer_alias(rgb);
    for(int i=0;i<100;++i) { adopt_newer_alias(lin); adopt_newer_alias(rgb); }
    assert(blitRequests==requests+1 && version==2);
    read(rgb->tex,out); wait_idle();
    for(unsigned y=0;y<4;++y) for(unsigned x=0;x<4;++x) {
        auto* pixel=(unsigned char*)out.contents+y*256+x*4;
        assert(pixel[0]==255 && pixel[1]==0 && pixel[2]==0 && pixel[3]==255);
    }

    // A render boundary must close copies before starting the render, then close the render for readback.
    [blit_encoder() copyFromBuffer:a sourceOffset:0 toBuffer:b destinationOffset:0 size:256];
    begin_clear(t3); assert(!R.blit && R.enc);
    g_draws_since_commit=256;
    auto beforeChunk=R.cmd;
    read(t3,out); // end_encoder commits the full render chunk before opening this blit.
    assert(!R.enc && R.blit && R.cmd!=beforeChunk);
    completed(beforeChunk); wait_idle();
    auto* bytes=(unsigned char*)out.contents;
    for(unsigned y=0;y<4;++y) for(unsigned x=0;x<4;++x) {
        auto* pixel=bytes+y*256+x*4;
        assert(pixel[0]==255 && pixel[1]==0 && pixel[2]==0 && pixel[3]==255);
    }
    g_draws_since_commit=0;

    // Empty/compute/flush boundaries, also used by screenshots and MetalFX preparation.
    end_encoder(); end_encoder();
    [blit_encoder() copyFromBuffer:a sourceOffset:0 toBuffer:c destinationOffset:0 size:256];
    end_encoder();
    auto compute=[command_buffer() computeCommandEncoder]; assert(compute); [compute endEncoding];
    auto last=R.cmd; flush(); completed(last);
    printf("Metal blit batch=%d passed: %llu requests, %llu encoders\n",batch,
        (unsigned long long)blitRequests,(unsigned long long)blitPasses);
} }
'''

with tempfile.TemporaryDirectory(prefix="wwhd-metal-blit-") as temp:
    cpp, exe = Path(temp) / "test.mm", Path(temp) / "test"
    cpp.write_text(harness)
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
                    str(cpp), "-framework", "Foundation", "-framework", "Metal", "-o", str(exe)], check=True)
    for batch in ("0", "1"):
        env = dict(os.environ, WWHD_METAL_BLIT_BATCH=batch, WWHD_METAL_ENCODER_STATS="1", MTL_DEBUG_LAYER="1")
        subprocess.run([str(exe)], env=env, check=True)
