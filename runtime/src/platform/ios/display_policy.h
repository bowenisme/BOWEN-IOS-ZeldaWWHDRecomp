// Pixel sizes and game aspect are independent of UIKit points and device names.
#pragma once
#include <algorithm>
#include <cmath>

namespace ios::display {
inline constexpr int kUpscalePresetCount = 7;
inline constexpr int kDefaultUpscalePreset = 4;

inline float native_scale(float width, float height, float aspect) {
    if (!std::isfinite(width) || !std::isfinite(height) || !std::isfinite(aspect) ||
        width <= 0 || height <= 0 || aspect <= 0) return 1;
    // The renderer already widens/tallens 1280x720 targets for the game aspect.
    const float base_width = std::max(1280.f, 720.f * aspect);
    const float base_height = std::max(720.f, 1280.f / aspect);
    return std::clamp(std::min(width / base_width, height / base_height), 1.f, 4.f);
}
inline int upscale_percent(int preset) {
    constexpr int percentages[]{60,65,70,75,80,85,90};
    return preset>=0 && preset<kUpscalePresetCount?percentages[preset]:80;
}
inline float upscale_ratio(int preset) {
    constexpr float ratios[]{.6f,.65f,.7f,.75f,.8f,.85f,.9f};
    return preset>=0 && preset<kUpscalePresetCount?ratios[preset]:.8f;
}
inline float legacy_upscale_ratio(int preset) {
    constexpr float ratios[]{.75f,.8f,.85f};
    return preset>=0 && preset<3?ratios[preset]:.8f;
}
inline float saved_upscale_ratio(int input_percent, int legacy_preset) {
    return input_percent>=0?static_cast<float>(std::clamp(input_percent,60,90))/100.f:legacy_upscale_ratio(legacy_preset);
}
inline int upscale_preset_for_ratio(float ratio) {
    if(!std::isfinite(ratio))return kDefaultUpscalePreset;
    int best=kDefaultUpscalePreset;
    for(int preset=0;preset<kUpscalePresetCount;++preset)
        if(std::fabs(upscale_ratio(preset)-ratio)<std::fabs(upscale_ratio(best)-ratio))best=preset;
    return best;
}
inline float upscale_scale(float width, float height, float aspect, float ratio=.8f) {
    if(!std::isfinite(ratio))ratio=.8f;
    return std::max(1.f,native_scale(width,height,aspect)*std::clamp(ratio,.6f,.9f));
}
inline float render_scale(bool native, float width, float height, float aspect) {
    return native ? native_scale(width,height,aspect) : 1.f;
}
}
