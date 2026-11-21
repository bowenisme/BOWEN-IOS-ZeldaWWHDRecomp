#!/usr/bin/env python3
"""Run the actual fs_ss_load body against throwaway original-save fixtures, never user saves."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root/'src/hle/fs.cpp').read_text()
restore = source[source.index('namespace {\n// Compare resolved host paths'):source.index('void fs_ss_save(ss::Writer& w)')] + source[source.index('void fs_ss_load(ss::Reader& r)'):]
header = (root/'src/savestate.h').read_text()
serialization = header[header.index('struct Writer {'):header.index('// ---- UI / test API')]
stubs = r'''
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <mutex>
#include <string>
#include <sys/stat.h>
#include <type_traits>
#include <unordered_map>
#include <vector>
namespace ss {
'''+serialization+r'''
}
void log_msg(const char*,...) {}
#define LOG(...) log_msg(__VA_ARGS__)
struct OpenFile { FILE* f; std::string path,mode; uint64_t limit=UINT64_MAX; bool story=false; std::string host; };
struct OpenDir { DIR* d; std::string path,gpath; uint32_t read=0; };
std::mutex g_fs_mutex;
std::unordered_map<uint32_t,OpenFile> g_files;
std::unordered_map<uint32_t,OpenDir> g_dirs;
uint32_t g_next_handle=1;
std::string fixture_dir;
namespace config { std::string save_dir; }
std::string host_path(const std::string& gp) {
    if(gp.rfind("/vol/save/",0)==0)return config::save_dir+gp.substr(9);
    return fixture_dir+"/content/"+std::filesystem::path(gp).filename().string();
}
std::string read_path(const std::string& gp,const std::string&) { return host_path(gp); }
namespace host { int file_seek(FILE* f,uint64_t offset,int origin) { return fseek(f,static_cast<long>(offset),origin); } }
namespace story_store {
bool is_save_file(const std::string& gp) { return gp.find("cking.sav")!=std::string::npos; }
uint64_t game_size(const std::string&,uint64_t size) { return size; }
}
std::string bytes(const std::string& path) {
    std::ifstream in(path,std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(in),{});
}
'''
tests = r'''
int main(int argc,char** argv) {
    assert(argc==2); fixture_dir=argv[1]; config::save_dir=fixture_dir+"/save";
    std::filesystem::create_directories(config::save_dir+"/user");
    std::filesystem::create_directories(fixture_dir+"/content");
    const std::string gp="/vol/save/user/cking.sav", backup="/vol/save/user/cking.sav.backup";
    const std::string data("original\0save\xff" "bytes",19), backup_data="independent backup bytes";
    std::ofstream(host_path(gp),std::ios::binary).write(data.data(),data.size());
    std::ofstream(host_path(backup),std::ios::binary)<<backup_data;
    auto section=[](const std::string& path,const std::string& mode) {
        ss::Writer w; w.u32(200); w.u32(1); w.u32(1); w.str(path); w.str(mode); w.u64(4); w.u32(0); return w;
    };
    std::string why;
    for(const auto& mode:{"w","wb","w+","a","ab","a+","r+","rb"}) {
        const bool writer=std::string(mode).find_first_of("wa+")!=std::string::npos;
        auto w=section(gp,mode); auto copy=w.b;
        assert(fs_ss_check(ss::Reader(w.b.data(),w.b.size()),why)==!writer);
        if(writer)assert(why=="snapshot contains an unfinished game save");
        assert(w.b==copy&&bytes(host_path(gp))==data&&bytes(host_path(backup))==backup_data);
        FILE* handle=fopen(host_path(gp).c_str(),"r+b"); assert(handle);
        g_files[1]={handle,gp,mode,UINT64_MAX,true,host_path(gp)};
        assert(fs_ss_can_snapshot(why)==!writer);
        if(writer)assert(why=="game save in progress");
        fclose(handle); g_files.clear();
        assert(fs_ss_can_snapshot(why));
    }
    config::save_dir+="/";
    assert(game_save_writer(host_path(gp),"r+")); // a configured trailing slash must not disable protection
    config::save_dir.pop_back();
    // Only host files inside the original save volume are guarded; content/MOD writers stay valid.
    auto mod=section("/vol/content/mod-data.bin","wb");
    assert(fs_ss_check(ss::Reader(mod.b.data(),mod.b.size()),why));
    auto sibling=section("/vol/save/../save-other/mod-data.bin","wb");
    assert(fs_ss_check(ss::Reader(sibling.b.data(),sibling.b.size()),why));
    auto missing=section("/vol/save/user/missing.sav","wb");
    assert(!fs_ss_check(ss::Reader(missing.b.data(),missing.b.size()),why));
    assert(!std::filesystem::exists(host_path("/vol/save/user/missing.sav")));
    // A content alias pointing at an original save is protected too.
    std::filesystem::create_symlink(host_path(gp),host_path("/vol/content/save-alias.bin"));
    auto alias=section("/vol/content/save-alias.bin","r+");
    assert(!fs_ss_check(ss::Reader(alias.b.data(),alias.b.size()),why));
    auto malformed=section(gp,"rb"); malformed.b.pop_back();
    assert(!fs_ss_check(ss::Reader(malformed.b.data(),malformed.b.size()),why));
    assert(why=="invalid snapshot file section");
    // Keep the existing low-level non-truncating reopen defense even when invoked directly.
    for(const auto& mode:{"w","wb","w+","a","ab","a+","r+","rb"}) {
        // Current gameplay handles have no pending writes: FSWriteFile already fflushes each write.
        FILE* live=fopen(host_path(gp).c_str(),"r+b"); assert(live);
        g_files[100]={live,gp,"r+b",UINT64_MAX,true,host_path(gp)};
        ss::Writer w; w.u32(200); w.u32(3);
        w.u32(1); w.str(gp); w.str(mode); w.u64(4);
        w.u32(2); w.str(backup); w.str(mode); w.u64(3);
        w.u32(3); w.str("/vol/save/user/missing.sav"); w.str("wb"); w.u64(0);
        w.u32(0); // directories
        ss::Reader reader(w.b.data(),w.b.size()); fs_ss_load(reader);
        assert(reader.ok&&reader.at_end());
        assert(bytes(host_path(gp))==data&&bytes(host_path(backup))==backup_data);
        assert(!std::filesystem::exists(host_path("/vol/save/user/missing.sav"))); // writers do not create absent files
        assert(g_files.size()==2&&ftell(g_files.at(1).f)==4&&ftell(g_files.at(2).f)==3);
        assert(g_next_handle>=200);
        for(auto& [handle,file]:g_files)fclose(file.f);
        g_files.clear();
    }
    // A later explicit game write is allowed to save its then-current progress normally.
    FILE* game=fopen(host_path(gp).c_str(),"r+b"); assert(game);
    assert(fwrite("NEW",1,3,game)==3&&fflush(game)==0); fclose(game);
    assert(bytes(host_path(gp))!=data&&bytes(host_path(backup))==backup_data);
}
'''
with tempfile.TemporaryDirectory(prefix='wwhd-fs-preserve-') as temp:
    cpp, exe = Path(temp)/'test.cpp', Path(temp)/'test'
    cpp.write_text(stubs+restore+tests)
    subprocess.run(shlex.split(os.environ.get('CXX','clang++'))+
                   ['-std=c++20','-Wall','-Wextra','-Werror','-UNDEBUG',str(cpp),'-o',str(exe)],check=True)
    subprocess.run([str(exe),temp],check=True)
print('PASS: production save-volume writer checks (live/snapshot), read-only and MOD access, aliases, malformed records; original/backup bytes unchanged, no missing save created, non-truncating reopen retained')
