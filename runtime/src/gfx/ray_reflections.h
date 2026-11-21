#pragma once
#include <atomic>
#include <cstdint>
#include <string>

namespace gfx::ray_reflections {
namespace detail {
enum class CaptureStage { NotIntegrated, Pending, Failed, Verified };
inline std::atomic<bool> request{false};
inline std::atomic<CaptureStage> captureStage{CaptureStage::NotIntegrated};
enum class RuntimeState { Waiting, Busy, Running, NoHits, FastForward, Inactive, InvalidData, Failed, Unsupported };
inline std::atomic<bool> capability{false}, effectActive{false}, foreground{true};
inline std::atomic<uint64_t> requestVersion{0};
inline std::atomic<RuntimeState> runtimeState{RuntimeState::Waiting};
}
inline bool requested() { return detail::request.load(std::memory_order_relaxed); }
inline void set_requested(bool value) {
#ifdef WWHD_IOS
    value=false; // iPad ray tracing was removed; stale preferences and launch overrides stay off.
#endif
    if(detail::request.exchange(value,std::memory_order_relaxed)!=value)++detail::requestVersion;
    if(!value)detail::effectActive=false;
}
inline bool available() { return detail::capability.load(std::memory_order_relaxed); }
inline bool active() {
    return requested() && available() && detail::foreground.load() && detail::effectActive.load(std::memory_order_relaxed) &&
        detail::runtimeState.load()==detail::RuntimeState::Running;
}
inline std::string status() {
    if(detail::runtimeState.load()==detail::RuntimeState::Unsupported)return "设备不支持当前硬件光追路径";
    if(available()) {
        if(!requested())return "可见几何硬件光追测试版，默认关闭";
        switch(detail::runtimeState.load(std::memory_order_relaxed)) {
        case detail::RuntimeState::Running: return "海面反射已生效，仅含屏幕可见物体";
        case detail::RuntimeState::NoHits: return "本帧无有效反射命中，保留原画面";
        case detail::RuntimeState::FastForward: return "快进期间暂停光追";
        case detail::RuntimeState::Inactive: return "失焦期间暂停光追";
        case detail::RuntimeState::InvalidData: return "海面或视图数据不可用，保留原画面";
        case detail::RuntimeState::Failed: return "光追执行失败，保留原画面";
        case detail::RuntimeState::Unsupported: return "设备不支持当前硬件光追路径";
        case detail::RuntimeState::Waiting: return "等待本帧有效海面，建议60FPS";
        case detail::RuntimeState::Busy: return "GPU繁忙，等待光追任务";
        }
    }
    switch (detail::captureStage.load(std::memory_order_relaxed)) {
    case detail::CaptureStage::Pending: return "正在验证海面数据，光追尚未接入";
    case detail::CaptureStage::Failed: return "海面数据验证失败，光追未启用";
    case detail::CaptureStage::Verified: return "数据验证通过，光追反射尚未接入";
    case detail::CaptureStage::NotIntegrated: return "尚未完成游戏光追接入";
    }
    return "尚未完成游戏光追接入";
}
} // namespace gfx::ray_reflections
