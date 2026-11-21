#!/usr/bin/env python3
"""Compile the real preview/slot-info/full-save-request bodies against temporary fixtures."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'src/savestate.cpp').read_text()
preview = source[source.index('std::string preview_stamp('):source.index('bool write_slot(')]
info = source[source.index('SlotInfo full_slot_info('):source.index('\nnamespace {\nSlotInfo portable_slot_info')]
request = source[source.index('void request_save_full(int slot,'):source.index('\nvoid request_save_portable')]
stubs = r'''
#include <atomic>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <functional>
#include <mutex>
#include <string>
#include <utility>
std::string dir;
constexpr int kSlots=5;
constexpr char kMagic[8]={'W','W','H','D','S','T','A','T'};
namespace save_request { enum class Kind { Full }; }
struct Header { char magic[8]; unsigned long long created; unsigned controller=1; char area[16]="sea"; };
struct SlotInfo {
    bool used=false,compatible=true,portable=false,thumbnail_linked=false;
    std::string path,when,controller,area,thumbnail_path;
};
std::string slot_path(int slot) { return dir+"/slot"+std::to_string(slot)+".bin"; }
bool is_auto(int) { return false; }
namespace host { bool replace_file(const std::string& a,const std::string& b) { return !rename(a.c_str(),b.c_str()); } }
bool read_header(FILE* f,Header& h,std::string&) { return fread(&h,sizeof h,1,f)==1&&!memcmp(h.magic,kMagic,8); }
std::string controller_label(unsigned) { return "GamePad"; }
std::string area_label(const char* a) { return a; }
std::mutex g_mu;
int queued_slot=0;
std::function<void(bool,const std::string&)> queued_done;
bool reject_disabled_manual_state(const std::function<void(bool,const std::string&)>&) { return false; }
bool enqueue_save(int slot,save_request::Kind,std::function<void(bool,const std::string&)> done,bool=false) {
    queued_slot=slot; queued_done=std::move(done); return true;
}
void fixture(int slot,unsigned long long created) {
    Header h{}; memcpy(h.magic,kMagic,8); h.created=created;
    std::ofstream out(slot_path(slot),std::ios::binary); out.write((const char*)&h,sizeof h);
}
'''
tests = r'''
int main(int argc,char** argv) {
    assert(argc==2); dir=argv[1];
    const auto empty=full_slot_info(1); assert(!empty.used&&!empty.thumbnail_linked);
    for(int slot:{1,2,5}) {
        fixture(slot,1700000000+slot*3600);
        auto old=full_slot_info(slot); assert(old.used&&old.compatible&&!old.when.empty()&&!old.thumbnail_linked);
        const std::string image=dir+"/slot"+std::to_string(slot)+".full.unique.png";
        write_preview_link(slot,image);
        auto pending=full_slot_info(slot);
        assert(pending.thumbnail_linked&&pending.thumbnail_path==image&&pending.when==old.when);
        assert(!std::filesystem::exists(image)); // snapshot and preview link can finish before the renderer
        std::ofstream(image)<<"PNG fixture";
        auto ready=full_slot_info(slot);
        assert(ready.thumbnail_path==image&&ready.when==old.when);
    }
    assert(full_slot_info(1).when!=full_slot_info(2).when);
    assert(full_slot_info(1).thumbnail_path!=full_slot_info(2).thumbnail_path);
    // Another save invalidates old metadata even if the old PNG remains on disk.
    const auto before=preview_stamp(slot_path(1));
    std::ofstream(slot_path(1),std::ios::binary|std::ios::app)<<"changed snapshot";
    assert(preview_stamp(slot_path(1))!=before&&!full_slot_info(1).thumbnail_linked);
    SlotInfo race; race.path=slot_path(1); read_preview_link(race,before); assert(!race.thumbnail_linked);
    // Imported malformed metadata cannot escape the slot directory.
    std::ofstream(slot_path(2)+".preview")<<preview_stamp(slot_path(2))<<"\n../other.png\n";
    assert(!full_slot_info(2).thumbnail_linked);
    std::ofstream(slot_path(2)+".preview")<<preview_stamp(slot_path(2))<<"\nslot5.full.unique.png\n";
    assert(!full_slot_info(2).thumbnail_linked); // copied metadata cannot select another slot's PNG
    // Explicit full-save dispatch never reads the portable/full preference or changes other files.
    bool called=false;
    request_save_full(0,[&](bool ok,const std::string& why) { called=true; assert(!ok&&why=="no such slot"); });
    assert(called&&queued_slot==0);
    request_save_full(2,[&](bool ok,const std::string&) { assert(ok); });
    assert(queued_slot==2&&queued_done);
    assert(g_mu.try_lock()); g_mu.unlock();
    queued_done(true,"");
    request_save_full(1); assert(queued_slot==1);
    assert(full_slot_info(5).thumbnail_linked); // old slot 5 fixture was never rewritten
}
'''
with tempfile.TemporaryDirectory(prefix='wwhd-slot-preview-') as temp:
    cpp, exe = Path(temp)/'test.cpp', Path(temp)/'test'
    cpp.write_text(stubs+preview+info+request+tests)
    subprocess.run(shlex.split(os.environ.get('CXX','clang++'))+
                   ['-std=c++20','-Wall','-Wextra','-Werror','-UNDEBUG',str(cpp),'-o',str(exe)],check=True)
    subprocess.run([str(exe),temp],check=True)
print('PASS: empty/legacy slots, file times, 1/2/5 preview pairing, async pending, stale/racing metadata, traversal refusal, explicit full-save callback')
