#include "platform/ios/display_policy.h"
#include "platform/ios/touch_layout.h"
#include "platform/touch_buttons.h"
#include <cassert>
#include <cstdio>
#include <limits>

int main() {
    for (auto [width,height]:{std::pair{1334.f,750.f}, {2556.f,1179.f}, {2796.f,1290.f},
                              {2420.f,1668.f}, {2732.f,2048.f}}) {
        const float aspect=width/height;
        const float scale=ios::display::native_scale(width,height,aspect);
        assert(ios::display::render_scale(false,width,height,aspect)==1);
        assert(ios::display::render_scale(true,width,height,aspect)==scale);
        const float up=ios::display::upscale_scale(width,height,aspect);
        assert(up>=1 && up<=scale);
        assert(std::abs(up-std::max(1.f,scale*.8f))<.0001f);
        for(int preset=0;preset<ios::display::kUpscalePresetCount;++preset) {
            const float ratio=ios::display::upscale_ratio(preset);
            const float candidate=ios::display::upscale_scale(width,height,aspect,ratio);
            assert(candidate>=1 && candidate<=scale);
            assert(std::abs(candidate-std::max(1.f,scale*ratio))<.0001f);
            assert(ios::display::upscale_preset_for_ratio(ratio)==preset);
            assert(ios::display::upscale_percent(ios::display::upscale_preset_for_ratio(
                ios::display::saved_upscale_ratio(ios::display::upscale_percent(preset),-1)))==
                ios::display::upscale_percent(preset));
        }
        assert(std::abs(std::max(1280.f,720.f*aspect)*scale-width)<.01f);
        assert(std::abs(std::max(720.f,1280.f/aspect)*scale-height)<.01f);
    }
    // A custom game aspect fits the drawable without allocating a larger target to shrink again.
    const float scale=ios::display::native_scale(2556,1179,21.f/9);
    assert(std::abs(1680*scale-2556)<.01f && 720*scale<=1179);
    assert(ios::display::upscale_ratio(-1)==.8f && ios::display::upscale_ratio(ios::display::kUpscalePresetCount)==.8f);
    assert(ios::display::legacy_upscale_ratio(0)==.75f && ios::display::legacy_upscale_ratio(1)==.8f &&
        ios::display::legacy_upscale_ratio(2)==.85f);
    assert(ios::display::saved_upscale_ratio(-1,0)==.75f && ios::display::saved_upscale_ratio(-1,1)==.8f &&
        ios::display::saved_upscale_ratio(-1,2)==.85f &&
        std::abs(ios::display::saved_upscale_ratio(85,1)-.85f)<.0001f);
    assert(ios::display::upscale_scale(2420,1668,2420.f/1668,std::numeric_limits<float>::quiet_NaN())==
        ios::display::upscale_scale(2420,1668,2420.f/1668));
    assert(ios::display::native_scale(0,0,1)==1);
    assert(ios::display::upscale_scale(0,0,1)==1);
    assert(ios::display::upscale_scale(1000,600,1000.f/600)==1);
    assert(std::abs(ios::display::upscale_scale(2420,1668,2420.f/1668)-1.5125f)<.0001f);
    assert(ios::display::native_scale(100,100,0)==1);
    assert(ios::display::native_scale(std::numeric_limits<float>::infinity(),100,1)==1);
    // View shape and pixel density are independent, including fixed-16:9 letterboxing on tablets.
    assert(ios::display::render_scale(false,2420,1668,16.f/9)==1);
    assert(ios::display::render_scale(false,2420,1668,2420.f/1668)==1);
    assert(ios::display::render_scale(true,2420,1668,16.f/9)>1);
    assert(ios::display::render_scale(true,2420,1668,2420.f/1668)>1);
    assert(ios::display::render_scale(true,1000,600,1000.f/600)==1);
    for (auto [width,height]:{std::pair{568.f,320.f},{568.f,400.f},{667.f,375.f},{724.f,369.f},
                              {812.f,375.f},{1024.f,748.f},{1194.f,810.f},{1366.f,1000.f}}) {
        const auto controls=ios::touch::layout(width,height);
        assert(controls.controls.size()==11);
        uint32_t buttons=0;
        for (size_t i=0;i<8;++i) {
            const auto& c=controls.controls[i];
            assert(c.x-c.radius>=0 && c.y-c.radius>=0);
            assert(c.x+c.radius<=width && c.y+c.radius<=height);
            assert(c.radius>=22); // at least a 44-point touch target
            assert(ios::touch::hit(c,c.x,c.y));
            buttons|=c.button;
            for(size_t j=i+1;j<8;++j) {
                const auto& other=controls.controls[j];
                assert(std::hypot(c.x-other.x,c.y-other.y)>=c.radius+other.radius);
            }
        }
        assert(controls.controls[9].kind==ios::touch::Kind::MoveZone);
        assert(controls.controls[10].kind==ios::touch::Kind::LookZone);
        assert(buttons==(input::kA|input::kB|input::kX|input::kY|input::kR|
            input::kZL|input::kZR|input::kPlus));
    }
    float x,y;
    ios::touch::stick(0,0,40,x,y); assert(x==0&&y==0);
    ios::touch::stick(40,0,40,x,y); assert(std::abs(x-1)<1e-6f&&y==0);
    ios::touch::stick(400,-400,40,x,y); assert(x>0&&y>0&&std::abs(std::hypot(x,y)-1)<1e-6f);
    input::PadState pad{},touch{};
    pad.buttons=input::kB; pad.rx=.4; touch.buttons=input::kA; touch.lx=1;
    ios::touch::merge(pad,touch);
    assert(pad.buttons==(input::kA|input::kB)&&pad.lx==1&&pad.rx==.4f);
    ios::touch::merge(pad,{}); assert(pad.lx==1&&pad.rx==.4f);
    assert(touch_buttons::visible(touch_buttons::Automatic,false,false));
    assert(!touch_buttons::visible(touch_buttons::Automatic,true,false));
    assert(touch_buttons::visible(touch_buttons::AlwaysShow,true,false));
    assert(!touch_buttons::visible(touch_buttons::Hide,false,false));
    std::puts("ios_portability_test: resolution, layout, sticks, merging and visibility passed");
}
