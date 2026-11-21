#!/usr/bin/env python3
"""Exercise production PSO descriptor equality and ready-only sharing with real Metal objects."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[2]
source=(ROOT/'runtime/src/gfx/metal_draw.mm').read_text()
def function(signature):
    start=source.index(signature);brace=source.index('{',start);depth=0
    for end in range(brace,len(source)):
        depth+=(source[end]=='{')-(source[end]=='}')
        if not depth:return source[start:end+1]
    raise AssertionError(signature)
start=source.index('using PipelineDescriptorKey =')
end=source.index('// Ambient-occlusion quirks',start)
production=source[start:end].replace('static uint64_t g_pipeline_reuse_hits = 0;','').replace('static std::atomic<uint64_t> g_pipeline_compile_submissions{0};','')
pipeline=function('static id<MTLRenderPipelineState> get_pipeline(')
assert '!rtFunction && !g_test_fail_compiles && function_reuse_enabled()' in pipeline
assert 'hash_bytes(&tf.color[i], 4, h)' in pipeline
assert pipeline.index('cache_record_pipeline(')<pipeline.index('reusable_pipeline(descriptorKey)')
assert 'remember_ready_pipeline(descriptorKey,p)' in pipeline
assert 'remember_ready_pipeline(descriptorKey,pl->state)' in pipeline
harness=r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <vector>
''' + function('static uint64_t hash_bytes(') + '\n' + production + r'''
static MTLRenderPipelineDescriptor* descriptor(id<MTLFunction> vertex,id<MTLFunction> fragment) {
    auto d=[MTLRenderPipelineDescriptor new];d.vertexFunction=vertex;d.fragmentFunction=fragment;
    d.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
    return d;
}
int main() { @autoreleasepool {
    auto device=MTLCreateSystemDefaultDevice();if(!device)return 77;
    NSError* error=nil;
    auto lib=[device newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 v(uint i [[vertex_id]]) { return float4(float2((i<<1)&2,i&2)*2-1,0,1); }\nfragment float4 f() { return float4(1,0,0,1); }" options:nil error:&error];
    assert(lib);auto vertex=[lib newFunctionWithName:@"v"],fragment=[lib newFunctionWithName:@"f"];
    auto d=descriptor(vertex,fragment);auto key=pipeline_descriptor_key(device,d);
    auto same=descriptor(vertex,fragment);assert(d!=same && pipeline_descriptor_key(device,same)==key);
    assert(!reusable_pipeline(key));remember_ready_pipeline(key,nil);assert(!reusable_pipeline(key));
    auto state=[device newRenderPipelineStateWithDescriptor:d error:&error];assert(state);
    remember_ready_pipeline(key,state);assert(reusable_pipeline(pipeline_descriptor_key(device,same))==state);
    MTLRenderPipelineDescriptor* different=[d copy];different.fragmentFunction=nil;
    assert(pipeline_descriptor_key(device,different)!=key);
    for(int slot=0;slot<8;++slot) {
        different=[d copy];different.colorAttachments[slot].blendingEnabled=YES;
        auto other=pipeline_descriptor_key(device,different);assert(other!=key && !reusable_pipeline(other));
        different=[d copy];different.colorAttachments[slot].writeMask=MTLColorWriteMaskNone;
        assert(pipeline_descriptor_key(device,different)!=key);
    }
    different=[d copy];different.colorAttachments[0].sourceRGBBlendFactor=MTLBlendFactorSourceAlpha;
    assert(pipeline_descriptor_key(device,different)!=key);
    different=[d copy];different.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
    assert(pipeline_descriptor_key(device,different)!=key);
    different=[d copy];different.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;
    assert(pipeline_descriptor_key(device,different)!=key);
    different=[d copy];different.stencilAttachmentPixelFormat=MTLPixelFormatStencil8;
    assert(pipeline_descriptor_key(device,different)!=key);
    different=[d copy];different.rasterSampleCount=4;
    assert(pipeline_descriptor_key(device,different)!=key);
    different=[d copy];different.vertexDescriptor=[MTLVertexDescriptor vertexDescriptor];
    auto vertexKey=pipeline_descriptor_key(device,different);
    for(int loc=0;loc<31;++loc) {
      for(int field=0;field<6;++field) {
        MTLRenderPipelineDescriptor* copy=[different copy];copy.vertexDescriptor=[different.vertexDescriptor copy];
        switch(field) {
        case 0:copy.vertexDescriptor.attributes[loc].format=MTLVertexFormatFloat3;break;
        case 1:copy.vertexDescriptor.attributes[loc].offset=16;break;
        case 2:copy.vertexDescriptor.attributes[loc].bufferIndex=2;break;
        case 3:copy.vertexDescriptor.layouts[loc].stride=32;break;
        case 4:copy.vertexDescriptor.layouts[loc].stepFunction=MTLVertexStepFunctionPerInstance;break;
        case 5:copy.vertexDescriptor.layouts[loc].stepRate=2;break;
        }
        assert(pipeline_descriptor_key(device,copy)!=vertexKey);
      }
    }
    // Hash collisions must still compare the full serialized descriptor.
    struct Collision { size_t operator()(const PipelineDescriptorKey&)const{return 0;} };
    std::unordered_map<PipelineDescriptorKey,int,Collision> collisions;
    different.colorAttachments[0].blendingEnabled=YES;
    auto blendKey=pipeline_descriptor_key(device,different);assert(blendKey!=key);
    collisions.emplace(key,1);collisions.emplace(blendKey,2);
    assert(collisions.size()==2 && collisions.at(key)==1 && collisions.at(blendKey)==2);
    puts("Metal PSO descriptor separation, collision equality and ready-only reuse passed");
} }
'''
with tempfile.TemporaryDirectory(prefix='wwhd-pipeline-reuse-') as temp:
    cpp,exe=Path(temp)/'test.mm',Path(temp)/'test';cpp.write_text(harness)
    subprocess.run(['xcrun','clang++','-std=c++17','-fobjc-arc','-Wall','-Wextra','-Werror',str(cpp),'-framework','Foundation','-framework','Metal','-o',str(exe)],check=True)
    subprocess.run([str(exe)],env=dict(os.environ,MTL_DEBUG_LAYER='1'),check=True)
