// Real guest pthread, freeze gate and HLE message queue; no ROM or user saves.
#include "../src/threads.cpp"
#include <cassert>
#include <fstream>

HleReg::HleReg(const char*, const char*, PpcFunc) {}
bool g_trace_hle = false;
void log_msg(const char*, ...) {}
[[noreturn]] void fatal(const char*, ...) { std::abort(); }
namespace perf_hint { void add_current_thread() {} }
namespace thread_sampler { void add_current_thread(const char*) {} }
namespace rprof { uint64_t thread_cpu_ns() { return 0; } }
namespace mods { bool fast_forward() { return false; } }
namespace game_clock {
bool shifted() { return false; }
unsigned rate() { return 1; }
Sample sample() { return {}; }
}
namespace mem {
std::string read_cstr(uint32_t a) {
    return a ? std::string((const char*)ptr(a)) : "";
}
}
namespace ss { uint32_t snap_ld32(uint32_t a) { return ld32(a); } }

constexpr uint32_t manager = 0x20001000, worker = 0x20002000;
constexpr uint32_t guest = 0x20003000, stack = 0x20010000, main_stack = 0x20005000;
std::atomic<unsigned> normal_exits{0};

// The sead::Thread loop's quit branch: actual OSReceiveMessage and normal thread_main epilogue.
uint32_t guest_call(Cpu* c, uint32_t fn, std::initializer_list<uint32_t> args) {
    assert(fn == GC(0x02760ACC));
    assert(args.size() == 2 && *args.begin() == 0 && *(args.begin() + 1) == worker);
    c->lr = GC(0x02760394);
    c->r[3] = worker + 0x20; c->r[4] = stack; c->r[5] = 1;
    imp_coreinit_OSReceiveMessage(c);
    assert(ld32(stack) == 0x7FFFFFFF);
    assert(ld32(worker + 0x80) == 2);
    st32(worker + 0x80, 3);
    ++normal_exits;
    return 0;
}

void until(const std::function<bool()>& pred) {
    const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!pred()) {
        assert(std::chrono::steady_clock::now() < end);
        std::this_thread::yield();
    }
}
ss::Reader reader(const std::vector<uint8_t>& bytes) { return {bytes.data(), bytes.size()}; }

int main(int argc, char** argv) {
    assert(argc == 3);
    for (uint32_t a : {GD(0x1018F47C) & ~0xFFFu, GD(0x10005518) & ~0xFFFu, manager}) {
        const uint32_t base = a & ~0xFFFu;
        const size_t size = base == (manager & ~0xFFFu) ? 0x20000 : 0x1000;
        void* p = mmap(PPC_MEM_BASE + base, size, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
        assert(p == PPC_MEM_BASE + base);
    }
    memcpy(mem::ptr(GD(0x10005518)), "NetBossThread", 14);
    st32(GD(0x1018F47C), manager); st32(manager + 0x1C, worker);
    st32(worker + 0x0C, GD(0x1015E528));
    st32(worker + 0x78, 0x7FFFFFFF); st32(worker + 0x80, 1); st32(worker + 0x88, guest);
    HostThread requester;
    requester.guest = manager + 0x800; requester.started = true; requester.suspend = 0;
    requester.cpu.r[1] = main_stack; requester.cpu.lr = 0x0203593C;
    t_self = &requester; t_cpu = &requester.cpu; g_threads[requester.guest] = &requester;
    auto* t = create_thread(guest, GC(0x02760ACC), 0, worker, stack + 0x8000, 0x8000, 16, 2);
    st32(guest + osthread::kName, GD(0x10005518));
    HQueue* q = g_queues.get(worker + 0x20); q->capacity = 32;
    t->started = true; t->suspend = 0;
    start_host_thread(t);
    until([&] { return t->wst.load() == kParked; });
    std::string why;
    assert(threads::quiesce(1000, why));

    if (std::string(argv[1]) == "capture") {
        {
            std::lock_guard<std::mutex> lk(q->m);
            q->msgs.push_back({0x7FFFFFFF, 0, 0, 0}); st32(worker + 0x80, 2);
        }
        q->cv.notify_all(); threads::thaw();
        threads::block_begin(); pthread_join(t->pt, nullptr); threads::block_end();
        assert(normal_exits == 1 && t->exited && ld8(guest + osthread::kState) == osthread::MORIBUND);
        assert(threads::quiesce(1000, why));
        ss::Writer out;
        assert(threads_ss_save(out, why));
        std::ofstream f(argv[2], std::ios::binary);
        f.write((const char*)out.b.data(), out.b.size()); assert(f.good());
        threads::thaw();
        return 0;
    }

    std::ifstream f(argv[2], std::ios::binary);
    const std::vector<uint8_t> saved((std::istreambuf_iterator<char>(f)), {});
    assert(!saved.empty());
    assert(!threads_ss_check(reader(saved), why));
    assert(why.find("exited in the save, running now") != std::string::npos);

    // Fail closed for another worker, an unexpected continuation, another lifecycle or bad input.
    g_frz_owner = nullptr; assert(!threads_ss_settle_offline(reader(saved))); g_frz_owner = &requester;
    st32(worker + 0x0C, 0);
    assert(!threads_ss_settle_offline(reader(saved))); st32(worker + 0x0C, GD(0x1015E528));
    st32(guest + osthread::kName, 0);
    assert(!threads_ss_settle_offline(reader(saved))); st32(guest + osthread::kName, GD(0x10005518));
    t->cpu.lr += 4; assert(!threads_ss_settle_offline(reader(saved))); t->cpu.lr -= 4;
    t->service = true; assert(!threads_ss_settle_offline(reader(saved))); t->service = false;
    t->entry += 4; assert(!threads_ss_settle_offline(reader(saved))); t->entry -= 4;
    t->wait_obj += 4; assert(!threads_ss_settle_offline(reader(saved))); t->wait_obj -= 4;
    t->wait_kind = W_MUTEX; assert(!threads_ss_settle_offline(reader(saved))); t->wait_kind = W_MSG_RECV;
    st32(worker + 0x88, guest + 4);
    assert(!threads_ss_settle_offline(reader(saved))); st32(worker + 0x88, guest);
    t->irq_off = 1; assert(!threads_ss_settle_offline(reader(saved))); t->irq_off = 0;
    { std::lock_guard<std::mutex> lk(q->m); q->capacity = 0; }
    assert(!threads_ss_settle_offline(reader(saved)));
    { std::lock_guard<std::mutex> lk(q->m); q->capacity = 32; q->msgs.push_back({1, 0, 0, 0}); }
    assert(!threads_ss_settle_offline(reader(saved)));
    { std::lock_guard<std::mutex> lk(q->m); q->msgs.clear(); }
    assert(!threads_ss_settle_offline({saved.data(), sizeof(uint32_t)}));
    auto running = saved;
    // The worker was captured as the second record (sorted by guest address).
    const size_t record = 4 + sizeof(ThreadRec);
    assert(reader(saved).u32() == 2);
    running[record + offsetof(ThreadRec, exited)] = 0;
    assert(!threads_ss_settle_offline(reader(running)));
    assert(q->msgs.empty() && !t->exited && normal_exits == 0);

    assert(threads_ss_settle_offline(reader(saved)));
    assert(!threads_ss_settle_offline(reader(saved))); // no duplicate quit message
    assert(!t->exited && normal_exits == 0); // enqueue is not restoration or forced thread exit
    assert(!threads_ss_check(reader(saved), why)); // all original checks still apply
    threads::thaw();
    threads::block_begin(); pthread_join(t->pt, nullptr); threads::block_end();
    assert(normal_exits == 1 && t->exited && ld8(guest + osthread::kState) == osthread::MORIBUND);
    assert(threads::quiesce(1000, why));
    assert(threads_ss_check(reader(saved), why));
    requester.cpu.lr += 4;
    assert(!threads_ss_check(reader(saved), why)); // unrelated LR mismatch is still rejected
    requester.cpu.lr -= 4;
    assert(threads_ss_check(reader(saved), why));
    threads::thaw();
    assert(!threads_ss_settle_offline(reader(saved))); // no preparation outside the freeze
    threads::release_core();
    puts("Restarted worker settled through real HLE queue and normal guest thread exit; checks preserved.");
}
