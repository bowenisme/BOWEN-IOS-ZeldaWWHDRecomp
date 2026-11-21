#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>
#include <cstring>
// Supply the instrumented fixture written by metal_rt_capture_test.cpp.
int main(int argc, char** argv) { @autoreleasepool {
    if(argc!=2)return 1;
    id<MTLDevice> d=MTLCreateSystemDefaultDevice(); if(!d)return 77;
    NSError* err=nil;
    NSString* src=[NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:&err];
    if(!src){fprintf(stderr,"source: %s\n",err.localizedDescription.UTF8String);return 1;}
    src=[src stringByAppendingString:@"\nfragment float4 capture_fs() { return float4(1); }\n"];
    MTLCompileOptions* options=[MTLCompileOptions new]; options.languageVersion=MTLLanguageVersion3_0;
    id<MTLLibrary> lib=[d newLibraryWithSource:src options:options error:&err];
    if(!lib){fprintf(stderr,"library: %s\n",err.localizedDescription.UTF8String);return 1;}
    MTLRenderPipelineDescriptor* pd=[MTLRenderPipelineDescriptor new];
    pd.vertexFunction=[lib newFunctionWithName:@"main0"]; pd.fragmentFunction=[lib newFunctionWithName:@"capture_fs"];
    pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> pipeline=[d newRenderPipelineStateWithDescriptor:pd error:&err];
    if(!pipeline){fprintf(stderr,"pipeline: %s\n",err.localizedDescription.UTF8String);return 1;}
    MTLTextureDescriptor* td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
    td.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> target=[d newTextureWithDescriptor:td];
    id<MTLBuffer> claims=[d newBufferWithLength:4225*4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> clips=[d newBufferWithLength:4225*16 options:MTLResourceStorageModeShared];
    memset(claims.contents,0,claims.length); memset(clips.contents,0xcd,clips.length);
    MTLRenderPassDescriptor* pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=target; pass.colorAttachments[0].loadAction=MTLLoadActionClear; pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLCommandQueue> queue=[d newCommandQueue]; id<MTLCommandBuffer> cmd=[queue commandBuffer];
    id<MTLRenderCommandEncoder> enc=[cmd renderCommandEncoderWithDescriptor:pass];
    const float identity[]={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};
    [enc setRenderPipelineState:pipeline]; [enc setVertexBytes:identity length:sizeof(identity) atIndex:0];
    [enc setVertexBuffer:claims offset:0 atIndex:29]; [enc setVertexBuffer:clips offset:0 atIndex:30];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [enc endEncoding]; [cmd commit]; [cmd waitUntilCompleted];
    if(cmd.status!=MTLCommandBufferStatusCompleted){fprintf(stderr,"GPU: %s\n",cmd.error.localizedDescription.UTF8String);return 1;}
    const uint32_t* c=(const uint32_t*)claims.contents; const float* p=(const float*)clips.contents;
    for(int i=0;i<3;++i)if(c[i]!=1||p[i*4]!=i||p[i*4+1]!=0||p[i*4+2]!=0||p[i*4+3]!=1)return 1;
    printf("Actual render VS clip writes/atomics: passed on %s\n",d.name.UTF8String);
} }
