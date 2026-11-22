#import "controls.h"
#include "touch_controls.h"
#include "display_policy.h"
#include "aspect.h"
#include "gfx/display_modes.h"
#include "motion/motion.h"
#import <QuartzCore/CAMetalLayer.h>
#include "ios.h"
#include "input.h"
#include "interp.h"
#include "game_clock.h"
#include "frame_pacing.h"
#include "perf_metrics.h"
#include "gfx/metal.h"
#include "gfx/metal_upscale.h"
#include "gfx/ray_reflections.h"
#include "savestate.h"
#include "mods/fast_forward.h"
#include "mods/manager.h"
#include "overlay/hostui.h"
#include "mods/game_settings.h"
#include "mods/save_folder.h"
#include "crashrec.h"
#include "overlay/overlay.h"
#include <atomic>
#include <algorithm>
#include <cmath>
#include <cstdint>

namespace {
std::atomic<bool> panel_open{false};
const bool native_settings_fallback = [] {
    const char* value = getenv("WWHD_IOS_NATIVE_SETTINGS");
    return !value || strcmp(value, "0");
}();
}
namespace ios { bool controls_block_input() { return panel_open.load() || touch_layout_editing(); } }

static UIColor* ink() { return [UIColor colorWithRed:.12 green:.27 blue:.24 alpha:1]; }
static UIColor* paper() { return [UIColor colorWithRed:.97 green:.95 blue:.84 alpha:.97]; }
static UILabel* label(NSString* title) {
    UILabel* v=[UILabel new]; v.text=title; v.textColor=ink();
    v.font=[UIFont systemFontOfSize:16 weight:UIFontWeightMedium]; return v;
}
static double metric_number(NSDictionary* values,NSString* key) {
    id value=values[key];
    const double number=[value isKindOfClass:NSNumber.class]?[value doubleValue]:-1;
    return std::isfinite(number)&&number>=0?number:-1;
}
static NSString* milliseconds(double value) {
    return value>=0?[NSString stringWithFormat:@"%.2f ms",value]:@"sampling";
}
static NSString* rate_reading(NSDictionary* metrics,NSString* key,NSString* unit) {
    const double value=metric_number(metrics,key);
    return value>0?[NSString stringWithFormat:@"%.1f %@",value,unit]:@"sampling";
}
static NSString* memory_size(double value) {
    return value>=0?[NSString stringWithFormat:@"%.0f MiB",value/1048576.0]:@"unavailable";
}
static NSString* interval_details(NSDictionary* metrics,NSString* key) {
    NSDictionary* value=[metrics[key] isKindOfClass:NSDictionary.class]?metrics[key]:nil;
    return [NSString stringWithFormat:@"Recent %@ · average %@\nValid samples %.0f / 120",
        milliseconds(metric_number(value,@"currentMs")),milliseconds(metric_number(value,@"averageMs")),
        std::max(0.0,metric_number(value,@"samples"))];
}
static bool testing_controls=false;
static void persist_setting(const char* key,const std::string& value) { if(!testing_controls)hostui::set(key,value); }
static int backend_slot(NSInteger index) { constexpr int slots[]={1,2,5}; return slots[std::clamp((int)index,0,2)]; }
static int visible_slot(int slot) { return slot==5?3:slot; }
static NSInteger frame_segment() { return interp::mode()==0?0:interp::fps()>=120?2:1; }
static bool screen_120() { return UIScreen.mainScreen.maximumFramesPerSecond>=120; }
static bool enforce_frame_limit() {
    // 60, or 120 on a 120 Hz screen (ProMotion)
    if(interp::fps()==60||(interp::fps()==120&&screen_120()))return false;
    interp::set_fps(60); interp::set_paced_interpolation_at(60,true);
    return true;
}
static int target_fps() {
    return ios::pacing::target_output_fps(interp::mode(),interp::output_fps(),game_clock::rate(),mods::fast_forward_active());
}
static NSString* state_failure(const std::string& why,bool loading) {
    if(why=="game save in progress")return loading?@"The game is saving; load again when it finishes":@"The game is saving; save state again when it finishes";
    if(why=="instant saves are disabled")return @"Save states are off";
    if(why=="snapshot contains an unfinished game save")return @"This save state contains an unfinished game save; use another slot.";
    return [NSString stringWithUTF8String:why.c_str()]?:@"unknown reason";
}
static NSString* text(const std::string& value) { return [NSString stringWithUTF8String:value.c_str()]?:@""; }
static NSString* upscale_status_text() {
    NSString* state=@(gfx::upscale::status());
    NSDictionary* descriptions=@{@"off":@"Off",@"checking":@"Preparing upscaling",
        @"active":@"On: higher-resolution input → rebuilt at screen size",
        @"inactive: GamePad view":@"GamePad fullscreen is showing; TV upscaling paused",
        @"unsupported: device":@"Not supported on this device; using normal scaling",
        @"fallback: source format":@"Current picture format not supported; using normal scaling",
        @"fallback: dimensions":@"Upscaling not needed or not possible at this size; using normal output",
        @"fallback: scaler creation":@"Upscaler failed to start; using normal scaling",
        @"fallback: texture or encoder":@"Upscaler resources unavailable; using normal scaling"};
    return descriptions[state]?:state;
}

static NSString* const show_key=@"wwhd.ios.performance";
static NSString* const state_key=@"wwhd.ios.quickStates";
enum { kSettingsScreen, kSettingsControls, kSettingsAssist, kSettingsSaves, kSettingsGame, kSettingsCategoryCount };

@interface WWFrameTimeGraph : UIView
@property(nonatomic,copy) NSArray<NSNumber*>* samples;
@property(nonatomic) double budget;
@end
@implementation WWFrameTimeGraph
- (void)drawRect:(CGRect)rect {
    CGContextRef c=UIGraphicsGetCurrentContext();
    [[ink() colorWithAlphaComponent:.9] setFill]; UIRectFill(rect);
    double top=std::max(33.34,self.budget*2);
    for(NSNumber* value in self.samples)top=std::max(top,value.doubleValue);
    const CGFloat h=std::max(1.0,rect.size.height-18),w=rect.size.width-12;
    auto y=[&](double ms){return 14+h*(1-std::clamp(ms/top,0.0,1.0));};
    CGContextSetLineWidth(c,1);
    CGContextSetStrokeColorWithColor(c,[UIColor colorWithRed:1 green:.8 blue:.2 alpha:.8].CGColor);
    CGContextMoveToPoint(c,6,y(self.budget)); CGContextAddLineToPoint(c,6+w,y(self.budget)); CGContextStrokePath(c);
    CGContextSetStrokeColorWithColor(c,UIColor.whiteColor.CGColor);
    bool drawing=false;
    for(NSUInteger i=0;i<self.samples.count;++i) {
        const double ms=self.samples[i].doubleValue;
        if(ms<=0) { drawing=false; continue; }
        const CGFloat x=6+w*i/std::max<NSUInteger>(1,self.samples.count-1);
        if(drawing)CGContextAddLineToPoint(c,x,y(ms));else CGContextMoveToPoint(c,x,y(ms));
        drawing=true;
    }
    CGContextStrokePath(c);
    [[NSString stringWithFormat:@"Frame time · last 10 s · top %.0f ms",top]
        drawAtPoint:CGPointMake(6,1) withAttributes:@{NSFontAttributeName:[UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular],NSForegroundColorAttributeName:UIColor.whiteColor}];
}
@end

@interface WWQuickControls : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic,strong) UIViewController* controller;
@property(nonatomic,strong) UIButton* entry;
@property(nonatomic,strong) UIControl* backdrop;
@property(nonatomic,strong) UIView* panel;
@property(nonatomic,strong) UILabel* hud;
@property(nonatomic,strong) WWFrameTimeGraph* hudGraph;
@property(nonatomic,strong) WWFrameTimeGraph* detailsGraph;
@property(nonatomic,strong) UILabel* status;
@property(nonatomic,strong) UILabel* slotStatus;
@property(nonatomic,strong) UIView* settingsPage;
@property(nonatomic,strong) UIView* settingsBody;
@property(nonatomic,strong) UISegmentedControl* settingsCategory;
@property(nonatomic,strong) NSArray<UIScrollView*>* settingsPages;
@property(nonatomic,strong) UIScrollView* settingsScroll;
@property(nonatomic,strong) UIStackView* detailsPage;
@property(nonatomic,strong) UILabel* detailsText;
@property(nonatomic,strong) UIButton* detailsButton;
@property(nonatomic,strong) UIButton* detailsBack;
@property(nonatomic,strong) NSDictionary* metrics;
@property(nonatomic,strong) UISwitch* performance;
@property(nonatomic,strong) UISwitch* fastEnabled;
@property(nonatomic,strong) UISwitch* fast;
@property(nonatomic,strong) UISwitch* states;
@property(nonatomic,strong) UISegmentedControl* rate;
@property(nonatomic,strong) UISegmentedControl* fastScope;
@property(nonatomic,strong) UILabel* playTime;
@property(nonatomic,strong) UISegmentedControl* slots;
@property(nonatomic,strong) UIImageView* thumbnail;
@property(nonatomic,strong) UILabel* thumbnailStatus;
@property(nonatomic,strong) NSString* thumbnailPath;
@property(nonatomic,strong) NSTimer* thumbnailRetryTimer;
@property(nonatomic) NSUInteger thumbnailRetryCount;
@property(nonatomic,strong) UISegmentedControl* controllerMode;
@property(nonatomic,strong) UISegmentedControl* gamepadScreen;
@property(nonatomic,strong) UISwitch* gyro;
@property(nonatomic,strong) UILabel* gyroStatus;
@property(nonatomic,strong) UISegmentedControl* touchMode;
@property(nonatomic,strong) UISlider* touchMove;
@property(nonatomic,strong) UISlider* touchLook;
@property(nonatomic,strong) UILabel* touchMoveValue;
@property(nonatomic,strong) UILabel* touchLookValue;
@property(nonatomic,strong) UISegmentedControl* frameMode;
@property(nonatomic,strong) UISegmentedControl* quality;
@property(nonatomic,strong) UISegmentedControl* upscaleQuality;
@property(nonatomic,strong) UILabel* upscaleQualityTitle;
@property(nonatomic,strong) UISegmentedControl* aspectMode;
@property(nonatomic,strong) UISegmentedControl* screenFill;
@property(nonatomic,strong) UILabel* resolutionNote;
@property(nonatomic,strong) UIButton* save;
@property(nonatomic,strong) UIStackView* gameStack;
@property(nonatomic,strong) UILabel* saveFolderStatus;
@property(nonatomic,strong) UISwitch* crashRecovery;
@property(nonatomic,strong) UIStackView* autoStates;
@property(nonatomic,strong) UIButton* load;
@property(nonatomic) BOOL saving;
@property(nonatomic) BOOL loading;
@property(nonatomic,strong) NSMutableDictionary* quickStateResult;
@property(nonatomic,strong) NSTimer* entryTimer;
@property(nonatomic,strong) UITapGestureRecognizer* touchObserver;
@property(nonatomic) BOOL slotUsed;
@property(nonatomic) BOOL slotCompatible;
@property(nonatomic) BOOL slotPortable;
@property(nonatomic,copy) NSString* slotWhen;
@property(nonatomic,copy) NSString* slotArea;
- (void)showEntry;
- (void)syncPerformanceDemand;
- (void)refreshHUD;
- (void)refreshDetails;
- (void)refreshSlot;
- (void)refreshPlayTime;
- (void)settingsCategoryChanged;
- (void)performLoadState;
- (void)performSaveSlot:(int)slot;
- (void)renderSlot:(const ss::SlotInfo&)slot;
- (void)finishLoadSlot:(int)slot ok:(BOOL)ok why:(NSString*)failure;
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)recognizer shouldReceiveTouch:(UITouch* _Nullable)touch;
- (void)togglePanel;
- (void)refresh;
@end

static WWQuickControls* controls;
@implementation WWQuickControls
- (UIButton*)button:(NSString*)title action:(SEL)action {
    UIButton* b=[UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:ink() forState:UIControlStateNormal];
    b.backgroundColor=[ink() colorWithAlphaComponent:.08]; b.layer.cornerRadius=10;
    b.titleLabel.font=[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    if(action)[b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (UIStackView*)row:(NSString*)title control:(UIView*)view {
    UIStackView* row=[[UIStackView alloc] initWithArrangedSubviews:@[label(title),view]];
    row.axis=UILayoutConstraintAxisHorizontal; row.alignment=UIStackViewAlignmentCenter; row.spacing=14;
    [row.heightAnchor constraintEqualToConstant:42].active=YES;
    [view setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal]; return row;
}
- (UISwitch*)toggle:(BOOL)on action:(SEL)action {
    UISwitch* s=[UISwitch new]; s.on=on; s.onTintColor=ink();
    [s addTarget:self action:action forControlEvents:UIControlEventValueChanged]; return s;
}
- (UISegmentedControl*)segments:(NSArray<NSString*>*)items action:(SEL)action {
    UISegmentedControl* s=[[UISegmentedControl alloc] initWithItems:items];
    s.selectedSegmentTintColor=paper();
    [s setTitleTextAttributes:@{NSForegroundColorAttributeName:ink(),NSFontAttributeName:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]} forState:UIControlStateNormal];
    [s addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [s.heightAnchor constraintEqualToConstant:34].active=YES; return s;
}
- (UIScrollView*)scrollWithContent:(UIView*)content {
    UIScrollView* scroll=[UIScrollView new]; scroll.alwaysBounceVertical=YES;
    scroll.translatesAutoresizingMaskIntoConstraints=NO; content.translatesAutoresizingMaskIntoConstraints=NO;
    [scroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]]];
    return scroll;
}
- (instancetype)initWithController:(UIViewController*)controller {
    if(!(self=[super init]))return nil;
    self.controller=controller;
    UIView* root=controller.view;
    self.entry=[self button:@"Settings" action:@selector(togglePanel)];
    self.entry.backgroundColor=paper(); self.entry.alpha=.8;
    self.entry.accessibilityLabel=@"Settings";
    self.entry.translatesAutoresizingMaskIntoConstraints=NO; [root addSubview:self.entry];
    [NSLayoutConstraint activateConstraints:@[
        [self.entry.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:12],
        [self.entry.trailingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.trailingAnchor constant:-14],
        [self.entry.widthAnchor constraintEqualToConstant:64],[self.entry.heightAnchor constraintEqualToConstant:36]]];
    self.hud=label(@""); self.hud.font=[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.hud.textColor=paper(); self.hud.backgroundColor=[ink() colorWithAlphaComponent:.75];
    self.hud.layer.cornerRadius=8; self.hud.clipsToBounds=YES; self.hud.numberOfLines=7;
    self.hud.accessibilityLabel=@"Game performance info";
    self.hud.translatesAutoresizingMaskIntoConstraints=NO; [root addSubview:self.hud];
    [NSLayoutConstraint activateConstraints:@[
        [self.hud.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:12],
        [self.hud.leadingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.leadingAnchor constant:14],
        [self.hud.widthAnchor constraintLessThanOrEqualToAnchor:root.safeAreaLayoutGuide.widthAnchor constant:-112],
        [self.hud.heightAnchor constraintEqualToConstant:132]]];
    NSLayoutConstraint* hudWidth=[self.hud.widthAnchor constraintEqualToConstant:370];
    hudWidth.priority=UILayoutPriorityDefaultHigh; hudWidth.active=YES;
    self.hudGraph=[WWFrameTimeGraph new]; self.hudGraph.userInteractionEnabled=NO;
    self.hudGraph.translatesAutoresizingMaskIntoConstraints=NO; [root addSubview:self.hudGraph];
    [NSLayoutConstraint activateConstraints:@[[self.hudGraph.topAnchor constraintEqualToAnchor:self.hud.bottomAnchor constant:2],
        [self.hudGraph.leadingAnchor constraintEqualToAnchor:self.hud.leadingAnchor],
        [self.hudGraph.widthAnchor constraintEqualToAnchor:self.hud.widthAnchor],
        [self.hudGraph.heightAnchor constraintEqualToConstant:48]]];

    self.backdrop=[UIControl new]; self.backdrop.backgroundColor=[UIColor colorWithWhite:0 alpha:.2];
    self.backdrop.translatesAutoresizingMaskIntoConstraints=NO;
    [self.backdrop addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:self.backdrop];
    [NSLayoutConstraint activateConstraints:@[[self.backdrop.topAnchor constraintEqualToAnchor:root.topAnchor],
        [self.backdrop.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [self.backdrop.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [self.backdrop.trailingAnchor constraintEqualToAnchor:root.trailingAnchor]]];
    self.panel=[UIView new]; self.panel.overrideUserInterfaceStyle=UIUserInterfaceStyleLight;
    self.panel.backgroundColor=paper(); self.panel.layer.cornerRadius=20;
    self.panel.layer.borderWidth=1; self.panel.layer.borderColor=[ink() colorWithAlphaComponent:.18].CGColor;
    self.panel.translatesAutoresizingMaskIntoConstraints=NO; [self.backdrop addSubview:self.panel];
    [NSLayoutConstraint activateConstraints:@[
        [self.panel.trailingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.trailingAnchor constant:-14],
        [self.panel.centerYAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.centerYAnchor],
        [self.panel.widthAnchor constraintLessThanOrEqualToAnchor:root.safeAreaLayoutGuide.widthAnchor constant:-28],
        [self.panel.heightAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.heightAnchor constant:-24]]];
    NSLayoutConstraint* panelWidth=[self.panel.widthAnchor constraintEqualToConstant:
        UIDevice.currentDevice.userInterfaceIdiom==UIUserInterfaceIdiomPad?560:350];
    panelWidth.priority=999; panelWidth.active=YES;
    UILabel* title=label(@"Settings"); title.font=[UIFont systemFontOfSize:23 weight:UIFontWeightBold];
    self.performance=[self toggle:[NSUserDefaults.standardUserDefaults boolForKey:show_key] action:@selector(performanceChanged)];
    [self syncPerformanceDemand];
    self.fastEnabled=[self toggle:mods::fast_forward() action:@selector(fastEnabledChanged)];
    self.fast=[self toggle:mods::fast_forward_latched() action:@selector(fastChanged)];
    self.states=[self toggle:[NSUserDefaults.standardUserDefaults boolForKey:state_key] action:@selector(statesChanged)];
    ss::set_instant_states_enabled(self.states.on);
    self.rate=[self segments:@[@"2×",@"3×",@"4×"] action:@selector(rateChanged)];
    self.rate.selectedSegmentIndex=mods::fast_forward_rate()-2;
    self.fastScope=[self segments:@[@"Cutscenes / dialogue",@"Everywhere"] action:@selector(scopeChanged)];
    self.fastScope.selectedSegmentIndex=mods::fast_forward_global()?1:0;
    self.controllerMode=[self segments:@[@"GamePad",@"Pro Controller"] action:@selector(controllerChanged)];
    self.controllerMode.selectedSegmentIndex=input::pro_controller()?1:0;
    self.gamepadScreen=[self segments:@[@"Auto",@"Small window",@"Fullscreen"] action:@selector(gamepadScreenChanged)];
    self.gyro=[self toggle:motion::settings().source==motion::kController action:@selector(gyroChanged)];
    self.gyroStatus=label(@""); self.gyroStatus.numberOfLines=0; self.gyroStatus.font=[UIFont systemFontOfSize:12];
    UIButton* recalibrate=[self button:@"Recalibrate motion" action:@selector(recalibrateGyro)];
    [recalibrate.heightAnchor constraintEqualToConstant:40].active=YES;
    self.touchMode=[self segments:@[@"Auto",@"Show",@"Hide"] action:@selector(touchChanged)];
    self.touchMode.selectedSegmentIndex=std::clamp((int)[NSUserDefaults.standardUserDefaults integerForKey:@"ios.touchControls"],0,2);
    self.touchMove=[UISlider new]; self.touchLook=[UISlider new];
    for(UISlider* slider in @[self.touchMove,self.touchLook]) {
        slider.minimumValue=.5; slider.maximumValue=2; slider.minimumTrackTintColor=ink();
        [slider addTarget:self action:@selector(touchSensitivityChanged) forControlEvents:UIControlEventValueChanged];
    }
    self.touchMove.accessibilityIdentifier=@"touch-move-sensitivity";
    self.touchLook.accessibilityIdentifier=@"touch-look-sensitivity";
    self.touchMoveValue=label(@""); self.touchLookValue=label(@"");
    UIButton* editTouch=[self button:@"Customize touch layout and buttons ›" action:@selector(editTouchLayout)];
    editTouch.accessibilityIdentifier=@"edit-touch-layout";
    UIButton* resetTouch=[self button:@"Reset touch controls to default" action:@selector(resetTouchConfiguration)];
    resetTouch.accessibilityIdentifier=@"reset-touch-configuration";
    UILabel* touchNote=label(@"While editing you can drag buttons and change their size and function. Sensitivity changes touch response, not game speed.");
    touchNote.numberOfLines=0; touchNote.font=[UIFont systemFontOfSize:12];
    self.frameMode=[self segments:screen_120()?@[@"30 FPS",@"60 FPS",@"120 FPS"]:@[@"30 FPS",@"60 FPS"] action:@selector(frameChanged)];
    self.frameMode.apportionsSegmentWidthsByContent=YES;
    self.frameMode.selectedSegmentIndex=frame_segment();
    self.aspectMode=[self segments:@[@"Fit screen",@"Original 16:9"] action:@selector(aspectChanged)];
    self.screenFill=[self segments:@[@"Full screen",@"Black bars"] action:@selector(screenFillChanged)];
    self.screenFill.selectedSegmentIndex=ios::full_screen()?0:1;
    self.quality=[self segments:@[@"Standard 1×",@"Native",@"MetalFX upscale"] action:@selector(qualityChanged)];
    self.quality.selectedSegmentIndex=[@"0" isEqualToString:[NSUserDefaults.standardUserDefaults stringForKey:@"ios.nativeResolution"]]?0:1;
    if(const char* value=getenv("WWHD_RES_SCALE"))self.quality.selectedSegmentIndex=atof(value)>1?1:0;
    if(gfx::upscale::requested())self.quality.selectedSegmentIndex=2;
    self.upscaleQualityTitle=label(@"Upscaler input resolution");
    self.upscaleQuality=[self segments:@[@"60%",@"65%",@"70%",@"75%",@"80%",@"85%",@"90%"] action:@selector(upscaleQualityChanged)];
    NSUserDefaults* defaults=NSUserDefaults.standardUserDefaults;
    id savedInputPercent=[defaults objectForKey:@"ios.upscaleInputPercent"];
    self.upscaleQuality.selectedSegmentIndex=ios::display::upscale_preset_for_ratio(
        ios::display::saved_upscale_ratio(savedInputPercent? (int)[savedInputPercent integerValue] : -1,
            (int)[defaults integerForKey:@"ios.upscaleQuality"]));
    self.upscaleQuality.accessibilityIdentifier=@"upscale-input-quality";
    self.upscaleQuality.accessibilityLabel=@"Upscaler input scale";
    self.resolutionNote=label(@""); self.resolutionNote.numberOfLines=0;
    self.resolutionNote.font=[UIFont systemFontOfSize:12];
    self.resolutionNote.accessibilityIdentifier=@"resolution-explanation";
    self.save=[self button:@"Save" action:@selector(saveState)]; self.load=[self button:@"Load" action:@selector(loadState)];
    UIStackView* actions=[[UIStackView alloc] initWithArrangedSubviews:@[self.save,self.load]];
    actions.distribution=UIStackViewDistributionFillEqually; actions.spacing=10;
    [actions.heightAnchor constraintEqualToConstant:40].active=YES;
    self.slots=[self segments:@[@"Slot 1",@"Slot 2",@"Slot 3"] action:@selector(slotChanged)];
    self.slots.selectedSegmentIndex=2; // visible slot 3 preserves the original backend slot 5
    self.thumbnail=[UIImageView new]; self.thumbnail.contentMode=UIViewContentModeScaleAspectFit;
    self.thumbnail.backgroundColor=[ink() colorWithAlphaComponent:.06]; self.thumbnail.clipsToBounds=YES;
    self.thumbnail.isAccessibilityElement=YES; self.thumbnail.accessibilityLabel=@"Selected slot thumbnail";
    [self.thumbnail.heightAnchor constraintEqualToConstant:150].active=YES;
    self.thumbnailStatus=label(@""); self.thumbnailStatus.font=[UIFont systemFontOfSize:12]; self.thumbnailStatus.numberOfLines=0;
    self.status=label(@"Manual save/load · slot 3 (keeps original slot 5)"); self.status.font=[UIFont systemFontOfSize:12]; self.status.numberOfLines=0;
    self.slotStatus=label(@""); self.slotStatus.font=self.status.font; self.slotStatus.numberOfLines=0;
    UIButton* close=[self button:@"Back to adventure" action:@selector(togglePanel)]; close.backgroundColor=ink();
    [close setTitleColor:paper() forState:UIControlStateNormal]; [close.heightAnchor constraintEqualToConstant:42].active=YES;
    UILabel* performanceNote=label(@"CPU: 100% is one core; GPU shows command time per frame.\nMemory is shared with Metal; iOS reports a thermal state, not °C.");
    performanceNote.font=[UIFont systemFontOfSize:11];performanceNote.numberOfLines=2;
    UILabel* stateNote=label(@"The game's own saves work as normal; use the in-game menu for regular saves. The three save-state slots are separate snapshots and don't trigger the game's save.\nLoading a save state restores progress in memory but doesn't roll back the game's save file; saving from the game menu afterwards writes the current progress as usual.");
    stateNote.font=[UIFont systemFontOfSize:12]; stateNote.numberOfLines=0;
    stateNote.accessibilityIdentifier=@"independent-save-types";
    self.detailsButton=[self button:@"Performance details ›" action:@selector(showDetails)];
    [self.detailsButton.heightAnchor constraintEqualToConstant:42].active=YES;
    UIStackView* screenStack=[[UIStackView alloc] initWithArrangedSubviews:@[
        [self row:@"Performance overlay" control:self.performance],performanceNote,self.detailsButton,self.frameMode,
        label(@"Screen"),self.screenFill,label(@"Aspect ratio"),self.aspectMode,label(@"Render resolution"),self.quality,self.upscaleQualityTitle,self.upscaleQuality,self.resolutionNote]];
    UIStackView* controlsStack=[[UIStackView alloc] initWithArrangedSubviews:@[
        label(@"Controller mode"),self.controllerMode,label(@"GamePad screen"),self.gamepadScreen,
        [self row:@"Controller gyro" control:self.gyro],self.gyroStatus,recalibrate,
        label(@"Touch buttons"),self.touchMode,editTouch,touchNote,self.touchMoveValue,self.touchMove,self.touchLookValue,self.touchLook,resetTouch]];
    self.playTime=label(@"");
    self.playTime.numberOfLines=0;
    self.playTime.font=[UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightRegular];
    self.playTime.accessibilityIdentifier=@"play-time";
    UILabel* playTimeNote=label(@"Counted since this version, including menus and cutscenes; pauses in the background, fast-forward counts real time. Separate from saves, so loading doesn't rewind it. Saved every 30 s and when you leave the app.");
    playTimeNote.font=[UIFont systemFontOfSize:12]; playTimeNote.numberOfLines=0;
    UIStackView* assistStack=[[UIStackView alloc] initWithArrangedSubviews:@[
        label(@"Play time"),self.playTime,playTimeNote,[self row:@"Fast-forward" control:self.fastEnabled],
        [self row:@"Fast-forward now" control:self.fast],self.fastScope,self.rate]];
    // Cross-save: the main project's save folder (mods/save_folder.h), a folder in Files / iCloud Drive
    // shared with the Mac version (platform/ios/save_folder_ios.mm)
    // Crash Recovery (crashrec.h): the main project's automatic save states. On by default on iPhone
    // (once: the player's own choice is kept after that)
    if(![NSUserDefaults.standardUserDefaults boolForKey:@"ios.crashRecoveryDefaulted"]) {
        crashrec::set_enabled(true);
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"ios.crashRecoveryDefaulted"];
    }
    UILabel* recoveryTitle=label(@"Crash recovery");
    recoveryTitle.font=[UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    self.crashRecovery=[self toggle:crashrec::enabled() action:@selector(crashRecoveryChanged)];
    UILabel* recoveryNote=label(@"Saves an automatic state every few minutes in the background, so a crash costs minutes, not your progress since the last save. Saving pauses the game for a moment.");
    recoveryNote.numberOfLines=0; recoveryNote.font=[UIFont systemFontOfSize:12];
    self.autoStates=[UIStackView new]; self.autoStates.axis=UILayoutConstraintAxisVertical; self.autoStates.spacing=8;
    UILabel* crossTitle=label(@"Cross-save");
    crossTitle.font=[UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    self.saveFolderStatus=label(@""); self.saveFolderStatus.numberOfLines=0; self.saveFolderStatus.font=[UIFont systemFontOfSize:12];
    UIButton* chooseFolder=[self button:@"Choose save folder (iCloud Drive…) ›" action:@selector(chooseSaveFolder)];
    [chooseFolder.heightAnchor constraintEqualToConstant:40].active=YES;
    UIButton* defaultFolder=[self button:@"Keep saves on this iPhone only" action:@selector(defaultSaveFolder)];
    [defaultFolder.heightAnchor constraintEqualToConstant:40].active=YES;
    UILabel* crossNote=label(@"Pick the same iCloud Drive folder here and in the Mac version (Settings > Saves > Save folder) to play one save on both. Applies the next time you open the game: close it from the app switcher. Your current save is copied there; if the folder already has one, you're asked which to keep (with a backup). Play on one device at a time.");
    crossNote.numberOfLines=0; crossNote.font=[UIFont systemFontOfSize:12];
    UIStackView* saveStack=[[UIStackView alloc] initWithArrangedSubviews:@[
        [self row:@"Save states" control:self.states],stateNote,self.slots,self.slotStatus,self.thumbnail,self.thumbnailStatus,actions,self.status,
        recoveryTitle,[self row:@"Automatic states" control:self.crashRecovery],recoveryNote,self.autoStates,
        crossTitle,self.saveFolderStatus,chooseFolder,defaultFolder,crossNote]];
    // Game: the main project's settings list (mods/game_settings.h), built from it each time it opens,
    // so options added upstream appear here without changes to this panel
    self.gameStack=[UIStackView new];
    for(UIStackView* stack in @[screenStack,controlsStack,assistStack,saveStack,self.gameStack]) {
        stack.axis=UILayoutConstraintAxisVertical; stack.spacing=10; stack.translatesAutoresizingMaskIntoConstraints=NO;
    }
    self.settingsPages=@[[self scrollWithContent:screenStack],[self scrollWithContent:controlsStack],
        [self scrollWithContent:assistStack],[self scrollWithContent:saveStack],[self scrollWithContent:self.gameStack]];
    self.settingsScroll=self.settingsPages[0];
    self.settingsCategory=[self segments:@[@"Display",@"Controls",@"Extras",@"Save",@"Game"] action:@selector(settingsCategoryChanged)];
    self.settingsCategory.selectedSegmentIndex=0;
    self.settingsCategory.accessibilityLabel=@"Settings category";
    UIStackView* header=[[UIStackView alloc] initWithArrangedSubviews:@[title,close]];
    header.axis=UILayoutConstraintAxisHorizontal; header.alignment=UIStackViewAlignmentCenter; header.spacing=12;
    [close.widthAnchor constraintEqualToConstant:112].active=YES;
    self.settingsPage=[UIView new]; self.settingsPage.translatesAutoresizingMaskIntoConstraints=NO;
    [self.panel addSubview:self.settingsPage];
    header.translatesAutoresizingMaskIntoConstraints=NO; [self.settingsPage addSubview:header];
    self.settingsCategory.translatesAutoresizingMaskIntoConstraints=NO; [self.settingsPage addSubview:self.settingsCategory];
    self.settingsBody=[UIView new]; self.settingsBody.translatesAutoresizingMaskIntoConstraints=NO;
    [self.settingsPage addSubview:self.settingsBody];
    [NSLayoutConstraint activateConstraints:@[
        [self.settingsPage.topAnchor constraintEqualToAnchor:self.panel.topAnchor constant:14],
        [self.settingsPage.bottomAnchor constraintEqualToAnchor:self.panel.bottomAnchor constant:-14],
        [self.settingsPage.leadingAnchor constraintEqualToAnchor:self.panel.leadingAnchor constant:20],
        [self.settingsPage.trailingAnchor constraintEqualToAnchor:self.panel.trailingAnchor constant:-20],
        [header.topAnchor constraintEqualToAnchor:self.settingsPage.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:self.settingsPage.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.settingsPage.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:42],
        [self.settingsCategory.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:10],
        [self.settingsCategory.leadingAnchor constraintEqualToAnchor:self.settingsPage.leadingAnchor],
        [self.settingsCategory.trailingAnchor constraintEqualToAnchor:self.settingsPage.trailingAnchor],
        [self.settingsBody.topAnchor constraintEqualToAnchor:self.settingsCategory.bottomAnchor constant:10],
        [self.settingsBody.bottomAnchor constraintEqualToAnchor:self.settingsPage.bottomAnchor],
        [self.settingsBody.leadingAnchor constraintEqualToAnchor:self.settingsPage.leadingAnchor],
        [self.settingsBody.trailingAnchor constraintEqualToAnchor:self.settingsPage.trailingAnchor]]];
    for(NSUInteger i=0;i<self.settingsPages.count;++i) {
        UIScrollView* page=self.settingsPages[i];
        page.hidden=i!=0;
        [self.settingsBody addSubview:page];
        [NSLayoutConstraint activateConstraints:@[[page.topAnchor constraintEqualToAnchor:self.settingsBody.topAnchor],
            [page.bottomAnchor constraintEqualToAnchor:self.settingsBody.bottomAnchor],
            [page.leadingAnchor constraintEqualToAnchor:self.settingsBody.leadingAnchor],
            [page.trailingAnchor constraintEqualToAnchor:self.settingsBody.trailingAnchor]]];
    }
    UILabel* detailsTitle=label(@"Performance details"); detailsTitle.font=title.font;
    self.detailsText=label(@"Sampling…"); self.detailsText.numberOfLines=0;
    self.detailsText.font=[UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.detailsText.accessibilityIdentifier=@"performance-details";
    UIScrollView* detailsScroll=[self scrollWithContent:self.detailsText];
    self.detailsGraph=[WWFrameTimeGraph new]; self.detailsGraph.translatesAutoresizingMaskIntoConstraints=NO;
    [self.detailsGraph.heightAnchor constraintEqualToConstant:64].active=YES;
    UIButton* resetStats=[self button:@"Reset FPS / lows" action:@selector(resetPerformance)];
    [resetStats.heightAnchor constraintEqualToConstant:34].active=YES;
    self.detailsBack=[self button:@"Back to settings" action:@selector(hideDetails)];
    [self.detailsBack.heightAnchor constraintEqualToConstant:42].active=YES;
    self.detailsPage=[[UIStackView alloc] initWithArrangedSubviews:@[detailsTitle,self.detailsGraph,resetStats,detailsScroll,self.detailsBack]];
    self.detailsPage.axis=UILayoutConstraintAxisVertical; self.detailsPage.spacing=14;
    self.detailsPage.translatesAutoresizingMaskIntoConstraints=NO; self.detailsPage.hidden=YES;
    [self.panel addSubview:self.detailsPage];
    [NSLayoutConstraint activateConstraints:@[[self.detailsPage.topAnchor constraintEqualToAnchor:self.panel.topAnchor constant:20],
        [self.detailsPage.bottomAnchor constraintEqualToAnchor:self.panel.bottomAnchor constant:-20],
        [self.detailsPage.leadingAnchor constraintEqualToAnchor:self.panel.leadingAnchor constant:20],
        [self.detailsPage.trailingAnchor constraintEqualToAnchor:self.panel.trailingAnchor constant:-20]]];
    // Observe touch-down without claiming the touch from the game or UIKit controls.
    self.touchObserver=[[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
    self.touchObserver.cancelsTouchesInView=NO;
    self.touchObserver.delaysTouchesBegan=NO; self.touchObserver.delaysTouchesEnded=NO;
    self.touchObserver.delegate=self; [root addGestureRecognizer:self.touchObserver];
    self.backdrop.hidden=YES; [self refresh]; [self showEntry]; return self;
}
- (void)showEntry {
    if(!native_settings_fallback) { self.entry.hidden=YES; return; }
    [self.entryTimer invalidate]; self.entryTimer=nil;
    self.entry.hidden=NO;
    if(panel_open.load())return;
    __weak WWQuickControls* weakSelf=self;
    self.entryTimer=[NSTimer timerWithTimeInterval:5 repeats:NO block:^(NSTimer*) {
        WWQuickControls* owner=weakSelf; if(!owner)return;
        if(!panel_open.load())owner.entry.hidden=YES;
        owner.entryTimer=nil;
    }];
    [NSRunLoop.mainRunLoop addTimer:self.entryTimer forMode:NSRunLoopCommonModes];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)recognizer shouldReceiveTouch:(UITouch* _Nullable)touch {
    [self showEntry];
    return NO;
}
- (void)togglePanel {
    self.backdrop.hidden=!self.backdrop.hidden; panel_open=!self.backdrop.hidden;
    if(panel_open.load()) {
        self.settingsPage.hidden=NO; self.detailsPage.hidden=YES;
        [self refresh];
    } else {
        self.settingsPage.hidden=YES; self.detailsPage.hidden=YES;
        [self.thumbnailRetryTimer invalidate]; self.thumbnailRetryTimer=nil;
    }
    [self syncPerformanceDemand];
    // Releasing gameplay input also resets fast-forward; a native menu preserves user intent.
    const bool armed=mods::fast_forward_latched();
    input::release_keys(); input::set_touch(false,0,0);
    if(armed)mods::set_fast_forward_latched(true);
    ios::refresh_touch_controls();
    [self showEntry];
}
- (void)settingsCategoryChanged {
    const NSInteger selected=std::clamp((int)self.settingsCategory.selectedSegmentIndex,0,kSettingsCategoryCount-1);
    self.settingsCategory.selectedSegmentIndex=selected;
    for(NSUInteger i=0;i<self.settingsPages.count;++i)self.settingsPages[i].hidden=i!=(NSUInteger)selected;
    self.settingsScroll=self.settingsPages[(NSUInteger)selected];
    [self.thumbnailRetryTimer invalidate]; self.thumbnailRetryTimer=nil;
    if(!panel_open.load()||self.settingsPage.hidden)return;
    if(selected==kSettingsScreen)[self refreshResolutionNote];
    if(selected==kSettingsAssist)[self refreshPlayTime];
    if(selected==kSettingsSaves){[self refreshSlot];[self refreshSaveFolder];[self refreshAutoStates];}
    if(selected==kSettingsGame)[self rebuildGameOptions];
}
// ---------------------------------------------------------------- Game: the main project's settings list
// Left out: what the other tabs of this panel already set (resolution, frame rate, touch buttons,
// fast-forward) and what a phone has no use for (mouse sensitivity).
static bool game_option_hidden(const std::string& id) {
    static const char* const kHidden[] = {"graphics.resolution","graphics.frame-rate",
        "screen.touch-buttons","screen.touch-controls","mouse-camera.sensitivity","fast-forward",
        "game.progress","game.achievements"};  // (these two open pages of the in-game pause menu)
    for(const char* h:kHidden)if(id==h)return true;
    return false;
}
static std::vector<std::string> g_game_ids;  // control tag -> item id (items are looked up again on change)
static NSString* ns(const std::string& s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }
- (void)gameOptionChanged:(UIControl*)control {
    if(control.tag<0||control.tag>=(NSInteger)g_game_ids.size())return;
    const game_settings::Item* item=game_settings::find(g_game_ids[(size_t)control.tag]);
    if(!item||!item->set)return;
    float value=0;
    if([control isKindOfClass:UISwitch.class])value=((UISwitch*)control).on?1:0;
    else if([control isKindOfClass:UISegmentedControl.class])value=(float)((UISegmentedControl*)control).selectedSegmentIndex;
    else if([control isKindOfClass:UISlider.class]) {
        value=((UISlider*)control).value;
        if(item->step>0)value=item->min+std::round((value-item->min)/item->step)*item->step;
    }
    item->set(value);
    // other options can depend on this one (shown dimmed): redraw once the change is applied
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/8),dispatch_get_main_queue(),^{ [self rebuildGameOptions]; });
}
- (void)gameSliderMoved:(UISlider*)slider {
    if(slider.tag<0||slider.tag>=(NSInteger)g_game_ids.size())return;
    const game_settings::Item* item=game_settings::find(g_game_ids[(size_t)slider.tag]);
    UILabel* value=(UILabel*)[slider.superview viewWithTag:-1];
    if(item&&value)value.text=item->format?ns(item->format(slider.value)):[NSString stringWithFormat:@"%.2f",slider.value];
}
- (void)rebuildGameOptions {
    if(!self.gameStack)return;
    game_settings::register_builtin();
    for(UIView* v in self.gameStack.arrangedSubviews){[self.gameStack removeArrangedSubview:v];[v removeFromSuperview];}
    g_game_ids.clear();
    for(const std::string& tab:game_settings::tabs()) {
        std::vector<const game_settings::Item*> shown;
        for(const game_settings::Item* it:game_settings::items(tab))if(!game_option_hidden(it->id))shown.push_back(it);
        if(shown.empty())continue;
        UILabel* header=label(ns(game_settings::tab_label(tab)));
        header.font=[UIFont systemFontOfSize:18 weight:UIFontWeightBold];
        [self.gameStack addArrangedSubview:header];
        for(const game_settings::Item* it:shown) {
            const NSInteger tag=(NSInteger)g_game_ids.size(); g_game_ids.push_back(it->id);
            const float v=it->get?it->get():0;
            const bool enabled=!it->enabled||it->enabled();
            UIView* control=nil;
            using K=game_settings::Kind;
            if(it->kind==K::Toggle) {
                UISwitch* sw=[self toggle:v>.5f action:@selector(gameOptionChanged:)]; sw.tag=tag; sw.enabled=enabled;
                control=[self row:ns(it->label) control:sw];
            } else if(it->kind==K::Choice) {
                NSMutableArray* names=[NSMutableArray array];
                for(const std::string& c:it->choices)[names addObject:ns(c)];
                [self.gameStack addArrangedSubview:label(ns(it->label))];
                if(names.count&&names.count<=4) {
                    UISegmentedControl* seg=[self segments:names action:@selector(gameOptionChanged:)];
                    seg.apportionsSegmentWidthsByContent=YES;
                    seg.selectedSegmentIndex=std::clamp((int)std::lround(v),0,(int)names.count-1); seg.tag=tag; seg.enabled=enabled;
                    control=seg;
                } else {
                    UIButton* b=[self button:ns(game_settings::value_text(*it)) action:nil];
                    NSMutableArray* actions=[NSMutableArray array];
                    for(NSUInteger i=0;i<names.count;++i) {
                        const std::string id=it->id; const float choice=(float)i;
                        UIAction* a=[UIAction actionWithTitle:names[i] image:nil identifier:nil handler:^(UIAction*) {
                            if(const game_settings::Item* item=game_settings::find(id))if(item->set)item->set(choice);
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/8),dispatch_get_main_queue(),^{ [self rebuildGameOptions]; });
                        }];
                        if((long)i==std::lround(v))a.state=UIMenuElementStateOn;
                        [actions addObject:a];
                    }
                    b.menu=[UIMenu menuWithChildren:actions]; b.showsMenuAsPrimaryAction=YES; b.enabled=enabled;
                    [b.heightAnchor constraintEqualToConstant:40].active=YES;
                    control=b;
                }
            } else if(it->kind==K::Number) {
                UISlider* slider=[UISlider new]; slider.minimumValue=it->min; slider.maximumValue=it->max; slider.value=v;
                slider.minimumTrackTintColor=ink(); slider.tag=tag; slider.enabled=enabled;
                [slider addTarget:self action:@selector(gameSliderMoved:) forControlEvents:UIControlEventValueChanged];
                [slider addTarget:self action:@selector(gameOptionChanged:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside];
                UILabel* value=label(ns(game_settings::value_text(*it))); value.tag=-1;
                [value setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
                [self.gameStack addArrangedSubview:label(ns(it->label))];
                UIStackView* row=[[UIStackView alloc] initWithArrangedSubviews:@[slider,value]];
                row.axis=UILayoutConstraintAxisHorizontal; row.spacing=12; row.alignment=UIStackViewAlignmentCenter;
                control=row;
            } else {  // Action
                std::string title=it->label; if(it->text){const std::string t=it->text(); if(!t.empty())title+=" · "+t;}
                UIButton* b=[self button:ns(title) action:nil];
                const std::string id=it->id;
                [b addAction:[UIAction actionWithHandler:^(UIAction*) {
                    if(const game_settings::Item* item=game_settings::find(id))if(item->set)item->set(0);
                }] forControlEvents:UIControlEventTouchUpInside];
                b.enabled=enabled; [b.heightAnchor constraintEqualToConstant:40].active=YES;
                control=b;
            }
            if(control)[self.gameStack addArrangedSubview:control];
            std::string help=it->help; if(it->next_start)help+=(help.empty()?"":" ")+std::string("Applies at the next start.");
            if(!help.empty()) {
                UILabel* note=label(ns(help)); note.numberOfLines=0; note.font=[UIFont systemFontOfSize:12];
                note.alpha=enabled?1:.5; [self.gameStack addArrangedSubview:note];
            }
        }
    }
    if(!self.gameStack.arrangedSubviews.count)
        [self.gameStack addArrangedSubview:label(@"These options appear once the game is running.")];
    // the rest of the main project's Settings window: the mod catalogue, quest mods, save backups,
    // audio, button mapping, language (host.mm hides the tabs this panel already covers)
    UILabel* moreTitle=label(@"Mods and more");
    moreTitle.font=[UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    UIButton* more=[self button:@"Mods, audio, button mapping & more ›" action:@selector(openMainSettings)];
    [more.heightAnchor constraintEqualToConstant:44].active=YES;
    UILabel* moreNote=label(@"Opens the main project's own menu: download and switch mods, save backups, sound, controller button mapping, language. Close it with ✕ or B.");
    moreNote.numberOfLines=0; moreNote.font=[UIFont systemFontOfSize:12];
    for(UIView* v in @[moreTitle,more,moreNote])[self.gameStack addArrangedSubview:v];
}
- (void)refreshPlayTime {
    if(!panel_open.load()||self.settingsPage.hidden||self.settingsCategory.selectedSegmentIndex!=kSettingsAssist)return;
    const auto time=ios::play_time();
    auto duration=[](double seconds) {
        return [NSString stringWithFormat:@"%.0f h %02u min %02u s",std::floor(seconds/3600),
            (unsigned)std::fmod(seconds/60,60),(unsigned)std::fmod(seconds,60)];
    };
    self.playTime.text=[NSString stringWithFormat:@"Total play  %@\nThis session  %@",duration(time.totalSeconds),duration(time.sessionSeconds)];
}
- (void)refresh {
    // Clamp legacy/environment values in memory without saving temporary settings.
    const bool frameLimited=enforce_frame_limit();
    self.hud.hidden=!self.performance.on;
    self.hudGraph.hidden=self.hud.hidden;
    [self refreshTouchSensitivity];
    self.fastEnabled.on=mods::fast_forward();
    self.fast.on=mods::fast_forward_latched();
    self.fast.enabled=mods::fast_forward();
    self.rate.selectedSegmentIndex=std::clamp(int(mods::fast_forward_rate())-2,0,2);
    self.frameMode.selectedSegmentIndex=frame_segment();
    self.controllerMode.selectedSegmentIndex=input::pro_controller()?1:0;
    self.gamepadScreen.selectedSegmentIndex=gfx::g_mode==gfx::kDrcGamePad?2:gfx::g_mode==gfx::kDrcPip?1:0;
    self.gyro.on=motion::settings().source==motion::kController;
    self.gyroStatus.text=motion::gyro_controllers()>0?
        @"Controller with gyro detected. Also turn on motion controls in the game; let go of the right stick while aiming. Keep the controller still while calibrating.":
        @"No controller with gyro detected. You can leave this on until one connects; buttons work normally.";
    if(panel_open.load()&&!self.settingsPage.hidden&&self.settingsCategory.selectedSegmentIndex==kSettingsScreen)
        [self refreshResolutionNote];
    self.fastScope.selectedSegmentIndex=mods::fast_forward_global()?1:0;
    if(frameLimited)[self refreshDetails];
    if(panel_open.load()&&!self.settingsPage.hidden&&self.settingsCategory.selectedSegmentIndex==kSettingsSaves)
        [self refreshSlot];
    [self refreshPlayTime];
}
- (void)slotChanged { [self refreshSlot]; }
- (void)openMainSettings {
    if(panel_open.load())[self togglePanel];
    overlay::set_open(true);
}
- (void)crashRecoveryChanged {
    crashrec::set_enabled(self.crashRecovery.on);
    [self refreshAutoStates];
}
- (void)refreshAutoStates {
    self.crashRecovery.on=crashrec::enabled();
    for(UIView* v in self.autoStates.arrangedSubviews){[self.autoStates removeArrangedSubview:v];[v removeFromSuperview];}
    for(int i=1;i<=crashrec::kAutoSlots;++i) {
        const crashrec::AutoInfo a=crashrec::auto_info(i);
        if(!a.used)continue;
        NSString* title=[NSString stringWithFormat:@"Load automatic state %d · %@%@%@",i,text(a.when),a.area.empty()?@"":@" · ",text(a.area)];
        UIButton* b=[self button:title action:nil];
        b.titleLabel.adjustsFontSizeToFitWidth=YES;
        const int slot=i;
        [b addAction:[UIAction actionWithHandler:^(UIAction*) {
            UIAlertController* ask=[UIAlertController alertControllerWithTitle:@"Load this automatic state?"
                message:@"Progress since then is lost unless you saved in the game." preferredStyle:UIAlertControllerStyleAlert];
            [ask addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [ask addAction:[UIAlertAction actionWithTitle:@"Load" style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
                crashrec::request_load(slot);
                if(panel_open.load())[self togglePanel];
            }]];
            [self.controller presentViewController:ask animated:YES completion:nil];
        }] forControlEvents:UIControlEventTouchUpInside];
        [b.heightAnchor constraintEqualToConstant:40].active=YES;
        [self.autoStates addArrangedSubview:b];
    }
    if(!self.autoStates.arrangedSubviews.count)
        [self.autoStates addArrangedSubview:label(crashrec::enabled()?@"No automatic state yet.":@"Off.")];
}
- (void)refreshSaveFolder {
    const save_folder::View v=save_folder::view();
    NSString* now=v.custom?[NSString stringWithFormat:@"Saves are in: %@",text(v.folder)]:@"Saves are on this iPhone (the app's own folder).";
    if(v.pending)now=[now stringByAppendingFormat:@"\nNext time you open the game: %@",
        v.chosen.empty()?@"this iPhone only":text(v.chosen)];
    if(!v.notice.empty())now=[now stringByAppendingFormat:@"\n%@",text(v.notice)];
    self.saveFolderStatus.text=now;
}
- (void)chooseSaveFolder {
    hostui::choose_save_folder([self](std::string path) {
        if(path.empty())return;
        save_folder::choose(path);
        dispatch_async(dispatch_get_main_queue(),^{ [self refreshSaveFolder]; });
    });
}
- (void)defaultSaveFolder {
    ios::forget_save_folder();
    save_folder::choose("");
    [self refreshSaveFolder];
}
- (void)refreshSlot {
    if(!panel_open.load()||self.settingsPage.hidden||self.settingsCategory.selectedSegmentIndex!=kSettingsSaves)return;
    if(!self.states.on) {
        [self.thumbnailRetryTimer invalidate]; self.thumbnailRetryTimer=nil;
        self.thumbnail.image=nil; self.thumbnailPath=@""; self.thumbnailStatus.text=@"Existing save states and screenshots are kept";
        self.slotUsed=NO; self.slotCompatible=NO; self.slotPortable=NO; self.slotWhen=@""; self.slotArea=@"";
        self.save.enabled=NO; self.load.enabled=NO;
        self.slotStatus.text=@"Save states are off. Existing slots and screenshots are kept and show up again when you turn this back on.";
        return;
    }
    const int selected=backend_slot(self.slots.selectedSegmentIndex);
    auto slot=ss::instant_slot_info(selected);
    if(!slot.used)slot=ss::slot_info(selected); // explain portable-only records without loading them
    [self renderSlot:slot];
}
- (void)scheduleThumbnailRetryForPath:(NSString*)path {
    if(self.thumbnailRetryTimer.valid&&[self.thumbnailPath isEqualToString:path])return;
    [self.thumbnailRetryTimer invalidate]; self.thumbnailRetryCount=0;
    __weak WWQuickControls* weakSelf=self;
    self.thumbnailRetryTimer=[NSTimer timerWithTimeInterval:.5 repeats:YES block:^(NSTimer* timer) {
        WWQuickControls* owner=weakSelf;
        if(!owner||!panel_open.load()||owner.settingsPage.hidden||owner.settingsCategory.selectedSegmentIndex!=kSettingsSaves||
           ![owner.thumbnailPath isEqualToString:path]||++owner.thumbnailRetryCount>8) {
            [timer invalidate]; if(owner)owner.thumbnailRetryTimer=nil; return;
        }
        UIImage* image=[UIImage imageWithContentsOfFile:path];
        if(image) {
            owner.thumbnail.image=image; owner.thumbnailStatus.text=@"Selected slot screenshot";
            owner.thumbnail.accessibilityValue=[NSString stringWithFormat:@"Slot %ld · %@",
                (long)owner.slots.selectedSegmentIndex+1,owner.thumbnailStatus.text];
            [timer invalidate]; owner.thumbnailRetryTimer=nil;
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:self.thumbnailRetryTimer forMode:NSRunLoopCommonModes];
}
- (void)renderSlot:(const ss::SlotInfo&)slot {
    self.slotUsed=slot.used; self.slotCompatible=slot.compatible; self.slotPortable=slot.portable;
    self.slotWhen=text(slot.when); self.slotArea=text(slot.area);
    self.save.enabled=self.states.on&&!self.saving&&!self.loading;
    self.load.enabled=self.save.enabled&&slot.used&&slot.compatible&&!slot.portable;
    NSString* kind=!slot.used?@"Empty slot · no save state yet":slot.portable?@"This slot only has an old-format record and can't be loaded":
        !slot.compatible?@"Old format or incompatible version · can't load":@"Save state available";
    self.slotStatus.text=[NSString stringWithFormat:@"Slot %ld · %@\nSaved: %@%@",
        (long)self.slots.selectedSegmentIndex+1,kind,slot.used?(slot.when.empty()?@"unknown (old format)":text(slot.when)):@"—",
        slot.area.empty()?@"":[@"\nLocation: " stringByAppendingString:text(slot.area)]];
    NSString* path=slot.used&&!slot.portable&&slot.thumbnail_linked?text(slot.thumbnail_path):@"";
    if(![self.thumbnailPath isEqualToString:path]) {
        [self.thumbnailRetryTimer invalidate]; self.thumbnailRetryTimer=nil;
        self.thumbnailRetryCount=0;
        self.thumbnail.image=nil; self.thumbnailPath=path;
    }
    if(path.length&&!self.thumbnail.image) {
        self.thumbnail.image=[UIImage imageWithContentsOfFile:path];
        if(!self.thumbnail.image)[self scheduleThumbnailRetryForPath:path];
        else { [self.thumbnailRetryTimer invalidate]; self.thumbnailRetryTimer=nil; }
    } else { [self.thumbnailRetryTimer invalidate]; self.thumbnailRetryTimer=nil; }
    self.thumbnailStatus.text=self.thumbnail.image?@"Selected slot screenshot":!slot.used?@"Empty slot · no screenshot":
        !slot.thumbnail_linked?@"Old format / no linked screenshot":@"Screenshot pending or unavailable";
    self.thumbnail.accessibilityValue=[NSString stringWithFormat:@"Slot %ld · %@",(long)self.slots.selectedSegmentIndex+1,self.thumbnailStatus.text];
    self.save.alpha=self.save.enabled?1:.4; self.load.alpha=self.load.enabled?1:.4;
}

- (void)syncPerformanceDemand {
    const bool wanted=self.performance.on || (panel_open.load() && self.detailsPage && !self.detailsPage.hidden);
    gfx::g_gpu_metrics=wanted; perf::set_host_demand(wanted);
}
- (void)showDetails {
    self.settingsPage.hidden=YES; self.detailsPage.hidden=NO;
    [self syncPerformanceDemand]; [self refreshDetails]; [self showEntry];
}
- (void)hideDetails {
    self.detailsPage.hidden=YES; self.settingsPage.hidden=NO;
    [self syncPerformanceDemand]; [self showEntry];
}
- (void)performanceChanged { if(!testing_controls)[NSUserDefaults.standardUserDefaults setBool:self.performance.on forKey:show_key]; [self syncPerformanceDemand]; [self refresh]; }
- (void)refreshHUD {
    if(!self.performance.on)return;
    NSDictionary* m=self.metrics;
    NSArray<NSString*>* thermal=@[@"Normal",@"Warm",@"Serious",@"Critical"];
    NSNumber* cpuValue=m[@"processCPUPercent"];
    const double cpu=[cpuValue isKindOfClass:NSNumber.class]?cpuValue.doubleValue:-1;
    NSString* cpuText=std::isfinite(cpu)&&cpu>=0?[NSString stringWithFormat:@"%.0f%%",cpu]:@"unavailable";
    NSNumber* gpuValue=m[@"gpuIntervalMsPerFrame"];
    const double gpuMs=[gpuValue isKindOfClass:NSNumber.class]?gpuValue.doubleValue:-1;
    NSString* gpu=std::isfinite(gpuMs)&&gpuMs>=0?[NSString stringWithFormat:@"%.2f ms/frame",gpuMs]:@"sampling";
    NSDictionary* frames=[m[@"frameStatistics"] isKindOfClass:NSDictionary.class]?m[@"frameStatistics"]:nil;
    self.hud.text=[NSString stringWithFormat:@"  Display %@ · Output %@\n  AVG %@ · 1%% Low %@\n  0.1%% Low %@ · Frame %@\n  Logic %@ · %@ · Thermal %@\n  CPU %@ (1 core) · GPU %@\n  Mem %@ · Free %@\n  Metal %@ (shared) · %.0f×%.0f",
        rate_reading(m,@"sampleDisplayedFPS",@"FPS"),rate_reading(m,@"sampleFPS",@"FPS"),
        rate_reading(frames,@"averageFPS",@"FPS"),rate_reading(frames,@"low1FPS",@"FPS"),
        rate_reading(frames,@"low01FPS",@"FPS"),milliseconds(metric_number(frames,@"currentMs")),
        rate_reading(m,@"sampleExecutedStepsPerSecond",@"Hz"),
        mods::fast_forward_active()?[NSString stringWithFormat:@"Fast %u×",mods::fast_forward_rate()]:@"Normal speed",
        thermal[std::clamp((int)NSProcessInfo.processInfo.thermalState,0,3)],cpuText,gpu,
        memory_size(metric_number(m,@"physicalFootprint")),memory_size(metric_number(m,@"availableMemoryBytes")),
        memory_size(metric_number(m,@"metalAllocatedBytes")),
        std::max(0.0,metric_number(m,@"renderWidth")),std::max(0.0,metric_number(m,@"renderHeight"))];
    NSDictionary* frameStats=[m[@"frameStatistics"] isKindOfClass:NSDictionary.class]?m[@"frameStatistics"]:nil;
    self.hudGraph.samples=[frameStats[@"graphMs"] isKindOfClass:NSArray.class]?frameStats[@"graphMs"]:@[];
    self.hudGraph.budget=1000.0/target_fps();
    [self.hudGraph setNeedsDisplay];
}
- (void)refreshDetails {
    if(!panel_open.load()||self.detailsPage.hidden)return;
    NSDictionary* m=self.metrics;
    const double cpu=metric_number(m,@"processCPUPercent"),cores=metric_number(m,@"processorCount");
    NSString* cpuText=cpu>=0?[NSString stringWithFormat:@"%.1f%%",cpu]:@"unavailable";
    NSString* allCores=cpu>=0&&cores>0?[NSString stringWithFormat:@"%.1f%% (of %.0f cores)",cpu/cores,cores]:@"unavailable";
    NSDictionary* gpu=[m[@"gpuCommandInterval"] isKindOfClass:NSDictionary.class]?m[@"gpuCommandInterval"]:nil;
    const double recent=metric_number(gpu,@"currentMs"),average=metric_number(gpu,@"averageMs");
    const int target=target_fps();
    const double budgetMs=1000.0/target;
    NSString* budget=recent>=0&&average>=0?[NSString stringWithFormat:@"Recent %.1f%% · average %.1f%%",recent/budgetMs*100,average/budgetMs*100]:@"sampling";
    NSString* device=[m[@"gpuDeviceName"] isKindOfClass:NSString.class]?m[@"gpuDeviceName"]:@"unavailable";
    NSString* output=[NSString stringWithFormat:@"Display %@\nOutput %@\nLogic %@\nRefresh callback %@ · requested %@",
        rate_reading(m,@"sampleDisplayedFPS",@"FPS"),rate_reading(m,@"sampleFPS",@"FPS"),
        rate_reading(m,@"sampleExecutedStepsPerSecond",@"Hz"),rate_reading(m,@"displayLinkHz",@"Hz"),
        rate_reading(m,@"requestedRefreshHz",@"Hz")];
    NSArray<NSString*>* thermal=@[@"Normal",@"Warm",@"Serious",@"Critical"];
    NSDictionary* frames=[m[@"frameStatistics"] isKindOfClass:NSDictionary.class]?m[@"frameStatistics"]:nil;
    NSArray* graph=[frames[@"graphMs"] isKindOfClass:NSArray.class]?frames[@"graphMs"]:@[];
    self.detailsGraph.samples=graph; self.detailsGraph.budget=budgetMs; [self.detailsGraph setNeedsDisplay];
    NSString* frameText=[NSString stringWithFormat:
        @"FPS / frame time\nAverage %@\n1%% Low %@\n0.1%% Low %@\nMin %@ · Max %@\n"
         "Recent %@ · average %@\nP99 %@ · P99.9 %@\nSlowest frame %@\nLong frames %.0f (over 1.5× frame budget)\n"
         "Window %.1f s · %.0f valid frame intervals\nRender %.0f × %.0f · Screen %.0f × %.0f\n\n",
        rate_reading(frames,@"averageFPS",@"FPS"),rate_reading(frames,@"low1FPS",@"FPS"),rate_reading(frames,@"low01FPS",@"FPS"),
        rate_reading(frames,@"minimumFPS",@"FPS"),rate_reading(frames,@"maximumFPS",@"FPS"),
        milliseconds(metric_number(frames,@"currentMs")),milliseconds(metric_number(frames,@"averageMs")),
        milliseconds(metric_number(frames,@"p99Ms")),milliseconds(metric_number(frames,@"p999Ms")),milliseconds(metric_number(frames,@"maximumMs")),
        std::max(0.0,metric_number(frames,@"longFrames")),std::max(0.0,metric_number(frames,@"seconds")),std::max(0.0,metric_number(frames,@"samples")),
        std::max(0.0,metric_number(m,@"renderWidth")),std::max(0.0,metric_number(m,@"renderHeight")),
        std::max(0.0,metric_number(m,@"drawableWidth")),std::max(0.0,metric_number(m,@"drawableHeight"))];
    if(gfx::upscale::requested()) frameText=[frameText stringByAppendingFormat:
        @"MetalFX spatial upscaling (beta)\n%@\n\n",upscale_status_text()];
    self.detailsText.text=[NSString stringWithFormat:
        @"%@CPU (process)\n%@ (100%% = 1 core)\n%@\nProcess CPU time %@ / output frame\n\n"
         "Game thread CPU\n%@\n\nRender thread CPU\n%@\n\n"
         "GPU · %@\nCommand time / output frame\n%@\nTarget %d FPS · frame budget %.2f ms\nShare of budget: %@\n\n"
         "Memory (unified)\nProcess %@ · peak %@\nResident %@ · compressed %@\nMetal allocated %@ · peak %@\nDevice RAM %@\nApp headroom %@\nRecommended Metal working set %@\n\n"
         "Output and thermal\n%@\nThermal state: %@\n\n"
         "About these numbers\nUpdated every 2 s; averages cover up to 120 valid samples.\n"
         "FPS / lows use about the last 60 s of displayed frames; 1%% / 0.1%% Low need at least 100 / 1000 intervals. P99 / P99.9 are frame-time percentiles.\n"
         "The graph shows peaks over the last 10 s so stutters stay visible; the yellow line is the frame budget. Stats restart after backgrounding or Reset.\n"
         "Display FPS uses real presentation timestamps; Output FPS counts rendered frames; Logic Hz counts game logic steps.\n"
         "Refresh callback and requested rates aren't the displayed FPS; the frame budget accounts for the screen limit and fast-forward.\n"
         "Thread CPU is running time between frames, excluding sleeps and waits.\n"
         "GPU command time includes queue stalls and is not GPU utilization; over 100%% means it exceeded the frame budget.\n"
         "The all-core CPU figure is a simple conversion, not total system load.\n"
         "Metal and process memory overlap, so don't add them.\n"
         "iOS doesn't expose CPU/GPU clocks, GPU utilization or temperatures.",
        frameText,cpuText,allCores,milliseconds(metric_number(m,@"processCPUMsPerFrame")),
        interval_details(m,@"gameThreadCPU"),interval_details(m,@"renderThreadCPU"),device,
        interval_details(m,@"gpuCommandInterval"),target,budgetMs,budget,
        memory_size(metric_number(m,@"physicalFootprint")),memory_size(metric_number(m,@"peakPhysicalFootprint")),
        memory_size(metric_number(m,@"residentMemoryBytes")),memory_size(metric_number(m,@"compressedMemoryBytes")),
        memory_size(metric_number(m,@"metalAllocatedBytes")),memory_size(metric_number(m,@"peakMetalAllocatedBytes")),
        memory_size(metric_number(m,@"devicePhysicalMemory")),memory_size(metric_number(m,@"availableMemoryBytes")),
        memory_size(metric_number(m,@"metalRecommendedWorkingSetBytes")),output,
        thermal[std::clamp((int)NSProcessInfo.processInfo.thermalState,0,3)]];
}
- (void)resetPerformance {
    ios::reset_performance_window(); self.metrics=nil;
    self.status.text=@"FPS / lows reset; sampling again.";
    ios::update_controls(@{});
}
- (void)scopeChanged {
    mods::set_fast_forward_global(self.fastScope.selectedSegmentIndex==1);
    persist_setting("ios.fastForwardGlobal",mods::fast_forward_global()?"1":"0");
}
- (void)fastEnabledChanged {
    if(testing_controls)mods::set_fast_forward(self.fastEnabled.on);
    else mods::manager::set_enabled("fast-forward",self.fastEnabled.on);
    [self refresh];
}
- (void)fastChanged {
    if(self.fast.on&&!mods::fast_forward()) { self.fast.on=NO; return; }
    mods::set_fast_forward_latched(self.fast.on);
    [self refresh];
}
- (void)rateChanged {
    mods::set_fast_forward_rate((unsigned)self.rate.selectedSegmentIndex+2);
    persist_setting("mod.fast-forward.rate",std::to_string(mods::fast_forward_rate()));
}
- (void)controllerChanged {
    bool pro=self.controllerMode.selectedSegmentIndex==1;
    hostui::set_pro_controller(pro); persist_setting("proController",pro?"1":"0");
    self.status.text=@"Controller mode selected; it switches after the current cutscene.";
}
- (void)gamepadScreenChanged {
    const int modes[]={gfx::kDrcAuto,gfx::kDrcPip,gfx::kDrcGamePad};
    const int selected=std::clamp((int)self.gamepadScreen.selectedSegmentIndex,0,2);
    gfx::display_set_mode(modes[selected]);
    persist_setting("ios.gamepadScreen",std::to_string(modes[selected]));
    [self refresh];
}
- (void)gyroChanged {
    auto setting=motion::settings();
    setting.source=self.gyro.on?motion::kController:motion::kOff;
    motion::set_settings(setting);
    persist_setting("gyro.source",motion::source_id(motion::settings().source));
    [self refresh];
}
- (void)recalibrateGyro {
    motion::recalibrate(); self.status.text=@"Keep the controller still for a moment while the gyro recalibrates.";
}
- (void)frameChanged {
    const int selected=std::clamp((int)self.frameMode.selectedSegmentIndex,0,screen_120()?2:1);
    self.frameMode.selectedSegmentIndex=selected;
    const int fps=selected==2?120:60;
    self.status.text=selected==0?@"Frame rate: 30 FPS":selected==1?@"Frame rate: 60 FPS":@"Frame rate: 120 FPS (uses more battery)";
    interp::set_fps(fps); interp::set_paced_interpolation_at(fps,true); interp::set_mode(selected?1:0);
    persist_setting("ios.interpFps",fps==120?"120":"60");
    persist_setting("ios.frameMode",selected?"1":"0");
    [self refresh]; [self refreshDetails];
}
- (void)qualityChanged {
    const bool native=self.quality.selectedSegmentIndex==1;
    const bool upscale=self.quality.selectedSegmentIndex==2;
    gfx::upscale::set_requested(upscale);
    persist_setting("ios.metalFX",upscale?"1":"0");
    persist_setting("ios.nativeResolution",native?"1":"0");
    const CGSize size=gfx::R.tv.layer.drawableSize;
    hostui::set_res_scale(upscale?ios::display::upscale_scale(size.width,size.height,aspect::requested(),
            ios::display::upscale_ratio((int)self.upscaleQuality.selectedSegmentIndex))
        :ios::display::render_scale(native,size.width,size.height,aspect::requested()));
    ios::reset_performance_window();
    [self refreshResolutionNote];
}
- (void)upscaleQualityChanged {
    persist_setting("ios.upscaleInputPercent",std::to_string(ios::display::upscale_percent(
        (int)self.upscaleQuality.selectedSegmentIndex)));
    [self qualityChanged];
}
- (void)screenFillChanged {
    const bool full=self.screenFill.selectedSegmentIndex==0;
    ios::set_full_screen(full);
    persist_setting("ios.screenFill",full?"full":"safe");
    // The game view changed shape: recompute the render size for the chosen resolution tier.
    [self qualityChanged];
}
- (void)aspectChanged {
    const bool original=self.aspectMode.selectedSegmentIndex==1;
    aspect::set_mode(original?aspect::kOriginal:aspect::kWindow);
    persist_setting("ios.aspectMode",original?"original":"window");
    // Recalculate pixel density for the new view shape while retaining the chosen resolution tier.
    [self qualityChanged];
}
- (void)refreshResolutionNote {
    self.aspectMode.selectedSegmentIndex=aspect::mode()==aspect::kWindow?0:
        aspect::mode()==aspect::kOriginal?1:UISegmentedControlNoSegment;
    const CGSize size=gfx::R.tv.layer.drawableSize;
    const float a=aspect::requested();
    const bool native=self.quality.selectedSegmentIndex==1;
    const bool upscale=self.quality.selectedSegmentIndex==2;
    self.upscaleQuality.hidden=!upscale; self.upscaleQualityTitle.hidden=!upscale;
    const float inputRatio=ios::display::upscale_ratio((int)self.upscaleQuality.selectedSegmentIndex);
    const float scale=upscale?ios::display::upscale_scale(size.width,size.height,a,inputRatio)
        :ios::display::render_scale(native,size.width,size.height,a);
    const float nativeScale=ios::display::native_scale(size.width,size.height,a);
    const float actualInputRatio=scale/std::max(1.f,nativeScale);
    NSString* tier=native?@"Native: sharper, uses more GPU and memory.":@"Standard: renders lower and scales up to save GPU and memory.";
    if(self.quality.selectedSegmentIndex==2) tier=[NSString stringWithFormat:
        @"MetalFX upscaling (beta): input %.0f%%, currently about %.0f%% of screen size; anti-aliased, then rebuilt at screen size.\n%@",
        inputRatio*100,actualInputRatio*100,upscale_status_text()];
    if(self.quality.selectedSegmentIndex==2) tier=[tier stringByAppendingFormat:
        @"\nOutput target about %.0f × %.0f",std::min(double(size.width),double(size.height)*a),
        std::min(double(size.height),double(size.width)/a)];
    self.resolutionNote.text=[NSString stringWithFormat:@"Aspect sets the view and layout; resolution sets the pixel count.\n%@\nTarget about %.0f × %.0f; native is at least 1×.",tier,
        std::max(1280.f,720.f*a)*scale,std::max(720.f,1280.f/a)*scale];
}
- (void)touchChanged {
    persist_setting("ios.touchControls",std::to_string((int)self.touchMode.selectedSegmentIndex));
    ios::refresh_touch_controls();
}
- (void)refreshTouchSensitivity {
    self.touchMove.value=ios::touch_move_sensitivity();
    self.touchLook.value=ios::touch_look_sensitivity();
    self.touchMoveValue.text=[NSString stringWithFormat:@"Move stick response  %.2f×",self.touchMove.value];
    self.touchLookValue.text=[NSString stringWithFormat:@"Camera sensitivity  %.2f×",self.touchLook.value];
    self.touchMove.accessibilityLabel=self.touchMoveValue.text;
    self.touchLook.accessibilityLabel=self.touchLookValue.text;
}
- (void)touchSensitivityChanged {
    ios::set_touch_sensitivity(std::round(self.touchMove.value*20)/20,std::round(self.touchLook.value*20)/20);
    [self refreshTouchSensitivity];
}
- (void)editTouchLayout {
    if(panel_open.load())[self togglePanel];
    ios::edit_touch_layout();
}
- (void)resetTouchConfiguration {
    UIAlertController* alert=[UIAlertController alertControllerWithTitle:@"Reset touch controls?"
        message:@"This resets button positions, sizes, functions and sensitivity." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction*) {
        ios::reset_touch_configuration(); [self refreshTouchSensitivity];
    }]];
    [self.controller presentViewController:alert animated:YES completion:nil];
}
- (void)statesChanged {
    ss::set_instant_states_enabled(self.states.on);
    if(!testing_controls)[NSUserDefaults.standardUserDefaults setBool:self.states.on forKey:state_key];
    [self refresh];
}
- (void)saveState {
    if(!self.save.enabled||self.saving||self.loading)return;
    const int selected=backend_slot(self.slots.selectedSegmentIndex);
    if(ss::slot_info(selected).used||ss::instant_slot_info(selected).used) {
        UIAlertController* alert=[UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Overwrite slot %d?",visible_slot(selected)]
            message:@"A new save state will replace the one in this slot. Other slots are kept." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Overwrite" style:UIAlertActionStyleDestructive handler:^(UIAlertAction*) {
            [self performSaveSlot:selected];
        }]];
        [self.controller presentViewController:alert animated:YES completion:nil];
    } else [self performSaveSlot:selected];
}
- (void)performSaveSlot:(int)selected {
    if(self.saving||self.loading||!self.states.on)return;
    self.saving=YES; self.status.text=[NSString stringWithFormat:@"Saving slot %d…",visible_slot(selected)]; [self refresh];
    __weak WWQuickControls* weakSelf=self;
    ss::request_save_full(selected,[weakSelf,selected](bool ok,const std::string& why) {
        NSString* failure=state_failure(why,false);
        dispatch_async(dispatch_get_main_queue(),^{
            WWQuickControls* owner=weakSelf; if(!owner)return;
            owner.saving=NO; owner.status.text=ok?[NSString stringWithFormat:@"Save state saved · slot %d (screenshot may still be writing)",visible_slot(selected)]:[NSString stringWithFormat:@"Slot %d not saved: %@",visible_slot(selected),failure];
            [owner refresh];
            if(getenv("WWHD_IOS_TEST_QUICK_SAVE")&&getenv("WWHD_IOS_TEST_QUICK_LOAD")) {
                owner.quickStateResult=[@{@"saveOK":@(ok),@"loadOK":ok?(id)NSNull.null:@NO,
                    @"why":ok?@"waiting for load result":failure,@"trigger":@"save callback then shared native load method"} mutableCopy];
                [owner writeQuickStateResult];
                if(ok) {
                    owner.settingsCategory.selectedSegmentIndex=kSettingsSaves;
                    owner.slots.selectedSegmentIndex=visible_slot(selected)-1;
                    [owner settingsCategoryChanged];
                    if(owner.backdrop.hidden)[owner togglePanel];
                    [owner performLoadState];
                } else owner.quickStateResult=nil;
            }
        });
    });
}
- (void)writeQuickStateResult {
    [NSFileManager.defaultManager createDirectoryAtPath:@"captures" withIntermediateDirectories:YES attributes:nil error:nil];
    NSData* data=[NSJSONSerialization dataWithJSONObject:self.quickStateResult options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:@"captures/controls-quick-state-test.json" atomically:YES];
}
- (void)performLoadState {
    [self refresh];
    if(!self.load.enabled) {
        self.status.text=@"Not loaded: this slot is unavailable, unsupported or busy. See the slot details.";
        if(self.quickStateResult) {
            self.quickStateResult[@"loadOK"]=@NO; self.quickStateResult[@"why"]=self.status.text;
            [self writeQuickStateResult]; self.quickStateResult=nil;
        }
        return;
    }
    const int selected=backend_slot(self.slots.selectedSegmentIndex);
    self.loading=YES; self.status.text=[NSString stringWithFormat:@"Loading slot %d…",visible_slot(selected)];
    mods::set_fast_forward_latched(false); [self refresh];
    __weak WWQuickControls* weakSelf=self;
    ss::request_load_full(selected,[weakSelf,selected](bool ok,const std::string& why) {
        NSString* failure=state_failure(why,true);
        dispatch_async(dispatch_get_main_queue(),^{
            WWQuickControls* owner=weakSelf; if(!owner)return;
            [owner finishLoadSlot:selected ok:ok why:failure];
        });
    });
}
- (void)finishLoadSlot:(int)selected ok:(BOOL)ok why:(NSString*)failure {
    self.loading=NO;
    self.status.text=ok?[NSString stringWithFormat:@"Save state loaded · slot %d",visible_slot(selected)]:
        [NSString stringWithFormat:@"Slot %d not loaded: %@",visible_slot(selected),failure.length?failure:@"load refused"];
    // Preserve terminal evidence across app restarts; never touch the snapshot or test the logger on user results.
    if(!testing_controls) {
        NSDictionary* result=@{@"visibleSlot":@(visible_slot(selected)),@"backendSlot":@(selected),
            @"restored":@(ok),@"reason":ok?@"":(failure?:@""),
            @"date":[[NSISO8601DateFormatter new] stringFromDate:NSDate.date],
            @"appVersion":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"",
            @"appBuild":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]?:@""};
        [NSFileManager.defaultManager createDirectoryAtPath:@"captures" withIntermediateDirectories:YES attributes:nil error:nil];
        NSData* data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:[NSString stringWithFormat:@"captures/full-load-slot-%d.json",selected] atomically:YES];
    }
    if(self.quickStateResult) {
        self.quickStateResult[@"loadOK"]=@(ok); self.quickStateResult[@"why"]=ok?@"":failure;
        [self writeQuickStateResult]; self.quickStateResult=nil;
    }
    if(ok) {
        [self refresh];
        if(!self.backdrop.hidden)[self togglePanel];
    } else {
        if(self.backdrop.hidden)[self togglePanel];
        if(!self.detailsPage.hidden)[self hideDetails];
        self.settingsCategory.selectedSegmentIndex=kSettingsSaves;
        [self settingsCategoryChanged];
        [self.controller.view layoutIfNeeded];
        [self.settingsScroll scrollRectToVisible:[self.status convertRect:self.status.bounds toView:self.settingsScroll] animated:NO];
    }
}
- (void)loadState {
    if(!self.load.enabled)return;
    UIAlertController* alert=[UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Load the save state in slot %ld?",(long)self.slots.selectedSegmentIndex+1] message:@"You'll go back to that save state and lose unsaved progress. Save states may not load across versions; use in-game saves for important progress." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Load" style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
        [self performLoadState];
    }]];
    [self.controller presentViewController:alert animated:YES completion:nil];
}
@end

namespace ios {
void install_controls(UIViewController* controller) { controls=[[WWQuickControls alloc] initWithController:controller]; }
void set_performance_hud(bool visible) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if(!controls)return;
        controls.performance.on=visible;
        [controls performanceChanged];
    });
}
void test_touch_settings() {
    NSUserDefaults* defaults=NSUserDefaults.standardUserDefaults;
    id oldMove=[defaults objectForKey:@"ios.touchMoveSensitivity"],oldLook=[defaults objectForKey:@"ios.touchLookSensitivity"];
    id oldLayout=[defaults objectForKey:@"ios.touchLayout"];
    const bool wasOpen=panel_open.load();
    NSMutableArray* checks=[NSMutableArray new];
    auto check=[&](bool ok,NSString* name){ [checks addObject:@{@"passed":@(ok),@"name":name}]; };
    check(controls.touchMove.minimumValue==.5f&&controls.touchMove.maximumValue==2,@"Movement sensitivity slider range");
    check(controls.touchLook.minimumValue==.5f&&controls.touchLook.maximumValue==2,@"Camera sensitivity slider range");
    controls.touchMove.value=1.25; controls.touchLook.value=.75;
    [controls.touchMove sendActionsForControlEvents:UIControlEventValueChanged];
    check(std::abs(touch_move_sensitivity()-1.25f)<.001&&std::abs(touch_look_sensitivity()-.75f)<.001,@"Sliders apply independent sensitivities");
    check(std::abs([defaults floatForKey:@"ios.touchMoveSensitivity"]-1.25f)<.001&&
        std::abs([defaults floatForKey:@"ios.touchLookSensitivity"]-.75f)<.001,@"Sensitivity choices are stored locally");
    if(!panel_open.load())[controls togglePanel];
    [controls editTouchLayout];
    check(!panel_open.load()&&touch_layout_editing()&&controls_block_input(),@"Layout editor closes settings and blocks game input");
    finish_touch_layout_edit();
    check(!touch_layout_editing()&&!controls_block_input(),@"Finish layout editing releases its input gate");
    if(oldMove)[defaults setObject:oldMove forKey:@"ios.touchMoveSensitivity"];else [defaults removeObjectForKey:@"ios.touchMoveSensitivity"];
    if(oldLook)[defaults setObject:oldLook forKey:@"ios.touchLookSensitivity"];else [defaults removeObjectForKey:@"ios.touchLookSensitivity"];
    if(oldLayout)[defaults setObject:oldLayout forKey:@"ios.touchLayout"];else [defaults removeObjectForKey:@"ios.touchLayout"];
    refresh_touch_controls();
    if(wasOpen)[controls togglePanel];
    [controls refreshTouchSensitivity];
    BOOL passed=YES;for(NSDictionary* item in checks)passed&=[item[@"passed"] boolValue];
    NSDictionary* result=@{@"passed":@(passed),@"checks":checks,@"method":@"Native settings action self-test; physical gesture verification remains separate"};
    NSData* data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:@"captures/touch-settings-test.json" atomically:YES];
}
void update_controls(NSDictionary* metrics) {
    controls.metrics=metrics;
    if(enforce_frame_limit()&&panel_open.load()&&!controls.settingsPage.hidden&&
       controls.settingsCategory.selectedSegmentIndex==kSettingsScreen)
        controls.frameMode.selectedSegmentIndex=frame_segment();
    if(controls.performance.on)[controls refreshHUD];
    if(panel_open.load()) {
        [controls refreshPlayTime];
        if(!controls.settingsPage.hidden&&controls.settingsCategory.selectedSegmentIndex==kSettingsScreen)
            [controls refreshResolutionNote];
        if(!controls.detailsPage.hidden)[controls refreshDetails];
    }
}
NSDictionary* controls_state() {
    const auto playTime=ios::play_time();
    return @{@"panelOpen":@(panel_open.load()),@"performanceVisible":@(!controls.hud.hidden),
        @"playTimeTotalSeconds":@(playTime.totalSeconds),@"playTimeSessionSeconds":@(playTime.sessionSeconds),
        @"playTimeText":controls.playTime.text?:@"",
        @"settingsCategoryIndex":@(controls.settingsCategory.selectedSegmentIndex),
        @"touchLayoutEditing":@(ios::touch_layout_editing()),@"touchMoveSensitivity":@(ios::touch_move_sensitivity()),
        @"touchLookSensitivity":@(ios::touch_look_sensitivity()),@"touchMode":@(controls.touchMode.selectedSegmentIndex),
        @"entryVisible":@(!controls.entry.hidden),@"entryHideTimerActive":@(controls.entryTimer.valid),
        @"hudText":controls.hud.text?:@"",@"detailsVisible":@(panel_open.load()&&!controls.detailsPage.hidden),
        @"detailsText":controls.detailsText.text?:@"",@"performanceSamplingActive":@(perf::enabled()),
        @"fastForwardEnabled":@(mods::fast_forward()),@"fastForwardArmed":@(mods::fast_forward_latched()),@"fastForwardActive":@(mods::fast_forward_active()),
        @"fastForwardRate":@(mods::fast_forward_rate()),@"quickStatesEnabled":@(controls.states.on),
        @"saving":@(controls.saving),@"loading":@(controls.loading),@"stateStatus":controls.status.text?:@"",
        @"slotStatus":controls.slotStatus.text?:@"",@"visibleSlot":@(controls.slots.selectedSegmentIndex+1),
        @"backendSlot":@(backend_slot(controls.slots.selectedSegmentIndex)),@"thumbnailPath":controls.thumbnailPath?:@"",
        @"thumbnailStatus":controls.thumbnailStatus.text?:@"",@"fastForwardGlobal":@(mods::fast_forward_global()),
        @"instantStatesEnabled":@(ss::instant_states_enabled()),
        @"targetFPS":@(target_fps()),@"rayReflectionsRequested":@(gfx::ray_reflections::requested()),
        @"rayReflectionsAvailable":@(gfx::ray_reflections::available()),@"rayReflectionsActive":@(gfx::ray_reflections::active()),
        @"rayReflectionsStatus":@"removed",
        @"upscaleInputRatio":@(ios::display::upscale_ratio((int)controls.upscaleQuality.selectedSegmentIndex)),
        @"resolutionMode":@(controls.quality.selectedSegmentIndex),@"aspectMode":@(aspect::mode()),@"nativeResolutionSelected":@(controls.quality.selectedSegmentIndex==1),
        @"resolutionNote":controls.resolutionNote.text?:@"",
        @"gamepadScreenMode":@(gfx::g_mode.load()),@"gamepadPinned":@(gfx::g_auto_pin.load()),
        @"gyroSource":@(motion::source_id(motion::settings().source)),@"gyroCapableControllers":@(motion::gyro_controllers()),
        @"gyroRuntimeStatus":@(motion::status().c_str()),
        @"proController":@(input::pro_controller())};
}
void test_controls() {
    [NSFileManager.defaultManager createDirectoryAtPath:@"captures" withIntermediateDirectories:YES attributes:nil error:nil];
    // Remove a previous successful result before starting asynchronous timer checks.
    [NSFileManager.defaultManager removeItemAtPath:@"captures/controls-test.json" error:nil];
    if(getenv("WWHD_IOS_TEST_QUICK_SAVE")&&getenv("WWHD_IOS_TEST_QUICK_LOAD"))
        [NSFileManager.defaultManager removeItemAtPath:@"captures/controls-quick-state-test.json" error:nil];
    testing_controls=true;
    const BOOL interaction=controls.controller.view.userInteractionEnabled;
    controls.controller.view.userInteractionEnabled=NO; // opt-in timed self-test must not race real touches
    NSMutableArray<NSString*>* checks=[NSMutableArray new];
    auto check=[checks](bool ok,NSString* reason) {
        if(ok) { [checks addObject:reason]; return; }
        NSData* failure=[NSJSONSerialization dataWithJSONObject:@{@"passed":@NO,@"failure":reason,@"checks":checks}
            options:NSJSONWritingPrettyPrinted error:nil];
        [failure writeToFile:@"captures/controls-test.json" atomically:YES];
        @throw [NSException exceptionWithName:@"ControlsTestFailed" reason:reason userInfo:nil];
    };
    const bool performance=controls.performance.on,states=controls.states.on,pro=input::pro_controller();
    const bool fastEnabled=mods::fast_forward(),instantStatesEnabled=ss::instant_states_enabled();
    const bool armed=mods::fast_forward_latched(),wasOpen=panel_open.load();
    const bool wasDetails=wasOpen&&!controls.detailsPage.hidden;
    const unsigned rate=mods::fast_forward_rate(); const int mode=interp::mode(),savedFPS=interp::fps();
    const bool global=mods::fast_forward_global(); const NSInteger selectedSlot=controls.slots.selectedSegmentIndex;
    const NSInteger selectedCategory=controls.settingsCategory.selectedSegmentIndex;
    if(wasOpen)[controls.backdrop sendActionsForControlEvents:UIControlEventTouchUpInside];
    controls.performance.on=YES; [controls.performance sendActionsForControlEvents:UIControlEventValueChanged];
    check(!controls.hud.hidden,@"Performance switch shows HUD");
    check(gfx::g_gpu_metrics.load()&&perf::enabled(),@"Performance switch enables GPU and thread sampling");
    check(controls.frameMode.numberOfSegments==2&&[[controls.frameMode titleForSegmentAtIndex:0] isEqualToString:@"30 FPS"]&&
        [[controls.frameMode titleForSegmentAtIndex:1] isEqualToString:@"60 FPS"],@"iPad exposes only 30 and 60 FPS");
    check(!gfx::ray_reflections::requested()&&!gfx::ray_reflections::available(),@"iPad ray tracing is disabled");
    const NSInteger quality=controls.quality.selectedSegmentIndex;
    const int savedAspect=aspect::mode();
    for(int a=0;a<2;++a) {
        controls.aspectMode.selectedSegmentIndex=a;
        [controls.aspectMode sendActionsForControlEvents:UIControlEventValueChanged];
        check(controls.quality.selectedSegmentIndex==quality,@"Changing aspect preserves resolution tier");
        for(int i=0;i<2;++i) {
            controls.quality.selectedSegmentIndex=i;
            [controls.quality sendActionsForControlEvents:UIControlEventValueChanged];
            check(controls.quality.enabled,@"Both quality choices remain available");
            check(aspect::mode()==(a?aspect::kOriginal:aspect::kWindow),@"Resolution tier does not change aspect");
        }
        controls.quality.selectedSegmentIndex=quality;
    }
    aspect::set_mode(savedAspect);
    controls.quality.selectedSegmentIndex=quality;
    [controls.quality sendActionsForControlEvents:UIControlEventValueChanged];
    controls.performance.on=NO; [controls.performance sendActionsForControlEvents:UIControlEventValueChanged];
    check(controls.hud.hidden&&!gfx::g_gpu_metrics.load(),@"Performance switch hides HUD and disables GPU sampling");
    controls.performance.on=YES; [controls.performance sendActionsForControlEvents:UIControlEventValueChanged];
    if(!panel_open.load())[controls togglePanel];
    CGFloat categoryPanelWidth=0;
    for(NSInteger i=0;i<kSettingsCategoryCount;++i) {
        controls.settingsCategory.selectedSegmentIndex=i;
        [controls.settingsCategory sendActionsForControlEvents:UIControlEventValueChanged];
        NSUInteger visible=0; for(UIScrollView* page in controls.settingsPages)if(!page.hidden)++visible;
        check(controls.settingsScroll==controls.settingsPages[i]&&visible==1,
            @"Each settings category selects exactly one independent scroll page");
        if(i==kSettingsAssist)check([controls.playTime.text containsString:@"Total play"]&&
            [controls.playTime.text containsString:@"This session"],@"Auxiliary settings display total and session play time");
        [controls.controller.view layoutIfNeeded];
        if(i==0)categoryPanelWidth=controls.panel.bounds.size.width;
        check(std::abs(controls.panel.bounds.size.width-categoryPanelWidth)<.5,@"Settings categories keep a stable panel width");
        UIGraphicsImageRenderer* categoryRenderer=[[UIGraphicsImageRenderer alloc] initWithSize:controls.panel.bounds.size];
        UIImage* categoryImage=[categoryRenderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
            [controls.panel.layer renderInContext:context.CGContext];
        }];
        NSString* categoryPath=[NSString stringWithFormat:@"captures/controls-category-%ld.png",(long)i];
        check([UIImagePNGRepresentation(categoryImage) writeToFile:categoryPath atomically:YES],@"Settings category screenshot saved");
    }
    controls.settingsCategory.selectedSegmentIndex=kSettingsScreen;
    NSString* hiddenPlayTime=controls.playTime.text;
    [controls refreshPlayTime];
    check([controls.playTime.text isEqualToString:hiddenPlayTime],@"Hidden play time does not format or refresh");
    [controls.settingsCategory sendActionsForControlEvents:UIControlEventValueChanged];
    controls.detailsText.text=@"hidden detail sentinel";
    controls.detailsGraph.samples=@[@123]; controls.detailsGraph.budget=123;
    controls.slotStatus.text=@"hidden slot sentinel"; controls.touchMoveValue.text=@"hidden menu sentinel";
    NSDictionary* savedMetrics=controls.metrics;
    update_controls(@{@"frameStatistics":@{@"graphMs":@[@8,@16]}});
    check([controls.detailsText.text isEqualToString:@"hidden detail sentinel"]&&
          [controls.detailsGraph.samples isEqual:@[@123]]&&controls.detailsGraph.budget==123,
          @"Hidden details text and graph do not refresh from metrics");
    check([controls.slotStatus.text isEqualToString:@"hidden slot sentinel"]&&
          [controls.touchMoveValue.text isEqualToString:@"hidden menu sentinel"],
          @"Metrics do not refresh hidden menu or selected-slot views");
    [controls.detailsButton sendActionsForControlEvents:UIControlEventTouchUpInside];
    check(controls.settingsPage.hidden&&!controls.detailsPage.hidden&&controls_block_input(),
          @"Opening performance details displays the details page, not a hidden-settings update");
    update_controls(@{});
    check([controls.detailsText.text containsString:@"unavailable"]&&[controls.detailsText.text containsString:@"sampling"],
        @"Missing detail readings show unavailable or sampling");
    check([controls.hud.text containsString:@"CPU unavailable"],@"Missing CPU sample shows unavailable");
    check([controls.hud.text containsString:@"Display sampling"]&&[controls.detailsText.text containsString:@"Display sampling"],
        @"Missing actual display timestamps never fall back to maximum refresh or output FPS");
    update_controls(@{@"sampleDisplayedFPS":@59.5,@"sampleFPS":@60,@"sampleExecutedStepsPerSecond":@30,
        @"displayLinkHz":@60,@"requestedRefreshHz":@60});
    check([controls.hud.text containsString:@"Display 59.5 FPS"]&&[controls.hud.text containsString:@"Output 60.0 FPS"]&&
          [controls.hud.text containsString:@"Logic 30.0 Hz"]&&[controls.hud.text componentsSeparatedByString:@"\n"].count==7,
        @"Seven-line HUD distinguishes display, render, lows and game logic");
    check([controls.detailsText.text containsString:@"Refresh callback 60.0 Hz · requested 60.0 Hz"],@"Details distinguish refresh hints from actual display FPS");
    update_controls(@{@"sampleDisplayedFPS":@(-1),@"sampleFPS":@60,@"displayMaximumHz":@60});
    check([controls.hud.text containsString:@"Display sampling"],@"Unavailable actual display FPS does not use submitted frames or maximum Hz");
    update_controls(@{@"processCPUPercent":@(-1)});
    check([controls.hud.text containsString:@"CPU unavailable"],@"Negative CPU sample shows unavailable");
    update_controls(@{@"frameStatistics":@{@"samples":@1500,@"seconds":@25,@"averageFPS":@59.8,
        @"low1FPS":@50,@"low01FPS":@28,@"currentMs":@16.67,@"graphMs":@[@16.67,@33.3,@16.67]}});
    check([controls.hud.text containsString:@"1% Low 50.0 FPS"]&&[controls.hud.text containsString:@"0.1% Low 28.0 FPS"]&&
        [controls.detailsText.text containsString:@"Average 59.8 FPS"]&&controls.hudGraph.samples.count==3,
        @"HUD, details and graph consume real frame statistics without substituting output FPS");
    const uint64_t generation=perf::generation(); [controls resetPerformance];
    check(perf::generation()!=generation&&[controls.hud.text containsString:@"1% Low sampling"]&&controls.hudGraph.samples.count==0,
        @"Reset clears visible low statistics and starts a new sampling generation");
    update_controls(@{@"processCPUPercent":@450,@"processorCount":@9,
        @"gpuCommandInterval":@{@"currentMs":@8,@"averageMs":@4,@"samples":@12}});
    check([controls.detailsText.text containsString:@"50.0% (of 9 cores)"],@"CPU full-core conversion is correct");
    for(int i=0;i<2;++i) {
        controls.frameMode.selectedSegmentIndex=i; [controls.frameMode sendActionsForControlEvents:UIControlEventValueChanged];
        check(interp::mode()==i&&interp::fps()==60&&controls.frameMode.selectedSegmentIndex==i,
            @"30/60 selection always keeps interpolation FPS at 60");
        const int effective=target_fps();
        NSString* ratio=[NSString stringWithFormat:@"Recent %.1f%% · average %.1f%%",8*effective/10.0,4*effective/10.0];
        check([controls.detailsText.text containsString:ratio],@"GPU budget follows effective target including display cap and fast-forward");
        NSString* budget=[NSString stringWithFormat:@"Target %d FPS · frame budget %.2f ms",effective,1000.0/effective];
        check([controls.detailsText.text containsString:budget],@"Budget label uses effective output target immediately after segment change");
    }
    check(ios::pacing::target_output_fps(1,60,2,true)==60&&ios::pacing::target_output_fps(1,60,1,false)==60&&
          ios::pacing::target_output_fps(0,60,1,false)==30,@"Budget follows 30/60 mode and fast-forward target");
    check([state_failure("game save in progress",false) containsString:@"The game is saving"]&&
          [state_failure("game save in progress",true) containsString:@"load again"],@"Save transaction refusals have concise Chinese reasons");
    check([controls.detailsText.text containsString:@"not GPU utilization"],@"GPU interval is clearly distinguished from hardware load");
    update_controls(savedMetrics?:@{});
    [controls.detailsBack sendActionsForControlEvents:UIControlEventTouchUpInside];
    check(controls.detailsPage.hidden&&!controls.settingsPage.hidden,@"Detail checks return to the selected settings category");
    for(int i=0;i<2;++i) {
        controls.fastScope.selectedSegmentIndex=i; [controls.fastScope sendActionsForControlEvents:UIControlEventValueChanged];
        check(mods::fast_forward_global()==bool(i),@"Both fast-forward scopes update backend independently of rate and latch");
    }
    for(int i=0;i<3;++i) { controls.rate.selectedSegmentIndex=i; [controls.rate sendActionsForControlEvents:UIControlEventValueChanged]; check(mods::fast_forward_rate()==unsigned(i+2),@"Fast-forward rate changes"); }
    controls.fastEnabled.on=NO; [controls.fastEnabled sendActionsForControlEvents:UIControlEventValueChanged];
    check(!mods::fast_forward()&&!mods::fast_forward_latched()&&mods::fast_forward_rate()==rate&&
        ss::instant_states_enabled()==instantStatesEnabled,@"Disabling the fast-forward master resets to 1x, preserves the selected rate, and leaves instant-save gate unchanged");
    controls.fastEnabled.on=YES; [controls.fastEnabled sendActionsForControlEvents:UIControlEventValueChanged];
    check(mods::fast_forward()&&ss::instant_states_enabled()==instantStatesEnabled,@"Fast-forward master can be enabled independently of instant saves");
    controls.fast.on=YES; [controls.fast sendActionsForControlEvents:UIControlEventValueChanged]; check(mods::fast_forward_latched(),@"Fast-forward switch arms");
    controls.fast.on=NO; [controls.fast sendActionsForControlEvents:UIControlEventValueChanged]; check(!mods::fast_forward_latched(),@"Fast-forward switch releases");
    const int savedScreen=gfx::g_mode.load(); const bool savedPin=gfx::g_auto_pin.load();
    for(int i=0;i<3;++i) {
        controls.gamepadScreen.selectedSegmentIndex=i;
        [controls.gamepadScreen sendActionsForControlEvents:UIControlEventValueChanged];
        const int modes[]={gfx::kDrcAuto,gfx::kDrcPip,gfx::kDrcGamePad};
        check(gfx::g_mode==modes[i],@"GamePad screen can be manually recovered in all three modes");
    }
    gfx::display_set_mode(savedScreen); gfx::g_auto_pin=savedPin;
    if(!motion::env_override()) {
        const auto savedGyro=motion::settings();
        controls.gyro.on=YES; [controls.gyro sendActionsForControlEvents:UIControlEventValueChanged];
        check(motion::wants_controller_sensors(),@"Native gyro switch enables controller sensors");
        controls.gyro.on=NO; [controls.gyro sendActionsForControlEvents:UIControlEventValueChanged];
        check(!motion::wants_controller_sensors(),@"Native gyro switch stops requesting controller sensors");
        motion::set_settings(savedGyro);
    }
    for(int i=0;i<2;++i) { controls.controllerMode.selectedSegmentIndex=i; [controls.controllerMode sendActionsForControlEvents:UIControlEventValueChanged]; check(input::pro_controller()==bool(i),@"Controller switch changes mode"); }
    controls.settingsCategory.selectedSegmentIndex=kSettingsSaves;
    [controls.settingsCategory sendActionsForControlEvents:UIControlEventValueChanged];
    controls.states.on=NO; [controls.states sendActionsForControlEvents:UIControlEventValueChanged];
    check(!ss::instant_states_enabled()&&mods::fast_forward(),@"Disabling instant saves leaves the independent fast-forward master enabled");
    controls.states.on=YES; [controls.states sendActionsForControlEvents:UIControlEventValueChanged];
    check(ss::instant_states_enabled()&&mods::fast_forward(),@"Instant-save master can be enabled independently of fast-forward");
    controls.states.on=NO; [controls.states sendActionsForControlEvents:UIControlEventValueChanged]; check(!controls.save.enabled&&!controls.load.enabled,@"State buttons disable");
    controls.states.on=YES; [controls.states sendActionsForControlEvents:UIControlEventValueChanged]; check(controls.save.enabled,@"State save button enables");
    for(int i=0;i<3;++i) {
        controls.slots.selectedSegmentIndex=i; [controls.slots sendActionsForControlEvents:UIControlEventValueChanged];
        const int backend=backend_slot(i); const auto full=ss::instant_slot_info(backend);
        check(backend==(i==2?5:i+1),@"Three visible slots map to 1/2/5 without moving old files");
        check(controls.load.enabled==(full.used&&full.compatible),@"Each selected slot loads only its compatible full snapshot");
    }
    // Fixtures use temporary PNGs only: no save request or user state files are touched.
    NSString* fixture=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:fixture withIntermediateDirectories:YES attributes:nil error:nil];
    UIGraphicsImageRenderer* fixtureRenderer=[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(16,9)];
    for(int i=0;i<3;++i) {
        controls.slots.selectedSegmentIndex=i;
        ss::SlotInfo sample; sample.used=true; sample.when="fixture-time-"+std::to_string(i);
        sample.thumbnail_linked=true;
        NSString* path=[fixture stringByAppendingPathComponent:[NSString stringWithFormat:@"slot-%d.png",i]];
        sample.thumbnail_path=path.UTF8String;
        [controls renderSlot:sample];
        check(!controls.thumbnail.image&&[controls.thumbnailStatus.text containsString:@"pending"],@"Pending image never reuses previous slot thumbnail");
        UIImage* image=[fixtureRenderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
            [[UIColor colorWithRed:i==0 green:i==1 blue:i==2 alpha:1] setFill];
            UIRectFill(CGRectMake(0,0,16,9));
        }];
        check([UIImagePNGRepresentation(image) writeToFile:path atomically:YES],@"Temporary slot thumbnail fixture saved");
        [controls renderSlot:sample];
        check(controls.thumbnail.image&&[controls.thumbnailPath isEqualToString:path]&&
            [controls.slotStatus.text containsString:text(sample.when)],@"Slot time and asynchronously appearing image stay paired");
    }
    for(int i=2;i>=0;--i) {
        controls.slots.selectedSegmentIndex=i;
        ss::SlotInfo sample; sample.used=true; sample.when="fixture-time-"+std::to_string(i); sample.thumbnail_linked=true;
        NSString* path=[fixture stringByAppendingPathComponent:[NSString stringWithFormat:@"slot-%d.png",i]];
        sample.thumbnail_path=path.UTF8String; [controls renderSlot:sample];
        check(controls.thumbnail.image&&[controls.thumbnailPath isEqualToString:path]&&[controls.slotStatus.text containsString:text(sample.when)],
            @"Switching back restores each slot's own time and image");
    }
    ss::SlotInfo legacy; legacy.used=true; legacy.compatible=false; [controls renderSlot:legacy];
    check(!controls.load.enabled&&!controls.thumbnail.image&&[controls.thumbnailStatus.text containsString:@"Old format"],@"Legacy incompatible slot has no guessed thumbnail");
    ss::SlotInfo empty; [controls renderSlot:empty];
    check(!controls.load.enabled&&!controls.thumbnail.image&&[controls.slotStatus.text containsString:@"Empty slot"],@"Empty slot clears previous time and image");
    [NSFileManager.defaultManager removeItemAtPath:fixture error:nil];
    controls.slots.selectedSegmentIndex=selectedSlot; [controls refresh];
    controls.loading=YES; [controls refresh];
    check(!controls.save.enabled&&!controls.load.enabled,@"Both state buttons disable while a load is pending");
    controls.loading=NO; controls.saving=YES; [controls refresh];
    check(!controls.save.enabled&&!controls.load.enabled,@"Both state buttons disable while snapshot write is pending");
    controls.saving=NO; [controls refresh];
    if(panel_open.load())[controls.backdrop sendActionsForControlEvents:UIControlEventTouchUpInside];
    [controls.entry sendActionsForControlEvents:UIControlEventTouchUpInside];
    [controls.backdrop sendActionsForControlEvents:UIControlEventTouchUpInside];
    check(!mods::fast_forward_latched(),@"Panel actions preserve disarmed fast-forward");
    controls.fast.on=YES; [controls.fast sendActionsForControlEvents:UIControlEventValueChanged];
    input::release_keys();
    check(!mods::fast_forward_latched(),@"Global input release still resets armed fast-forward");
    controls.fast.on=YES; [controls.fast sendActionsForControlEvents:UIControlEventValueChanged];
    [controls.entry sendActionsForControlEvents:UIControlEventTouchUpInside];
    check(controls_block_input()&&mods::fast_forward_latched(),@"Opening panel captures input and preserves armed fast-forward");
    controls.loading=YES; [controls finishLoadSlot:backend_slot(selectedSlot) ok:NO why:@"synthetic chain mismatch"];
    check(!controls.loading&&controls_block_input()&&[controls.status.text containsString:@"synthetic chain mismatch"],@"Failed restoration clears the load state and leaves the panel open with failure reason");
    controls.performance.on=NO; [controls.performance sendActionsForControlEvents:UIControlEventValueChanged];
    controls.settingsCategory.selectedSegmentIndex=kSettingsScreen;
    [controls.settingsCategory sendActionsForControlEvents:UIControlEventValueChanged];
    [controls.detailsButton sendActionsForControlEvents:UIControlEventTouchUpInside];
    check(!controls.detailsPage.hidden&&controls.settingsPage.hidden&&controls_block_input(),@"Details action opens native scroll page and captures input");
    check(controls.hud.hidden&&gfx::g_gpu_metrics.load()&&perf::enabled(),@"Details sample CPU and GPU with compact HUD turned off");
    [controls.detailsBack sendActionsForControlEvents:UIControlEventTouchUpInside];
    check(controls.detailsPage.hidden&&!controls.settingsPage.hidden&&!gfx::g_gpu_metrics.load(),@"Return action restores settings and releases detail-only GPU demand");
    check(mods::fast_forward_latched()&&!controls.entryTimer.valid,@"Detail navigation preserves armed state and keeps panel open");
    controls.performance.on=YES; [controls.performance sendActionsForControlEvents:UIControlEventValueChanged];
    [controls.backdrop sendActionsForControlEvents:UIControlEventTouchUpInside];
    check(!controls_block_input()&&mods::fast_forward_latched(),@"Closing panel releases input and preserves armed fast-forward");
    check(controls.entryTimer.valid&&!controls.entry.hidden,@"Closing panel starts five-second entry timer");

    // Let the actual run-loop timers expire; never fire the timer early in the self-test.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(5.25*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        check(controls.entry.hidden&&!controls.hud.hidden,@"After five seconds entry hides while performance HUD stays visible");
        check(![controls gestureRecognizer:controls.touchObserver shouldReceiveTouch:nil],@"Touch observer does not claim game touches");
        check(!controls.entry.hidden&&controls.entryTimer.valid,@"Touch-down reveals entry and starts a new timer");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(2.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            [controls gestureRecognizer:controls.touchObserver shouldReceiveTouch:nil];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(2.8*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                check(!controls.entry.hidden,@"Another touch restarts the five-second timer");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(2.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                    check(controls.entry.hidden&&!controls.hud.hidden,@"Entry hides again after touch while HUD remains visible");
                    [controls gestureRecognizer:controls.touchObserver shouldReceiveTouch:nil];
                    [controls.entry sendActionsForControlEvents:UIControlEventTouchUpInside];
                    [controls.detailsButton sendActionsForControlEvents:UIControlEventTouchUpInside];
                    check(!controls.entryTimer.valid,@"Open details cancel entry hide timer");
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(5.25*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                        check(controls_block_input()&&!controls.backdrop.hidden&&!controls.entry.hidden&&!controls.hud.hidden,
                            @"Open panel and HUD remain visible beyond five seconds");
                        check(!controls.detailsPage.hidden&&controls.settingsPage.hidden,@"Details remain open beyond five seconds");
                        check(mods::fast_forward_latched(),@"Fast-forward stays armed throughout panel UI actions");
                        [controls.controller.view layoutIfNeeded];
                        UIScrollView* detailScroll=(UIScrollView*)controls.detailsText.superview;
                        check(detailScroll.scrollEnabled&&detailScroll.contentSize.height>=controls.detailsText.bounds.size.height-1,
                            @"Details scroll view contains the complete text without shrinking its font");
                        auto capture=[check](UIView* view,NSString* path) {
                            UIGraphicsImageRenderer* renderer=[[UIGraphicsImageRenderer alloc] initWithSize:view.bounds.size];
                            UIImage* image=[renderer imageWithActions:^(UIGraphicsImageRendererContext* context) { [view.layer renderInContext:context.CGContext]; }];
                            check([UIImagePNGRepresentation(image) writeToFile:path atomically:YES],@"Native UI screenshot saved");
                        };
                        capture(controls.panel,@"captures/controls-details.png");
                        capture(controls.detailsText,@"captures/controls-details-content.png");
                        [detailScroll setContentOffset:CGPointMake(0,std::max(CGFloat(0),detailScroll.contentSize.height-detailScroll.bounds.size.height)) animated:NO];
                        capture(controls.panel,@"captures/controls-details-bottom.png");
                        [detailScroll setContentOffset:CGPointZero animated:NO];
                        [controls.detailsBack sendActionsForControlEvents:UIControlEventTouchUpInside];
                        check(controls.detailsPage.hidden&&!controls.settingsPage.hidden,@"Details return button remains usable after timer wait");
                        [controls.controller.view layoutIfNeeded];
                        capture(controls.panel,@"captures/controls-panel.png");
                        capture(controls.hud,@"captures/controls-hud.png");
                        NSMutableDictionary* result=[controls_state() mutableCopy];
                        result[@"passed"]=@YES; result[@"checks"]=checks;
                        result[@"touchInjection"]=@"UIKit delegate path; physical touch still needs device verification";
                        NSData* data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
                        check([data writeToFile:@"captures/controls-test.json" atomically:YES],@"Self-test JSON saved");
                        [controls.backdrop sendActionsForControlEvents:UIControlEventTouchUpInside];
                        controls.performance.on=performance; [controls.performance sendActionsForControlEvents:UIControlEventValueChanged];
                        controls.states.on=states; [controls.states sendActionsForControlEvents:UIControlEventValueChanged];
                        ss::set_instant_states_enabled(instantStatesEnabled);
                        controls.fastEnabled.on=fastEnabled; [controls.fastEnabled sendActionsForControlEvents:UIControlEventValueChanged];
                        controls.rate.selectedSegmentIndex=rate-2; [controls.rate sendActionsForControlEvents:UIControlEventValueChanged];
                        controls.controllerMode.selectedSegmentIndex=pro?1:0; [controls.controllerMode sendActionsForControlEvents:UIControlEventValueChanged];
                        interp::set_fps(savedFPS); interp::set_mode(mode); [controls refresh];
                        controls.fastScope.selectedSegmentIndex=global?1:0; [controls.fastScope sendActionsForControlEvents:UIControlEventValueChanged];
                        controls.slots.selectedSegmentIndex=selectedSlot; [controls refresh];
                        controls.fast.on=armed; [controls.fast sendActionsForControlEvents:UIControlEventValueChanged];
                        controls.settingsCategory.selectedSegmentIndex=selectedCategory;
                        [controls.settingsCategory sendActionsForControlEvents:UIControlEventValueChanged];
                        if(wasOpen)[controls.entry sendActionsForControlEvents:UIControlEventTouchUpInside];
                        if(wasDetails)[controls.detailsButton sendActionsForControlEvents:UIControlEventTouchUpInside];
                        controls.controller.view.userInteractionEnabled=interaction;
                        testing_controls=false;
                        if(getenv("WWHD_IOS_TEST_QUICK_SAVE"))
                            [NSTimer scheduledTimerWithTimeInterval:10 repeats:NO block:^(NSTimer*) {
                                controls.states.on=YES; [controls.states sendActionsForControlEvents:UIControlEventValueChanged];
                                int unused=-1;
                                for(int i=0;i<3;++i)if(!ss::slot_info(backend_slot(i)).used&&!ss::instant_slot_info(backend_slot(i)).used) { unused=i; break; }
                                if(unused<0) { controls.status.text=@"Auto save/load test skipped: all three slots are in use and won't be overwritten."; return; }
                                controls.slots.selectedSegmentIndex=unused; [controls refresh];
                                [controls.save sendActionsForControlEvents:UIControlEventTouchUpInside];
                            }];
                    });
                });
            });
        });
    });
}
}
