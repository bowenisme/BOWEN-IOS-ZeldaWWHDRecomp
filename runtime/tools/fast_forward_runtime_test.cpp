// Tests the actual mod/input state machine against synthetic guest fields, no game files.
#include "mods/fast_forward.h"
#include "game_clock.h"
#include "runtime.h"
#include <cassert>
#include <cstdlib>
#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#endif
namespace { bool blocked = false, controls_blocked = false; unsigned flushes = 0; }
namespace ios { bool controls_block_input() { return controls_blocked; } }
namespace overlay { bool blocks_input() { return blocked; } }
namespace timebase { void set_clock_rate(unsigned r) { game_clock::set_rate(r); } }
namespace mods { bool trace_on() { return true; } void trace(const char*, ...) {} }
namespace audio { void flush() { ++flushes; } }
void map(uint32_t address) {
#ifdef _WIN32
    auto p = VirtualAlloc(mem::ptr(address), 65536, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
#else
    auto p = mmap(mem::ptr(address), 65536, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
#endif
    assert(p == mem::ptr(address));
}
int main(int argc, char** argv) {
    if (argc == 6 || argc == 7) {
        assert(mods::fast_forward() == (std::atoi(argv[2]) != 0));
        assert(mods::fast_forward_rate() == unsigned(std::atoi(argv[3])));
        assert(mods::fast_forward_button() == uint32_t(std::strtoul(argv[4], nullptr, 0)));
        assert(mods::fast_forward_mute() == (std::atoi(argv[5]) != 0));
        if (argc == 7) assert(mods::fast_forward_global() == (std::atoi(argv[6]) != 0));
        return 0;
    }
    map(0x10470000); map(0x101E0000); map(0x101F0000); map(0x11000000);
    constexpr uint32_t play = 0x1046F0B0;
    using namespace mods;
    assert(!fast_forward() && fast_forward_rate() == 2 && fast_forward_button() == 0x40 && fast_forward_mute());
    assert(!fast_forward_global());
    memcpy(mem::ptr(play + 0x5134), "sea", 4);
    st32(play + 0x5B34, 0x11000000);
    st8(play + 0x5292, 1);
    auto input = [](uint32_t b) { fast_forward_input(b); return b; };
    assert(input(0x8040) == 0x8040); fast_forward_service(); assert(!fast_forward_active());
    set_fast_forward(true);
    assert(input(0x8040) == 0x8000); fast_forward_service(); assert(fast_forward_active() && game_clock::rate() == 2);
    set_fast_forward_rate(4); fast_forward_service(); assert(game_clock::rate() == 4);
    assert(input(0x8000) == 0x8000); fast_forward_service(); assert(!fast_forward_active() && game_clock::rate() == 1);
    for (unsigned event = 0; event <= 4; ++event) {
        st8(play + 0x5292, event);
        input(0x40); fast_forward_service(); assert(fast_forward_active() == (event >= 1 && event <= 3));
    }
    st8(play + 0x5292, 2); input(0x40); fast_forward_service(); assert(fast_forward_active());
    fast_forward_reset(); assert(game_clock::rate() == 1);
    input(0x40); fast_forward_service(); assert(!fast_forward_active()); // save/load must not latch boost
    input(0); input(0x40); fast_forward_service(); assert(fast_forward_active());
    blocked = true; fast_forward_service(); assert(!fast_forward_active());
    blocked = false;
    for (const char* stage : {"sea_T", "Name", ""}) {
        memset(mem::ptr(play + 0x5134), 0, 8); memcpy(mem::ptr(play + 0x5134), stage, strlen(stage));
        input(0x40); fast_forward_service(); assert(!fast_forward_active());
    }
    // Story events do not require a Link actor, including the ending stage.
    st32(play + 0x5B34, 0);
    for (const char* stage : {"ENDumi", "sea", "sea_E"}) {
        memset(mem::ptr(play + 0x5134), 0, 8); memcpy(mem::ptr(play + 0x5134), stage, strlen(stage));
        for (unsigned event : {1u, 2u, 3u}) {
            st8(play + 0x5292, event); input(0x40); fast_forward_service(); assert(fast_forward_active());
        }
        st8(play + 0x5292, 0); fast_forward_service(); assert(!fast_forward_active());
    }
    memcpy(mem::ptr(play + 0x5134), "sea\0\0\0\0", 8);
    // Dialogue can remain open after the event control returns to NONE.
    for (uint32_t offset : {0x5BB2u, 0x5BB3u}) {
        st8(play + offset, 1); fast_forward_service(); assert(fast_forward_active());
        st8(play + offset, 0); fast_forward_service(); assert(!fast_forward_active());
    }
    // HD opening uses a separate loaded screen while stage/event/Link may still
    // describe the title or file selection. A stage name alone never enables it.
    constexpr uint32_t opening = 0x11000000, screen = opening + 0x1000;
    st32(0x101F8318, opening); st32(opening + 0x94, screen);
    st32(screen + 4, 0x100FFED0); st32(screen + 0x44, screen + 0x100);
    for (const char* stage : {"sea_T", "Name", ""}) {
        memset(mem::ptr(play + 0x5134), 0, 8); memcpy(mem::ptr(play + 0x5134), stage, strlen(stage));
        set_fast_forward_latched(true); input(0);
        for (unsigned rate : {2u, 3u, 4u}) {
            set_fast_forward_rate(rate); fast_forward_service();
            assert(fast_forward_active() && game_clock::rate() == rate);
        }
        st8(screen + 0x88, 1); fast_forward_service(); assert(!fast_forward_active() && game_clock::rate() == 1);
        st8(screen + 0x88, 0);
    }
    st32(screen + 0x44, 0); fast_forward_service(); assert(!fast_forward_active());
    st32(screen + 0x44, screen + 0x100);
    st32(screen + 4, 0x10000000); fast_forward_service(); assert(!fast_forward_active());
    st32(screen + 4, 0x100FFED0);
    for (uint32_t invalid : {0u, 0xFFFFFFFFu, 0x50000000u, opening + 1}) {
        st32(opening + 0x94, invalid); fast_forward_service(); assert(!fast_forward_active());
    }
    st32(opening + 0x94, screen);
    for (uint32_t invalid : {0u, 0xFFFFFFFFu, 0x50000000u, opening + 1}) {
        st32(0x101F8318, invalid); fast_forward_service(); assert(!fast_forward_active());
    }
    st32(0x101F8318, opening); fast_forward_service(); assert(fast_forward_active());
    blocked = true; fast_forward_service(); assert(!fast_forward_active()); blocked = false;
#ifdef WWHD_IOS
    controls_blocked = true; fast_forward_service(); assert(!fast_forward_active()); controls_blocked = false;
#endif
    st8(play + 0x5140 + 12, 1); fast_forward_service(); assert(!fast_forward_active());
    st8(play + 0x5140 + 12, 0);
    st32(0x101F36CC, opening); fast_forward_service(); assert(!fast_forward_active()); st32(0x101F36CC, 0);
    st8(0x101EA069, 1); fast_forward_service(); assert(!fast_forward_active()); st8(0x101EA069, 0);
    fast_forward_service(); assert(fast_forward_active());
    fast_forward_reset(); input(0x40); fast_forward_service(); assert(!fast_forward_active() && !fast_forward_latched());
    input(0); input(0x40); fast_forward_service(); assert(fast_forward_active());
    st32(0x101F8318, 0); fast_forward_service(); assert(!fast_forward_active());
    // Even stale event/message fields in the title/file selector must stay 1x.
    for (const char* stage : {"sea_T", "Name"}) {
        memset(mem::ptr(play + 0x5134), 0, 8); memcpy(mem::ptr(play + 0x5134), stage, strlen(stage));
        st8(play + 0x5292, 1); st8(play + 0x5BB2, 1); st8(play + 0x5BB3, 1);
        fast_forward_service(); assert(!fast_forward_active() && game_clock::rate() == 1);
    }
    st8(play + 0x5BB2, 0); st8(play + 0x5BB3, 0);
    memcpy(mem::ptr(play + 0x5134), "sea\0\0\0\0", 8);
    st8(play + 0x5140 + 12, 1); input(0x40); fast_forward_service(); assert(!fast_forward_active());
    st8(play + 0x5140 + 12, 0);
    st32(0x101F36CC, 0x11000000); fast_forward_service(); assert(!fast_forward_active());
    st32(0x101F36CC, 0);
    st8(0x101EA069, 1); fast_forward_service(); assert(!fast_forward_active());
    st8(0x101EA069, 0); fast_forward_service(); assert(fast_forward_active());
    set_fast_forward_button(0x8000); assert(fast_forward_button() == 0x40);
    set_fast_forward_rate(0); set_fast_forward_rate(5); assert(fast_forward_rate() == 4);
    set_fast_forward(false); fast_forward_service(); assert(!fast_forward_active() && game_clock::rate() == 1);
    assert(input(0x8040) == 0x8040);
    set_fast_forward_latched(true);input(0);
    for(unsigned rate:{2u,3u,4u}) {
        set_fast_forward_rate(rate);fast_forward_service();assert(game_clock::rate()==rate);
    }
    st8(play+0x5292,0);fast_forward_service();assert(!fast_forward_active()&&game_clock::rate()==1);
    st8(play+0x5292,1);fast_forward_service();assert(fast_forward_active());
    fast_forward_reset();assert(!fast_forward_latched()&&game_clock::rate()==1);
    set_fast_forward_latched(true);set_fast_forward_latched(false);fast_forward_service();
    assert(!fast_forward_active()&&game_clock::rate()==1);

    // Ordinary movement/combat (event NONE) uses the same clock, with no
    // actor/event manipulation. Story-only mode remains the default.
    st8(play + 0x5292, 0); st32(play + 0x5B34, 0x11000000);
    set_fast_forward_latched(true); input(0); fast_forward_service();
    assert(!fast_forward_active());
    set_fast_forward_global(true);
    for (unsigned event : {0u, 1u, 2u, 3u, 4u}) {
        st8(play + 0x5292, event);
        for (unsigned rate : {2u, 3u, 4u}) {
            const auto before_flush = flushes;
            const auto before_rate = game_clock::rate();
            set_fast_forward_rate(rate); fast_forward_service();
            assert(fast_forward_active() && game_clock::rate() == rate);
            assert(flushes == before_flush + unsigned(before_rate != rate));
            const auto stable_flush = flushes;
            fast_forward_service(); assert(flushes == stable_flush);
        }
    }
    st8(play + 0x5292, 0);
    for (uint32_t trigger : {0x40000u, 0x20000u, 0x20u, 0x10u, 0x80u, 0x40u}) {
        set_fast_forward_button(trigger); set_fast_forward_latched(true);
        // A latched switch never consumes ZL/L/R (or any configured trigger).
        assert(input(0xFFFFF) == 0xFFFFF);
        fast_forward_service(); assert(fast_forward_active());
        set_fast_forward_latched(false);
        assert(input(trigger | 0x8000) == (trigger | 0x8000));
        fast_forward_service(); assert(!fast_forward_active()); // release still required
        input(0);
        assert(input(trigger | 0x8000) == 0x8000);
        fast_forward_service(); assert(fast_forward_active());
        input(0); fast_forward_service(); assert(!fast_forward_active() && game_clock::rate() == 1);
    }
    set_fast_forward_button(0x40); set_fast_forward_latched(true); input(0);
    fast_forward_service(); assert(fast_forward_active());
    blocked = true; fast_forward_service(); assert(!fast_forward_active() && game_clock::rate() == 1);
    blocked = false; fast_forward_service(); assert(fast_forward_active() && fast_forward_latched());
#ifdef WWHD_IOS
    controls_blocked = true; fast_forward_service(); assert(!fast_forward_active() && game_clock::rate() == 1);
    assert(input(0x8040) == 0x8040);
    controls_blocked = false; fast_forward_service(); assert(fast_forward_active());
#endif
    // Scene load/wipe and game pause suspend, then resume the armed setting.
    for (uint32_t address : {play + 0x514C, 0x101EA069u}) {
        st8(address, 1); fast_forward_service(); assert(!fast_forward_active() && game_clock::rate() == 1);
        st8(address, 0); fast_forward_service(); assert(fast_forward_active());
    }
    st32(0x101F36CC, 1); fast_forward_service(); assert(!fast_forward_active() && game_clock::rate() == 1);
    st32(0x101F36CC, 0); fast_forward_service(); assert(fast_forward_active());
    for (const char* stage : {"sea_T", "Name", ""}) {
        memset(mem::ptr(play + 0x5134), 0, 8); memcpy(mem::ptr(play + 0x5134), stage, strlen(stage));
        fast_forward_service(); assert(!fast_forward_active() && game_clock::rate() == 1);
    }
    memcpy(mem::ptr(play + 0x5134), "sea\0\0\0\0", 8);
    for (uint32_t invalid : {0u, 0xFFFFFFFFu, 0x50000000u, 0x11000001u}) {
        st32(play + 0x5B34, invalid); fast_forward_service(); assert(!fast_forward_active());
    }
    st32(play + 0x5B34, 0x11000000); fast_forward_service(); assert(fast_forward_active());
    set_fast_forward_global(false); assert(game_clock::rate() == 1);
    fast_forward_service(); assert(!fast_forward_active() && fast_forward_latched());
    st8(play + 0x5292, 1); fast_forward_service(); assert(fast_forward_active()); // old story mode
    set_fast_forward_global(true); st8(play + 0x5292, 0); fast_forward_service(); assert(fast_forward_active());
    // release_keys/focus loss and both save/load request paths call this reset.
    fast_forward_reset(); assert(!fast_forward_latched() && game_clock::rate() == 1);
    assert(fast_forward_global()); // preference survives; activation never does
    assert(input(0x8040) == 0x8040);
    fast_forward_service(); assert(!fast_forward_active());
    input(0); input(0x40); fast_forward_service(); assert(fast_forward_active());
    set_fast_forward(false); assert(game_clock::rate() == 1);
    fast_forward_service(); assert(!fast_forward_active() && !fast_forward_latched());
}
