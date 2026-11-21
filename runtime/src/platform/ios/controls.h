#pragma once
#import <UIKit/UIKit.h>
namespace ios {
void install_controls(UIViewController* controller);
void set_performance_hud(bool visible);
void update_controls(NSDictionary* metrics);
NSDictionary* controls_state();
// Opt-in UI-action/timer self-test (~19 seconds), including RT and 30/60 FPS selection and temporary slot previews;
// never overwrites occupied slots (optional quick-save/load uses an empty visible slot only). It writes captures/controls-{test.json,panel.png,hud.png,details.png,details-content.png,details-bottom.png}.
void test_controls();
void test_touch_settings();
}
