// Offline replay of real device VS/support/VB data; never reports offscreen data as depth verified.
#include "gfx/metal_rt_capture.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
using namespace gfx::rt_capture;
template<class T> static std::vector<T> load(const std::string& path) {
    std::ifstream file(path,std::ios::binary|std::ios::ate);
    if(!file)throw std::runtime_error("missing capture file: "+path);
    auto size=file.tellg();
    if(size<0 || size%sizeof(T))throw std::runtime_error("invalid file size: "+path);
    std::vector<T> values(size_t(size)/sizeof(T)); file.seekg(0);
    if(!file.read(reinterpret_cast<char*>(values.data()),size))throw std::runtime_error("read failed: "+path);
    return values;
}
int main(int argc,char** argv) {
    if(argc!=2)return 1;
    try {
        const std::string root=argv[1];
        Sea s; s.bytes=load<uint8_t>(root+"/sea-vb-be.bin");
        auto support=load<uint8_t>(root+"/vs-support.bin");
        auto sourceBytes=load<char>(root+"/vs-original.metal");
        auto claims=load<uint32_t>(root+"/claimed-u32-le.bin");
        auto clips=load<float>(root+"/actual-clip-f32-le.bin");
        auto indices=load<uint32_t>(root+"/indices-u32-le.bin");
        auto depth=load<float>(root+"/scene-depth-f32-le.bin");
        if(s.bytes.size()!=vb_bytes || claims.size()!=vertices || clips.size()!=vertices*4)return 1;
        const std::string source(sourceBytes.begin(),sourceBytes.end());
        if(!sea_transform(source,support.data(),support.size(),s))throw std::runtime_error("unverified VS/support layout");
        const bool halfZ=source.find("out.position.z = (out.position.z + out.position.w)")==std::string::npos;
        auto result=validate_clip(s,claims.data(),clips.data(),halfZ);
        bool clear=std::all_of(depth.begin(),depth.end(),[](float f){return f==1;});
        std::cout<<"{\"clip_checked\":"<<result.checked<<",\"clip_failed\":"<<result.bad
            <<",\"max_relative_error\":"<<result.max_relative_error<<",\"depth_all_clear\":"<<(clear?"true":"false")
            <<",\"visible_strip\":"<<(visible_strip(s,indices,0,halfZ)?"true":"false")<<",\"game_reflections\":false}\n";
        if(result.checked<32 || result.bad)return 1;
        // Negative controls: the actual M5 evidence must reject wrong transforms and changed inputs.
        s.pv[3]+=100;
        if(!validate_clip(s,claims.data(),clips.data(),halfZ).bad)return 1;
        Sea rejected;
        if(sea_transform("unknown shader",support.data(),support.size(),rejected))return 1;
        return 0;
    } catch(const std::exception& e) { std::cerr<<e.what()<<'\n'; return 1; }
}
