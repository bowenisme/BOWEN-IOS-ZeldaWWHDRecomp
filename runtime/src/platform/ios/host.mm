// UIKit host for the existing Metal renderer. Game code is generated and signed on the Mac.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <sys/resource.h>
#include "game_clock.h"
#include <condition_variable>
#include <map>
#include <mutex>
#include <string>
#include <tuple>
#include "ios.h"
#include "controls.h"
#include "runtime_test.h"
#include "frame_pacing.h"
#include "frame_statistics.h"
#include "play_time.h"
#include "display_policy.h"
#include "touch_controls.h"
#include "gamepad_touch.h"
#include "mods/fast_forward.h"
#include "runtime.h"
#include "recomp_table.h"
#include "input.h"
#include "input_map.h"
#include "interp.h"
#include "savestate.h"
#include "perf_metrics.h"
#include "aspect.h"
#include "guest_addr.h"
#include "gfx/metal.h"
#include "gfx/metal_upscale.h"
#include "gfx/metal_gamepad_backdrop.h"
#import <MetalFX/MetalFX.h>
#include "gx2/gx2.h"
#include "gfx/renderer.h"
#include "gfx/display_modes.h"
#include "gfx/headless_compose.h"
#include "overlay/overlay.h"
#include "overlay/guest_hud.h"
#include "overlay/hostui.h"
#include "overlay/extensions.h"
#include "exception_report.h"
#include "screenshot.h"
#include "imgui.h"
#include "backends/imgui_impl_metal.h"

namespace gfx {
bool request_ios_live_present_capture(const std::string& path);
void cancel_ios_live_present_capture(const std::string& path);
}

static UIWindow* g_window;
@class WWMetalView;
static WWMetalView* g_metal_view;
static UILabel* g_status;
static bool g_initialized = false;
static bool g_game_running = false;
static std::mutex g_gpu_mutex;
static std::condition_variable g_gpu_cv;
static bool g_active = true;
static CADisplayLink* g_display_link;
static int g_refresh_request = 0;
static double g_display_link_hz = 0;
static ios::PlayTimeCounter g_play_time;
static double g_play_time_saved_at = 0;
static NSString* const play_time_key = @"ios.playTimeSeconds";

static void save_play_time(double now) {
    [NSUserDefaults.standardUserDefaults setDouble:g_play_time.checkpoint(now) forKey:play_time_key];
    g_play_time_saved_at = now;
}

static int target_output_fps() {
    return ios::pacing::target_output_fps(interp::mode(), interp::output_fps(),
        game_clock::rate(), mods::fast_forward_active());
}

static NSString* ios_live_capture_path(NSString* captures, uint64_t sequence) {
    for (NSUInteger suffix = 1;; ++suffix) {
        NSString* name = suffix == 1
            ? [NSString stringWithFormat:@"ios-live-input-present-%llu.png", (unsigned long long)sequence]
            : [NSString stringWithFormat:@"ios-live-input-present-%llu_%lu.png", (unsigned long long)sequence, (unsigned long)suffix];
        NSString* path = [captures stringByAppendingPathComponent:name];
        if (![NSFileManager.defaultManager fileExistsAtPath:path] &&
            ![NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingString:@".part"]]) return path;
    }
}

static NSString* ios_live_controller_family() {
    switch (input_map::pad_family()) {
    case input_map::PadFamily::kXbox: return @"xbox";
    case input_map::PadFamily::kPlayStation: return @"playstation";
    case input_map::PadFamily::kNintendo: return @"nintendo";
    case input_map::PadFamily::kUnknown: return @"unknown";
    }
    return @"unknown";
}

// Live, file-driven gameplay input is an opt-in device-test aid. Each command is bounded to 2 s;
// it goes through the normal GamePad path and is released on timeout, focus loss, or panel capture.
static void start_live_input_bridge(NSString* documents) {
    const char* enabled = getenv("WWHD_IOS_LIVE_INPUT");
    if (!enabled || strcmp(enabled, "1")) return;
    NSString* captures = [documents stringByAppendingPathComponent:@"captures"];
    [NSFileManager.defaultManager createDirectoryAtPath:captures withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* commandPath = [captures stringByAppendingPathComponent:@"ios-live-input.json"];
    NSString* ackPath = [captures stringByAppendingPathComponent:@"ios-live-input-ack.json"];
    [@"{\"sequence\":0}" writeToFile:commandPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    LOG("[ios-live-input] enabled; commands: %s", commandPath.fileSystemRepresentation);

    __block uint64_t lastSequence = 0, actionStartFrame = 0, actionStartStep = 0;
    __block double actionStartTime = 0, releaseAt = 0;
    __block bool holding = false;
    __block uint32_t lastButtons = 0;
    __block NSString* lastCapture = @"";
    __block NSString* lastPresentCapture = @"";
    __block NSString* pendingPresentCapture = @"";
    __block NSString* presentCaptureStatus = @"idle";
    __block double presentCaptureDeadline = 0;
    auto writeAck = ^(uint64_t sequence, NSString* status, uint64_t frames, uint64_t steps, double seconds) {
        const uint32_t play = GD(0x1046F0B0);
        char stage[9]{};
        memcpy(stage, mem::ptr(play + 0x5134), 8);
        NSDictionary* ack = @{@"sequence":@(sequence), @"status":status,
            @"frameCount":@(render::frame_count()), @"logicSteps":@(interp::executed_steps()),
            @"actionFrames":@(frames), @"actionSteps":@(steps), @"actionSeconds":@(seconds),
            @"stage":[NSString stringWithUTF8String:stage]?:@"unknown", @"eventMode":@(ld8(play + 0x5292)),
            @"active":@(UIApplication.sharedApplication.applicationState == UIApplicationStateActive),
            @"settingsOpen":@(ios::controls_block_input()), @"capture":lastCapture,
            @"presentCapture":lastPresentCapture, @"presentCaptureStatus":presentCaptureStatus,
            @"controllerFamily":ios_live_controller_family()};
        NSData* data = [NSJSONSerialization dataWithJSONObject:ack options:0 error:nil];
        if (data) [data writeToFile:ackPath atomically:YES];
    };
    auto readNumber = [](NSDictionary* command, NSString* key, double fallback, bool* valid) {
        id value = command[key];
        if (!value) return fallback;
        if (![value isKindOfClass:NSNumber.class]) { *valid = false; return fallback; }
        const double number = [value doubleValue];
        if (!std::isfinite(number) || number < -1 || number > 1) *valid = false;
        return number;
    };
    [NSTimer scheduledTimerWithTimeInterval:.05 repeats:YES block:^(NSTimer*) {
        const double now = CACurrentMediaTime();
        NSData* data = [NSData dataWithContentsOfFile:commandPath options:NSDataReadingMappedIfSafe error:nil];
        NSDictionary* command = data.length > 0 && data.length <= 1024
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSNumber* sequenceValue = [command isKindOfClass:NSDictionary.class] ? command[@"sequence"] : nil;
        if ([sequenceValue isKindOfClass:NSNumber.class] && sequenceValue.unsignedLongLongValue > lastSequence) {
            const uint64_t sequence = sequenceValue.unsignedLongLongValue;
            lastSequence = sequence;
            bool valid = true;
            const double duration = [command[@"durationMs"] isKindOfClass:NSNumber.class] ? [command[@"durationMs"] doubleValue] : 0;
            id presentScreenshotValue = command[@"presentScreenshot"];
            const bool wantsPresentScreenshot = [presentScreenshotValue isKindOfClass:NSNumber.class] &&
                [presentScreenshotValue boolValue];
            if (presentScreenshotValue && (![presentScreenshotValue isKindOfClass:NSNumber.class] ||
                                            ([presentScreenshotValue doubleValue] != 0.0 && [presentScreenshotValue doubleValue] != 1.0))) valid = false;
            id performanceHudValue = command[@"performanceHud"];
            const bool setsPerformanceHud = performanceHudValue != nil;
            if (setsPerformanceHud && (![performanceHudValue isKindOfClass:NSNumber.class] ||
                                       ([performanceHudValue doubleValue] != 0.0 && [performanceHudValue doubleValue] != 1.0))) valid = false;
            input::PadState pad{};
            pad.lx = (float)readNumber(command, @"lx", 0, &valid);
            pad.ly = (float)readNumber(command, @"ly", 0, &valid);
            pad.rx = (float)readNumber(command, @"rx", 0, &valid);
            pad.ry = (float)readNumber(command, @"ry", 0, &valid);
            NSArray* buttons = [command[@"buttons"] isKindOfClass:NSArray.class] ? command[@"buttons"] : @[];
            if (buttons.count > 8 || (!wantsPresentScreenshot && !setsPerformanceHud &&
                                      (!std::isfinite(duration) || duration < 1 || duration > 2000))) valid = false;
            if (wantsPresentScreenshot && (buttons.count != 0 || pad.lx != 0 || pad.ly != 0 || pad.rx != 0 || pad.ry != 0 ||
                                           [command[@"screenshot"] boolValue] || command[@"durationMs"])) valid = false;
            if (setsPerformanceHud && (wantsPresentScreenshot || buttons.count != 0 || pad.lx != 0 || pad.ly != 0 ||
                                       pad.rx != 0 || pad.ry != 0 || [command[@"screenshot"] boolValue] || command[@"durationMs"])) valid = false;
            for (id value in buttons) {
                if (![value isKindOfClass:NSString.class]) { valid = false; break; }
                NSString* button = value;
                if ([button isEqualToString:@"A"]) pad.buttons |= input::kA;
                else if ([button isEqualToString:@"B"]) pad.buttons |= input::kB;
                else if ([button isEqualToString:@"X"]) pad.buttons |= input::kX;
                else if ([button isEqualToString:@"Y"]) pad.buttons |= input::kY;
                else if ([button isEqualToString:@"R"]) pad.buttons |= input::kR;
                else if ([button isEqualToString:@"ZL"]) pad.buttons |= input::kZL;
                else if ([button isEqualToString:@"ZR"]) pad.buttons |= input::kZR;
                else if ([button isEqualToString:@"PLUS"]) pad.buttons |= input::kPlus;
                else if ([button isEqualToString:@"MINUS"]) pad.buttons |= input::kMinus;
                else if ([button isEqualToString:@"UP"]) pad.buttons |= input::kUp;
                else if ([button isEqualToString:@"DOWN"]) pad.buttons |= input::kDown;
                else if ([button isEqualToString:@"LEFT"]) pad.buttons |= input::kLeft;
                else if ([button isEqualToString:@"RIGHT"]) pad.buttons |= input::kRight;
                else valid = false;
            }
            const bool bridgeAction = wantsPresentScreenshot || setsPerformanceHud;
            const bool allowed = g_active && UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
                (bridgeAction || !ios::controls_block_input());
            if (holding) { input::set_touch_pad({}); holding = false; }
            if (!valid || !allowed) {
                writeAck(sequence, valid ? @"blocked" : @"invalid", 0, 0, 0);
            } else if (setsPerformanceHud) {
                ios::set_performance_hud([performanceHudValue boolValue]);
                // The setter queues on the main thread; ACK after the UIKit toggle and demand refresh.
                dispatch_async(dispatch_get_main_queue(),^{ writeAck(sequence,@"performance-updated",0,0,0); });
            } else if (wantsPresentScreenshot) {
                NSString* path = ios_live_capture_path(captures, sequence);
                if (!pendingPresentCapture.length && gfx::request_ios_live_present_capture(path.fileSystemRepresentation)) {
                    lastPresentCapture = pendingPresentCapture = path;
                    presentCaptureStatus = @"pending";
                    presentCaptureDeadline = now + 10.0;
                    writeAck(sequence, @"capture-pending", 0, 0, 0);
                } else {
                    lastPresentCapture = path;
                    presentCaptureStatus = @"busy";
                    writeAck(sequence, @"capture-busy", 0, 0, 0);
                }
            } else {
                actionStartFrame = render::frame_count();
                actionStartStep = interp::executed_steps();
                actionStartTime = now;
                releaseAt = now + duration / 1000.0;
                holding = true;
                lastButtons = pad.buttons;
                input::set_touch_pad(pad);
                if ([command[@"screenshot"] boolValue]) {
                    lastCapture = @(screenshot::last_file().c_str());
                    screenshot::request();
                }
                writeAck(sequence, @"accepted", 0, 0, 0);
                LOG("[ios-live-input] seq=%llu durationMs=%.0f buttons=%08X L=(%.2f,%.2f) R=(%.2f,%.2f)",
                    (unsigned long long)sequence, duration, lastButtons, pad.lx, pad.ly, pad.rx, pad.ry);
            }
        }
        if (holding && (!g_active || UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
                        ios::controls_block_input() || now >= releaseAt)) {
            input::set_touch_pad({});
            holding = false;
            const uint64_t frames = render::frame_count() - actionStartFrame;
            const uint64_t steps = interp::executed_steps() - actionStartStep;
            writeAck(lastSequence, @"completed", frames, steps, now - actionStartTime);
            LOG("[ios-live-input] seq=%llu released after %.3fs, frames=%llu steps=%llu",
                (unsigned long long)lastSequence, now - actionStartTime,
                (unsigned long long)frames, (unsigned long long)steps);
        }
        if (lastCapture.length) {
            const std::string capture = screenshot::last_file();
            if (capture.size() && ![lastCapture isEqualToString:@(capture.c_str())]) {
                lastCapture = @(capture.c_str());
                writeAck(lastSequence, holding ? @"accepted" : @"completed",
                    render::frame_count() - actionStartFrame, interp::executed_steps() - actionStartStep,
                    now - actionStartTime);
            }
        }
        if (pendingPresentCapture.length) {
            if ([NSFileManager.defaultManager fileExistsAtPath:pendingPresentCapture]) {
                lastPresentCapture = pendingPresentCapture;
                pendingPresentCapture = @"";
                presentCaptureStatus = @"captured";
                writeAck(lastSequence, holding ? @"accepted" : @"completed",
                    holding ? render::frame_count() - actionStartFrame : 0,
                    holding ? interp::executed_steps() - actionStartStep : 0,
                    holding ? now - actionStartTime : 0);
            } else if (now >= presentCaptureDeadline) {
                gfx::cancel_ios_live_present_capture(pendingPresentCapture.fileSystemRepresentation);
                pendingPresentCapture = @"";
                presentCaptureStatus = @"failed";
                writeAck(lastSequence, @"capture-failed", 0, 0, 0);
            }
        }
    }];
}

namespace gfx {
bool fxaa_enabled();
void dump_texture(id<MTLTexture>, const char*, bool, bool);
// the picture's size at full internal resolution (same helpers as display.mm on the Mac)
static float nominal_w(const Screen& s) { return s.tex ? float(s.tex.width) / s.dyn : 0.0f; }
static float nominal_h(const Screen& s) { return s.tex ? float(s.tex.height) / s.dyn : 0.0f; }
#include "gfx/metal_present.inc"

bool host_setting(const char* key, std::string& value) {
    id v = [NSUserDefaults.standardUserDefaults stringForKey:@(key)];
    if (!v) return false;
    value = [v UTF8String];
    return true;
}
void set_host_setting(const char* key, const std::string& value) {
    [NSUserDefaults.standardUserDefaults setObject:@(value.c_str()) forKey:@(key)];
}
void run_appkit_loop() {} // UIApplicationMain already owns the main thread's event loop.
void show_startup_notice(const std::string& title, const std::string& text) {
    LOG("[ios] %s: %s", title.c_str(), text.c_str());
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController* a = [UIAlertController alertControllerWithTitle:@(title.c_str()) message:@(text.c_str()) preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [g_window.rootViewController presentViewController:a animated:YES completion:nil];
    });
}
}

@interface WWMetalView : UIView {
    UITouch* _gamepadTouch;
}
- (void)releaseGamepadTouch;
@end
@implementation WWMetalView
+ (Class)layerClass { return CAMetalLayer.class; }
- (void)refreshFrameRate:(CADisplayLink*)link {
    const int maximum = (int)(self.window.screen ?: UIScreen.mainScreen).maximumFramesPerSecond;
    const int requested = ios::pacing::refresh_request(g_game_running ? target_output_fps() : 30, maximum);
    if (g_refresh_request != requested) {
        // ProMotion hints do not guarantee the requested rate (power, thermal and OS policy).
        link.preferredFrameRateRange = CAFrameRateRangeMake(requested, requested, requested);
        g_refresh_request = requested;
    }
    static bool overlay_was_up = false;  // the touch buttons step aside while the Settings window is open
    if (const bool up = overlay::captures(); up != overlay_was_up) { overlay_was_up = up; ios::refresh_touch_controls(); }
    const double interval = link.targetTimestamp - link.timestamp;
    g_display_link_hz = interval > 0 ? 1.0 / interval : 0;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer* layer = (CAMetalLayer*)self.layer;
    CGFloat scale = self.window.screen.nativeScale ?: UIScreen.mainScreen.nativeScale;
    self.contentScaleFactor = scale;
    const CGSize size=CGSizeMake(std::round(self.bounds.size.width * scale),std::round(self.bounds.size.height * scale));
    if (!CGSizeEqualToSize(layer.drawableSize,size)) { [self releaseGamepadTouch]; layer.drawableSize=size; }
    CGSize pixels = layer.drawableSize;
    if (pixels.width > 0 && pixels.height > 0) {
        aspect::set_window_aspect(pixels.width / pixels.height);
        if (!getenv("WWHD_RES_SCALE")) {
            const bool native=!gfx::upscale::requested() && ![@"0" isEqualToString:[NSUserDefaults.standardUserDefaults stringForKey:@"ios.nativeResolution"]];
            id savedInputPercent=[NSUserDefaults.standardUserDefaults objectForKey:@"ios.upscaleInputPercent"];
            const float inputRatio=ios::display::saved_upscale_ratio(savedInputPercent? (int)[savedInputPercent integerValue] : -1,
                (int)[NSUserDefaults.standardUserDefaults integerForKey:@"ios.upscaleQuality"]);
            gfx::set_res_scale(gfx::upscale::requested()
                ?ios::display::upscale_scale(pixels.width,pixels.height,aspect::requested(),
                    inputRatio)
                :ios::display::render_scale(native,pixels.width,pixels.height,aspect::requested()));
        }
    }
}
- (void)routeTouch:(UITouch*)touch down:(bool)down {
    if (!g_active || ios::controls_block_input()) { [self releaseGamepadTouch]; return; }
    CGPoint p = [touch locationInView:self];
    if (self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;
    float nx = p.x / self.bounds.size.width, ny = p.y / self.bounds.size.height;
    if (overlay::captures()) {
        overlay::mouse_move(nx, ny, true);
        overlay::mouse_button(0, down, true);
    } else {
        if (!down) {
            if (touch == _gamepadTouch) [self releaseGamepadTouch];
            return;
        }
        if (_gamepadTouch && touch != _gamepadTouch) return;
        float tx = 0, ty = 0;
        if (gfx::overlay_hit(nx, ny, &tx, &ty, _gamepadTouch != nil)) {
            _gamepadTouch = touch;
            input::set_touch(true, tx, ty);
        }
    }
}
- (void)releaseGamepadTouch { _gamepadTouch = nil; input::set_touch(false, 0, 0); }
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { for (UITouch* touch in touches) [self routeTouch:touch down:true]; }
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { for (UITouch* touch in touches) [self routeTouch:touch down:true]; }
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { for (UITouch* touch in touches) [self routeTouch:touch down:false]; }
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { for (UITouch* touch in touches) [self routeTouch:touch down:false]; }
@end

namespace ios {
CGRect gamepad_touch_region(UIView* target, bool* fullscreen) {
    if (fullscreen) *fullscreen = false;
    float x, y, w, h;
    if (!target || !g_metal_view || !gfx::gamepad_picture(&x, &y, &w, &h, fullscreen)) return CGRectNull;
    const CGRect bounds = g_metal_view.bounds;
    const CGRect picture = CGRectMake(bounds.origin.x + x * bounds.size.width,
        bounds.origin.y + y * bounds.size.height, w * bounds.size.width, h * bounds.size.height);
    return [g_metal_view convertRect:picture toView:target];
}
}

namespace gfx {
void display_init() {
    R.tv.layer = (CAMetalLayer*)g_metal_view.layer;
    R.tv.layer.device = R.device;
    R.tv.layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    R.tv.layer.framebufferOnly = YES;
    R.tv.visible = true;
    g_has_drc_window = false;
    g_drc_during_switch = true;
    display_set_mode(kDrcAuto);
    NSString* savedScreen=[NSUserDefaults.standardUserDefaults stringForKey:@"ios.gamepadScreen"];
    if([savedScreen isEqualToString:@"1"])display_set_mode(kDrcPip);
    if([savedScreen isEqualToString:@"4"])display_set_mode(kDrcGamePad);
    g_shown = true;
    interp::set_display_hz((int)g_window.screen.maximumFramesPerSecond);
    overlay::set_density(g_window.screen.scale);
    input::init();
    create_present_pipeline();
}
}

static NSArray* g_full_constraints;
static NSArray* g_safe_constraints;
static bool g_full_screen=true;
namespace ios {
bool full_screen() { return g_full_screen; }
void set_full_screen(bool full) {
    if(!g_full_constraints||full==g_full_screen) return;
    g_full_screen=full;
    [NSLayoutConstraint deactivateConstraints:full?g_safe_constraints:g_full_constraints];
    [NSLayoutConstraint activateConstraints:full?g_full_constraints:g_safe_constraints];
    [g_metal_view.superview layoutIfNeeded];
}
PlayTime play_time() {
    const double now = CACurrentMediaTime();
    return {g_play_time.total(now), g_play_time.session(now)};
}
void reset_performance_window() {
    perf::reset();
    std::lock_guard<std::mutex> frames(gfx::g_ios_present_mutex);
    gfx::g_ios_frame_history.reset();
}
void adopt_game_controller(bool pro) {
    input::set_pro_controller(pro);
    dispatch_async(dispatch_get_main_queue(), ^{
        if(input::pro_controller()!=pro)return;
        gfx::set_host_setting("proController",pro?"1":"0");
        if(!pro)gfx::display_show_drc(true);
    });
}
void run_gpu(void (*fn)()) {
    std::unique_lock<std::mutex> lock(g_gpu_mutex);
    g_gpu_cv.wait(lock, [] { return g_active; });
    render::with_autorelease_pool(fn);
}
static void set_active(bool active) {
    const double now = CACurrentMediaTime();
    g_play_time.set_running(active && g_game_running, now);
    if (!active && g_game_running) save_play_time(now);
    std::lock_guard<std::mutex> lock(g_gpu_mutex);
    g_active = active;
    if (!active) { std::lock_guard<std::mutex> frames(gfx::g_ios_present_mutex); gfx::g_ios_frame_history.reset(); }
    input::set_motion_active(active);
    g_display_link.paused = !active;
    gfx::R.tv.visible = active;
    if (!active && g_initialized) render::wait_idle();
    if (active) g_gpu_cv.notify_all();
    else { release_touch_controls(); [g_metal_view releaseGamepadTouch]; input::release_keys(); input::set_touch(false, 0, 0); overlay::focus_lost(); }
}
void prompt_text(const std::u16string& initial, int max_len, std::function<void(bool, std::u16string)> done) {
    dispatch_async(dispatch_get_main_queue(), ^{
        release_touch_controls(); [g_metal_view releaseGamepadTouch]; input::release_keys(); input::set_touch(false,0,0);
        UIAlertController* a = [UIAlertController alertControllerWithTitle:@"Enter name" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField* f) {
            f.text = [NSString stringWithCharacters:(const unichar*)initial.data() length:initial.size()];
            f.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction*) { done(false, {}); }]];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
            NSString* text = a.textFields.firstObject.text ?: @"";
            NSUInteger n = std::min(text.length, (NSUInteger)std::max(0, max_len));
            if (n && CFStringIsSurrogateHighCharacter([text characterAtIndex:n-1])) --n;
            std::u16string out(n, u'\0');
            [text getCharacters:(unichar*)out.data() range:NSMakeRange(0,n)];
            done(true, out);
        }]];
        [g_window.rootViewController presentViewController:a animated:YES completion:nil];
    });
}
}

namespace mods {
// shortcut: desktop mouse capture has no UIKit equivalent; add pointer controls when requested.
bool mouse_captured() { return false; }
void update_gyro_mouse() {}
void mouse_release() { input::release_mouse_bindings(); }
bool host_key_down(uint16_t) { return false; }
void mouse_init(void*) {}
}

namespace hostui {
void post(std::function<void()> fn) { dispatch_async(dispatch_get_main_queue(), ^{ fn(); }); }
// shortcut: source preparation/import runs on the Mac for the first signed runtime build.
void choose_game_source(bool, std::function<void(std::string)> chosen) { chosen({}); }
void choose_mod_source(bool, std::function<void(std::string)> chosen) { chosen({}); }
bool get(const char* k, std::string& v) { return gfx::host_setting(k,v); }
void set(const char* k, const std::string& v) { gfx::set_host_setting(k,v); }
float res_scale() { return render::res_scale(); }
void set_res_scale(float s) { render::set_res_scale(s); }
void graphics_changed() {}
int scale_filter() { return gfx::g_filter; }
void set_scale_filter(int f) { gfx::g_filter = std::clamp(f,0,2); }
bool scale_filter_available() { return true; }
bool fullscreen() { return true; }
void set_fullscreen(bool) {}
int drc_modes() { return gfx::kDrcModeCount; }
bool drc_mode_offered(int m) { return gfx::drc_mode_offered(m); }
int drc_mode() { return gfx::g_mode; }
void set_drc_mode(int m) { if (drc_mode_offered(m)) gfx::display_set_mode(m); }
int pip_anchor() { return gfx::g_pip_anchor; }
void set_pip_anchor(int c) { gfx::g_pip_anchor = std::clamp(c,0,int(gfx::kPipCustom)); }
void save_pip_position() {}
// main-project host hooks with no iPhone equivalent (choose_save_folder: platform/ios/save_folder_ios.mm)
void choose_file(const char*, const char*, bool, std::function<void(std::string)> chosen) { chosen({}); }
bool displays_swapped() { return false; }
void set_displays_swapped(bool) {}
void quit() {}  // iOS apps are closed from the app switcher
bool quit_from_menu() { return false; }
int startup_drc_mode() { return gfx::g_mode; }
float pip_size() { return gfx::g_pip_size; }
void set_pip_size(float s) { gfx::g_pip_size = std::clamp(s,0.1f,0.5f); }
float pip_opacity() { return gfx::g_pip_opacity; }
void set_pip_opacity(float o) { gfx::g_pip_opacity = std::clamp(o,0.2f,1.f); }
bool drc_available() { return true; }
bool drc_shown() { return gfx::drc_screen_shown(false); }
void show_drc(bool on) { gfx::display_show_drc(on); }
void set_pro_controller(bool on) {
    input::set_pro_controller(on);
    if(!on && gfx::g_mode==gfx::kDrcOff)gfx::display_set_mode(gfx::kDrcAuto);
    show_drc(!on);
}
const char* name() { return "UIKit"; }
void set_clipboard(const std::string& t) { UIPasteboard.generalPasteboard.string = @(t.c_str()); }
bool can_open_folder() { return false; }
void open_folder(const std::string&) {}
void run_posted() {}
void load_saved_options() {}
void toggle_drc() { gfx::display_show_drc(!gfx::drc_screen_shown(false)); }
void drc_window_closed() {}
void tv_fullscreen_changed() {}
}

static uint64_t physical_footprint() {
    task_vm_info_data_t info{};
    mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(),TASK_VM_INFO,reinterpret_cast<task_info_t>(&info),&count)==KERN_SUCCESS ? info.phys_footprint : 0;
}
static double process_cpu_seconds() {
    rusage usage{};
    if(getrusage(RUSAGE_SELF,&usage))return -1;
    return usage.ru_utime.tv_sec+usage.ru_utime.tv_usec/1e6+usage.ru_stime.tv_sec+usage.ru_stime.tv_usec/1e6;
}

// No guest functions run in this self-check. It exercises the linked runtime and real renderer.
static void runtime_smoke(NSString* documents) {
    [[NSFileManager defaultManager] removeItemAtPath:[documents stringByAppendingPathComponent:@"runtime-report.json"] error:nil];
    const uint64_t before=physical_footprint();
    mem::init();
    const uint64_t afterMemory=physical_footprint();
    const uint32_t addresses[] = {0x10000, 0x10000000, 0x80000000, 0xfffffff8};
    for (unsigned i=0;i<4;++i) st32(addresses[i], 0x13570000+i);
    for (unsigned i=0;i<4;++i) if (ld32(addresses[i]) != 0x13570000+i) fatal("iPad runtime memory round trip failed");
    render::choose(0,nullptr);
    render::init();
    g_initialized = true;
    auto& R = gfx::R;
    uint32_t offset=0;
    id<MTLBuffer> guest = gfx::guest_buffer(0x10000000,&offset);
    if (!guest) fatal("iPad guest memory is not GPU visible");
    id<MTLBuffer> readback = [R.device newBufferWithLength:16384 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [R.queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromBuffer:guest sourceOffset:offset toBuffer:readback destinationOffset:0 size:4];
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted || memcmp(readback.contents, mem::ptr(0x10000000),4)) fatal("iPad Metal guest buffer readback failed");
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1280 height:720 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    R.tv.tex = [R.device newTextureWithDescriptor:td];
    if (!R.tv.tex) fatal("iPad smoke render target allocation failed");
    __block unsigned frames=0;
    NSMutableDictionary* report = [@{@"kind":@"runtime-self-check-no-game", @"guestBase":@"0x800000000", @"guestBytes":@4294967296ULL,
        @"memoryRoundTrip":@YES, @"gpuGuestReadback":@YES, @"metalDevice":R.device.name,
        @"footprintBefore":@(before), @"footprintAfterMemory":@(afterMemory), @"footprintAfterMetal":@(physical_footprint()),
        @"runtimeBuild":[NSString stringWithUTF8String:__DATE__ " " __TIME__],
        @"guestBufferBytes":@(0x56000000ULL), @"guestBufferCount":@(R.guest.size()), @"targetGameFPS":@30, @"gameBooted":@NO} mutableCopy];
    NSString* path = [documents stringByAppendingPathComponent:@"runtime-report.json"];
    [NSTimer scheduledTimerWithTimeInterval:1.0/30 repeats:YES block:^(NSTimer* timer) {
        if (!g_active) return;
        @autoreleasepool {
            MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = gfx::R.tv.tex;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0.08,0.3,0.5,1);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> encoder = [gfx::command_buffer() renderCommandEncoderWithDescriptor:rp];
            [encoder endEncoding];
            gfx::present_screens();
            id<MTLCommandBuffer> submitted = gfx::command_buffer();
            gfx::wait_idle();
            if (submitted.status != MTLCommandBufferStatusCompleted) fatal("iPad composition failed: %s", submitted.error.localizedDescription.UTF8String);
            if (++frames == 30) {
                [timer invalidate];
                report[@"completedCompositionFrames"] = @(frames);
                report[@"footprintAfterComposition"] = @(physical_footprint());
                report[@"drawableCount"] = @(gfx::g_ios_drawables.load());
                report[@"presentedCallbacks"] = @(gfx::g_ios_presented.load());
                report[@"ok"] = @(gfx::g_ios_drawables.load() == frames && gfx::g_ios_presented.load() > 0);
                NSData* data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
                if (!data || ![data writeToFile:path atomically:YES]) fatal("cannot write iPad runtime report");
                g_status.text = [report[@"ok"] boolValue] ? @"Runtime self-check passed: 4 GiB memory, Metal shared buffers and compositing\nGame not started; waiting for the original game files and regenerated code" : @"Display self-check failed; see runtime-report.json";
                UIApplication.sharedApplication.idleTimerDisabled = NO;
                LOG("[ios] runtime self-check complete: %s",path.UTF8String);
                fflush(stderr);
            }
        }
    }];
}

// Keep legacy render/submission samples; only increasing presentedTime values measure display FPS.
static void start_game_metrics(NSString* documents) {
    __block uint64_t previousFrames=render::frame_count();
    __block uint64_t previousSteps=interp::executed_steps();
    __block double previousTime=CACurrentMediaTime();
    __block double previousCPU=process_cpu_seconds();
    __block uint64_t previousGPU=gfx::g_gpu_total_ns.load();
    __block uint64_t previousSubmitted=gfx::g_ios_submitted.load();
    __block auto previousPresentation=gfx::ios_present_times();
    const double startTime=previousTime;
    NSString* session=NSUUID.UUID.UUIDString;
    NSString* path=[documents stringByAppendingPathComponent:@"game-runtime-report.json"];
    FILE* history=getenv("WWHD_IOS_METRICS_HISTORY")?fopen("captures/game-runtime-history.jsonl","w"):nullptr;
    const bool writeReport=history || getenv("WWHD_IOS_METRICS_REPORT") ||
        getenv("WWHD_IOS_RUNTIME_TEST") || getenv("WWHD_IOS_CONTROLS_TEST");
    __block bool sampling=writeReport;
    __block uint64_t memoryPeak=0,metalPeak=0;
    [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer*) {
        const double now=CACurrentMediaTime();
        if(g_active && now-g_play_time_saved_at>=30)save_play_time(now);
        // Hidden performance UI has no sampling/dictionary/file work in a normal session.
        if (!writeReport && !perf::enabled() && !ios::controls_block_input()) { sampling=false; return; }
        const uint64_t frames=render::frame_count();
        const uint64_t steps=interp::executed_steps();
        const double cpu=process_cpu_seconds();
        const uint64_t gpu=gfx::g_gpu_total_ns.load();
        const uint64_t submitted=gfx::g_ios_submitted.load();
        const auto presentation=gfx::ios_present_times();
        if (!sampling) {
            sampling=true; previousTime=now; previousCPU=cpu; previousGPU=gpu;
            previousFrames=frames; previousSteps=steps; previousSubmitted=submitted; previousPresentation=presentation;
            return;
        }
        const double cpuDelta=cpu>=previousCPU&&previousCPU>=0?cpu-previousCPU:-1;
        const double gpuMs=gfx::g_gpu_metrics.load()&&frames>previousFrames?(gpu-previousGPU)/1e6/(frames-previousFrames):-1;
        const auto performance=perf::snapshot();
        const auto frameHistory=gfx::ios_frame_history();
        const auto frameStats=frameHistory.summarize(now,ios::pacing::refresh_request(target_output_fps(),(int)g_window.screen.maximumFramesPerSecond));
        NSMutableArray* graph=[NSMutableArray arrayWithCapacity:frameStats.graph.size()];
        for(double ms:frameStats.graph)[graph addObject:@(ms)];
        NSDictionary* frameReport=@{@"samples":@(frameStats.samples),@"seconds":@(frameStats.seconds),
            @"averageFPS":@(frameStats.fps),@"low1FPS":@(frameStats.low1),@"low01FPS":@(frameStats.low01),
            @"currentMs":@(frameStats.currentMs),@"averageMs":@(frameStats.averageMs),
            @"p99Ms":@(frameStats.p99Ms),@"p999Ms":@(frameStats.p999Ms),@"maximumMs":@(frameStats.maximumMs),
            @"minimumFPS":@(frameStats.minimumFPS),@"maximumFPS":@(frameStats.maximumFPS),
            @"longFrames":@(frameStats.longFrames),@"catchUpPairs":@(frameStats.catchUpPairs),@"graphMs":graph};
        task_vm_info_data_t vm{}; mach_msg_type_number_t vmCount=TASK_VM_INFO_COUNT;
        const bool memoryValid=task_info(mach_task_self(),TASK_VM_INFO,reinterpret_cast<task_info_t>(&vm),&vmCount)==KERN_SUCCESS;
        const uint64_t metal=gfx::R.device.currentAllocatedSize;
        if(memoryValid)memoryPeak=std::max(memoryPeak,uint64_t(vm.phys_footprint));
        metalPeak=std::max(metalPeak,metal);
        auto metric=[](const perf::Metric& value) -> NSDictionary* {
            return @{@"currentMs":@(value.current),@"averageMs":@(value.average()),@"samples":@(value.count)};
        };
        const int64_t workingSet=[gfx::R.device respondsToSelector:@selector(recommendedMaxWorkingSetSize)]
            ?int64_t(gfx::R.device.recommendedMaxWorkingSetSize):-1;
        const uint32_t play=GD(0x1046F0B0),link=ld32(play+0x5B34);
        char stage[9]{};memcpy(stage,mem::ptr(play+0x5134),8);
        id linkPosition=NSNull.null;
        if(link>=mem::kMem2Start&&link<=mem::kMem2End-0x320&&!(link&3)) {
            const double x=ldf32(link+0x314),y=ldf32(link+0x318),z=ldf32(link+0x31C);
            if(std::isfinite(x)&&std::isfinite(y)&&std::isfinite(z))linkPosition=@[@(x),@(y),@(z)];
        }
        const auto runtimeTest=ios::runtime_test_tick(stage,ld8(play+0x5292),
            link>=mem::kMem2Start&&link<=mem::kMem2End-4&&!(link&3),now);
        const int mode=interp::mode();
        NSDictionary* report=@{@"kind":@"game-runtime", @"session":session, @"elapsedSeconds":@(now-startTime),
            @"runtimeTestPhase":@(runtimeTest.name),@"runtimeTestComplete":@(runtimeTest.complete),
            @"runtimeTestElapsed":@(runtimeTest.phase==ios::RuntimeTestPlan::Phase::Disabled?0:runtimeTest.elapsed),
            @"targetOutputFPS":@(target_output_fps()),
            @"selectedInterpolationFPS":@(interp::fps()),@"cappedInterpolationFPS":@(interp::output_fps()),
            @"fastForwardActive":@(mods::fast_forward_active()),
            @"requestedRefreshHz":@(g_refresh_request),@"pacedPresentation":@(gfx::duration_pacing_enabled()),@"displayLinkHz":@(g_display_link_hz),
            @"gameBooted":@(frames>0), @"frameCount":@(frames), @"completedFrames":@(render::frames_completed()),
            @"sampleSeconds":@(now-previousTime), @"sampleFPS":@((frames-previousFrames)/(now-previousTime)),
            @"executedSteps":@(steps), @"sampleExecutedStepsPerSecond":@((steps-previousSteps)/(now-previousTime)),
            @"presentedCallbacks":@(gfx::g_ios_presented.load()), @"physicalFootprint":@(memoryValid?int64_t(vm.phys_footprint):-1),
            @"residentMemoryBytes":@(memoryValid?int64_t(vm.resident_size):-1),@"compressedMemoryBytes":@(memoryValid?int64_t(vm.compressed):-1),
            @"peakPhysicalFootprint":@(memoryValid?int64_t(memoryPeak):-1),@"peakMetalAllocatedBytes":@(metalPeak),
            @"frameStatistics":frameReport,
            @"submittedPresentations":@(submitted),@"sampleSubmittedFPS":@((submitted-previousSubmitted)/(now-previousTime)),
            @"validPresentedTimes":@(presentation.valid),@"uniquePresentedTimes":@(presentation.unique),
            @"invalidPresentedTimes":@(presentation.invalid),@"nonIncreasingPresentedTimes":@(presentation.nonIncreasing),
            @"sampleDisplayedFPS":@(ios::pacing::displayed_fps(previousPresentation,presentation)),
            @"sampleDisplayedFrames":@(presentation.unique-previousPresentation.unique),
            @"sampleDisplayIntervalCount":@(presentation.intervals-previousPresentation.intervals),
            @"sampleDisplayIntervalSeconds":@(presentation.intervalSeconds-previousPresentation.intervalSeconds),
            @"lastPresentedTime":@(presentation.last),@"lastDisplayIntervalMs":@(presentation.lastIntervalSeconds*1000),
            @"active":@(g_active), @"interpolationMode":@(mode), @"displayMaximumHz":@(g_window.screen.maximumFramesPerSecond),
            @"drawableWidth":@(((CAMetalLayer*)g_metal_view.layer).drawableSize.width),
            @"drawableHeight":@(((CAMetalLayer*)g_metal_view.layer).drawableSize.height),
            @"nativeScale":@(g_window.screen.nativeScale),
            @"controls":ios::controls_state(), @"thermalState":@(NSProcessInfo.processInfo.thermalState),
            @"availableMemoryBytes":@(os_proc_available_memory()), @"clockRate":@(game_clock::rate()),
            @"processCPUPercent":@(cpuDelta>=0?100*cpuDelta/(now-previousTime):-1),
            @"processCPUMsPerFrame":@(cpuDelta>=0&&frames>previousFrames?1000*cpuDelta/(frames-previousFrames):-1),
            @"processorCount":@(NSProcessInfo.processInfo.activeProcessorCount),
            @"gpuIntervalMsPerFrame":@(gpuMs), @"metalAllocatedBytes":@(metal),
            @"devicePhysicalMemory":@(NSProcessInfo.processInfo.physicalMemory),
            @"gpuDeviceName":gfx::R.device.name?:@"unavailable",@"metalRecommendedWorkingSetBytes":@(workingSet>0?workingSet:-1),
            @"metalSupportsRaytracing":@(gfx::R.device.supportsRaytracing),
            @"metalSupportsRaytracingFromRender":@(gfx::R.device.supportsRaytracingFromRender),
            @"performanceSamplingActive":@(perf::enabled()),@"performanceSampleWindow":@(perf::Metric::capacity),
            @"gameThreadCPU":metric(performance.game),@"renderThreadCPU":metric(performance.render),
            @"gpuCommandInterval":metric(performance.gpu),
            @"renderWidth":@(gfx::g_ios_picture_width.load()),@"renderHeight":@(gfx::g_ios_picture_height.load()),
            @"upscaleSourceFormat":@(gfx::upscale::source_format()),
            @"upscaleRequested":@(gfx::upscale::requested()),@"upscaleActive":@(gfx::upscale::active()),
            @"upscaleAvailable":@(gfx::upscale::available()),@"upscaleStatus":@(gfx::upscale::status()),
            @"upscaleInputWidth":@(gfx::upscale::input_width()),@"upscaleInputHeight":@(gfx::upscale::input_height()),
            @"upscaleOutputWidth":@(gfx::upscale::output_width()),@"upscaleOutputHeight":@(gfx::upscale::output_height()),
            @"stage":[NSString stringWithUTF8String:stage]?:@"unknown",@"eventMode":@(ld8(play+0x5292)),
            @"linkPosition":linkPosition,
            @"linkPresent":@(link>=mem::kMem2Start&&link<mem::kMem2End),
            @"lastFullLoadFrame":@(ss::last_load_frame()),@"lastFullLoadStep":@(ss::last_load_step()),
            @"lastFullLoadCounter":@(ss::last_load_counter()),
            @"keepGameSpeed":@(interp::paced_interpolation())};
        if (writeReport) {
            NSData* data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
            [data writeToFile:path atomically:YES];
        }
        if(history) {
            NSData* line=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
            if(line) { fwrite(line.bytes,1,line.length,history);fputc('\n',history);fflush(history); }
        }
        ios::update_controls(report);
        previousTime=now; previousFrames=frames; previousSteps=steps;
        previousCPU=cpu; previousGPU=gpu;
        previousSubmitted=submitted; previousPresentation=presentation;
    }];
}

int wwhd_runtime_main(int, char**);
@interface WWGameController : UIViewController
@end
@implementation WWGameController
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
@end
@interface WWAppDelegate : UIResponder <UIApplicationDelegate>
@property(strong,nonatomic) UIWindow* window;
@end
@implementation WWAppDelegate
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
    g_play_time = ios::PlayTimeCounter([NSUserDefaults.standardUserDefaults doubleForKey:play_time_key]);
    // Conservative first-run resolution; existing players retain their explicit native choice.
    [NSUserDefaults.standardUserDefaults registerDefaults:@{@"ios.nativeResolution":@"0",@"ios.touchControls":@1,@"ios.upscaleQuality":@1}];
    const char* upscaleEnv=getenv("WWHD_METALFX");
    gfx::upscale::set_requested(upscaleEnv ? atoi(upscaleEnv)!=0 :
        [@"1" isEqualToString:[NSUserDefaults.standardUserDefaults stringForKey:@"ios.metalFX"]]);
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    g_window = self.window;
    if (!getenv("WWHD_ASPECT")) {
        const bool original=[@"original" isEqualToString:[NSUserDefaults.standardUserDefaults stringForKey:@"ios.aspectMode"]];
        aspect::set_mode(original?aspect::kOriginal:aspect::kWindow);
    }
    UIViewController* vc = [WWGameController new];
    vc.view = [[UIView alloc] initWithFrame:self.window.bounds];
    vc.view.backgroundColor = UIColor.blackColor;
    g_metal_view=[[WWMetalView alloc] initWithFrame:vc.view.bounds];
    g_metal_view.translatesAutoresizingMaskIntoConstraints=NO;
    [vc.view addSubview:g_metal_view];
    // Screen fill (Settings > Display > Screen): edge to edge by default, or inside the safe area with
    // black bars. The touch controls lay themselves out inside the safe area either way.
    auto pin=^NSArray*(id guide){ return @[
        [g_metal_view.leadingAnchor constraintEqualToAnchor:[guide leadingAnchor]],
        [g_metal_view.trailingAnchor constraintEqualToAnchor:[guide trailingAnchor]],
        [g_metal_view.topAnchor constraintEqualToAnchor:[guide topAnchor]],
        [g_metal_view.bottomAnchor constraintEqualToAnchor:[guide bottomAnchor]]]; };
    g_full_constraints=pin(vc.view);
    g_safe_constraints=pin(vc.view.safeAreaLayoutGuide);
    g_full_screen=![@"safe" isEqualToString:[NSUserDefaults.standardUserDefaults stringForKey:@"ios.screenFill"]];
    [NSLayoutConstraint activateConstraints:g_full_screen?g_full_constraints:g_safe_constraints];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    g_display_link = [CADisplayLink displayLinkWithTarget:g_metal_view selector:@selector(refreshFrameRate:)];
    [g_metal_view refreshFrameRate:g_display_link];
    [g_display_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSString* state = [docs stringByAppendingPathComponent:@"state"];
    [[NSFileManager defaultManager] createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("WWHD_USER_DIR",state.UTF8String,1);
    setenv("WWHD_STATE_DIR",state.UTF8String,1);
    chdir(docs.UTF8String);
    NSString* captures = [docs stringByAppendingPathComponent:@"captures"];
    [[NSFileManager defaultManager] createDirectoryAtPath:captures withIntermediateDirectories:YES attributes:nil error:nil];
    freopen([[captures stringByAppendingPathComponent:@"ios-console.log"] fileSystemRepresentation],"w",stderr);
    setvbuf(stderr,nullptr,_IONBF,0);
    NSError* audioError=nil;
    [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:&audioError];
    [AVAudioSession.sharedInstance setActive:YES error:&audioError];
    application.idleTimerDisabled = YES;
    // The main project's Settings window ("Mods, audio & more" in the iPhone panel): only the tabs the
    // panel doesn't cover. Graphics, Display and Saves (resolution, frame rate, screens, save states,
    // save folder) are the panel's; everything else comes as the main project draws it.
    overlay::ext::Features features;
    features.full_states = true;
    features.file_picker = false;    // no desktop file chooser (mods come from the online list)
    features.keyboard = false;       // keyboard and mouse hints
    features.speaker_choice = false; // iOS picks the output
    features.code_mods = false;      // the iPhone build is translated without mod hooks
    overlay::ext::set_features(features);
    overlay::ext::hide_tab("graphics");
    overlay::ext::hide_tab("display");
    overlay::ext::hide_tab("saves");
    dispatch_async(dispatch_get_main_queue(), ^{
        bool smoke = [NSProcessInfo.processInfo.arguments containsObject:@"--ios-smoke"];
        bool haveGame = [NSFileManager.defaultManager fileExistsAtPath:@"game/code/cking.rpx"];
        if (!g_recomp_entry_point || !haveGame || smoke) {
            g_status = [[UILabel alloc] initWithFrame:CGRectInset(vc.view.bounds,50,60)];
            g_status.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            g_status.numberOfLines = 0; g_status.textColor = UIColor.whiteColor;
            g_status.textAlignment = NSTextAlignmentCenter;
            g_status.text = @"Checking the runtime and Metal…\nThis build hasn't run the game yet";
            [vc.view addSubview:g_status];
            runtime_smoke(docs);
        } else {
            // no --save: the save stays in Documents/save unless the player chose a save folder
            // (Settings > Save > Cross-save; mods/save_folder.h), which --save would switch off
            char name[]="wwhd", gameOpt[]="--game", gamePath[]="game";
            char* args[]={name,gameOpt,gamePath,nullptr};
            wwhd_runtime_main(3,args);
            g_initialized = true;
            g_game_running = true;
            g_play_time_saved_at = CACurrentMediaTime();
            g_play_time.set_running(g_active, g_play_time_saved_at);
            ios::install_touch_controls(vc);
            ios::install_controls(vc);
            start_live_input_bridge(docs);
            start_game_metrics(docs);
            if(getenv("WWHD_IOS_CONTROLS_TEST"))
                [NSTimer scheduledTimerWithTimeInterval:5 repeats:NO block:^(NSTimer*) { ios::test_controls(); }];
            if(getenv("WWHD_IOS_TOUCH_TEST"))
                [NSTimer scheduledTimerWithTimeInterval:5 repeats:NO block:^(NSTimer*) { ios::test_touch_controls(); }];
            if(getenv("WWHD_IOS_TOUCH_TEST"))
                [NSTimer scheduledTimerWithTimeInterval:8 repeats:NO block:^(NSTimer*) { ios::test_touch_settings(); }];
            // Development-only boot acceleration; restore normal pacing before measuring gameplay.
            if (const char* rate = getenv("WWHD_IOS_TEST_BOOT_RATE")) {
                const unsigned speed = (unsigned)atoi(rate);
                if (speed >= 2 && speed <= 4) {
                    const int mode = interp::mode();
                    interp::set_mode(0);
                    timebase::set_clock_rate(speed);
                    LOG("[ios] test boot acceleration %ux", speed);
                    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer* timer) {
                        const uint32_t play = GD(0x1046F0B0);
                        const char* stage = reinterpret_cast<const char*>(mem::ptr(play + 0x5134));
                        if (*stage && strncmp(stage,"sea_T",5) && strncmp(stage,"Name",4) && ld32(play + 0x5B34)) {
                            timebase::set_clock_rate(1);
                            interp::set_mode(mode);
                            LOG("[ios] test boot acceleration off at stage %s", stage);
                            [timer invalidate];
                        }
                    }];
                }
            }
        }
    });
    return YES;
}
- (void)applicationWillResignActive:(UIApplication*)application { ios::set_active(false); application.idleTimerDisabled=NO; }
- (void)applicationDidBecomeActive:(UIApplication*)application { ios::set_active(true); if (g_game_running) application.idleTimerDisabled=YES; }
- (void)applicationWillTerminate:(UIApplication*)application { ios::set_active(false); }
@end
int main(int argc, char** argv) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(WWAppDelegate.class)); }
}
