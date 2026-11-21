#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include "input.h"

namespace ios::touch {
enum class Kind { Button, GuideButton, MoveZone, LookZone };
struct Control {
    Kind kind;
    float x, y, radius, width, height;
    uint32_t button;
    const char* label;
    const char* hint;
};
struct Rect { float x, y, width, height; };
struct Binding { uint32_t button; const char* label; };
inline constexpr std::array<Binding, 16> kBindings = {{
    {input::kA, "A"}, {input::kB, "B"}, {input::kX, "X"}, {input::kY, "Y"},
    {input::kL, "L"}, {input::kR, "R"}, {input::kZL, "ZL"}, {input::kZR, "ZR"},
    {input::kPlus, "+"}, {input::kMinus, "-"}, {input::kUp, "↑"}, {input::kDown, "↓"},
    {input::kLeft, "←"}, {input::kRight, "→"}, {input::kStickL, "L3"}, {input::kStickR, "R3"},
}};
struct ButtonConfig { float x, y, scale; uint32_t button; };
using ButtonConfigs = std::array<ButtonConfig, 8>;
inline constexpr float kMinButtonScale = .65f, kMaxButtonScale = 1.5f;
inline constexpr float kMinSensitivity = .5f, kMaxSensitivity = 2.f;
struct Layout {
    std::array<Control, 11> controls;
    float move_x, move_y, move_radius, look_x, look_y, look_radius, look_speed;
    bool gamepad_only;
};

inline int binding_index(uint32_t button) {
    for (size_t i = 0; i < kBindings.size(); ++i)
        if (kBindings[i].button == button) return static_cast<int>(i);
    return -1;
}

inline bool valid_button_configs(const ButtonConfigs& configs) {
    for (const auto& c : configs)
        if (!std::isfinite(c.x) || !std::isfinite(c.y) || !std::isfinite(c.scale) ||
            c.x < 0 || c.x > 1 || c.y < 0 || c.y > 1 ||
            c.scale < kMinButtonScale || c.scale > kMaxButtonScale || binding_index(c.button) < 0) return false;
    return true;
}

inline ButtonConfigs button_configs(const Layout& layout, float width, float height,
                                    const Layout* defaults = nullptr) {
    ButtonConfigs configs{};
    for (size_t i = 0; i < configs.size(); ++i) {
        const auto& c = layout.controls[i];
        const float base_radius = defaults ? defaults->controls[i].radius : c.radius;
        configs[i] = {width > 0 ? c.x / width : 0, height > 0 ? c.y / height : 0,
                      base_radius > 0 ? c.radius / base_radius : 1, c.button};
    }
    return configs;
}

inline bool apply_button_configs(Layout& layout, float width, float height, const ButtonConfigs& configs) {
    if (!std::isfinite(width) || !std::isfinite(height) || width <= 0 || height <= 0 ||
        !valid_button_configs(configs)) return false;
    for (size_t i = 0; i < configs.size(); ++i) {
        auto& c = layout.controls[i];
        const uint32_t default_button = c.button;
        c.radius *= configs[i].scale;
        c.x = std::clamp(configs[i].x * width, c.radius, std::max(c.radius, width - c.radius));
        c.y = std::clamp(configs[i].y * height, c.radius, std::max(c.radius, height - c.radius));
        c.button = configs[i].button;
        const int binding = binding_index(c.button);
        if (binding >= 0 && c.button != default_button) {
            c.label = kBindings[binding].label;
            c.hint = "功能";
        }
    }
    return true;
}

inline float sensitivity(float value) {
    return std::isfinite(value) ? std::clamp(value, kMinSensitivity, kMaxSensitivity) : 1.f;
}

inline void apply_sensitivity(float& x, float& y, float factor) {
    factor = sensitivity(factor);
    x *= factor;
    y *= factor;
    const float magnitude = std::hypot(x, y);
    if (magnitude > 1.f) { x /= magnitude; y /= magnitude; }
}

inline Layout layout(float width, float height, bool gamepad_only = false) {
    if (!std::isfinite(width) || !std::isfinite(height) || width <= 0 || height <= 0) return {};
    const float edge = std::min(width, height);
    const float r = std::clamp(edge * .105f, 32.f, 48.f);
    const float margin = std::clamp(edge * .025f, 8.f, 14.f);
    const float action_y = height - 1.75f * r - margin;
    const float items_y = height - 4.05f * r - margin;
    const float action_x = width - 3.65f * r - margin;
    const float move_r = gamepad_only ? std::clamp(edge * .15f, 44.f, 62.f) : std::clamp(edge * .20f, 60.f, 78.f);
    const float move_x = gamepad_only ? move_r + margin :
        std::clamp(width * .14f, std::min(move_r + margin, width * .32f), width * .32f);
    const float move_y = height - move_r - margin;
    const float look_r = gamepad_only ? move_r : std::clamp(edge * .13f, 44.f, 62.f);
    const float look_x = gamepad_only ? move_x : width - look_r - margin;
    const float look_y = gamepad_only ? look_r + margin : height - look_r - margin;
    const bool landscape = width > height * 1.35f;
    const float lock_x = landscape ? width * .70f : width * .82f;
    const float shield_x = width * .82f;
    const float lock_y = landscape ? r + margin : height * .22f;
    const float shield_y = landscape ? r + margin : height * .35f;
    const float pause_x = landscape ? width * .72f : width * .88f;
    const float pause_y = landscape ? 3.2f * r + margin : height * .14f;
    const float guide_r = r * .42f;
    return {
        {{
            {Kind::Button, action_x, action_y, r, 0, 0, input::kA, "A", "动作"},
            {Kind::Button, width - 1.25f * r - margin, action_y, r * 1.08f, 0, 0, input::kB, "B", "剑/停船"},
            {Kind::Button, width - 4.45f * r - margin, items_y, r * .78f, 0, 0, input::kX, "X", "物品"},
            {Kind::Button, width - 2.65f * r - margin, items_y, r * .78f, 0, 0, input::kY, "Y", "物品"},
            {Kind::Button, width - .95f * r - margin, items_y, r * .78f, 0, 0, input::kR, "R", "物品"},
            {Kind::Button, lock_x, lock_y, r * .72f, 0, 0, input::kZL, "ZL", "锁定"},
            {Kind::Button, shield_x, shield_y, r * .72f, 0, 0, input::kZR, "ZR", "盾/巡航"},
            {Kind::Button, pause_x, pause_y, r * .72f, 0, 0, input::kPlus, "+", "暂停"},
            {Kind::GuideButton, width * .5f, margin + guide_r, guide_r, 0, 0, 0, "?", ""},
            gamepad_only
                ? Control{Kind::MoveZone, move_x, move_y, move_r, 0, 0, 0, "", ""}
                : Control{Kind::MoveZone, 0, height * .35f, 0, width * .48f, height * .65f, 0, "", ""},
            gamepad_only
                ? Control{Kind::LookZone, look_x, look_y, look_r, 0, 0, 0, "", ""}
                : Control{Kind::LookZone, width * .50f, 0, 0, width * .50f, height, 0, "", ""},
        }},
        move_x,
        move_y,
        move_r,
        look_x,
        look_y,
        look_r,
        std::clamp(edge * 1.45f, 420.f, 900.f),
        gamepad_only,
    };
}

inline bool hit(const Control& c, float x, float y) {
    if (c.kind == Kind::Button || c.kind == Kind::GuideButton ||
        ((c.kind == Kind::MoveZone || c.kind == Kind::LookZone) && c.radius > 0)) {
        if (c.radius <= 0) return false;
        return std::hypot(x - c.x, y - c.y) <= c.radius;
    }
    return x >= c.x && y >= c.y && x <= c.x + c.width && y <= c.y + c.height;
}

inline bool circle_overlaps_rect(float x, float y, float radius, Rect rect) {
    const float closest_x = std::clamp(x, rect.x, rect.x + rect.width);
    const float closest_y = std::clamp(y, rect.y, rect.y + rect.height);
    return std::hypot(x - closest_x, y - closest_y) < radius;
}

inline bool can_place_button(const Layout& layout, size_t index, float width, float height,
                             float x, float y, float radius, Rect obstacle = {}, Rect protected_area = {}) {
    if (index >= 8 || radius <= 0 || x - radius < 0 || x + radius > width || y - radius < 0 || y + radius > height)
        return false;
    const auto overlaps = [radius, x, y](Rect r) {
        return r.width > 0 && r.height > 0 && circle_overlaps_rect(x, y, radius, r);
    };
    if (overlaps(obstacle) || overlaps(protected_area)) return false;
    const auto& guide = layout.controls[8];
    if (std::hypot(x - guide.x, y - guide.y) < radius + guide.radius) return false;
    if (std::hypot(x - layout.move_x, y - layout.move_y) < radius + layout.move_radius) return false;
    if (layout.gamepad_only && std::hypot(x - layout.look_x, y - layout.look_y) < radius + layout.look_radius)
        return false;
    for (size_t i = 0; i < 8; ++i) {
        if (i == index) continue;
        const auto& other = layout.controls[i];
        if (other.radius > 0 && std::hypot(x - other.x, y - other.y) < radius + other.radius) return false;
    }
    return true;
}

// Keep visible buttons entirely out of the GamePad picture. Touches inside the picture belong to
// the native GamePad view; a button must never look tappable where that view receives the touch.
inline void avoid_rect(Layout& layout, float width, float height, Rect obstacle, Rect protected_area = {}) {
    if (!std::isfinite(obstacle.x) || !std::isfinite(obstacle.y) ||
        !std::isfinite(obstacle.width) || !std::isfinite(obstacle.height) ||
        obstacle.width <= 0 || obstacle.height <= 0) return;
    for (size_t i = 0; i < 8; ++i) {
        auto& button = layout.controls[i];
        if (button.radius <= 0 || !circle_overlaps_rect(button.x, button.y, button.radius, obstacle)) continue;
        const float old_x = button.x, old_y = button.y;
        const float step = std::max(8.f, button.radius * .28f);
        float best_distance = std::numeric_limits<float>::infinity();
        float best_x = 0, best_y = 0;
        bool found = false;
        for (float y = button.radius; y <= height - button.radius; y += step) {
            for (float x = button.radius; x <= width - button.radius; x += step) {
                if (!can_place_button(layout, i, width, height, x, y, button.radius, obstacle, protected_area)) continue;
                const float dx = x - old_x, dy = y - old_y;
                const float distance = dx * dx + dy * dy;
                if (distance < best_distance) {
                    best_distance = distance;
                    best_x = x;
                    best_y = y;
                    found = true;
                }
            }
        }
        if (found) { button.x = best_x; button.y = best_y; }
        else button.radius = 0; // hidden and unhittable is safer than a visible dead control
    }
}

inline int control_at(const Layout& layout, float x, float y) {
    for (size_t i = 0; i < layout.controls.size(); ++i)
        if (hit(layout.controls[i], x, y)) return static_cast<int>(i);
    return -1;
}

inline void stick(float dx, float dy, float radius, float& x, float& y) {
    const float distance = std::hypot(dx, dy);
    if (!std::isfinite(distance) || !std::isfinite(radius) || radius <= 0) { x = y = 0; return; }
    const float dead = radius * .10f;
    if (distance <= dead) { x = y = 0; return; }
    const float scale = std::min(1.f, (distance - dead) / (radius - dead)) / distance;
    x = dx * scale;
    y = -dy * scale;
}

inline void merge(input::PadState& pad, const input::PadState& touch) {
    pad.buttons |= touch.buttons;
    if (touch.lx || touch.ly) { pad.lx = touch.lx; pad.ly = touch.ly; }
    if (touch.rx || touch.ry) { pad.rx = touch.rx; pad.ry = touch.ry; }
}
}
