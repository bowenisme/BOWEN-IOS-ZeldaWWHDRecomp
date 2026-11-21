#pragma once
#import <UIKit/UIKit.h>
namespace ios {
void install_touch_controls(UIViewController* controller);
void refresh_touch_controls();
void release_touch_controls();
void edit_touch_layout();
bool touch_layout_editing();
void finish_touch_layout_edit();
float touch_move_sensitivity();
float touch_look_sensitivity();
void set_touch_sensitivity(float move, float look);
void reset_touch_configuration();
void test_touch_controls();
}
