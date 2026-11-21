#pragma once
#import <UIKit/UIKit.h>
namespace ios {
// Actual rendered GamePad rectangle converted from the Metal view, including safe-area offsets.
CGRect gamepad_touch_region(UIView* target, bool* fullscreen = nullptr);
}
