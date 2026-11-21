// A queued update must not finish before the producer has published blended uniforms.
#include "runtime.h"
#include <atomic>
#include <cassert>
#include <chrono>
#include <thread>
#include <sys/mman.h>
extern "C" void hook_027F55FC(Cpu*);
extern "C" void hook_027F5018(Cpu*);
#ifndef INTERP_TEST_SOURCE
#define INTERP_TEST_SOURCE "../src/interp.cpp"
#endif
#include INTERP_TEST_SOURCE
namespace { std::thread worker; std::atomic<bool> running{false},done{false},upload{false}; bool queue_job=false,inline_job=false; unsigned uploads=0; }
namespace true60 { bool enabled(){return false;} bool selected(){return false;} bool drawing_60(){return false;} void set_enabled(bool){} }
namespace mods { bool fast_forward_active(){return false;} }
namespace threads { void block_begin(){} void block_end(){} }
void log_msg(const char*,...) {}
extern "C" void f_027F55FC_orig(Cpu* c) {
    if(!queue_job)return;
    if(inline_job) { hook_027F5018(c); assert(upload); return; }
    uint32_t model=c->r[3];
    worker=std::thread([model]{Cpu job{};job.r[3]=model;running=true;hook_027F5018(&job);done=true;});
    while(!running)std::this_thread::yield();
    // Force the worker to reach the skip before the main thread's upload.
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    assert(!done && "worker published completion before blended UBO upload");
}
extern "C" void f_027F5018_orig(Cpu*) { upload=true; ++uploads; }
int main() {
    constexpr uint32_t base=0x10000000,model=base,joints=base+0x1000,matrices=base+0x2000;
    void* p=mmap(mem::ptr(base),0x10000,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);assert(p==mem::ptr(base));
    st32(model+0x2C,joints);st32(joints+0x10,matrices);st16(joints+0x2C,1);
    for(unsigned i:{0u,5u,10u})stf32(matrices+4*i,1);
    interp::set_mode(1);interp::g_exact_step=false;
    interp::g_hold=true;interp::g_phase=1;interp::g_step_n=1;interp::g_record_passes=1;Cpu c{};c.r[3]=model;hook_027F55FC(&c);
    interp::g_hold=false;interp::g_phase=0;stf32(matrices+12,10);queue_job=true;c.r[3]=model;hook_027F55FC(&c);
    worker.join();assert(upload&&done&&ldf32(matrices+12)==10);
    // Some jobs are deliberately dispatched inline by J3DModel::viewCalc.
    // They must run once, with no self-wait, rather than deadlocking on the producer.
    queue_job=false;interp::g_hold=true;interp::g_phase=1;c.r[3]=model;hook_027F55FC(&c);
    interp::g_hold=false;interp::g_phase=0;stf32(matrices+12,20);
    queue_job=true;inline_job=true;upload=false;uploads=0;c.r[3]=model;hook_027F55FC(&c);
    assert(upload&&uploads==1&&ldf32(matrices+12)==20);
}
