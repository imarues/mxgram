#import <UIKit/UIKit.h>
#import "Headers.h"
#import "../Logger/Logger.h"
#import <objc/runtime.h>
#import <objc/message.h>

@interface ASDisplayNode : NSObject
@property (atomic, assign, readonly) UIView *view;
@property (atomic, copy, readonly) NSArray *subnodes;
@property (atomic, copy, readwrite) NSString *accessibilityLabel;
- (ASDisplayNode *)supernode;
- (void)setNeedsLayout;
- (void)layoutIfNeeded;
@end

@interface ASControlNode : ASDisplayNode
- (void)sendActionsForControlEvents:(NSUInteger)controlEvents withEvent:(UIEvent *)event;
@end

@interface _TtC18MultiScaleTextNode18MultiScaleTextNode : ASDisplayNode
@end

@interface _TtCC20StoryContainerScreen30StoryItemSetContainerComponent4View : UIView
- (void)requestSave;
@end

@interface _TtC14PeerInfoScreen18PeerInfoHeaderNode : ASDisplayNode
@property (nonatomic, strong) id peer;
@end

@interface LegacyComponentsGlobals : NSObject
+ (id)provider;
@end

@protocol LegacyComponentsGlobalsProvider
- (TGLocalization *)effectiveLocalization;
@end

// Mx's own translations, not the host's. Deliberately not called TGLoc the way
// Mx.m calls it: this file talks to both localisations and they answer
// different questions — MxLoc for the tweak's own wording, and
// getActiveTGLocalization() below for what the host app named a row on screen.
#define MxLoc(key) [MxLocalization localizedStringForKey:(key)]

static TGLocalization *TGLocalizationShared = nil;

static TGLocalization *getActiveTGLocalization(void) {
    if (TGLocalizationShared) return TGLocalizationShared;
    @try {
        Class cls = objc_getClass("LegacyComponentsGlobals");
        if (cls && [cls respondsToSelector:@selector(provider)]) {
            id provider = [cls performSelector:@selector(provider)];
            if ([provider respondsToSelector:@selector(effectiveLocalization)]) {
                TGLocalization *loc = [provider performSelector:@selector(effectiveLocalization)];
                if (loc) { TGLocalizationShared = loc; return loc; }
            }
        }
    } @catch (...) {}
    return nil;
}

// Does this label say what the host's own localisation says for `key`?
//
// Asking the host beats listing phrases: a fork ships whatever languages it
// ships, and a phrase list only covers the ones somebody thought to write down.
//
// `twoWay` additionally accepts a label the localised string *contains*, which
// is how a fork that shortens a row ("Support" under "Support & FAQ") still
// gets recognised. It is only safe where a false match costs nothing. The
// one-way form guards itself with a length floor instead: a language that
// renders the key as one short word would otherwise swallow every row that
// happens to contain that word.
static BOOL mxLabelMatchesLocalizedKey(NSString *lower, NSString *key, BOOL twoWay) {
    TGLocalization *loc = getActiveTGLocalization();
    if (!loc) return NO;
    NSString *str = [loc get:key];
    // TGLocalization hands the key straight back when it has no entry for it.
    if (str.length == 0 || [str isEqualToString:key]) return NO;
    NSString *needle = [str lowercaseString];
    if ([lower isEqualToString:needle]) return YES;
    if (twoWay) {
        return [lower containsString:needle] || [needle containsString:lower];
    }
    return needle.length >= 6 && [lower containsString:needle];
}

// Is this accessibility label the "Ask a Question" row in Settings?
//
// That row is the one and only way into the tweak's own menu, so a label this
// function fails to recognise means a host app whose settings cannot be opened
// at all. Turrit renames the row to "About Turrit"; the brand name stays in
// Latin script in every localisation it ships, Chinese included (关于Turrit), so
// a bare "turrit" substring covers all of them at once. Matching the full
// English and Russian phrases — which is what this used to do — left the Chinese
// build with no way in.
static BOOL mxLabelIsSupportRow(NSString *label) {
    if (!label.length) return NO;
    NSString *lower = [[label lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // Different Telegram languages use different words, but the only entry
    // point is the Ask a Question item. Never bind the gift row, profile,
    // generic Support, or any other Settings item.
    static NSArray<NSString *> *phrases;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        phrases = @[
            @"ask a question", @"задать вопрос", @"hacer una pregunta",
            @"poser une question", @"stellen sie eine frage", @"fai una domanda",
            @"bir soru sor", @"질문하기", @"提问", @"提問",
            @"質問する", @"đặt câu hỏi", @"اسأل سؤالاً", @"اسأل سؤالا",
            @"اسال سؤالا", @"اطرح سؤالاً", @"اطرح سؤالا"
        ];
    });
    for (NSString *phrase in phrases) {
        if ([lower isEqualToString:phrase]) return YES;
    }
    // Host Telegram's live localization covers languages not listed above.
    return mxLabelMatchesLocalizedKey(lower, @"Settings.Support", NO);
}

// Which app is this dylib running inside? Only the first-run instructions need
// to know: iMe's Support row opens a context menu of its own, so telling an iMe
// user to long-press it sends them to a dead end, and Turrit renames the row
// outright.
static __attribute__((unused)) BOOL mxHostBundleIs(NSString *bundleId) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:bundleId];
}

// The row name as the user will actually read it on screen, falling back to
// English when the host has no entry. Naming a row in a language the user does
// not have in front of them is worse than not naming it.
static __attribute__((unused)) NSString *mxLocalizedRowName(NSString *key, NSString *fallback) {
    TGLocalization *loc = getActiveTGLocalization();
    NSString *str = loc ? [loc get:key] : nil;
    if (str.length == 0 || [str isEqualToString:key]) return fallback;
    return str;
}

void showUI();

// Defined further down, next to the rest of the edit-history code. Declared
// here so the notification observer above it can refresh a badge directly
// instead of asking for a layout pass that AsyncDisplayKit may never schedule.
static void updateMxEditBadge(ASDisplayNode *node, NSNumber *msgId, NSNumber *peerKey);

%hook _TtC10TelegramUI30ChatPresentationInterfaceState
- (BOOL)copyProtectionEnabled {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kDisableForwardRestriction]) {
        return NO;
    }
    return %orig;
}
%end

%hook _TtC30ChatPresentationInterfaceState30ChatPresentationInterfaceState
- (BOOL)copyProtectionEnabled {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kDisableForwardRestriction]) {
        return NO;
    }
    return %orig;
}
%end

// Postbox.Message used to be hooked here, overriding -isCopyProtected and
// -adAttribute. Checked against release-12.9.2: neither can ever have run.
//
// `Message` is `public final class Message` with no NSObject anywhere in
// Postbox/Sources/Message.swift, so there is no Objective-C class to hook, and
// both properties are computed in TelegramCore extensions
// (Utils/MessageUtils.swift, TelegramEngine/Messages/Message.swift) without
// @objc — Swift dispatches them directly, never through objc_msgSend.
//
// Both features are already served where they actually work: copy protection is
// cleared off the wire in TLParser.stripNoForwards, and sponsored messages are
// blocked at the request layer in FunctionHandler.m.

// Send as Voice used to live here, as a %hook on
// _TtC12TelegramCore16TelegramMediaFile overriding -isVoice. It never ran, for
// two independent reasons:
//
//   * the mangled name is wrong — "TelegramMediaFile" is 17 characters, not 16,
//     so the class was never found and %hook quietly did nothing;
//   * even spelled correctly it would not have fired. TelegramMediaFile is a
//     plain Swift class and isVoice is a computed property, so the call never
//     goes through objc_msgSend and there is no method to swap out.
//
// The voice flag is set on the outgoing request instead — see
// TLParser.rewriteVoiceUpload. That reaches the recipient as well, which the
// local override never could.

// ChatMessageItem and ApiChat carried the same -noForwards override, and they
// are gone for the same kind of reason. In release-12.9.2 ChatMessageItem is a
// *protocol* (Components/Chat/ChatMessageItem/Sources/ChatMessageItem.swift)
// with no noForwards member at all, and the string "ApiChat" does not occur
// anywhere in the tree. objc_getClass returned nil for both, so %init simply
// skipped them.

// One recognizer per localized Ask-a-Question row. Ordinary taps are never
// intercepted: they retain Telegram's normal Support action.
static BOOL _kiraLongPressAttached = NO;
static const void *kKiraLongPressKey = &kKiraLongPressKey;

@interface KiraSupportGestureTarget : NSObject
@end
@implementation KiraSupportGestureTarget
- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) showUI();
}
@end
static KiraSupportGestureTarget *_kiraGestureTarget = nil;

static void kiraAttachSupportLongPress(UIView *row, NSString *label) {
    if (!row || !mxLabelIsSupportRow(label) ||
        objc_getAssociatedObject(row, kKiraLongPressKey)) return;
    if (!_kiraGestureTarget) _kiraGestureTarget = [KiraSupportGestureTarget new];
    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:_kiraGestureTarget action:@selector(handleLongPress:)];
    gesture.minimumPressDuration = 0.6;
    gesture.cancelsTouchesInView = YES;
    gesture.delaysTouchesBegan = NO;
    gesture.delaysTouchesEnded = NO;
    // If Telegram offers its own long-press context menu for this row,
    // let the Kira recognizer win. No tap recognizers are added or altered.
    UIView *scan = row;
    for (int depth = 0; scan && depth < 5; depth++, scan = scan.superview) {
        for (UIGestureRecognizer *existing in scan.gestureRecognizers) {
            if ([existing isKindOfClass:[UILongPressGestureRecognizer class]]) {
                [existing requireGestureRecognizerToFail:gesture];
            }
        }
    }
    [row addGestureRecognizer:gesture];
    objc_setAssociatedObject(row, kKiraLongPressKey, gesture,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    _kiraLongPressAttached = YES;
    mxDiag("Kira Ask a Question long press attached: %{public}s", label.UTF8String);
}

static void tryAttachMxGestureInView(UIView *view) {
    if (!view) return;
    if ([NSStringFromClass([view class]) containsString:@"AccessibilityAreaNode"]) {
        NSString *label = view.accessibilityLabel;
        if (mxLabelIsSupportRow(label)) {
            kiraAttachSupportLongPress(view.superview ?: view, label);
        }
    }
    for (UIView *sub in view.subviews) {
        tryAttachMxGestureInView(sub);
    }
}
static void tryAttachMxGesture(void) {
    UIWindow *window = UIApplication.sharedApplication.keyWindow;
    if (window) tryAttachMxGestureInView(window);
}

%hook TGLocalization
- (id)get:(id)key {
    TGLocalizationShared = self;
    if (!_kiraLongPressAttached) {
        dispatch_async(dispatch_get_main_queue(), ^{ tryAttachMxGesture(); });
    }
    return %orig;
}
- (id)initWithVersion:(int)a code:(id)b dict:(id)c isActive:(BOOL)d {
    TGLocalization *instance = %orig;
    if (instance) {
        TGLocalizationShared = instance;
        dispatch_async(dispatch_get_main_queue(), ^{ tryAttachMxGesture(); });
    }
    return instance;
}
%end

void showUI() {
    // Settings can be behind an already-presented controller. Presenting on
    // window.rootViewController then silently fails with a UIKit warning.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ showUI(); });
        return;
    }
    UIWindow *window = UIApplication.sharedApplication.keyWindow;
    if (!window) {
        for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
            if (!candidate.hidden && candidate.windowLevel == UIWindowLevelNormal) {
                window = candidate;
                break;
            }
        }
    }
    UIViewController *presenter = window.rootViewController;
    while (presenter.presentedViewController) {
        presenter = presenter.presentedViewController;
    }
    if (!presenter || presenter.isBeingDismissed) return;
    if ([presenter isKindOfClass:[Mx class]]) return;
    if ([presenter isKindOfClass:[UINavigationController class]]) {
        UIViewController *top = ((UINavigationController *)presenter).topViewController;
        if ([top isKindOfClass:[Mx class]]) return;
    }
    UINavigationController *navVC = [[UINavigationController alloc]
        initWithRootViewController:[Mx new]];
    mxDiag("Opening Kira from Ask a Question long press on %{public}s",
           NSStringFromClass([presenter class]).UTF8String);
    [presenter presentViewController:navVC animated:YES completion:nil];
}



// ============================================================
// Long-press to open Kira menu on "Ask a Question" row.
//
// Root cause of the language bug: didEnterHierarchy fires BEFORE
// update() sets accessibilityLabel, so the label is always empty
// at that point. The fix: hook setAccessibilityLabel: on
// AccessibilityAreaNode — it's called from update() with the
// correct localized text, regardless of language.
//
// "Ask a Question" is always id:0 in the .support section —
// its parent is always PeerInfoScreenDisclosureItemNode.
// We identify it by checking the parent node class + label;
// mxLabelIsSupportRow() owns the label half of that test and
// is shared with the late-attach path.
// ============================================================

%hook ASDisplayNode
- (void)setAccessibilityLabel:(NSString *)label {
    %orig;
    if (!label.length || ![NSStringFromClass([self class]) containsString:@"AccessibilityAreaNode"])
        return;
    ASDisplayNode *parent = [self supernode];
    if (!parent || !mxLabelIsSupportRow(label)) return;
    NSString *parentClass = NSStringFromClass([parent class]);
    if ([parentClass containsString:@"ChatMessage"]) return;
    kiraAttachSupportLongPress(parent.view, label);
}
%end


// // ============================================================
// // Mx nav bar button — liquid glass shield, injected into
// // GlassContextExtractableContainer (rightButtonsBackground).
// //
// // GlassContextExtractableContainer is a public UIView subclass
// // from GlassBackgroundComponent module. It wraps rightButtonsContainer
// // which holds the Edit button. We hook its layoutSubviews and add
// // our button to its contentView (normalContentView).
// // ============================================================
// 
// @interface _TtC24GlassBackgroundComponent31GlassContextExtractableContainer : UIView
// @property (nonatomic, strong, readonly) UIView *contentView;
// @end
// 
// %hook _TtC24GlassBackgroundComponent31GlassContextExtractableContainer
// 
// - (void)layoutSubviews {
//     %orig;
//     @try {
//         // Already injected
//         if ([self viewWithTag:9876]) return;
// 
//         // contentView holds rightButtonsContainer
//         UIView *cv = self.contentView;
//         if (!cv) return;
// 
//         // rightButtonsContainer must have a NavigationButton subview
//         BOOL hasNavBtn = NO;
//         for (UIView *sub in cv.subviews) {
//             NSString *cls = NSStringFromClass([sub class]);
//             if ([cls containsString:@"NavigationButton"] || [cls containsString:@"HighlightableButton"]) {
//                 hasNavBtn = YES; break;
//             }
//         }
//         if (!hasNavBtn) return;
// 
//         CGFloat h = cv.bounds.size.height;
//         if (h < 20 || h > 60) return;
// 
//         // Build liquid glass button
//         CGFloat btnW = h;
//         UIButton *mxBtn = [UIButton buttonWithType:UIButtonTypeSystem];
//         mxBtn.tag = 9876;
//         mxBtn.frame = CGRectMake(-(btnW + 8), 0, btnW, h);
//         mxBtn.layer.cornerRadius = h * 0.5;
//         mxBtn.clipsToBounds = YES;
// 
//         // Blur background (liquid glass)
//         UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
//         UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:blur];
//         glass.frame = mxBtn.bounds;
//         glass.layer.cornerRadius = h * 0.5;
//         glass.clipsToBounds = YES;
//         glass.userInteractionEnabled = NO;
//         [mxBtn insertSubview:glass atIndex:0];
// 
//         // Shield icon
//         UIImage *icon = [UIImage systemImageNamed:@"shield.lefthalf.filled"];
//         if (!icon) icon = [UIImage systemImageNamed:@"shield.fill"];
//         UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
//             configurationWithPointSize:15 weight:UIImageSymbolWeightMedium];
//         if (cfg) icon = [icon imageByApplyingSymbolConfiguration:cfg];
//         [mxBtn setImage:icon forState:UIControlStateNormal];
//         mxBtn.tintColor = [UIColor labelColor];
// 
//         [mxBtn addTarget:self action:@selector(__mxShieldTap)
//               forControlEvents:UIControlEventTouchUpInside];
// 
//         // Widen contentView to show the button
//         CGRect cvf = cv.frame;
//         cvf.origin.x -= (btnW + 8);
//         cvf.size.width += (btnW + 8);
//         cv.frame = cvf;
//         cv.clipsToBounds = NO;
// 
//         [cv addSubview:mxBtn];
//         customLog2(@"[Kira] shield button injected h=%.0f", h);
//     } @catch (NSException *e) {
//         customLog2(@"[Kira] shield inject error: %@", e);
//     }
// }
// 
// %new
// - (void)__mxShieldTap {
//     showUI();
// }
// 
// %end
// 


// The original first-launch modal promoted an external channel and blocked the host UI.
// The customized build intentionally never presents it.
static void showWelcomeAlertIfNeeded() {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"MxWelcomeShown"];
}

#import "../Headers.h"

@interface ASDisplayNode (TGExtra)
@property (nonatomic, readonly) UIView *view;
@property (nonatomic, copy, readonly) NSArray *subnodes;
@end

static ASDisplayNode *findNodeByClassNamePrefix(ASDisplayNode *root, NSString *prefix) {
    if (!root) return nil;
    if ([NSStringFromClass([root class]) containsString:prefix]) {
        return root;
    }
    @try {
        NSArray *subs = root.subnodes;
        for (ASDisplayNode *child in subs) {
            ASDisplayNode *found = findNodeByClassNamePrefix(child, prefix);
            if (found) return found;
        }
    } @catch (NSException *e) {}
    return nil;
}

static BOOL injectBadgeToNode(ASDisplayNode *textNode, ASDisplayNode *headerNode, long long peerId) {
    @try {
        if (!textNode.view || !headerNode.view) return NO;

        if (peerId == 0) {
            NSString *cls = NSStringFromClass([headerNode class]);
            if ([cls containsString:@"Settings"] || [cls containsString:@"Profile"]) {
                peerId = [[NSUserDefaults standardUserDefaults] integerForKey:@"MxLastKnownUserId"];
            }
        }

        if (peerId == 0) return NO;

        NSString *prefix = nil;
        UIColor *badgeColor = [UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:1.0]; // Kira Blue

        // Add your IDs here
        if (peerId == 5576711589 || peerId == 7846965839) {
            prefix = @"👑 Kira Owner";
            badgeColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.0 alpha:1.0]; // Gold
        } else {
            NSNumber *currId = [NSClassFromString(@"TLParser") performSelector:@selector(getCurrentUserId)];
            if (currId && [currId longLongValue] == peerId) {
                prefix = @"by iKiraPlus";
                badgeColor = [UIColor colorWithRed:0.88 green:0.10 blue:0.15 alpha:1.0]; // Kira red
            }
        }
        
        if (!prefix) {
            UIView *oldBadge = [headerNode.view viewWithTag:9988];
            if (oldBadge) [oldBadge removeFromSuperview];
            return NO;
        }

        UILabel *badge = (UILabel *)[headerNode.view viewWithTag:9988];
        if (!badge) {
            badge = [[UILabel alloc] init];
            badge.tag = 9988;
            badge.font = [UIFont boldSystemFontOfSize:10];
            badge.textColor = [UIColor whiteColor];
            badge.layer.cornerRadius = 4;
            badge.layer.masksToBounds = YES;
            badge.layer.zPosition = 9999;
            [headerNode.view addSubview:badge];
        }
        
        badge.backgroundColor = badgeColor;
        badge.text = [NSString stringWithFormat:@" %@ ", prefix];
        [badge sizeToFit];
        
        // Keep the badge fully within the profile header, even for long names,
        // narrow devices and resized/rotated views. Never hide it for overflow.
        badge.numberOfLines = 1;
        badge.adjustsFontSizeToFitWidth = YES;
        badge.minimumScaleFactor = 0.80;
        CGRect bounds = headerNode.view.bounds;
        CGRect nameFrame = [textNode.view convertRect:textNode.view.bounds toView:headerNode.view];
        CGFloat badgeWidth = MIN(ceil(badge.bounds.size.width), MAX(1.0, bounds.size.width - 16.0));
        CGFloat badgeHeight = MIN(ceil(badge.bounds.size.height), MAX(1.0, bounds.size.height - 8.0));
        CGFloat x = CGRectGetMaxX(nameFrame) + 6.0;
        CGFloat y = CGRectGetMidY(nameFrame) - badgeHeight / 2.0;
        if (x + badgeWidth > CGRectGetMaxX(bounds) - 8.0) {
            x = CGRectGetMaxX(bounds) - badgeWidth - 8.0;
            if (CGRectIntersectsRect(CGRectMake(x, y, badgeWidth, badgeHeight), nameFrame)) {
                y = CGRectGetMaxY(nameFrame) + 3.0;
            }
        }
        x = MAX(CGRectGetMinX(bounds) + 8.0,
                MIN(x, CGRectGetMaxX(bounds) - badgeWidth - 8.0));
        y = MAX(CGRectGetMinY(bounds) + 4.0,
                MIN(y, CGRectGetMaxY(bounds) - badgeHeight - 4.0));
        badge.frame = CGRectMake(x, y, badgeWidth, badgeHeight);

        badge.hidden = NO;
        [headerNode.view bringSubviewToFront:badge];
        return YES;
    } @catch (NSException *e) {}
    return NO;
}

/// Returns YES once the badge has been placed, so the walk can stop.
///
/// A header holds several text nodes — name, status, sometimes more. Every one
/// of them used to be handed to injectBadgeToNode, and since they all address
/// the same tagged label the badge ended up wherever the *last* node happened to
/// be, which is how it came to sit off the top of the screen. The name comes
/// first in the tree, so the first match is the one worth keeping.
static BOOL recursiveSearchAndInject(ASDisplayNode *node, ASDisplayNode *header, long long peerId) {
    if (!node) return NO;
    NSString *cls = NSStringFromClass([node class]);

    if ([cls containsString:@"TextNode"] && ![cls containsString:@"Accessibility"] && ![cls containsString:@"Button"]) {
        if (injectBadgeToNode(node, header, peerId)) return YES;
    }
    @try {
        NSArray *subs = node.subnodes;
        for (ASDisplayNode *sub in subs) {
            if (recursiveSearchAndInject(sub, header, peerId)) return YES;
        }
    } @catch (NSException *e) {}
    return NO;
}

// ============================================================
// Ghost Mode exception button, injected into a peer's profile header.
//
// Tapping it puts that user on the Ghost Exceptions list, so they keep seeing
// your real typing indicators and read receipts while Ghost Mode stays on for
// everybody else.
// ============================================================

#import "../GhostExceptions.h"

#define kMxGhostExceptionButtonTag 9977

static const void *kMxGhostPeerIdKey = &kMxGhostPeerIdKey;
static const void *kMxGhostNodeBoxKey = &kMxGhostNodeBoxKey;

// Holds the header node weakly. Associating the node directly would form a
// retain cycle (node -> view -> button -> node) and leak every profile opened.
@interface MxWeakBox : NSObject
@property (nonatomic, weak) id object;
@end
@implementation MxWeakBox
@end

// Brief self-dismissing confirmation. The button's only state is a small icon,
// which is too subtle on its own to tell the user what just happened.
void MxOpenTelegramURL(NSURL *url) {
    if (!url) return;
    id<UIApplicationDelegate> delegate = UIApplication.sharedApplication.delegate;
    if ([delegate respondsToSelector:@selector(application:openURL:options:)]) {
        if ([delegate application:UIApplication.sharedApplication openURL:url options:@{}]) {
            return;
        }
    }
    // Only reached when this app declined the URL, in which case letting iOS
    // route it is better than doing nothing.
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

void MxShowToast(NSString *text) {
    // Audio extraction reports progress from a background queue, so callers
    // cannot be trusted to already be on main.
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ MxShowToast(text); });
        return;
    }

    UIWindow *window = UIApplication.sharedApplication.keyWindow;
    if (!window) return;

    UILabel *toast = [[UILabel alloc] init];
    toast.text = text;
    toast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    toast.textColor = [UIColor whiteColor];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.82];
    toast.numberOfLines = 0;
    toast.layer.cornerRadius = 14;
    toast.layer.masksToBounds = YES;
    toast.layer.zPosition = 99999;
    toast.alpha = 0.0;

    CGFloat maxWidth = window.bounds.size.width - 80;
    CGSize fitted = [toast sizeThatFits:CGSizeMake(maxWidth, CGFLOAT_MAX)];
    CGFloat width = MIN(maxWidth, fitted.width + 32);
    CGFloat height = fitted.height + 20;
    toast.frame = CGRectMake((window.bounds.size.width - width) / 2.0,
                             window.bounds.size.height - height - 120,
                             width, height);

    [window addSubview:toast];
    [UIView animateWithDuration:0.2 animations:^{ toast.alpha = 1.0; } completion:^(BOOL done) {
        [UIView animateWithDuration:0.3 delay:1.6 options:0 animations:^{
            toast.alpha = 0.0;
        } completion:^(BOOL finished) {
            [toast removeFromSuperview];
        }];
    }];
}

static void updateGhostExceptionButtonAppearance(UIButton *button, BOOL isException) {
    UIImage *icon = [UIImage systemImageNamed:isException ? @"eye.fill" : @"eye.slash.fill"];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:16
                                                        weight:UIImageSymbolWeightSemibold];
    if (cfg && icon) icon = [icon imageByApplyingSymbolConfiguration:cfg];
    [button setImage:icon forState:UIControlStateNormal];
    button.tintColor = isException ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
}

@interface MxGhostExceptionButtonTarget : NSObject
+ (instancetype)shared;
@end

@implementation MxGhostExceptionButtonTarget

+ (instancetype)shared {
    static MxGhostExceptionButtonTarget *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [self new]; });
    return instance;
}

- (void)handleTap:(UIButton *)sender {
    NSNumber *peerId = objc_getAssociatedObject(sender, kMxGhostPeerIdKey);
    if (!peerId || peerId.longLongValue == 0) return;

    BOOL wasException = [MxGhostExceptions containsPeerId:peerId.longLongValue];

    if (wasException) {
        [MxGhostExceptions removePeerId:peerId.longLongValue];
        mxDiag("exception REMOVE peer=%{public}@", peerId);
        MxShowToast([MxLocalization localizedStringForKey:@"GHOST_EXCEPTION_REMOVED_TOAST"]);
    } else {
        // The name lookup is deliberately deferred to this point: it builds a
        // full description of the node, far too slow to do during layout.
        NSString *name = nil;
        NSString *username = nil;
        MxWeakBox *box = objc_getAssociatedObject(sender, kMxGhostNodeBoxKey);
        if (box.object) {
            @try {
                NSDictionary *info = [TLParser getPeerDisplayInfoFromNode:box.object];
                name = info[@"name"];
                username = info[@"username"];
            } @catch (NSException *e) {}
        }

        // Reflecting over the header node only works when the host hands the
        // tweak a peer object it can walk, which this fork does not — entries
        // ended up filed with no name and the list showed a bare numeric ID.
        // The same two fields came off the wire when the profile was opened.
        if (!name.length && !username.length) {
            @try {
                NSDictionary *cached = [TLParser cachedPeerInfoForId:peerId];
                name = cached[@"name"];
                username = cached[@"username"];
            } @catch (NSException *e) {}
        }

        [MxGhostExceptions addPeerId:peerId.longLongValue name:name username:username];
        mxDiag("exception ADD peer=%{public}@ name=%{public}@ username=%{public}@", peerId,
                 name ?: @"(none)", username ?: @"(none)");
        MxShowToast([MxLocalization localizedStringForKey:@"GHOST_EXCEPTION_ADDED_TOAST"]);
    }

    updateGhostExceptionButtonAppearance(sender, !wasException);

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];
}

@end

// Hops to the main thread: AsyncDisplayKit runs -layout off-main, and this adds
// a subview and reads its geometry.
// Reports each distinct (class, peerId) pair once, plus a one-shot structural
// dump of the first header node whose peer failed to resolve. Purely diagnostic
// — compiled out with MX_DIAG.
static void mxDiagProfileNode(NSString *cls, long long peerId, ASDisplayNode *node) {
#if MX_DIAG
    static NSMutableSet *seen = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ seen = [NSMutableSet new]; });

    NSString *key = [NSString stringWithFormat:@"%@|%lld", cls, peerId];
    BOOL isNew = NO;
    @synchronized(seen) {
        if (![seen containsObject:key]) {
            [seen addObject:key];
            isNew = YES;
        }
    }
    if (!isNew) return;

    mxDiag("profile-node cls=%{public}@ peerId=%lld", cls, peerId);

    // Only the header node is worth dumping, and only when its peer came back
    // empty — that dump is what says whether the peer is absent or just unread.
    static BOOL dumped = NO;
    if (!dumped && peerId == 0 && [cls containsString:@"Header"]) {
        dumped = YES;
        @try {
            mxDiag("header-dump %{public}@", [TLParser debugPeerCandidates:node]);
        } @catch (NSException *e) {
            mxDiag("header-dump failed: %{public}@", e);
        }
    }
#endif
}

static void injectGhostExceptionButton(ASDisplayNode *headerNode, long long peerId) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            injectGhostExceptionButton(headerNode, peerId);
        });
        return;
    }

    @try {
        UIView *headerView = headerNode.view;
        if (!headerView) return;

        UIButton *existing = (UIButton *)[headerView viewWithTag:kMxGhostExceptionButtonTag];

        // Users only — GhostExceptions.h explains why groups and channels are
        // out of scope. Your own profile gets nothing either.
        BOOL isOwnProfile = NO;
        BOOL ownIdKnown = NO;
        if (peerId > 0) {
            NSNumber *currentUserId = [TLParser getCurrentUserId];
            ownIdKnown = (currentUserId != nil);
            isOwnProfile = (ownIdKnown && currentUserId.longLongValue == peerId);
            mxDiag("ghost-button peer=%lld me=%lld own=%d",
                     peerId, ownIdKnown ? currentUserId.longLongValue : -1, isOwnProfile);
        }
        // Not knowing who we are used to read as "this is somebody else", which
        // put the button on your own profile — the one place it must never be.
        // Withholding it costs nothing until the id arrives; the button only
        // matters once Ghost Mode is on, and by then a users vector has been
        // seen.
        if (peerId <= 0 || isOwnProfile || !ownIdKnown) {
            if (existing) [existing removeFromSuperview];
            return;
        }

        BOOL isException = [MxGhostExceptions containsPeerId:peerId];

        UIButton *button = existing;
        if (!button) {
            button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.tag = kMxGhostExceptionButtonTag;
            button.layer.zPosition = 9999;
            button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                      UIViewAutoresizingFlexibleBottomMargin;
            [button addTarget:[MxGhostExceptionButtonTarget shared]
                       action:@selector(handleTap:)
             forControlEvents:UIControlEventTouchUpInside];
            [headerView addSubview:button];
        }

        objc_setAssociatedObject(button, kMxGhostPeerIdKey, @(peerId),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        MxWeakBox *box = [MxWeakBox new];
        box.object = headerNode;
        objc_setAssociatedObject(button, kMxGhostNodeBoxKey, box,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Anchored against the window's safe area, not the header's own origin.
        // The header starts flush with the top of the screen, so a small y here
        // lands the button under the status bar and navigation bar — drawn, but
        // with its touches swallowed by the bar above it.
        const CGFloat buttonSize = 34.0;
        const CGFloat rightMargin = 12.0;
        const CGFloat belowNavBar = 52.0;

        UIWindow *window = headerView.window ?: UIApplication.sharedApplication.keyWindow;
        CGRect frame;
        if (window) {
            CGPoint desired = CGPointMake(
                CGRectGetWidth(window.bounds) - buttonSize - rightMargin,
                window.safeAreaInsets.top + belowNavBar);
            CGPoint local = [headerView convertPoint:desired fromView:nil];
            frame = CGRectMake(local.x, local.y, buttonSize, buttonSize);
        } else {
            frame = CGRectMake(CGRectGetWidth(headerView.bounds) - buttonSize - rightMargin,
                               100.0, buttonSize, buttonSize);
        }
        button.frame = frame;
        updateGhostExceptionButtonAppearance(button, isException);
        [headerView bringSubviewToFront:button];
    } @catch (NSException *e) {}
}

static NSHashTable *activeMessageNodes = nil;

@interface MxAntiRevokeUpdater : NSObject
@end
@implementation MxAntiRevokeUpdater
+ (instancetype)shared {
    static id instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [self new];
        // Both notifications carry the same payload and need the same reaction:
        // the badge for those ids is drawn during -layout, and layout will not
        // run again on its own just because a message changed underneath.
        [[NSNotificationCenter defaultCenter] addObserver:instance selector:@selector(handleMessagesChanged:) name:@"MxMessageDeletedRealtime" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:instance selector:@selector(handleMessagesChanged:) name:@"MxMessageEditedRealtime" object:nil];
    });
    return instance;
}
- (void)handleMessagesChanged:(NSNotification *)note {
    NSArray *deletedIds = note.userInfo[@"ids"];
    if (!deletedIds || deletedIds.count == 0) return;
    
    NSHashTable *nodesCopy = nil;
    @synchronized(activeMessageNodes) {
        nodesCopy = [activeMessageNodes copy];
    }
    
    for (ASDisplayNode *node in nodesCopy) {
        NSNumber *msgId = [TLParser getMessageIdFromNode:node];
        if (!msgId || ![deletedIds containsObject:msgId]) continue;

        [node setNeedsLayout];
        [node.view setNeedsLayout];

        // setNeedsLayout alone was not enough for the pencil: AsyncDisplayKit
        // reuses a cached layout when the size has not changed, so -layout —
        // where the badge is drawn — never ran again and the badge only turned
        // up after the chat was reopened. Draw it here instead.
        ASDisplayNode *n = node;
        NSNumber *identifier = msgId;
        NSNumber *peerKey = [TLParser getMessagePeerKeyFromNode:node];
        dispatch_async(dispatch_get_main_queue(), ^{
            updateMxEditBadge(n, identifier, peerKey);
        });
    }
}
@end

// ============================================================
// Edit history: a pencil badge on any message Anti-Edit has more than one
// recorded version of. Tapping it lists every version, oldest first, so the
// original stays in the bubble while the edits remain reachable.
// ============================================================
static const NSInteger kMxEditBadgeTag = 8899;
static char kMxEditMsgIdKey;
static char kMxEditPeerKey;

@interface MxEditHistoryButtonTarget : NSObject
+ (instancetype)shared;
@end

@implementation MxEditHistoryButtonTarget

+ (instancetype)shared {
    static MxEditHistoryButtonTarget *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [self new]; });
    return instance;
}

- (void)handleTap:(UIButton *)sender {
    NSNumber *msgId = objc_getAssociatedObject(sender, &kMxEditMsgIdKey);
    if (!msgId) return;
    NSNumber *peerKey = objc_getAssociatedObject(sender, &kMxEditPeerKey);

    NSArray<NSString *> *versions = [TLParser editHistoryForId:msgId peer:peerKey];
    if (versions.count < 2) return;

    NSMutableString *body = [NSMutableString string];
    for (NSUInteger i = 0; i < versions.count; i++) {
        NSString *label = (i == 0) ? [MxLocalization localizedStringForKey:@"EDIT_HISTORY_ORIGINAL"]
                                   : [NSString stringWithFormat:@"%@ %lu",
                                        [MxLocalization localizedStringForKey:@"EDIT_HISTORY_EDIT"],
                                        (unsigned long)i];
        [body appendFormat:@"%@\n%@", label, versions[i]];
        if (i < versions.count - 1) [body appendString:@"\n\n"];
    }

    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:[MxLocalization localizedStringForKey:@"EDIT_HISTORY_TITLE"]
                         message:body
                  preferredStyle:UIAlertControllerStyleAlert];

    // The newest version is what the user came for, so that is what Copy takes.
    [sheet addAction:[UIAlertAction
        actionWithTitle:[MxLocalization localizedStringForKey:@"EDIT_HISTORY_COPY_LATEST"]
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) {
                    UIPasteboard.generalPasteboard.string = versions.lastObject;
                }]];
    [sheet addAction:[UIAlertAction
        actionWithTitle:[MxLocalization localizedStringForKey:@"CLOSE"]
                  style:UIAlertActionStyleCancel
                handler:nil]];

    UIWindow *window = UIApplication.sharedApplication.keyWindow;
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:sheet animated:YES completion:nil];
}

@end

/// Places, or hides, the pencil badge on one message node.
static void updateMxEditBadge(ASDisplayNode *node, NSNumber *msgId, NSNumber *peerKey) {
    UIButton *badge = nil;
    for (UIView *v in node.view.subviews) {
        if (v.tag == kMxEditBadgeTag) { badge = (UIButton *)v; break; }
    }

    NSUInteger versions = (msgId != nil)
        ? [TLParser editHistoryForId:msgId peer:peerKey].count
        : 0;
    BOOL hasHistory = (versions > 1);

    // The pencil survives while the chat is on screen and is gone after leaving
    // and coming back. Both paths end here, so the three things that decide it
    // — the id, the conversation, and how many versions the lookup returns —
    // are worth naming rather than inferring from whether a glyph appeared.
#if MX_DIAG
    {
        static NSMutableSet *seen = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ seen = [NSMutableSet set]; });
        NSString *key = [NSString stringWithFormat:@"%@/%@/%lu", msgId, peerKey,
                         (unsigned long)versions];
        BOOL report = NO;
        @synchronized(seen) {
            if (seen.count < 40 && ![seen containsObject:key]) {
                [seen addObject:key];
                report = YES;
            }
        }
        if (report) {
            mxDiag("edit-badge id=%{public}s peer=%{public}s versions=%lu drawn=%d",
                   msgId ? msgId.stringValue.UTF8String : "nil",
                   peerKey ? peerKey.stringValue.UTF8String : "nil",
                   (unsigned long)versions, hasHistory);
        }
    }
#endif

    if (!hasHistory) {
        badge.hidden = YES;
        return;
    }

    if (!badge) {
        badge = [UIButton buttonWithType:UIButtonTypeSystem];
        badge.tag = kMxEditBadgeTag;
        [badge setImage:[UIImage systemImageNamed:@"pencil.circle.fill"]
               forState:UIControlStateNormal];
        badge.tintColor = [UIColor systemBlueColor];
        // The glyph stays small enough not to crowd the timestamp, but the
        // button itself is a full touch target — 22pt next to a message tap
        // area of its own was more miss than hit.
        badge.contentEdgeInsets = UIEdgeInsetsMake(9, 9, 9, 9);
        [badge addTarget:[MxEditHistoryButtonTarget shared]
                  action:@selector(handleTap:)
        forControlEvents:UIControlEventTouchUpInside];
        [node.view addSubview:badge];
    }
    objc_setAssociatedObject(badge, &kMxEditMsgIdKey, msgId, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(badge, &kMxEditPeerKey, peerKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Keep the parent interactive; some bubble nodes ship with taps disabled on
    // their backing view, which would swallow every touch aimed at the badge.
    node.view.userInteractionEnabled = YES;

    // Placed just past the trailing edge of the bubble rather than inside it.
    // The status node sits at the bubble's bottom corner, so clearing its width
    // puts the badge in empty row space: nothing to compete with for touches,
    // and no crowding of the timestamp.
    static const CGFloat kBadgeSide = 40.0;
    ASDisplayNode *statusNode = findNodeByClassNamePrefix(node, @"ChatMessageDateAndStatusNode");
    if (statusNode && statusNode.view) {
        CGRect statusFrame = [node.view convertRect:statusNode.view.bounds fromView:statusNode.view];
        CGFloat x = CGRectGetMaxX(statusFrame) + 4.0;
        // Keep it on screen even for a bubble that already reaches the edge.
        CGFloat maxX = node.view.bounds.size.width - kBadgeSide;
        if (maxX > 0 && x > maxX) x = maxX;
        badge.frame = CGRectMake(x,
                                 CGRectGetMidY(statusFrame) - (kBadgeSide / 2.0),
                                 kBadgeSide, kBadgeSide);
        badge.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                                 UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    } else {
        badge.frame = CGRectMake(node.view.bounds.size.width - kBadgeSide,
                                 node.view.bounds.size.height - kBadgeSide - 4,
                                 kBadgeSide, kBadgeSide);
        badge.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    }

    badge.hidden = NO;
    [node.view bringSubviewToFront:badge];
}

%hook ASDisplayNode
- (void)layout {
    %orig;

    if ([[NSUserDefaults standardUserDefaults] boolForKey:kDisableAllAds]) {
        @try {
            NSString *className = NSStringFromClass([self class]);
            if ([className containsString:@"ChatSponsoredMessage"] || [className containsString:@"ChatChannelAdItemNode"]) {
                self.view.hidden = YES;
                self.view.alpha = 0.0;
                return;
            }

            if ([self respondsToSelector:NSSelectorFromString(@"item")]) {
                id item = [self valueForKey:@"item"];
                if (item && [item respondsToSelector:NSSelectorFromString(@"message")]) {
                    id message = [item valueForKey:@"message"];
                    if (message && [message respondsToSelector:NSSelectorFromString(@"adAttribute")]) {
                        if ([message valueForKey:@"adAttribute"] != nil) {
                            self.view.hidden = YES;
                            self.view.alpha = 0.0;
                            return;
                        }
                    }
                }
            }
        } @catch (NSException *e) {}
    }

    NSString *cls = NSStringFromClass([self class]);

    // Was: anything whose class mentioned Profile, UserInfo, ContactInfo,
    // PeerInfo, UserNode or Settings. Measured on iMe that matched 18 distinct
    // node classes — its whole SettingsUI module answers to "Settings" and every
    // row of the settings list answers to "PeerInfo". Each match then had its
    // text nodes scanned and a badge planted, which is why the tag turned up
    // floating off the top of the screen and again inside the Support page.
    //
    // The real profile header is the node the eye button has always been
    // restricted to. The badge belongs on the same one.
    BOOL isProfileHeader = [cls containsString:@"PeerInfoHeaderNode"];

    if (isProfileHeader) {
        long long peerId = 0;
        peerId = [[NSClassFromString(@"TLParser") performSelector:@selector(getPeerIdFromNode:) withObject:self] longLongValue];
        
        // A header that cannot say whose it is used to be assumed to be yours.
        // On the settings screen that guess is right; on any other header it
        // hands your own id to somebody else's profile, and the badge follows.
        // Only the settings screen has no peer of its own, so ask the header
        // whether it is showing one at all before falling back.
        SEL peerSel = NSSelectorFromString(@"peer");
        BOOL headerHasNoPeer = NO;
        if ([self respondsToSelector:peerSel]) {
            id (*getPeer)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            headerHasNoPeer = (getPeer(self, peerSel) == nil);
        }
        if (peerId == 0 && headerHasNoPeer) {
            peerId = [[NSUserDefaults standardUserDefaults] integerForKey:@"MxLastKnownUserId"];
        }
        recursiveSearchAndInject(self, self, peerId);

        // Diagnostic: report every distinct class/peer pair reaching this point
        // exactly once. Keyed on the pair rather than the peer alone, because
        // logging only on change hides "called constantly, always resolves to 0"
        // — which is indistinguishable from "never called at all".
        mxDiagProfileNode(cls, peerId, self);

        injectGhostExceptionButton(self, peerId);
    }

    if ([[NSUserDefaults standardUserDefaults] boolForKey:kHideStories]) {
        NSString *className = NSStringFromClass([self class]);
        if ([className containsString:@"StoryPeerList"] || 
            [className containsString:@"StoryContainer"] ||
            [className containsString:@"StorySetIndicator"] ||
            [className containsString:@"AvatarStoryIndicator"]) {
            self.view.hidden = YES;
            self.view.alpha = 0.0;
        }
    }

    NSString *className = NSStringFromClass([self class]);
    if (![className containsString:@"ChatMessage"] || ![className containsString:@"ItemNode"]) {
        return;
    }
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        activeMessageNodes = [NSHashTable weakObjectsHashTable];
    });
    
    @synchronized(activeMessageNodes) {
        [activeMessageNodes addObject:self];
    }
    
    NSNumber *msgId = [TLParser getMessageIdFromNode:self];
    NSNumber *nodePeerKey = msgId ? [TLParser getMessagePeerKeyFromNode:self] : nil;
    BOOL isDeletedMsg = (msgId && [TLParser isDeleted:msgId peer:nodePeerKey]);
    BOOL isSelfDestructMsg = (msgId && [TLParser isMessageSelfDestructing:msgId]);
    
    ASDisplayNode *node = (ASDisplayNode *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (isDeletedMsg || isSelfDestructMsg) {
            UIImageView *statusIcon = nil;
            for (UIView *v in node.view.subviews) {
                if (v.tag == 8898) {
                    statusIcon = (UIImageView *)v;
                    break;
                }
            }
            
            BOOL isNewlyCreated = NO;
            if (!statusIcon) {
                statusIcon = [[UIImageView alloc] init];
                statusIcon.tag = 8898;
                [node.view addSubview:statusIcon];
                isNewlyCreated = YES;
            }
            
            if (isDeletedMsg) {
                statusIcon.image = [UIImage systemImageNamed:@"trash.fill"];
                statusIcon.tintColor = [UIColor systemRedColor];
            } else {
                statusIcon.image = [UIImage systemImageNamed:@"timer"];
                statusIcon.tintColor = [UIColor systemOrangeColor];
            }
            
            ASDisplayNode *statusNode = findNodeByClassNamePrefix(node, @"ChatMessageDateAndStatusNode");
            if (statusNode && statusNode.view) {
                CGRect statusFrame = [node.view convertRect:statusNode.view.bounds fromView:statusNode.view];
                statusIcon.frame = CGRectMake(statusFrame.origin.x - 18, statusFrame.origin.y + (statusFrame.size.height / 2.0) - 7, 14, 14);
                statusIcon.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
            } else {
                // Same 14pt as the anchored branch. A bubble with no
                // date-and-status node — a sticker, a GIF, a round video — used
                // to get a 20pt icon here, visibly bigger than the one every
                // other message shows.
                statusIcon.frame = CGRectMake(node.view.bounds.size.width - 34, node.view.bounds.size.height - 32, 14, 14);
                statusIcon.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
            }
            
            BOOL wasHidden = statusIcon.hidden;
            statusIcon.hidden = NO;
            [node.view bringSubviewToFront:statusIcon];
            
            if (wasHidden || isNewlyCreated) {
                statusIcon.transform = CGAffineTransformMakeScale(0.1, 0.1);
                statusIcon.alpha = 0.0;
                [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.8 options:UIViewAnimationOptionCurveEaseOut animations:^{
                    statusIcon.transform = CGAffineTransformIdentity;
                    statusIcon.alpha = 1.0;
                } completion:nil];
            }
            
        } else {
            node.view.backgroundColor = [UIColor clearColor];
            for (UIView *v in node.view.subviews) {
                if (v.tag == 8898) {
                    v.hidden = YES;
                }
            }
        }

        updateMxEditBadge(node, msgId, nodePeerKey);
    });
}
%end

/// The chat screen's class, whichever of the two names this client uses.
static Class mxChatControllerClass(void) {
    Class cls = objc_getClass("_TtC10TelegramUI18ChatControllerImpl");
    return cls ?: objc_getClass("_TtC10TelegramUI14ChatController");
}

// The chat screen's concrete class is TelegramUI.ChatControllerImpl; plain
// ChatController is a protocol declared in AccountContext, and objc_getClass on
// its mangled name has been returning nil for as long as this hook has existed.
// %init below resolves Impl first and keeps the old name as a fallback for any
// client still shipping it.
%hook _TtC10TelegramUI18ChatControllerImpl
- (void)viewDidLayoutSubviews {
    %orig;
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
}
- (void)viewDidLoad {
    %orig;
    @try {
        id context = [((id)self) valueForKey:@"context"];
        Class tlParser = NSClassFromString(@"TLParser");
        if ([tlParser respondsToSelector:@selector(setSharedContext:)]) {
            [tlParser performSelector:@selector(setSharedContext:) withObject:context];
            
            NSNumber *currId = [tlParser performSelector:@selector(getCurrentUserId)];
            if (currId) {
                [[NSUserDefaults standardUserDefaults] setInteger:[currId integerValue] forKey:@"MxLastKnownUserId"];
            }
        }
    } @catch (NSException *e) {}
}
%end

%hook _TtC10TelegramUI22TelegramRootController
- (void)loadView {
    %orig;
    @try {
        id context = [((id)self) valueForKey:@"context"];
        Class tlParser = NSClassFromString(@"TLParser");
        if (context && [tlParser respondsToSelector:@selector(setSharedContext:)]) {
            [tlParser performSelector:@selector(setSharedContext:) withObject:context];
        }
    } @catch (NSException *e) {}
}
%end

%group CallConfirmHooks

%hook ASControlNode
- (void)sendActionsForControlEvents:(NSUInteger)controlEvents withEvent:(UIEvent *)event {
    if (controlEvents == (1 << 4)) { // ASControlNodeEventTouchUpInside
        NSString *label = [(id)self accessibilityLabel];
        if (label && label.length > 0 && [[NSUserDefaults standardUserDefaults] boolForKey:kConfirmCalls]) {
            NSString *lower = [label lowercaseString];
            
            // All known call button labels (EN, RU, case-insensitive)
            NSSet *callLabels = [NSSet setWithArray:@[
                @"call", @"позвонить", @"звонок"
            ]];
            NSSet *videoLabels = [NSSet setWithArray:@[
                @"video", @"видео", @"video call", @"видеозвонок"
            ]];
            
            BOOL isCall = [callLabels containsObject:lower];
            BOOL isVideo = [videoLabels containsObject:lower];
            
            if (isCall || isVideo) {
                UIWindow *window = UIApplication.sharedApplication.keyWindow;
                UIViewController *rootVC = window.rootViewController;
                while (rootVC.presentedViewController) {
                    rootVC = rootVC.presentedViewController;
                }
                if (rootVC) {
                    NSString *confirmTitle = isVideo ? @"Video Call" : @"Call";
                    NSString *alertTitle = isVideo ? @"Start Video Call?" : @"Start Call?";
                    
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:alertTitle
                                                                                   message:nil
                                                                            preferredStyle:UIAlertControllerStyleAlert];
                    
                    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                             style:UIAlertActionStyleCancel
                                                           handler:nil]];
                    [alert addAction:[UIAlertAction actionWithTitle:confirmTitle
                                                             style:UIAlertActionStyleDefault
                                                           handler:^(UIAlertAction *action) {
                        %orig(controlEvents, event);
                    }]];
                    
                    [rootVC presentViewController:alert animated:YES completion:nil];
                    return;
                }
            }
        }
    }
    %orig;
}
%end

%end // CallConfirmHooks

%group SiriBypassHooks
%hook INPreferences

+ (void)initialize {
}

+ (instancetype)sharedPreferences {
    return nil;
}

+ (instancetype)alloc {
    return nil;
}

+ (instancetype)new {
    return nil;
}

- (instancetype)init {
    return nil;
}

+ (NSInteger)siriAuthorizationStatus {
    return 0; // INSiriAuthorizationStatusNotDetermined
}

+ (void)requestSiriAuthorization:(void (^)(NSInteger status))routine {
    if (routine) {
        routine(0);
    }
}

%end
%end // SiriBypassHooks

// ============================================================
// Download Stories: auto-save story to camera roll when opened.
// Hooks StoryItemSetContainerComponent.View — calls requestSave
// automatically when the story becomes visible.
//
// The class name carried a length of 32 for a 30-character class, so
// objc_getClass returned nil and this never bound. Corrected against
// release-12.9.2.
//
// Binding it is necessary but not sufficient: -requestSave is
// `private func requestSave()` in StoryItemSetContainerComponent.swift with no
// @objc, so it has no selector and the call below still cannot land. Saving a
// story needs a different route — the Save entry in the story's own context
// menu, or saveToCameraRoll reached some other way. Left wired up so that route
// only has to be filled in here.
// ============================================================
%hook _TtCC20StoryContainerScreen30StoryItemSetContainerComponent4View

- (void)didMoveToWindow {
    %orig;
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kDownloadStories]) return;
    if (!self.window) return;
    // Delay slightly so the story is fully loaded before saving
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            if ([[NSUserDefaults standardUserDefaults] boolForKey:kDownloadStories]) {
                [self requestSave];
            }
        } @catch (NSException *e) {}
    });
}

%end

__attribute__((constructor))
static void hook() {
    NSLog(@"[Kira] Tweak initializing...");

    // Intents.framework is loaded on the second runloop turn rather than here.
    // A tweak constructor runs inside dyld, before the app has drawn anything,
    // so pulling in a system framework and its dependencies at this point is
    // added straight onto launch time — and INPreferences is not consulted
    // until well after the UI is up.
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [[NSBundle bundleWithPath:@"/System/Library/Frameworks/Intents.framework"] load];
            Class inPreferencesClass = objc_getClass("INPreferences");
            if (inPreferencesClass) {
                %init(SiriBypassHooks, INPreferences = inPreferencesClass);
                NSLog(@"[Kira] SiriBypassHooks initialized");
            } else {
                NSLog(@"[Kira] SiriBypassHooks init failed: INPreferences class not found");
            }
        } @catch (NSException *e) {
            NSLog(@"[Kira] SiriBypassHooks init failed: %@", e);
        }
    });

    [MxAntiRevokeUpdater shared];

    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kDisableAllAds: @NO,
        kAntiRevoke: @NO,
        kAntiEdit: @NO,
        kAntiSelfDestruct: @NO,
        kHideStories: @NO,
        kDownloadStories: @NO,
        kDisableMessageReadReceipt: @NO,
        kDisableStoriesReadReceipt: @NO,
        kDisableOnlineStatus: @NO,
        kDisableTypingStatus: @NO,
        kHideDisappearingLabel: @NO,
        kConfirmCalls: @YES
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        %init(
            _TtC10TelegramUI30ChatPresentationInterfaceState = objc_getClass("_TtC10TelegramUI30ChatPresentationInterfaceState"),
            _TtC30ChatPresentationInterfaceState30ChatPresentationInterfaceState = objc_getClass("_TtC30ChatPresentationInterfaceState30ChatPresentationInterfaceState"),
            _TtC10TelegramUI18ChatControllerImpl = mxChatControllerClass()
        );

        @try {
            Class asControlNodeClass = objc_getClass("ASControlNode");
            if (asControlNodeClass) {
                %init(CallConfirmHooks, ASControlNode = asControlNodeClass);
                NSLog(@"[Kira] CallConfirmHooks initialized");
            }
        } @catch (NSException *e) {
            NSLog(@"[Kira] CallConfirmHooks init failed: %@", e);
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            showWelcomeAlertIfNeeded();
        });

        // Download Speed Boost — find FetchImpl.Impl via runtime class scan.
        // The class name contains "FetchImpl" and "Impl" and lives in TelegramCore.
        // We swizzle the init method to intercept defaultPartSize and maxPendingParts.
        //
        // Skipped entirely when the feature is off. The scan walks every class
        // registered in the process — tens of thousands in this app — and used
        // to run on every launch whether or not anything came of it.
        if ([[NSUserDefaults standardUserDefaults] integerForKey:kDownloadSpeedBoost] > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [MxDownloadBoost install];
            });
        }
    });
 }
