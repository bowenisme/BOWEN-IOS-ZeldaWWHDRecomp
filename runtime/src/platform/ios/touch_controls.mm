#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <atomic>
#include <map>
#include <string_view>
#include "touch_controls.h"
#include "touch_layout.h"
#include "gamepad_touch.h"
#include "platform/touch_buttons.h"
#include "gfx/display_modes.h"
#include "input_map.h"
#include "ios.h"

namespace {
struct Finger {
    int control;
    CGPoint start, point, velocity;
    NSTimeInterval lastSample, lastMotion;
};
std::atomic<bool> g_touch_layout_editing{false};
}

@interface WWSyntheticTouch : NSObject
@property(nonatomic, weak) UIView* view;
@property(nonatomic) CGPoint point;
@property(nonatomic) NSTimeInterval sampleTime;
- (CGPoint)locationInView:(UIView*)view;
- (NSTimeInterval)timestamp;
@end

@implementation WWSyntheticTouch
- (CGPoint)locationInView:(UIView*)view { return [self.view convertPoint:self.point toView:view]; }
- (NSTimeInterval)timestamp { return self.sampleTime; }
@end

@interface WWTouchControls : UIView {
    ios::touch::Layout _layout;
    std::map<uintptr_t, Finger> _fingers;
    CGRect _area;
    CGRect _gamePadRect;
    input::PadState _pad;
    CADisplayLink* _lookLink;
    CAShapeLayer* _moveRing;
    CAShapeLayer* _moveKnob;
    CAShapeLayer* _lookCursor;
    CATextLayer* _moveLabel;
    BOOL _active;
    BOOL _guideShown;
    BOOL _gamePadFullscreen;
    BOOL _geometryReady;
    BOOL _editing;
    int _selectedButton;
    uintptr_t _editorTouch;
    CGPoint _editorGrabOffset;
}
- (void)refreshVisibility;
- (void)updateMotionLayers;
- (void)updateLayout;
- (ios::touch::Rect)gamepadObstacle;
- (BOOL)canPlaceButton:(size_t)index x:(float)x y:(float)y radius:(float)radius;
- (void)releaseTouches;
- (void)rebuildPad:(BOOL)redraw;
- (CGRect)guideCardRect;
- (CGRect)editorToolbarRect;
- (CGRect)editorActionRect:(int)index;
- (void)drawEditor;
- (void)saveTouchLayout;
- (BOOL)loadTouchLayoutInto:(ios::touch::Layout&)layout;
- (void)resetTouchLayout;
- (void)beginLayoutEdit;
- (void)finishLayoutEdit;
- (BOOL)isEditingLayout;
- (BOOL)testLayoutPersistenceRoundTrip;
- (void)changeSelectedBinding:(int)step;
- (void)changeSelectedScale:(float)step;
- (void)runSelfTest;
- (void)invalidateFinger:(const Finger&)finger;
@end

@implementation WWTouchControls
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.multipleTouchEnabled = YES;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _area = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    _gamePadRect = CGRectNull;
    _layout = ios::touch::layout(_area.size.width, _area.size.height);
    _moveRing = [CAShapeLayer layer]; _moveKnob = [CAShapeLayer layer];
    _lookCursor = [CAShapeLayer layer]; _moveLabel = [CATextLayer layer];
    _moveRing.lineWidth = 1.5;
    _moveLabel.string = @"Move"; _moveLabel.fontSize = 12;
    _moveLabel.alignmentMode = kCAAlignmentCenter;
    _moveLabel.foregroundColor = [UIColor colorWithWhite:1 alpha:.72].CGColor;
    _moveLabel.contentsScale = UIScreen.mainScreen.scale;
    [_moveRing addSublayer:_moveKnob]; [_moveRing addSublayer:_moveLabel];
    [self.layer addSublayer:_moveRing]; [self.layer addSublayer:_lookCursor];
    _lookCursor.bounds = CGRectMake(-18,-18,36,36);
    _lookCursor.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-18,-18,36,36)].CGPath;
    _lookCursor.fillColor = [UIColor colorWithWhite:1 alpha:.20].CGColor;
    _lookCursor.strokeColor = [UIColor colorWithWhite:1 alpha:.65].CGColor;
    _lookCursor.lineWidth = 1;
    _selectedButton = -1;
    _active = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
    for (NSString* name in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification])
        [nc addObserver:self selector:@selector(controllerChanged:) name:name object:nil];
    [nc addObserver:self selector:@selector(inactive:) name:UIApplicationWillResignActiveNotification object:nil];
    [nc addObserver:self selector:@selector(active:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [self refreshVisibility];
    return self;
}
- (void)dealloc {
    [_lookLink invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (void)controllerChanged:(NSNotification*)note {
    // GameController notification delivery is not a UIKit thread guarantee.
    dispatch_async(dispatch_get_main_queue(), ^{ [self refreshVisibility]; });
}
- (void)inactive:(NSNotification*)note { _active = NO; [self refreshVisibility]; }
- (void)active:(NSNotification*)note { _active = YES; [self refreshVisibility]; }
- (void)refreshVisibility {
    [self updateLayout];
    BOOL physical = NO;
    for (GCController* c in GCController.controllers) if (c.extendedGamepad) { physical = YES; break; }
    const NSInteger mode = [NSUserDefaults.standardUserDefaults integerForKey:@"ios.touchControls"];
    const BOOL visible = _active && (_editing || (!ios::controls_block_input() &&
        touch_buttons::visible((int)mode, physical, false)));
    if (!visible) { _guideShown = NO; [self releaseTouches]; }
    self.hidden = !visible;
    [self updateMotionLayers];
    [self setNeedsDisplayInRect:self.bounds];
}
- (void)releaseLookUpdates {
    [_lookLink invalidate];
    _lookLink = nil;
}
- (void)releaseTouches {
    for (const auto& [key, finger] : _fingers) [self invalidateFinger:finger];
    for (size_t i = 0; i < 8; ++i) {
        const auto& c = _layout.controls[i];
        if (c.radius > 0 && (_pad.buttons & c.button)) {
            [self setNeedsDisplayInRect:CGRectInset(CGRectMake(_area.origin.x + c.x - c.radius,
                _area.origin.y + c.y - c.radius, c.radius * 2, c.radius * 2), -4, -4)];
        }
    }
    [self releaseLookUpdates];
    _fingers.clear();
    _pad = {};
    input::set_touch_pad(_pad);
    [self updateMotionLayers];
}
- (void)updateLayout {
    const CGRect area = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    BOOL fullscreen = NO;
    const CGRect gamePad = ios::gamepad_touch_region(self, &fullscreen);
    const BOOL sameArea = CGRectEqualToRect(area, _area);
    const BOOL sameGamePad = (CGRectIsNull(gamePad) && CGRectIsNull(_gamePadRect)) ||
        CGRectEqualToRect(gamePad, _gamePadRect);
    if (_geometryReady && sameArea && sameGamePad && fullscreen == _gamePadFullscreen) return;

    // Mode changes, PiP movement, rotation, or safe-area changes invalidate finger anchors.
    if (!_fingers.empty()) [self releaseTouches];
    _area = area;
    _gamePadRect = gamePad;
    _gamePadFullscreen = fullscreen;
    _layout = ios::touch::layout(area.size.width, area.size.height, fullscreen);
    [self loadTouchLayoutInto:_layout];
    const ios::touch::Rect settings{static_cast<float>(area.size.width - 78), 12, 78, 36};
    const ios::touch::Rect obstacle = [self gamepadObstacle];
    ios::touch::avoid_rect(_layout, area.size.width, area.size.height, settings, obstacle);
    if (!fullscreen && !CGRectIsNull(gamePad) && CGRectGetWidth(gamePad) > 0 && CGRectGetHeight(gamePad) > 0) {
        ios::touch::avoid_rect(_layout, area.size.width, area.size.height, obstacle, settings);
    }
    _geometryReady = YES;
    [self updateMotionLayers];
    [self setNeedsDisplayInRect:self.bounds];
}
- (ios::touch::Rect)gamepadObstacle {
    if (_gamePadFullscreen || CGRectIsNull(_gamePadRect)) return {};
    return {float(_gamePadRect.origin.x-_area.origin.x),float(_gamePadRect.origin.y-_area.origin.y),
        float(_gamePadRect.size.width),float(_gamePadRect.size.height)};
}
- (BOOL)canPlaceButton:(size_t)index x:(float)x y:(float)y radius:(float)radius {
    const ios::touch::Rect settings{float(_area.size.width-78),12,78,36};
    if (!ios::touch::can_place_button(_layout,index,_area.size.width,_area.size.height,x,y,radius,
        [self gamepadObstacle],settings)) return NO;
    const CGRect toolbar=[self editorToolbarRect];
    return !_editing || !ios::touch::circle_overlaps_rect(x,y,radius,
        {float(toolbar.origin.x-_area.origin.x),float(toolbar.origin.y-_area.origin.y),float(toolbar.size.width),float(toolbar.size.height)});
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [self updateLayout];
}
- (BOOL)loadTouchLayoutInto:(ios::touch::Layout&)layout {
    NSArray* stored = [NSUserDefaults.standardUserDefaults arrayForKey:@"ios.touchLayout"];
    if (stored.count != ios::touch::ButtonConfigs{}.size()) return NO;
    ios::touch::ButtonConfigs configs{};
    for (size_t i = 0; i < configs.size(); ++i) {
        if (![stored[i] isKindOfClass:NSDictionary.class]) return NO;
        NSDictionary* item = stored[i];
        id x = item[@"x"], y = item[@"y"], scale = item[@"scale"], button = item[@"button"];
        if (![x isKindOfClass:NSNumber.class] || ![y isKindOfClass:NSNumber.class] ||
            ![scale isKindOfClass:NSNumber.class] || ![button isKindOfClass:NSNumber.class]) return NO;
        configs[i] = {[(NSNumber*)x floatValue], [(NSNumber*)y floatValue],
                       [(NSNumber*)scale floatValue], [(NSNumber*)button unsignedIntValue]};
    }
    return ios::touch::apply_button_configs(layout, _area.size.width, _area.size.height, configs);
}
- (void)saveTouchLayout {
    if (_area.size.width <= 0 || _area.size.height <= 0) return;
    const auto defaults = ios::touch::layout(_area.size.width, _area.size.height, _gamePadFullscreen);
    const auto configs = ios::touch::button_configs(_layout, _area.size.width, _area.size.height, &defaults);
    if (!ios::touch::valid_button_configs(configs)) return;
    NSMutableArray* stored = [NSMutableArray arrayWithCapacity:configs.size()];
    for (const auto& c : configs)
        [stored addObject:@{@"x":@(c.x), @"y":@(c.y), @"scale":@(c.scale), @"button":@(c.button)}];
    [NSUserDefaults.standardUserDefaults setObject:stored forKey:@"ios.touchLayout"];
}
- (void)resetTouchLayout {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"ios.touchLayout"];
    _geometryReady = NO;
    [self updateLayout];
    [self setNeedsDisplayInRect:self.bounds];
}
- (void)finishLayoutEdit {
    [self saveTouchLayout];
    _editing = NO;
    g_touch_layout_editing.store(false, std::memory_order_release);
    _selectedButton = -1;
    _editorTouch = 0;
    _geometryReady = NO;
    [self updateLayout];
    [self refreshVisibility];
    [self setNeedsDisplayInRect:self.bounds];
}
- (void)beginLayoutEdit {
    if (_editing) return;
    [self releaseTouches];
    _guideShown = NO;
    _selectedButton = -1;
    _editorTouch = 0;
    _editing = YES;
    g_touch_layout_editing.store(true, std::memory_order_release);
    [self refreshVisibility];
    [self setNeedsDisplayInRect:self.bounds];
}
- (BOOL)isEditingLayout { return _editing; }
- (BOOL)testLayoutPersistenceRoundTrip {
    if (_area.size.width <= 0 || _area.size.height <= 0) return NO;
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSString* key = @"ios.touchLayout";
    id savedObject = [[defaults objectForKey:key] copy];
    const BOOL hadSavedObject = savedObject != nil;
    const ios::touch::Layout savedLayout = _layout;
    BOOL passed = NO;
    @try {
        auto baseline = ios::touch::layout(_area.size.width, _area.size.height, _gamePadFullscreen);
        auto config = ios::touch::button_configs(baseline, _area.size.width, _area.size.height);
        config[0].x = .37f;
        config[0].y = .61f;
        config[0].scale = 1.25f;
        config[0].button = input::kMinus;
        NSMutableArray* stored = [NSMutableArray arrayWithCapacity:config.size()];
        for (const auto& c : config)
            [stored addObject:@{@"x":@(c.x), @"y":@(c.y), @"scale":@(c.scale), @"button":@(c.button)}];
        [defaults setObject:stored forKey:key];

        auto loaded = ios::touch::layout(_area.size.width, _area.size.height, _gamePadFullscreen);
        const BOOL didLoad = [self loadTouchLayoutInto:loaded];
        passed = didLoad && stored.count == config.size() &&
            loaded.controls[0].button == input::kMinus &&
            loaded.controls[0].label == std::string_view("-") &&
            std::abs(loaded.controls[0].radius - baseline.controls[0].radius * 1.25f) < .001f &&
            std::abs(loaded.controls[0].x - config[0].x * _area.size.width) < 1.f &&
            std::abs(loaded.controls[0].y - config[0].y * _area.size.height) < 1.f;
    } @finally {
        if (hadSavedObject) [defaults setObject:savedObject forKey:key];
        else [defaults removeObjectForKey:key];
        _layout = savedLayout;
    }
    return passed;
}
- (CGRect)editorToolbarRect {
    const CGFloat width = MIN(300.0, MAX(0.0, _area.size.width - 16.0));
    const CGFloat height = 60.0;
    return CGRectMake(_area.origin.x + 8, _area.origin.y + (_area.size.height - height) * .5, width, height);
}
- (CGRect)editorActionRect:(int)index {
    if (index < 0 || index >= 7) return CGRectNull;
    const CGFloat widths[7] = {48, 44, 26, 40, 26, 30, 30};
    const CGRect toolbar = [self editorToolbarRect];
    const CGFloat total = 262;
    const CGFloat scale = MIN(1.0, MAX(.6, (CGRectGetWidth(toolbar) - 16) / total));
    CGFloat x = toolbar.origin.x + 8;
    for (int i = 0; i < index; ++i) x += widths[i] * scale + 3 * scale;
    return CGRectMake(x, toolbar.origin.y + 26, widths[index] * scale, 26 * scale);
}
- (void)changeSelectedBinding:(int)step {
    if (_selectedButton < 0 || _selectedButton >= 8) return;
    auto& c = _layout.controls[_selectedButton];
    const int oldBinding = ios::touch::binding_index(c.button);
    if (oldBinding < 0) return;
    const CGRect oldRect = CGRectMake(_area.origin.x + c.x - c.radius - 5,
        _area.origin.y + c.y - c.radius - 5, (c.radius + 5) * 2, (c.radius + 5) * 2);
    const int next = (oldBinding + step + (int)ios::touch::kBindings.size()) % (int)ios::touch::kBindings.size();
    const auto base = ios::touch::layout(_area.size.width, _area.size.height, _gamePadFullscreen);
    c.button = ios::touch::kBindings[next].button;
    c.label = ios::touch::kBindings[next].label;
    c.hint = c.button == base.controls[_selectedButton].button
        ? base.controls[_selectedButton].hint : "Custom";
    const CGRect newRect = CGRectMake(_area.origin.x + c.x - c.radius - 5,
        _area.origin.y + c.y - c.radius - 5, (c.radius + 5) * 2, (c.radius + 5) * 2);
    [self setNeedsDisplayInRect:oldRect];
    [self setNeedsDisplayInRect:newRect];
    [self setNeedsDisplayInRect:[self editorToolbarRect]];
}
- (void)changeSelectedScale:(float)step {
    if (_selectedButton < 0 || _selectedButton >= 8) return;
    const auto base = ios::touch::layout(_area.size.width, _area.size.height, _gamePadFullscreen);
    auto& c = _layout.controls[_selectedButton];
    const float oldRadius = c.radius;
    const float baseRadius = base.controls[_selectedButton].radius;
    if (baseRadius <= 0) return;
    const CGRect oldRect = CGRectMake(_area.origin.x + c.x - oldRadius - 5,
        _area.origin.y + c.y - oldRadius - 5, (oldRadius + 5) * 2, (oldRadius + 5) * 2);
    const float scale = std::clamp(oldRadius / baseRadius + step,
        ios::touch::kMinButtonScale, ios::touch::kMaxButtonScale);
    const float newRadius=baseRadius*scale;
    const float newX=std::clamp(c.x,newRadius,std::max(newRadius,float(_area.size.width)-newRadius));
    const float newY=std::clamp(c.y,newRadius,std::max(newRadius,float(_area.size.height)-newRadius));
    if (![self canPlaceButton:_selectedButton x:newX y:newY radius:newRadius]) return;
    c.radius=newRadius; c.x=newX; c.y=newY;
    const CGRect newRect = CGRectMake(_area.origin.x + c.x - c.radius - 5,
        _area.origin.y + c.y - c.radius - 5, (c.radius + 5) * 2, (c.radius + 5) * 2);
    [self setNeedsDisplayInRect:oldRect];
    [self setNeedsDisplayInRect:newRect];
    [self setNeedsDisplayInRect:[self editorToolbarRect]];
}
- (void)drawEditor {
    const CGRect toolbar = [self editorToolbarRect];
    UIBezierPath* panel = [UIBezierPath bezierPathWithRoundedRect:toolbar cornerRadius:12];
    [[UIColor colorWithRed:.015 green:.045 blue:.065 alpha:.94] setFill]; [panel fill];
    [[UIColor colorWithWhite:1 alpha:.55] setStroke]; panel.lineWidth = 1; [panel stroke];

    const auto baseLayout = ios::touch::layout(_area.size.width, _area.size.height, _gamePadFullscreen);
    const float baseRadius = _selectedButton >= 0 ? baseLayout.controls[_selectedButton].radius : 1;
    NSString* selection = _selectedButton >= 0
        ? [NSString stringWithFormat:@"Drag to move  ·  %@  %.0f%%",
            @(_layout.controls[_selectedButton].label),
            baseRadius > 0 ? 100.0 * _layout.controls[_selectedButton].radius / baseRadius : 100.0]
        : @"Tap a button, then drag it; you can change its function and size";
    NSDictionary* titleStyle = @{NSFontAttributeName:[UIFont systemFontOfSize:11 weight:UIFontWeightMedium],
        NSForegroundColorAttributeName:[UIColor colorWithWhite:1 alpha:.90]};
    [selection drawAtPoint:CGPointMake(toolbar.origin.x + 9, toolbar.origin.y + 5) withAttributes:titleStyle];

    NSString* titles[7] = {@"Done", @"Reset", @"‹", @"?", @"›", @"−", @"+"};
    if (_selectedButton >= 0) titles[3] = @(_layout.controls[_selectedButton].label);
    for (int i = 0; i < 7; ++i) {
        const CGRect r = [self editorActionRect:i];
        UIBezierPath* button = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:6];
        [[UIColor colorWithWhite:1 alpha:(i == 0 ? .23 : .12)] setFill]; [button fill];
        [[UIColor colorWithWhite:1 alpha:.34] setStroke]; button.lineWidth = .7; [button stroke];
        NSDictionary* style = @{NSFontAttributeName:[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold],
            NSForegroundColorAttributeName:UIColor.whiteColor};
        const CGSize size = [titles[i] sizeWithAttributes:style];
        [titles[i] drawAtPoint:CGPointMake(CGRectGetMidX(r) - size.width / 2,
            CGRectGetMidY(r) - size.height / 2) withAttributes:style];
    }
}
- (void)runSelfTest {
    NSMutableDictionary<NSString*, id>* results = [NSMutableDictionary dictionary];
    const BOOL skipped = _editing || !_active || !_fingers.empty() || _guideShown || ios::controls_block_input();
    const input::PadState savedPad = _pad;
    [self releaseLookUpdates];

    UIGraphicsBeginImageContextWithOptions(self.bounds.size, NO, 0);
    [self.layer displayIfNeeded];
    [self.layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage* image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    results[@"layout_defaults_roundtrip"] = @([self testLayoutPersistenceRoundTrip]);

    if (skipped) {
        results[@"status"] = @"skipped";
        results[@"reason"] = @"requires active app, no held touches, closed guide, and no blocking overlay";
    } else {
        auto find_point = [&](int control) {
            for (CGFloat y = CGRectGetMinY(_area) + 1; y < CGRectGetMaxY(_area); y += 16)
                for (CGFloat x = CGRectGetMinX(_area) + 1; x < CGRectGetMaxX(_area); x += 16) {
                    const CGPoint p = CGPointMake(x, y);
                    if ([self controlAt:p] == control) return p;
                }
            return CGPointMake(-1, -1);
        };
        const CGPoint moveStart = find_point(9), lookStart = find_point(10);
        const auto& action = _layout.controls[0];
        const CGPoint actionPoint = CGPointMake(_area.origin.x + action.x, _area.origin.y + action.y);
        if (moveStart.x < 0 || lookStart.x < 0 || [self controlAt:actionPoint] != 0) {
            results[@"status"] = @"skipped";
            results[@"reason"] = @"no move, look, and A touch targets in the current display mode";
        } else {
            const NSTimeInterval baseTime = CACurrentMediaTime();
            WWSyntheticTouch* move = [WWSyntheticTouch new];
            move.view = self; move.point = moveStart; move.sampleTime = baseTime;
            WWSyntheticTouch* look = [WWSyntheticTouch new];
            look.view = self; look.point = lookStart; look.sampleTime = baseTime;
            WWSyntheticTouch* actionTouch = [WWSyntheticTouch new];
            actionTouch.view = self; actionTouch.point = actionPoint; actionTouch.sampleTime = baseTime;
            NSSet* began = [NSSet setWithArray:@[move, look, actionTouch]];
            [self touchesBegan:(id)began withEvent:nil];
            [self.layer displayIfNeeded];
            move.point = CGPointMake(moveStart.x + 32, moveStart.y);
            look.point = CGPointMake(lookStart.x + 30, lookStart.y - 4);
            move.sampleTime = look.sampleTime = actionTouch.sampleTime = baseTime + .04;
            NSSet* moved = [NSSet setWithArray:@[move, look, actionTouch]];
            [self touchesMoved:(id)moved withEvent:nil];
            results[@"motion_avoids_canvas_redraw"] = @(!self.layer.needsDisplay && !_moveRing.hidden && !_lookCursor.hidden);
            results[@"multitouch_move_look_action"] = @(_pad.lx > .1f && (_pad.rx != 0 || _pad.ry != 0) &&
                                                          (_pad.buttons & action.button) != 0);

            for (auto& [key, finger] : _fingers)
                if (_layout.controls[finger.control].kind == ios::touch::Kind::LookZone)
                    finger.lastMotion = CACurrentMediaTime() - .13;
            [self cameraFrame:nil];
            results[@"camera_timeout_stops"] = @(_pad.rx == 0 && _pad.ry == 0);
            [self touchesEnded:(id)began withEvent:nil];

            const auto& bButton = _layout.controls[1];
            WWSyntheticTouch* sliding = [WWSyntheticTouch new];
            sliding.view = self; sliding.point = CGPointMake(_area.origin.x + bButton.x,
                _area.origin.y + bButton.y); sliding.sampleTime = CACurrentMediaTime();
            [self touchesBegan:(id)[NSSet setWithObject:sliding] withEvent:nil];
            const BOOL bPressed = (_pad.buttons & bButton.button) != 0;
            sliding.point = CGPointMake(_area.origin.x + bButton.x + bButton.radius + 20,
                                        _area.origin.y + bButton.y);
            sliding.sampleTime += .04;
            [self touchesMoved:(id)[NSSet setWithObject:sliding] withEvent:nil];
            results[@"button_slide_releases"] = @(bPressed && (_pad.buttons & bButton.button) == 0);
            [self touchesEnded:(id)[NSSet setWithObject:sliding] withEvent:nil];

            const auto& lockButton = _layout.controls[5];
            WWSyntheticTouch* cancelled = [WWSyntheticTouch new];
            cancelled.view = self; cancelled.point = CGPointMake(_area.origin.x + lockButton.x,
                _area.origin.y + lockButton.y); cancelled.sampleTime = CACurrentMediaTime();
            [self touchesBegan:(id)[NSSet setWithObject:cancelled] withEvent:nil];
            const BOOL lockPressed = (_pad.buttons & lockButton.button) != 0;
            [self touchesCancelled:(id)[NSSet setWithObject:cancelled] withEvent:nil];
            results[@"cancel_releases"] = @(lockPressed && (_pad.buttons & lockButton.button) == 0);

            WWSyntheticTouch* background = [WWSyntheticTouch new];
            background.view = self; background.point = actionPoint; background.sampleTime = CACurrentMediaTime();
            [self touchesBegan:(id)[NSSet setWithObject:background] withEvent:nil];
            [self releaseTouches];
            results[@"background_release"] = @(_fingers.empty() && _pad.buttons == 0 && _pad.lx == 0 &&
                                               _pad.ly == 0 && _pad.rx == 0 && _pad.ry == 0);
            BOOL pass = YES;
            for (NSString* key in @[@"layout_defaults_roundtrip", @"motion_avoids_canvas_redraw", @"multitouch_move_look_action", @"camera_timeout_stops",
                                    @"button_slide_releases", @"cancel_releases", @"background_release"])
                pass = pass && [results[key] boolValue];
            results[@"status"] = pass ? @"passed" : @"failed";
        }
    }

    [self releaseTouches];
    _pad = savedPad;
    input::set_touch_pad(_pad);
    [self setNeedsDisplayInRect:self.bounds];
    results[@"test_type"] = @"synthetic event samples through the real UIKit touch methods; not device-finger validation";
    results[@"gamepad_fullscreen"] = @(_gamePadFullscreen);
    results[@"layout_image"] = @"captures/touch-controls-layout.png";

    NSError* error = nil;
    NSArray<NSURL*>* documentURLs = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
        inDomains:NSUserDomainMask];
    NSURL* documents = documentURLs.firstObject;
    NSURL* captures = [documents URLByAppendingPathComponent:@"captures" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:captures withIntermediateDirectories:YES
        attributes:nil error:&error];
    if (!error) {
        NSData* json = [NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted error:&error];
        if (json) [json writeToURL:[captures URLByAppendingPathComponent:@"touch-controls-test.json"]
                            options:NSDataWritingAtomic error:&error];
        NSData* png = UIImagePNGRepresentation(image);
        if (png) [png writeToURL:[captures URLByAppendingPathComponent:@"touch-controls-layout.png"]
                         options:NSDataWritingAtomic error:&error];
    }
}
- (BOOL)gamePadOwnsPoint:(CGPoint)point {
    return !_gamePadFullscreen && !CGRectIsNull(_gamePadRect) && CGRectContainsPoint(_gamePadRect, point);
}
- (int)controlAt:(CGPoint)point {
    [self updateLayout];
    if (!_active || ios::controls_block_input() || !CGRectContainsPoint(_area, point) || [self gamePadOwnsPoint:point])
        return -1;
    return ios::touch::control_at(_layout, point.x - _area.origin.x, point.y - _area.origin.y);
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event {
    [self updateLayout];
    if (_editing) return CGRectContainsPoint(_area, point);
    if (_guideShown && CGRectContainsPoint([self guideCardRect], point)) return YES;
    return [self controlAt:point] >= 0;
}
- (BOOL)hasLookFinger {
    for (const auto& [key, finger] : _fingers)
        if (_layout.controls[finger.control].kind == ios::touch::Kind::LookZone) return YES;
    return NO;
}
- (void)invalidateFinger:(const Finger&)finger {
    if (finger.control < 0 || finger.control >= (int)_layout.controls.size()) return;
    const auto& c = _layout.controls[finger.control];
    CGRect dirty;
    if (c.kind == ios::touch::Kind::Button) {
        dirty = CGRectMake(_area.origin.x + c.x - c.radius, _area.origin.y + c.y - c.radius,
                           c.radius * 2, c.radius * 2);
    } else if (c.kind == ios::touch::Kind::MoveZone || c.kind == ios::touch::Kind::LookZone) {
        return; // Moving indicators have their own layers; never dirty the full-screen canvas.
    } else {
        const CGRect card = [self guideCardRect];
        dirty = CGRectIsNull(card) ? self.bounds : card;
    }
    [self setNeedsDisplayInRect:CGRectInset(dirty, -4, -4)];
}
- (void)startLookUpdates {
    if (_lookLink) return;
    _lookLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(cameraFrame:)];
    _lookLink.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
    [_lookLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)cameraFrame:(CADisplayLink*)link {
    NSTimeInterval latestMotion = 0;
    const NSTimeInterval now = CACurrentMediaTime();
    for (auto& [key, finger] : _fingers) {
        if (_layout.controls[finger.control].kind == ios::touch::Kind::LookZone &&
            finger.lastMotion && now - finger.lastMotion > .12) {
            [self invalidateFinger:finger];
            finger.lastMotion = 0;
            finger.velocity = CGPointZero;
        }
        if (_layout.controls[finger.control].kind == ios::touch::Kind::LookZone)
            latestMotion = std::max(latestMotion, finger.lastMotion);
    }
    if (!latestMotion) [self releaseLookUpdates];
    [self rebuildPad:NO];
}
- (void)rebuildPad:(BOOL)redraw {
    const input::PadState oldPad = _pad;
    _pad = {};
    const NSTimeInterval now = CACurrentMediaTime();
    for (const auto& [key, finger] : _fingers) {
        if (finger.control < 0 || [self gamePadOwnsPoint:finger.point]) continue;
        const auto& c = _layout.controls[finger.control];
        const float x = finger.point.x - _area.origin.x, y = finger.point.y - _area.origin.y;
        if (c.kind == ios::touch::Kind::Button) {
            if (ios::touch::hit(c, x, y)) _pad.buttons |= c.button; // sliding out releases a button
        } else if (c.kind == ios::touch::Kind::MoveZone) {
            ios::touch::stick(x - (finger.start.x - _area.origin.x),
                              y - (finger.start.y - _area.origin.y),
                              _layout.move_radius, _pad.lx, _pad.ly);
            ios::touch::apply_sensitivity(_pad.lx, _pad.ly, ios::touch_move_sensitivity());
        } else if (finger.lastMotion && now - finger.lastMotion <= .12) {
            // Right-side swipes act like a camera rate control; a stationary finger stops turning.
            ios::touch::stick(finger.velocity.x, finger.velocity.y, _layout.look_speed, _pad.rx, _pad.ry);
            ios::touch::apply_sensitivity(_pad.rx, _pad.ry, ios::touch_look_sensitivity());
        }
    }
    input::set_touch_pad(_pad);
    [self updateMotionLayers];
    if (redraw) {
        for (size_t i = 0; i < 8; ++i) {
            const auto& c = _layout.controls[i];
            if (c.radius > 0 && ((oldPad.buttons ^ _pad.buttons) & c.button))
                [self setNeedsDisplayInRect:CGRectInset(CGRectMake(_area.origin.x + c.x - c.radius,
                    _area.origin.y + c.y - c.radius, c.radius * 2, c.radius * 2), -4, -4)];
        }
    }
}
- (BOOL)controlOccupied:(int)control {
    for (const auto& [key, finger] : _fingers) if (finger.control == control) return YES;
    return NO;
}
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self updateLayout];
    if (_editing) {
        UITouch* touch = touches.anyObject;
        if (!touch) return;
        const CGPoint point = [touch locationInView:self];
        for (int i = 0; i < 7; ++i) {
            if (!CGRectContainsPoint([self editorActionRect:i], point)) continue;
            switch (i) {
            case 0: [self finishLayoutEdit]; return;
            case 1: [self resetTouchLayout]; _selectedButton = -1; break;
            case 2: [self changeSelectedBinding:-1]; break;
            case 4: [self changeSelectedBinding:1]; break;
            case 5: [self changeSelectedScale:-.05f]; break;
            case 6: [self changeSelectedScale:.05f]; break;
            default: break;
            }
            [self setNeedsDisplayInRect:[self editorToolbarRect]];
            return;
        }
        int selected = -1;
        const float x = point.x - _area.origin.x, y = point.y - _area.origin.y;
        if (_selectedButton >= 0 && ios::touch::hit(_layout.controls[_selectedButton], x, y))
            selected = _selectedButton;
        for (int i = 0; selected < 0 && i < 8; ++i)
            if (ios::touch::hit(_layout.controls[i], x, y)) selected = i;
        const int oldSelected = _selectedButton;
        _selectedButton = selected;
        _editorTouch = (uintptr_t)(__bridge void*)touch;
        if (selected >= 0) {
            const auto& c = _layout.controls[selected];
            _editorGrabOffset = CGPointMake(c.x - x, c.y - y);
        }
        if (oldSelected >= 0) {
            const auto& c = _layout.controls[oldSelected];
            [self setNeedsDisplayInRect:CGRectInset(CGRectMake(_area.origin.x + c.x - c.radius,
                _area.origin.y + c.y - c.radius, c.radius * 2, c.radius * 2), -5, -5)];
        }
        if (selected >= 0) {
            const auto& c = _layout.controls[selected];
            [self setNeedsDisplayInRect:CGRectInset(CGRectMake(_area.origin.x + c.x - c.radius,
                _area.origin.y + c.y - c.radius, c.radius * 2, c.radius * 2), -5, -5)];
        }
        [self setNeedsDisplayInRect:[self editorToolbarRect]];
        return;
    }
    if (_guideShown) {
        for (UITouch* t in touches) {
            const CGPoint point = [t locationInView:self];
            if (CGRectContainsPoint([self guideCardRect], point)) {
                _guideShown = NO;
                [self setNeedsDisplayInRect:[self guideCardRect]];
                return;
            }
        }
        _guideShown = NO; // A control remains usable while the compact guide card is open.
        [self setNeedsDisplayInRect:[self guideCardRect]];
    }
    const auto& guide = _layout.controls[8];
    for (UITouch* t in touches) {
        const CGPoint point = [t locationInView:self];
        if (! [self gamePadOwnsPoint:point] &&
            ios::touch::hit(guide, point.x - _area.origin.x, point.y - _area.origin.y)) {
            [self releaseTouches];
            _guideShown = YES;
            [self setNeedsDisplayInRect:[self guideCardRect]];
            return;
        }
    }
    for (UITouch* t in touches) {
        const CGPoint point = [t locationInView:self];
        const int index = [self controlAt:point];
        if (index < 0 || [self controlOccupied:index]) continue;
        _fingers[(uintptr_t)(__bridge void*)t] = {index, point, point, CGPointZero, t.timestamp, 0};
    }
    [self rebuildPad:YES];
}
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (_editing) {
        for (UITouch* t in touches) {
            if ((uintptr_t)(__bridge void*)t != _editorTouch || _selectedButton < 0) continue;
            auto& c = _layout.controls[_selectedButton];
            const CGRect oldRect = CGRectMake(_area.origin.x + c.x - c.radius - 5,
                _area.origin.y + c.y - c.radius - 5, (c.radius + 5) * 2, (c.radius + 5) * 2);
            const CGPoint point = [t locationInView:self];
            const float x = std::clamp(static_cast<float>(point.x - _area.origin.x + _editorGrabOffset.x),
                             c.radius, std::max(c.radius, static_cast<float>(_area.size.width) - c.radius));
            const float y = std::clamp(static_cast<float>(point.y - _area.origin.y + _editorGrabOffset.y),
                             c.radius, std::max(c.radius, static_cast<float>(_area.size.height) - c.radius));
            if (![self canPlaceButton:_selectedButton x:x y:y radius:c.radius]) continue;
            c.x = x;
            c.y = y;
            const CGRect newRect = CGRectMake(_area.origin.x + c.x - c.radius - 5,
                _area.origin.y + c.y - c.radius - 5, (c.radius + 5) * 2, (c.radius + 5) * 2);
            [self setNeedsDisplayInRect:oldRect];
            [self setNeedsDisplayInRect:newRect];
        }
        return;
    }
    for (UITouch* t in touches) {
        auto i = _fingers.find((uintptr_t)(__bridge void*)t);
        if (i == _fingers.end()) continue;
        const CGPoint point = [t locationInView:self];
        auto& finger = i->second;
        if (_layout.controls[finger.control].kind == ios::touch::Kind::LookZone) {
            const NSTimeInterval dt = t.timestamp - finger.lastSample;
            if (dt > 0 && dt <= .5) {
                finger.velocity = CGPointMake((point.x - finger.point.x) / dt, (point.y - finger.point.y) / dt);
                finger.lastMotion = CACurrentMediaTime();
                [self startLookUpdates];
            }
            finger.lastSample = t.timestamp;
        }
        finger.point = point;

    }
    [self rebuildPad:YES];
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (_editing) {
        for (UITouch* t in touches)
            if ((uintptr_t)(__bridge void*)t == _editorTouch) _editorTouch = 0;
        return;
    }
    for (UITouch* t in touches) {
        auto i = _fingers.find((uintptr_t)(__bridge void*)t);
        if (i != _fingers.end()) [self invalidateFinger:i->second];
        _fingers.erase((uintptr_t)(__bridge void*)t);
    }
    if (![self hasLookFinger]) [self releaseLookUpdates];
    [self rebuildPad:YES];
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self touchesEnded:touches withEvent:event];
}
- (void)drawButton:(const ios::touch::Control&)c active:(BOOL)active {
    if (c.radius <= 0) return;
    const CGPoint center = CGPointMake(_area.origin.x + c.x, _area.origin.y + c.y);
    const CGRect bounds = CGRectMake(center.x - c.radius, center.y - c.radius, c.radius * 2, c.radius * 2);
    UIBezierPath* path = [UIBezierPath bezierPathWithOvalInRect:bounds];
    [[UIColor colorWithRed:.035 green:.105 blue:.13 alpha:(active ? .55 : .20)] setFill];
    [path fill];
    [[UIColor colorWithWhite:1 alpha:(active ? .88 : .50)] setStroke];
    path.lineWidth = 1.5;
    [path stroke];
    NSString* title = @(c.label);
    NSString* hint = @(c.hint);
    const CGFloat titleSize = c.radius < 30 ? 15 : c.radius < 38 ? 16 : 18;
    NSDictionary* titleStyle = @{NSFontAttributeName:[UIFont systemFontOfSize:titleSize weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName:[UIColor colorWithWhite:1 alpha:.95]};
    NSDictionary* hintStyle = @{NSFontAttributeName:[UIFont systemFontOfSize:10 weight:UIFontWeightMedium],
        NSForegroundColorAttributeName:[UIColor colorWithWhite:1 alpha:.78]};
    const CGSize titleSizeInView = [title sizeWithAttributes:titleStyle];
    const CGSize hintSizeInView = [hint sizeWithAttributes:hintStyle];
    const CGFloat titleOffset = hint.length ? -hintSizeInView.height * .28 : 0;
    [title drawAtPoint:CGPointMake(center.x - titleSizeInView.width / 2, center.y - titleSizeInView.height / 2 + titleOffset)
        withAttributes:titleStyle];
    if (hint.length)
        [hint drawAtPoint:CGPointMake(center.x - hintSizeInView.width / 2, center.y + c.radius * .20 - hintSizeInView.height / 2)
            withAttributes:hintStyle];
}
- (void)drawLookPadAt:(CGPoint)center radius:(CGFloat)radius {
    CGRect bounds = CGRectMake(center.x - radius, center.y - radius, radius * 2, radius * 2);
    UIBezierPath* ring = [UIBezierPath bezierPathWithOvalInRect:bounds];
    [[UIColor colorWithWhite:0 alpha:.10] setFill]; [ring fill];
    [[UIColor colorWithWhite:1 alpha:.34] setStroke]; ring.lineWidth = 1.5; [ring stroke];
    NSString* title = @"Camera";
    NSDictionary* style = @{NSFontAttributeName:[UIFont systemFontOfSize:12 weight:UIFontWeightMedium],
        NSForegroundColorAttributeName:[UIColor colorWithWhite:1 alpha:.72]};
    const CGSize size = [title sizeWithAttributes:style];
    [title drawAtPoint:CGPointMake(center.x - size.width / 2, center.y + radius * .48 - size.height / 2)
        withAttributes:style];
}
- (CGRect)guideCardRect {
    const CGFloat edge = MIN(_area.size.width, _area.size.height);
    const CGFloat fontSize = std::clamp(edge * .034, 11.0, 14.0);
    const CGFloat lineHeight = fontSize * 1.48;
    const CGFloat padding = 10;
    const CGFloat width = MIN(460.0, MAX(0.0, _area.size.width - 20.0));
    const CGFloat height = padding * 2 + fontSize * 1.5 + lineHeight * 5 + 3;
    return CGRectMake(_area.origin.x + (_area.size.width - width) / 2,
                     _area.origin.y + (_area.size.height - height) / 2, width, height);
}
- (void)updateMotionLayers {
    const CGPoint ghost = CGPointMake(_area.origin.x + _layout.move_x, _area.origin.y + _layout.move_y);
    CGPoint anchor = ghost, knob = CGPointZero, look = CGPointZero;
    BOOL moving = NO, looking = NO;
    const NSTimeInterval now = CACurrentMediaTime();
    for (const auto& [key, finger] : _fingers) {
        if ([self gamePadOwnsPoint:finger.point]) continue;
        if (_layout.controls[finger.control].kind == ios::touch::Kind::MoveZone) {
            anchor = finger.start;
            float x = 0, y = 0;
            ios::touch::stick(finger.point.x-finger.start.x, finger.point.y-finger.start.y, _layout.move_radius,x,y);
            knob = CGPointMake(x*_layout.move_radius,-y*_layout.move_radius);
            moving = YES;
        } else if (_layout.controls[finger.control].kind == ios::touch::Kind::LookZone &&
                   finger.lastMotion && now-finger.lastMotion <= .12) {
            looking = YES; look = finger.point;
        }
    }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _moveRing.hidden = _editing || (!moving && [self gamePadOwnsPoint:ghost]);
    _lookCursor.hidden = _editing || !looking;
    const CGFloat radius = _layout.move_radius;
    const CGRect ringRect = CGRectMake(-radius,-radius,radius*2,radius*2);
    if (!_moveRing.path || !CGRectEqualToRect(CGPathGetBoundingBox(_moveRing.path),ringRect)) {
        _moveRing.bounds = ringRect;
        _moveRing.path = [UIBezierPath bezierPathWithOvalInRect:ringRect].CGPath;
        const CGFloat dot = radius*.28;
        _moveKnob.bounds = CGRectMake(-dot,-dot,dot*2,dot*2);
        _moveKnob.path = [UIBezierPath bezierPathWithOvalInRect:_moveKnob.bounds].CGPath;
        _moveLabel.frame = CGRectMake(-40,radius*.48-8,80,20);
    }
    _moveRing.position = anchor; _moveKnob.position = knob;
    _moveRing.fillColor = [UIColor colorWithWhite:0 alpha:moving?.18:.10].CGColor;
    _moveRing.strokeColor = [UIColor colorWithWhite:1 alpha:moving?.56:.34].CGColor;
    _moveKnob.fillColor = [UIColor colorWithWhite:1 alpha:moving?.62:.28].CGColor;
    _moveLabel.hidden = moving; _lookCursor.position = look;
    [CATransaction commit];
}
- (void)drawGuide {
    const CGFloat edge = MIN(_area.size.width, _area.size.height);
    const CGFloat fontSize = std::clamp(edge * .034, 11.0, 14.0);
    const CGFloat lineHeight = fontSize * 1.48;
    NSString* action = @(_layout.controls[0].label);
    NSString* sword = @(_layout.controls[1].label);
    NSString* itemX = @(_layout.controls[2].label);
    NSString* itemY = @(_layout.controls[3].label);
    NSString* itemR = @(_layout.controls[4].label);
    NSString* lock = @(_layout.controls[5].label);
    NSString* shield = @(_layout.controls[6].label);
    NSArray<NSString*>* lines = @[
        @"Move: drag on the left; swipe on the right to look around",
        [NSString stringWithFormat:@"Action/combat: %@ interact, %@ target, %@ sword, %@ shield", action, lock, sword, shield],
        [NSString stringWithFormat:@"Sailing: stick steers, %@ sail/fire, %@ slow down/disembark", action, sword],
        [NSString stringWithFormat:@"Items: %@/%@/%@; you can tap the GamePad screen directly", itemX, itemY, itemR],
    ];
    const CGFloat padding = 10;
    const CGRect card = [self guideCardRect];
    UIBezierPath* panel = [UIBezierPath bezierPathWithRoundedRect:card cornerRadius:14];
    [[UIColor colorWithRed:.025 green:.07 blue:.09 alpha:.92] setFill];
    [panel fill];
    [[UIColor colorWithWhite:1 alpha:.78] setStroke];
    panel.lineWidth = 1;
    [panel stroke];

    NSDictionary* titleStyle = @{
        NSFontAttributeName:[UIFont systemFontOfSize:fontSize * 1.12 weight:UIFontWeightBold],
        NSForegroundColorAttributeName:UIColor.whiteColor,
    };
    NSDictionary* bodyStyle = @{
        NSFontAttributeName:[UIFont systemFontOfSize:fontSize weight:UIFontWeightMedium],
        NSForegroundColorAttributeName:[UIColor colorWithWhite:1 alpha:.94],
    };
    NSDictionary* closeStyle = @{
        NSFontAttributeName:[UIFont systemFontOfSize:fontSize * .82 weight:UIFontWeightRegular],
        NSForegroundColorAttributeName:[UIColor colorWithWhite:1 alpha:.68],
    };
    [@"Touch controls" drawAtPoint:CGPointMake(card.origin.x + padding, card.origin.y + padding * .45)
        withAttributes:titleStyle];
    CGFloat y = card.origin.y + padding + fontSize * 1.45;
    for (NSString* line in lines) {
        [line drawAtPoint:CGPointMake(card.origin.x + padding, y) withAttributes:bodyStyle];
        y += lineHeight;
    }
    [@"Tap this card to close it; controls outside it still work" drawAtPoint:CGPointMake(card.origin.x + padding, y - lineHeight * .1)
        withAttributes:closeStyle];
}
- (void)drawRect:(CGRect)rect {
    for (size_t i = 0; i < 8; ++i) {
        const auto& c = _layout.controls[i];
        const CGRect buttonRect = CGRectMake(_area.origin.x + c.x - c.radius,
            _area.origin.y + c.y - c.radius, c.radius * 2, c.radius * 2);
        if (c.radius > 0 && CGRectIntersectsRect(rect, buttonRect))
            [self drawButton:c active:(_pad.buttons & c.button) != 0 || (_editing && (int)i == _selectedButton)];
    }
    if (_layout.gamepad_only && !_editing) {
        const CGPoint center = CGPointMake(_area.origin.x + _layout.look_x, _area.origin.y + _layout.look_y);
        const CGRect lookRect = CGRectMake(center.x - _layout.look_radius - 4, center.y - _layout.look_radius - 4,
            (_layout.look_radius + 4) * 2, (_layout.look_radius + 4) * 2);
        if (CGRectIntersectsRect(rect, lookRect)) [self drawLookPadAt:center radius:_layout.look_radius];
    }
    if (_editing) {
        [self drawEditor];
    } else if (!_guideShown) {
        const auto& guide = _layout.controls[8];
        const CGRect guideRect = CGRectMake(_area.origin.x + guide.x - guide.radius,
            _area.origin.y + guide.y - guide.radius, guide.radius * 2, guide.radius * 2);
        if (CGRectIntersectsRect(rect, guideRect)) [self drawButton:guide active:NO];
    } else if (CGRectIntersectsRect(rect, [self guideCardRect])) {
        [self drawGuide];
    }
}
@end

namespace ios {
static WWTouchControls* touch_view;
void install_touch_controls(UIViewController* controller) {
    touch_view = [[WWTouchControls alloc] initWithFrame:controller.view.bounds];
    [controller.view addSubview:touch_view];
}
void refresh_touch_controls() { [touch_view refreshVisibility]; }
void release_touch_controls() { [touch_view releaseTouches]; }
void edit_touch_layout() { [touch_view beginLayoutEdit]; }
bool touch_layout_editing() { return g_touch_layout_editing.load(std::memory_order_acquire); }
void finish_touch_layout_edit() { [touch_view finishLayoutEdit]; }
float touch_move_sensitivity() {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:@"ios.touchMoveSensitivity"];
    return ios::touch::sensitivity([value isKindOfClass:NSNumber.class] ? [(NSNumber*)value floatValue] : 1.f);
}
float touch_look_sensitivity() {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:@"ios.touchLookSensitivity"];
    return ios::touch::sensitivity([value isKindOfClass:NSNumber.class] ? [(NSNumber*)value floatValue] : 1.f);
}
void set_touch_sensitivity(float move, float look) {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    [defaults setFloat:ios::touch::sensitivity(move) forKey:@"ios.touchMoveSensitivity"];
    [defaults setFloat:ios::touch::sensitivity(look) forKey:@"ios.touchLookSensitivity"];
}
void reset_touch_configuration() {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:@"ios.touchLayout"];
    [defaults removeObjectForKey:@"ios.touchMoveSensitivity"];
    [defaults removeObjectForKey:@"ios.touchLookSensitivity"];
    [defaults setFloat:1 forKey:@"ios.touchMoveSensitivity"];
    [defaults setFloat:1 forKey:@"ios.touchLookSensitivity"];
    [touch_view resetTouchLayout];
}
void test_touch_controls() {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [touch_view runSelfTest]; });
        return;
    }
    [touch_view runSelfTest];
}
}
