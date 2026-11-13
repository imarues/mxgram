// MX group-only selection mode.
// This tweak NEVER sends deletion RPCs. It only asks a compatible native
// VoidGram bridge to open Telegram's official multiple-message selection.
#import "MxPurge.h"
#import "Headers.h"
#import "UI/Headers.h"
#import <objc/runtime.h>
#import <objc/message.h>

static const void *kMxGroupTrashContextKey = &kMxGroupTrashContextKey;

static NSString *mxGroupText(NSString *ar, NSString *en) {
    NSString *cancel = [MxLocalization localizedStringForKey:@"CANCEL"];
    BOOL arabic = [cancel isEqualToString:@"إلغاء"] ||
        (((cancel.length == 0) || [cancel isEqualToString:@"CANCEL"]) &&
         [[[NSLocale preferredLanguages].firstObject lowercaseString] hasPrefix:@"ar"]);
    return arabic ? ar : en;
}

// Objective-C interface is implemented in the native TelegramUI patch,
// not in the injected dylib. Never call an absent selector.
static BOOL mxGroupBool(id instance, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!instance || ![instance respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(instance, selector);
}
static int32_t mxGroupNumber(id instance, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!instance || ![instance respondsToSelector:selector]) return 0;
    return ((int32_t (*)(id, SEL))objc_msgSend)(instance, selector);
}
static void mxGroupInvoke(id instance, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (instance && [instance respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(instance, selector);
    }
}

@interface MxGroupTrashContext : NSObject
@property (nonatomic, weak) UIViewController *controller;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL requested;
@end
@implementation MxGroupTrashContext @end

@interface MxGroupTrashManager : NSObject
@property (nonatomic, weak) UIViewController *visibleChat;
+ (instancetype)shared;
- (void)appeared:(UIViewController *)controller;
- (void)layout:(UIViewController *)controller;
- (void)disappeared:(UIViewController *)controller;
- (void)settingsChanged;
- (void)tapped:(UIButton *)button;
@end

@implementation MxGroupTrashManager
+ (instancetype)shared {
    static MxGroupTrashManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [MxGroupTrashManager new]; });
    return manager;
}
- (BOOL)enabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kDeleteMyMessages];
}
- (BOOL)eligible:(UIViewController *)controller {
    return [self enabled] &&
        mxGroupBool(controller, @"mxCanSelectMyGroupMessages");
}
- (void)alert:(NSString *)message title:(NSString *)title
     context:(MxGroupTrashContext *)ctx {
    UIViewController *vc = ctx.controller;
    if (!vc || !vc.view.window || vc.presentedViewController) return;
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:mxGroupText(@"حسناً", @"OK")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}
- (void)status:(MxGroupTrashContext *)ctx {
    if (!ctx.button || ctx.cancelled) return;
    int32_t status = mxGroupNumber(ctx.controller, @"mxMyGroupSelectionStatus");
    UIColor *color = [UIColor systemGrayColor];
    if (status == 2) color = [UIColor systemGreenColor];
    else if (status == 3) color = [UIColor systemRedColor];
    // 0 idle, 1 in progress, 4 unverifiable remain gray.
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration
        configurationWithPointSize:21 weight:UIImageSymbolWeightSemibold];
    UIImage *image = [[UIImage systemImageNamed:@"trash.fill"]
        imageByApplyingSymbolConfiguration:configuration];
    [ctx.button setImage:image forState:UIControlStateNormal];
    ctx.button.tintColor = color;
    ctx.button.layer.borderColor = [color colorWithAlphaComponent:0.85].CGColor;
    ctx.button.enabled = YES; // even gray/green can explain the state
    ctx.button.alpha = 1.0;
}
- (void)position:(MxGroupTrashContext *)ctx {
    UIView *host = ctx.controller.view;
    UIWindow *window = host.window;
    if (!host || !window || !ctx.button || ctx.cancelled) return;
    CGFloat width = CGRectGetWidth(host.bounds);
    CGFloat height = CGRectGetHeight(host.bounds);
    if (width < 100.0 || height < 200.0) return;
    CGFloat top = host.safeAreaInsets.top;
    CGFloat y = MIN(MAX(top + 132.0, 124.0),
                    height - host.safeAreaInsets.bottom - 72.0);
    CGFloat x = width - host.safeAreaInsets.right - 54.0;
    ctx.button.frame = [host convertRect:CGRectMake(MAX(8.0, x), y, 44.0, 44.0)
                                 toView:window];
    if (ctx.button.superview != window) {
        [ctx.button removeFromSuperview];
        [window addSubview:ctx.button];
    }
    [window bringSubviewToFront:ctx.button];
}
- (void)refresh:(UIViewController *)controller {
    if (self.visibleChat != controller) return;
    MxGroupTrashContext *ctx = objc_getAssociatedObject(controller, kMxGroupTrashContextKey);
    if (!ctx || ctx.cancelled) return;
    if (![self eligible:controller]) {
        [ctx.button removeFromSuperview];
        return;
    }
    if (!ctx.button) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(0, 0, 44, 44);
        button.tag = 91017;
        button.accessibilityLabel = mxGroupText(@"تحديد رسائلي بهذا الكروب",
                                                 @"Select my messages in this group");
        button.layer.cornerRadius = 22.0;
        button.layer.borderWidth = 1.0;
        button.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.98];
        button.userInteractionEnabled = YES;
        button.exclusiveTouch = YES;
        // Telegram's chat pan recognizer may swallow TouchUpInside.
        [button addTarget:self action:@selector(tapped:)
         forControlEvents:UIControlEventTouchDown];
        ctx.button = button;
    }
    if (!ctx.requested) {
        ctx.requested = YES;
        mxGroupInvoke(controller, @"mxPrepareMyGroupSelection");
    }
    [self status:ctx];
    [self position:ctx];
}
- (void)appeared:(UIViewController *)controller {
    if (!controller) return;
    self.visibleChat = controller;
    MxGroupTrashContext *old = objc_getAssociatedObject(controller, kMxGroupTrashContextKey);
    old.cancelled = YES;
    [old.button removeFromSuperview];
    mxGroupInvoke(controller, @"mxCancelMyGroupSelection");

    MxGroupTrashContext *ctx = [MxGroupTrashContext new];
    ctx.controller = controller;
    objc_setAssociatedObject(controller, kMxGroupTrashContextKey,
                             ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self refresh:controller];
}
- (void)layout:(UIViewController *)controller {
    [self refresh:controller];
}
- (void)disappeared:(UIViewController *)controller {
    MxGroupTrashContext *ctx = objc_getAssociatedObject(controller, kMxGroupTrashContextKey);
    ctx.cancelled = YES;
    [ctx.button removeFromSuperview];
    mxGroupInvoke(controller, @"mxCancelMyGroupSelection");
    if (self.visibleChat == controller) self.visibleChat = nil;
}
- (void)settingsChanged {
    UIViewController *vc = self.visibleChat;
    if (!vc) return;
    MxGroupTrashContext *ctx = objc_getAssociatedObject(vc, kMxGroupTrashContextKey);
    if (![self enabled]) {
        ctx.cancelled = YES;
        [ctx.button removeFromSuperview];
        mxGroupInvoke(vc, @"mxCancelMyGroupSelection");
    } else {
        [self appeared:vc];
    }
}
- (void)tapped:(UIButton *)button {
    UIViewController *vc = self.visibleChat;
    MxGroupTrashContext *ctx = vc ? objc_getAssociatedObject(vc, kMxGroupTrashContextKey) : nil;
    if (!ctx || ctx.cancelled || ctx.button != button ||
        ![self eligible:vc]) return;

    int32_t status = mxGroupNumber(vc, @"mxMyGroupSelectionStatus");
    switch (status) {
    case 3: {
        if (mxGroupBool(vc, @"mxBeginMyGroupSelection")) {
            // The native Telegram selection toolbar takes control from here.
            [button removeFromSuperview];
        } else {
            mxGroupInvoke(vc, @"mxPrepareMyGroupSelection");
            [self alert:mxGroupText(@"تعذّر فتح وضع التحديد. أعد فحص هذا الكروب.",
                                    @"Could not open native selection. Scan this group again.")
                 title:mxGroupText(@"التحديد غير متاح", @"Selection unavailable")
               context:ctx];
        }
        break;
    }
    case 2:
        [self alert:mxGroupText(@"ماكو رسائل مرسلة من حسابك بهذا الكروب حسب نتائج بحث تيليجرام.",
                                @"Telegram found no messages from your account in this group.")
             title:mxGroupText(@"لا توجد رسائل", @"No messages found")
           context:ctx];
        break;
    case 1:
        [self alert:mxGroupText(@"جار البحث عن رسائلك بهذا الكروب. ماكو حذف تلقائي.",
                                @"Finding your messages in this group. Nothing is deleted automatically.")
             title:mxGroupText(@"جاري الفحص", @"Scanning")
           context:ctx];
        break;
    default:
        mxGroupInvoke(vc, @"mxPrepareMyGroupSelection");
        [self alert:mxGroupText(@"تعذّر التحقق حالياً أو انتهت صلاحية الفحص. بدأت إعادة البحث، وحذف الرسائل يبقى يدوياً من تيليجرام.",
                                @"Verification failed or expired. Rescanning; deletion remains manual in Telegram.")
             title:mxGroupText(@"إعادة الفحص", @"Rescan")
           context:ctx];
        break;
    }
}
@end

// Retained for the existing Logos hooks. No capture or deletion is performed.
void MxPurgeCaptureRequest(__unused MTRequest *request,
                           __unused MTRequestMessageService *service) {}
void MxPurgeChatAppeared(UIViewController *controller) {
    [[MxGroupTrashManager shared] appeared:controller];
}
void MxPurgeChatDisappeared(UIViewController *controller) {
    [[MxGroupTrashManager shared] disappeared:controller];
}
void MxPurgeChatLayout(UIViewController *controller) {
    [[MxGroupTrashManager shared] layout:controller];
}
void MxPurgeSettingsChanged(void) {
    [[MxGroupTrashManager shared] settingsChanged];
}
