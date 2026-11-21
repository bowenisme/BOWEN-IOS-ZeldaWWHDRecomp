#!/usr/bin/env python3
"""Exercise production iOS 30/60 FPS policy and action bodies without UIKit or a device."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1]/'src/platform/ios/controls.mm').read_text()
persist = source[source.index('static bool testing_controls'):source.index('static int backend_slot')]
policy = source[source.index('static NSInteger frame_segment'):source.index('static int target_fps')]

def action(name, next_name):
    body = source.split(f'- (void){name} {{', 1)[1].split(f'\n- (void){next_name}', 1)[0]
    body = body.replace('self.frameMode.selectedSegmentIndex','selection').replace('self.status.text','status')
    body = body.replace('self.rayReflections.on','switchOn').replace('[self refresh]','refresh()')
    body = body.replace('[self refreshDetails]','refreshDetails()').replace('@"','"')
    return f'void {name}() {{'+body+'\n'

stubs = r'''
#include <algorithm>
#include <cassert>
#include <map>
#include <string>
using NSInteger=long;
std::map<std::string,std::string> settings;
namespace hostui { void set(const char* key,const std::string& value) { settings[key]=value; } }
namespace interp {
int m=1,f=60;
int mode() { return m; } int fps() { return f; }
void set_mode(int value) { m=value; } void set_fps(int value) { f=value; }
}
namespace gfx::ray_reflections {
bool ready=false,request=false;
bool available() { return ready; } bool requested() { return request; }
void set_requested(bool value) { request=value; }
}
NSInteger selection=2;
bool switchOn=false;
std::string status;
int detailRefreshes=0;
'''
tests = r'''
void reset(bool available,bool requested,int mode=1,int fps=60) {
    gfx::ray_reflections::ready=available; gfx::ray_reflections::request=requested;
    interp::m=mode; interp::f=fps; selection=frame_segment(); settings.clear(); status.clear(); testing_controls=false;
}
int main() {
    // Legacy high FPS is shown as the 60 segment and normalized live, regardless of RT availability.
    for(bool ready:{false,true})for(bool requested:{false,true})for(int fps:{120,240}) {
        reset(ready,requested,1,fps);
        assert(frame_segment()==1&&enforce_frame_limit()&&interp::fps()==60&&interp::mode()==1&&settings.empty());
        assert(!enforce_frame_limit());
    }
    reset(true,true,0,120); assert(frame_segment()==0&&enforce_frame_limit());
    assert(interp::mode()==0&&interp::fps()==60&&settings.empty());
    reset(true,true,2,240); assert(frame_segment()==1&&enforce_frame_limit());
    assert(interp::mode()==2&&interp::fps()==60&&settings.empty());

    // Only 30/60 are selectable; even stale segment indices cannot request high FPS.
    reset(false,false);
    selection=0; frameChanged(); assert(interp::mode()==0&&selection==0&&interp::fps()==60);
    assert(settings.at("ios.frameMode")=="0"&&settings.at("ios.interpFps")=="60");
    selection=1; frameChanged(); assert(interp::mode()==1&&selection==1&&interp::fps()==60);
    selection=2; frameChanged(); assert(interp::mode()==1&&selection==1&&interp::fps()==60);

    // Test mode must not persist settings while exercising real actions.
    reset(true,false); testing_controls=true;
    selection=0; frameChanged(); selection=1; frameChanged();
    assert(interp::fps()==60&&settings.empty()&&detailRefreshes>0);

}

'''
with tempfile.TemporaryDirectory(prefix='wwhd-controls-rt-policy-') as temp:
    cpp, exe = Path(temp)/'test.cpp', Path(temp)/'test'
    cpp.write_text(stubs+persist+policy+
                   '\nvoid refresh() { enforce_frame_limit(); selection=frame_segment(); }\n'
                   'void refreshDetails() { ++detailRefreshes; }\n'+
                   action('frameChanged','qualityChanged')+tests)
    subprocess.run(shlex.split(os.environ.get('CXX','clang++'))+
                   ['-std=c++20','-Wall','-Wextra','-Werror','-UNDEBUG',str(cpp),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
assert 'rayReflectionsChanged' not in source and '光追反射（测试版）' not in source
print('PASS: production 30/60 actions, legacy FPS clamp, test persistence, removed RT controls')
