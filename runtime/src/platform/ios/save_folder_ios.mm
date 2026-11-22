// Cross-save on iPhone/iPad: the main project's save folder (mods/save_folder.h) with an iOS folder.
//
// The player picks a folder in Files (Settings > Save > Cross-save), for example one in iCloud Drive that
// the Mac version uses as its save folder too (Settings > Saves > Save folder). save_folder.h does the
// rest at the next start: copying the save there, the "which save to keep" question when both sides
// have one, cloud conflict copies, the lock of the device playing, and safe writes.
//
// iOS needs three things more:
//   - a folder outside the app may only be used while its security scope is open: the picker's URL is
//     kept as a bookmark (NSUserDefaults "ios.saveFolderBookmark") and opened again at every start,
//     before the game reads its save, and kept open while the app runs;
//   - iCloud Drive keeps files it hasn't downloaded as ".name.icloud" placeholders: they are downloaded
//     (a few seconds at most) before save_folder.h reads the save, so it never takes a missing file for
//     no save;
//   - save_folder.h's questions (gfx::ask_player_alert) as UIKit alerts.
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "gfx/player_question.h"
#include "mods/save_folder.h"
#include "overlay/hostui.h"
#include "runtime.h"

#include <functional>
#include <string>
#include <vector>

static NSString* const kBookmarkKey = @"ios.saveFolderBookmark";
static NSURL* g_open_folder;  // the folder whose security scope is open (kept for the app's lifetime)

static UIViewController* top_controller() {
    UIWindow* window = nil;
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class])
            for (UIWindow* w in ((UIWindowScene*)scene).windows)
                if (w.isKeyWindow || !window) window = w;
    UIViewController* vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static NSString* ns_string(const std::string& s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }

// Open the folder's security scope (once) and keep it open.
static bool open_scope(NSURL* url) {
    if (g_open_folder && [g_open_folder isEqual:url]) return true;
    if (![url startAccessingSecurityScopedResource]) LOG("[save-folder] iOS: no security scope for %s (it may not need one)", url.path.UTF8String);
    if (g_open_folder) [g_open_folder stopAccessingSecurityScopedResource];
    g_open_folder = url;
    return true;
}

// Spin the main run loop until `done` or the timeout (the game starts on the main thread, before
// UIKit's loop takes over: alerts and iCloud downloads need the loop to run).
static void run_until(const std::function<bool()>& done, double seconds) {
    const NSDate* end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && [end timeIntervalSinceNow] > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}

// iCloud Drive placeholders (".cking.sav.icloud") in the folder and its subfolders: start their download.
static int request_downloads(NSURL* folder) {
    int pending = 0;
    NSFileManager* fm = NSFileManager.defaultManager;
    NSDirectoryEnumerator* e = [fm enumeratorAtURL:folder includingPropertiesForKeys:nil options:0 errorHandler:nil];
    for (NSURL* url in e) {
        NSString* name = url.lastPathComponent;
        if (![name hasPrefix:@"."] || ![name hasSuffix:@".icloud"] || name.length <= 8) continue;
        NSString* real = [name substringWithRange:NSMakeRange(1, name.length - 8)];
        NSURL* target = [url.URLByDeletingLastPathComponent URLByAppendingPathComponent:real];
        [fm startDownloadingUbiquitousItemAtURL:target error:nil];
        ++pending;
    }
    return pending;
}

void ios_prepare_save_folder(const std::string& config_dir) {
    NSData* bookmark = [NSUserDefaults.standardUserDefaults dataForKey:kBookmarkKey];
    if (!bookmark) return;
    BOOL stale = NO;
    NSError* error = nil;
    NSURL* url = [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:&error];
    if (!url) {
        // save_folder.h then finds the chosen folder gone and says so; nothing is made anew
        LOG("[save-folder] iOS: the chosen save folder can't be opened (%s)", error.localizedDescription.UTF8String ?: "");
        return;
    }
    open_scope(url);
    if (stale) {
        NSData* fresh = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
        if (fresh) [NSUserDefaults.standardUserDefaults setObject:fresh forKey:kBookmarkKey];
    }
    // let iCloud bring down what it only has online, so the save is read, not taken for missing
    if (request_downloads(url) > 0) {
        LOG("[save-folder] iOS: waiting for iCloud to download the save folder");
        run_until([&] { return request_downloads(url) == 0; }, 20);
        if (request_downloads(url) > 0) LOG("[save-folder] iOS: some files are still downloading");
    }
}

// ---------------------------------------------------------------- the picker
@interface WWSaveFolderPicker : NSObject <UIDocumentPickerDelegate>
@property(nonatomic, copy) void (^chosen)(NSURL* _Nullable url);
@end
@implementation WWSaveFolderPicker
- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    if (self.chosen) self.chosen(urls.firstObject);
    self.chosen = nil;
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller {
    if (self.chosen) self.chosen(nil);
    self.chosen = nil;
}
@end
static WWSaveFolderPicker* g_picker;

namespace hostui {
// Settings > Save > Cross-save (platform/ios/controls.mm) and the main project's own Saves tab
void choose_save_folder(std::function<void(std::string)> chosen) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIDocumentPickerViewController* picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder]];
        picker.allowsMultipleSelection = NO;
        if (!g_picker) g_picker = [WWSaveFolderPicker new];
        auto done = chosen;
        g_picker.chosen = ^(NSURL* url) {
            if (!url) return;  // cancelled: nothing changes
            open_scope(url);
            NSError* error = nil;
            NSData* bookmark = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
            if (!bookmark) {
                LOG("[save-folder] iOS: can't keep access to %s (%s)", url.path.UTF8String, error.localizedDescription.UTF8String ?: "");
                return;
            }
            [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:kBookmarkKey];
            done(url.path.UTF8String);
        };
        picker.delegate = g_picker;
        [top_controller() presentViewController:picker animated:YES completion:nil];
    });
}
}  // namespace hostui

namespace ios {
// Back to the app's own save folder: forget the bookmark (save_folder::choose("") is the caller's)
void forget_save_folder() { [NSUserDefaults.standardUserDefaults removeObjectForKey:kBookmarkKey]; }
}  // namespace ios

// ---------------------------------------------------------------- save_folder.h's questions
namespace gfx {
// From the main thread (the game starts there, before UIKit's loop runs) the main run loop is spun
// until the tap, like the Mac's modal alert; from another thread it waits for the main thread's answer.
int ask_player_alert(const std::string& title, const std::string& text, const std::vector<std::string>& buttons) {
    if (buttons.empty()) return -1;
    __block int answer = -2;
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    void (^show)(void) = ^{
        UIViewController* vc = top_controller();
        if (!vc) { answer = -1; dispatch_semaphore_signal(answered); return; }
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:ns_string(title) message:ns_string(text)
                                                                preferredStyle:UIAlertControllerStyleAlert];
        for (size_t i = 0; i < buttons.size(); i++) {
            const int index = int(i);
            [alert addAction:[UIAlertAction actionWithTitle:ns_string(buttons[i]) style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction*) { answer = index; dispatch_semaphore_signal(answered); }]];
        }
        [vc presentViewController:alert animated:YES completion:nil];
    };
    if (NSThread.isMainThread) {
        show();
        run_until([&] { return answer != -2; }, 24 * 3600);
    } else {
        dispatch_async(dispatch_get_main_queue(), show);
        dispatch_semaphore_wait(answered, DISPATCH_TIME_FOREVER);
    }
    return answer < 0 ? -1 : answer;
}
}  // namespace gfx
