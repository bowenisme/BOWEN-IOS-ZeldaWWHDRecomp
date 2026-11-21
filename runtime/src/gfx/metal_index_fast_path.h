#pragma once

#include <cstdint>

namespace gfx::metal_index {

constexpr uint32_t kTriangleList = 4;
constexpr uint32_t kNativeUInt16 = 0;
constexpr uint32_t kMaxDirectCount = (UINT32_MAX - 255u) / 2u;

constexpr bool direct_u16_triangle(uint32_t prim, uint32_t indexType, uint32_t indexAddr, uint32_t count,
                                   bool enabled, bool capturing, bool seaCapture) {
    return enabled && indexAddr && count && prim == kTriangleList && indexType == kNativeUInt16 &&
           count <= kMaxDirectCount && !capturing && !seaCapture;
}

}  // namespace gfx::metal_index
