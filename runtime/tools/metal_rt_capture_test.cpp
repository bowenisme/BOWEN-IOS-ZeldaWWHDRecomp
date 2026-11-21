#include "gfx/metal_rt_capture.h"
#include "gfx/ray_reflections.h"
#include <cassert>
#include <cstdio>
#include <fstream>
#include <limits>
using namespace gfx::rt_capture;
static void put_be(uint8_t* p, float f) {
    uint32_t u; std::memcpy(&u,&f,4);
    for (int i=0;i<4;++i) p[i]=uint8_t(u>>(24-8*i));
}
int main(int argc, char** argv) {
    namespace reflection = gfx::ray_reflections;
    assert(!reflection::requested() && !reflection::available() && !reflection::active());
    reflection::set_requested(true);
    assert(reflection::requested() && !reflection::available() && !reflection::active());
    reflection::detail::captureStage=reflection::detail::CaptureStage::Verified;
    assert(reflection::status().find("尚未接入")!=std::string::npos && !reflection::active());
    reflection::set_requested(false);
    const std::string verifiedSea="// shader 8d585a2172b7d624\nSET_POSITION(float4(R1f.x, R1f.y, R1f.z, R1f.w));";
    std::array<float,40> actualSupport{1,0,0,0,0,1,0,0,0,0,1,0,
        1,0,0,10,0,1,0,20,0,0,1,30, 2,0,0,0,0,3,0,0,0,0,-1.01f,-6,0,0,-1,0};
    Sea extracted;
    assert(sea_transform(verifiedSea,actualSupport.data(),sizeof(actualSupport),extracted));
    assert(extracted.pv[0]==2 && extracted.pv[3]==20 && extracted.pv[7]==60 && extracted.pv[15]==-30);
    assert(extracted.eye[0]==-10 && extracted.eye[1]==-20 && extracted.eye[2]==-30);
    assert(!sea_transform("different shader",actualSupport.data(),sizeof(actualSupport),extracted));
    assert(!sea_transform(verifiedSea,actualSupport.data(),20,extracted));
    actualSupport[0]=2;
    assert(!sea_transform(verifiedSea,actualSupport.data(),sizeof(actualSupport),extracted));
    actualSupport[0]=1; actualSupport[12]=NAN;
    assert(!sea_transform(verifiedSea,actualSupport.data(),sizeof(actualSupport),extracted));
    setenv("WWHD_RT_CAPTURE","1",1);
    Sea s; s.vb=0x1234; s.bytes.resize(vb_bytes);
    s.pv={2,0,0,3, 0,3,0,-2, 0,0,4,1, 0,0,0,1};
    for (uint32_t i=0;i<vertices;++i) {
        put_be(s.bytes.data()+i*stride,float(i%65));
        put_be(s.bytes.data()+i*stride+4,float(i%7));
        put_be(s.bytes.data()+i*stride+8,-float(i/65));
    }
    std::vector<uint32_t> claim(vertices);
    std::vector<float> clip(vertices*4);
    for (bool halfZ:{true,false}) {
        std::array<double,16> inv;
        assert(inverse(s.pv,halfZ,inv));
        for (uint32_t i=0;i<40;++i) {
            claim[i]=1; auto p=project(s,i,halfZ);
            for(int j=0;j<4;++j)clip[4*i+j]=float(p[j]);
            double recovered[4]{};
            for(int r=0;r<4;++r)for(int c=0;c<4;++c) recovered[r]+=inv[r*4+c]*p[c];
            assert(std::abs(recovered[0]-double(i%65))<1e-8);
            assert(std::abs(recovered[1]-double(i%7))<1e-8);
            assert(std::abs(recovered[3]-1)<1e-8);
        }
        auto v=validate_clip(s,claim.data(),clip.data(),halfZ);
        assert(v.checked==40 && v.bad==0);
        float saved=clip[0]; clip[0]+=1;
        assert(validate_clip(s,claim.data(),clip.data(),halfZ).bad==1);
        clip[0]=std::numeric_limits<float>::quiet_NaN();
        assert(validate_clip(s,claim.data(),clip.data(),halfZ).bad==1);
        clip[0]=saved;
    }
    std::array<double,16> inverseOut;
    std::array<float,16> zero{}; assert(!inverse(zero,true,inverseOut));
    auto nan=s.pv; nan[4]=NAN; assert(!inverse(nan,true,inverseOut));
    std::array<uint8_t,80> ubo{};
    for(int i=0;i<16;++i)put_be(ubo.data()+8+4*i,s.pv[i]);
    assert(contains_matrix(ubo.data(),ubo.size(),s.pv));
    std::vector<uint32_t> triangles;
    std::vector<float> rasterDepth(256*256,.4f);
    for(uint32_t y=0;y<65;++y)for(uint32_t x=0;x<65;++x) {
        uint32_t i=y*65+x; claim[i]=1;
        clip[4*i]=-.9f+1.8f*x/64; clip[4*i+1]=-.9f+1.8f*y/64;
        clip[4*i+2]=.4f; clip[4*i+3]=1;
        if(x<64 && y<64)triangles.insert(triangles.end(),{i,i+1,i+65,i+1,i+66,i+65});
    }
    auto depthCheck=[&] { return validate_depth(triangles,false,claim.data(),clip.data(),rasterDepth.data(),
        256,256,{0,0,256,256,0,1},{0,0,256,256},.000002); };
    auto depthGood=depthCheck(); assert(depthGood.passed && depthGood.matched>1000);
    std::fill(rasterDepth.begin(),rasterDepth.end(),.7f); assert(!depthCheck().passed);
    std::fill(rasterDepth.begin(),rasterDepth.end(),1); assert(depthCheck().tested==0);
    std::fill(rasterDepth.begin(),rasterDepth.end(),.4f); std::fill(claim.begin(),claim.end(),0);
    assert(depthCheck().tested==0);
    put_be(ubo.data()+8,99); assert(!contains_matrix(ubo.data(),ubo.size(),s.pv));
    for(int i=0;i<16;++i){ float f=s.pv[4*(i%4)+i/4]; std::memcpy(ubo.data()+8+4*i,&f,4); }
    assert(contains_matrix(ubo.data(),ubo.size(),s.pv));
    publish(s);
    assert(match(s.vb,s.bytes.data(),s.bytes.size()));
    assert(!match(s.vb+4,s.bytes.data(),s.bytes.size()));
    auto corrupt=s.bytes; corrupt[17]^=1;
    assert(!match(s.vb,corrupt.data(),corrupt.size()));
    for(uint32_t i=0;i<12;++i){ s.vb=100+i; publish(s); }
    assert(recent.size()==8 && !match(100,s.bytes.data(),s.bytes.size()));
    std::string source=R"MSL(#include <metal_stdlib>
using namespace metal;
struct VertexOut { float4 position [[position]]; };
vertex VertexOut main0(uint vid [[vertex_id]], uint iid [[instance_id]], constant float4x4& m [[buffer(0)]]) {
    VertexOut out; out.position=m*float4(float(vid),0,0,1); return out;
}
)MSL";
    auto invalid=source; invalid.insert(0,"// [[buffer(30)]]\n"); assert(!instrument(invalid));
    invalid="vertex void main0() {}"; assert(!instrument(invalid));
    assert(instrument(source)); assert(source.find("atomic_exchange_explicit")!=std::string::npos);
    if(argc==2)std::ofstream(argv[1])<<source;
    finished=true; assert(!match(s.vb,s.bytes.data(),s.bytes.size()));
    std::puts("RT capture: inverse, clip/depth rejection, endian/transpose, exact VB pairing, bounded history and VS instrumentation passed");
}
