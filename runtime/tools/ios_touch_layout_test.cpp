#include "platform/ios/touch_layout.h"

#include <cassert>
#include <cmath>
#include <limits>
#include <string_view>

int main() {
    constexpr float screens[][2] = {
        {320, 568}, {568, 320}, {667, 375}, {844, 390}, {1024, 768}, {1366, 768}, {390, 844},
    };
    for (const auto& screen : screens) {
        const float width = screen[0], height = screen[1];
        const auto controls = ios::touch::layout(width, height);
        assert(controls.controls.size() == 11);
        for (size_t i = 0; i < 8; ++i) {
            const auto& c = controls.controls[i];
            assert(c.kind == ios::touch::Kind::Button);
            assert(c.x - c.radius >= 0 && c.x + c.radius <= width);
            assert(c.y - c.radius >= 0 && c.y + c.radius <= height);
            assert(ios::touch::control_at(controls, c.x, c.y) == static_cast<int>(i));
            for (size_t j = i + 1; j < 8; ++j) {
                const auto& other = controls.controls[j];
                assert(std::hypot(c.x - other.x, c.y - other.y) >= c.radius + other.radius);
            }
        }
        assert(controls.controls[0].button == input::kA);       // context action
        assert(controls.controls[0].label == std::string_view("A"));
        assert(controls.controls[0].hint == std::string_view("动作"));
        assert(controls.controls[1].button == input::kB);       // sword / sailing stop
        assert(controls.controls[1].hint == std::string_view("剑/停船"));
        assert(controls.controls[2].button == input::kX);       // item
        assert(controls.controls[3].button == input::kY);       // item
        assert(controls.controls[4].button == input::kR);       // item
        assert(controls.controls[5].button == input::kZL);      // target lock
        assert(controls.controls[5].hint == std::string_view("锁定"));
        assert(controls.controls[6].button == input::kZR);      // shield / cruise
        assert(controls.controls[6].hint == std::string_view("盾/巡航"));
        assert(controls.controls[7].button == input::kPlus);    // pause/menu
        assert(controls.controls[8].kind == ios::touch::Kind::GuideButton);
        assert(controls.controls[9].kind == ios::touch::Kind::MoveZone);
        assert(controls.controls[10].kind == ios::touch::Kind::LookZone);
        const auto& guide = controls.controls[8];
        assert(guide.x - guide.radius >= 0 && guide.x + guide.radius <= width);
        assert(guide.y - guide.radius >= 0 && guide.y + guide.radius <= height);
        for (size_t i = 0; i < 8; ++i) {
            const auto& c = controls.controls[i];
            assert(std::hypot(c.x - guide.x, c.y - guide.y) >= c.radius + guide.radius);
        }
        assert(controls.controls[9].x + controls.controls[9].width < controls.controls[10].x);
        for (size_t i = 5; i < 8; ++i) {
            const auto& c = controls.controls[i];
            const bool separated = c.x + c.radius <= width - 78 || c.x - c.radius >= width - 14 ||
                c.y + c.radius <= 12 || c.y - c.radius >= 48;
            assert(separated); // leaves the 64x36 top-right settings entry clear
        }
        assert(ios::touch::control_at(controls, controls.controls[8].x, controls.controls[8].y) == 8);
        assert(ios::touch::control_at(controls, width * .10f, height * .50f) == 9);
        assert(ios::touch::control_at(controls, width * .52f, height * .50f) == 10);
        assert(ios::touch::control_at(controls, controls.move_x, controls.move_y) == 9);

        const auto gamepad = ios::touch::layout(width, height, true);
        assert(gamepad.gamepad_only);
        assert(gamepad.controls[9].radius == gamepad.move_radius);
        assert(gamepad.controls[10].radius == gamepad.look_radius);
        assert(ios::touch::control_at(gamepad, gamepad.move_x, gamepad.move_y) == 9);
        assert(ios::touch::control_at(gamepad, gamepad.look_x, gamepad.look_y) == 10);
        assert(ios::touch::control_at(gamepad, gamepad.move_x + gamepad.move_radius * .95f,
                                      gamepad.move_y + gamepad.move_radius * .95f) == -1);
        for (size_t i = 0; i < 8; ++i) {
            const auto& button = gamepad.controls[i];
            assert(ios::touch::control_at(gamepad, button.x, button.y) == static_cast<int>(i));
            assert(std::hypot(button.x - gamepad.move_x, button.y - gamepad.move_y) >=
                   button.radius + gamepad.move_radius);
            assert(std::hypot(button.x - gamepad.look_x, button.y - gamepad.look_y) >=
                   button.radius + gamepad.look_radius);
        }
        assert(gamepad.controls[9].radius * 2 < width * .45f);
        assert(gamepad.controls[10].radius * 2 < height * .45f);

        // The four possible PiP corners must not leave any visible control partly untappable.
        const float pip_w = width * .45f, pip_h = height * .30f;
        const float margin = std::min(width, height) * .02f;
        const ios::touch::Rect settings{width - 78, 12, 78, 36};
        for (const auto& mode : {controls, gamepad}) {
            assert(!ios::touch::can_place_button(mode, 0, width, height, width - 40, 30, 10, {}, settings));
            assert(!ios::touch::can_place_button(mode, 0, width, height, mode.move_x, mode.move_y, 10));
            assert(!ios::touch::can_place_button(mode, 0, width, height,
                mode.controls[1].x, mode.controls[1].y, 10));
            auto misplaced = mode;
            misplaced.controls[0].x = width - 40;
            misplaced.controls[0].y = 30;
            ios::touch::avoid_rect(misplaced, width, height, settings);
            const auto& relocated = misplaced.controls[0];
            assert(relocated.radius <= 0 || !ios::touch::circle_overlaps_rect(
                relocated.x, relocated.y, relocated.radius, settings));
        }
        for (int corner = 0; corner < 4; ++corner) {
            auto safe = controls;
            const ios::touch::Rect pip{
                (corner & 1) ? width - pip_w - margin : margin,
                (corner & 2) ? height - pip_h - margin : margin,
                pip_w, pip_h,
            };
            ios::touch::avoid_rect(safe, width, height, pip, settings);
            for (size_t i = 0; i < 8; ++i) {
                const auto& c = safe.controls[i];
                if (c.radius <= 0) continue;
                assert(c.x - c.radius >= 0 && c.x + c.radius <= width);
                assert(c.y - c.radius >= 0 && c.y + c.radius <= height);
                assert(!ios::touch::circle_overlaps_rect(c.x, c.y, c.radius, pip));
                assert(!ios::touch::circle_overlaps_rect(c.x, c.y, c.radius, settings));
                for (size_t j = i + 1; j < 8; ++j) {
                    const auto& other = safe.controls[j];
                    if (other.radius > 0)
                        assert(std::hypot(c.x - other.x, c.y - other.y) >= c.radius + other.radius);
                }
            }
        }

        auto configured = controls;
        auto config = ios::touch::button_configs(configured, width, height);
        assert(ios::touch::valid_button_configs(config));
        config[0].x = .05f;
        config[0].y = .96f;
        config[0].scale = ios::touch::kMaxButtonScale;
        config[0].button = input::kMinus;
        assert(ios::touch::apply_button_configs(configured, width, height, config));
        assert(configured.controls[0].button == input::kMinus);
        assert(configured.controls[0].label == std::string_view("-"));
        assert(configured.controls[0].hint == std::string_view("功能"));
        assert(configured.controls[0].radius == controls.controls[0].radius * ios::touch::kMaxButtonScale);
        assert(configured.controls[0].x - configured.controls[0].radius >= 0);
        assert(configured.controls[0].y + configured.controls[0].radius <= height);
        const float radiusBeforeRebind = configured.controls[0].radius;
        config = ios::touch::button_configs(configured, width, height, &controls);
        config[0].button = input::kLeft;
        auto rebound = controls;
        assert(ios::touch::apply_button_configs(rebound, width, height, config));
        assert(rebound.controls[0].radius == radiusBeforeRebind); // rebinding preserves the chosen size
        const auto beforeInvalid = configured.controls[1].x;
        config[1].scale = std::numeric_limits<float>::quiet_NaN();
        assert(!ios::touch::apply_button_configs(configured, width, height, config));
        assert(configured.controls[1].x == beforeInvalid); // invalid data is rejected atomically
    }

    float x = 0, y = 0;
    ios::touch::stick(0, 0, 100, x, y);
    assert(x == 0 && y == 0);
    ios::touch::stick(0, -100, 100, x, y);
    assert(x == 0 && y == 1); // screen-up is stick-up
    ios::touch::stick(200, 0, 100, x, y);
    assert(x == 1 && y == 0); // clamps outside the virtual stick
    ios::touch::stick(std::numeric_limits<float>::infinity(), 0, 100, x, y);
    assert(x == 0 && y == 0);

    input::PadState host{}, touch{};
    host.buttons = input::kB;
    host.lx = .25f; host.ly = .5f; host.rx = .1f; host.ry = -.2f;
    touch.buttons = input::kA;
    touch.lx = .75f; touch.rx = -.4f;
    ios::touch::merge(host, touch);
    assert(host.buttons == (input::kA | input::kB));
    assert(host.lx == .75f && host.ly == 0); // a touched stick takes over as a pair
    assert(host.rx == -.4f && host.ry == 0);
    assert(ios::touch::layout(0, 0).controls[0].radius == 0);
    assert(ios::touch::sensitivity(std::numeric_limits<float>::quiet_NaN()) == 1.f);
    assert(ios::touch::sensitivity(.1f) == ios::touch::kMinSensitivity);
    assert(ios::touch::sensitivity(9.f) == ios::touch::kMaxSensitivity);
    x = y = 1.f / std::sqrt(2.f);
    ios::touch::apply_sensitivity(x, y, 2.f);
    assert(std::abs(std::hypot(x, y) - 1.f) < .0001f); // sensitivity cannot overdrive the stick magnitude
    assert(ios::touch::binding_index(input::kUp) >= 0);
    assert(ios::touch::binding_index(input::kStickR) >= 0);
}
