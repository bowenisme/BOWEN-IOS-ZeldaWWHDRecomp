#include "gfx/metal_rt_visible_math.h"
#include <cassert>
#include <cstdio>
using namespace gfx::ray_scene;
static float dot(F4 a,F4 b){return a.x*b.x+a.y*b.y+a.z*b.z+a.w*b.w;}
int main() {
    gfx::rt_capture::Sea sea;
    sea.projection={1.2f,0,0,0,0,1.8f,0,0,0,0,-1.00004f,-8,0,0,-1,0};
    sea.view={1,0,0,-100000,0,1,0,-50,0,0,1,-300000};sea.eye={100000,50,300000};
    for(bool half:{false,true}) {
        Params p;assert(parameters(sea,half,p));assert(p.eye.x==100000 && p.view[2].w==-300000);
        for(float distance:{10.f,100.f,1000.f,10000.f,40000.f}) {
            F4 v{distance*.15f,distance*-.1f,-distance,1};
            F4 c{dot(p.projection[0],v),dot(p.projection[1],v),dot(p.projection[2],v),dot(p.projection[3],v)};
            if(!half)c.z=(c.z+c.w)*.5f;
            F4 ndc{c.x/c.w,c.y/c.w,c.z/c.w,1};
            F4 q{dot(p.inverseProjection[0],ndc),dot(p.inverseProjection[1],ndc),dot(p.inverseProjection[2],ndc),dot(p.inverseProjection[3],ndc)};
            assert(q.w>0 && std::isfinite(q.w));
            F4 restored{q.x/q.w,q.y/q.w,q.z/q.w,1};
            assert(std::abs(restored.z-v.z)/distance<.005);
            F4 projected{dot(p.projection[0],restored),dot(p.projection[1],restored),dot(p.projection[2],restored),dot(p.projection[3],restored)};
            assert(std::abs(projected.x/projected.w-ndc.x)<1e-6 && std::abs(projected.y/projected.w-ndc.y)<1e-6);
            // Coordinates in the AS are relative to the camera, not NDC or 300000-unit world translations.
            assert(std::abs(restored.x)<10000 && std::abs(restored.z)<50000);
        }
    }
    sea.projection={};Params singular;assert(!parameters(sea,false,singular));
    namespace rr=gfx::ray_reflections;using S=rr::detail::RuntimeState;
    rr::detail::capability=true;rr::set_requested(true);rr::detail::effectActive=true;rr::detail::runtimeState=S::Running;
    assert(rr::available() && rr::requested() && rr::active());
    rr::detail::foreground=false;assert(!rr::active());rr::detail::foreground=true;
    rr::detail::runtimeState=S::FastForward;assert(!rr::active() && rr::status().find("快进")!=std::string::npos);
    rr::detail::runtimeState=S::InvalidData;assert(!rr::active());
    auto version=rr::detail::requestVersion.load();rr::set_requested(false);
    assert(!rr::active() && rr::detail::requestVersion.load()!=version);
    std::puts("Visible RT: camera-relative unprojection, both clip conventions, singular rejection and request/active/pause gates passed");
}
