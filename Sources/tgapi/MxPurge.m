// Per-chat "Delete My Messages" interface and verified MTProto execution.
// Never delete conversation history, delete messages from other authors,
// or fall back to a global message search. The default is OFF.
#import "MxPurge.h"
#import "Headers.h"
#import "UI/Headers.h"
#import <objc/runtime.h>

@interface MTRpcError (MxPurgeError)
@property (nonatomic, readonly) NSString *errorDescription;
@end

@interface MxPurgeCodec : NSObject
+ (NSDictionary *)peerFromRequest:(NSData *)payload;
+ (NSString *)chatKeyForController:(id)controller;
+ (NSNumber *)accountIdForContext:(id)context;
+ (NSNumber *)accountIdForController:(id)controller;
+ (NSData *)makeSelfCheck;
+ (NSNumber *)selfIdFromResponse:(NSData *)data;
+ (NSData *)makeSearchForPeer:(NSData *)peer offset:(int32_t)offset limit:(int32_t)limit;
+ (NSDictionary *)searchResult:(NSData *)data;
+ (NSString *)searchResponseDiagnostic:(NSData *)data;
+ (NSData *)makeDeleteForPeer:(NSData *)peer ids:(NSArray<NSNumber *> *)ids;
+ (BOOL)deleteSucceeded:(NSData *)data;
@end

static NSString *mxPurgeText(NSString *ar, NSString *en) {
    NSString *c = [MxLocalization localizedStringForKey:@"CANCEL"];
    BOOL arabic = [c isEqualToString:@"إلغاء"] ||
        ((!c.length || [c isEqualToString:@"CANCEL"]) &&
         [[[NSLocale preferredLanguages].firstObject lowercaseString] hasPrefix:@"ar"]);
    return arabic ? ar : en;
}
static const void *kMxPurgeContextKey = &kMxPurgeContextKey;

@interface MxPurgeContext : NSObject
@property (nonatomic, weak) UIViewController *controller;
@property (nonatomic, weak) MTRequestMessageService *service;
@property (nonatomic, copy) NSString *peerKey;
@property (nonatomic, strong) NSData *peerData;
@property (nonatomic, strong) NSNumber *accountId;
@property (nonatomic, copy) NSString *failureReason;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UIBarButtonItem *barItem; // legacy; custom Telegram nav ignores it
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL partial;
@property (nonatomic, assign) BOOL verifiedEmpty;
@property (nonatomic, assign) BOOL scanned;
@property (nonatomic, assign) NSUInteger deletedCount;
@property (nonatomic, assign) NSUInteger batchCount;
@property (nonatomic, assign) NSUInteger repeatCount;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *deletedIds;
@end
@implementation MxPurgeContext @end

@interface MxPurgePeer : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) NSData *peerData;
@property (nonatomic, weak) MTRequestMessageService *service;
@end
@implementation MxPurgePeer @end

@interface MxPurgePending : NSObject
@property (nonatomic, assign) BOOL resolved;
@end
@implementation MxPurgePending @end

typedef void (^MxPurgeResult)(NSData *response, NSString *error);

@interface MxPurgeManager : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, MxPurgePeer *> *peers;
@property (nonatomic, weak) UIViewController *visibleChat;
+ (instancetype)shared;
- (void)capture:(MTRequest *)request service:(MTRequestMessageService *)service;
- (void)appeared:(UIViewController *)controller;
- (void)layout:(UIViewController *)controller;
- (void)disappeared:(UIViewController *)controller;
- (void)settingsChanged;
- (void)tapped:(UIButton *)button;
@end

@implementation MxPurgeManager

+ (instancetype)shared {
    static MxPurgeManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        manager = [MxPurgeManager new];
        manager.peers = [NSMutableDictionary dictionary];
    });
    return manager;
}
- (BOOL)enabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kDeleteMyMessages];
}
- (void)capture:(MTRequest *)request service:(MTRequestMessageService *)service {
    if (![self enabled] || !request.payload || !service) return;
    NSDictionary *found = [MxPurgeCodec peerFromRequest:request.payload];
    NSString *key = found[@"key"];
    NSData *peerData = found[@"peerData"];
    if (!key.length || !peerData.length) return;
    @synchronized (self) {
        MxPurgePeer *record = self.peers[key] ?: [MxPurgePeer new];
        record.key = key;
        record.peerData = peerData;
        record.service = service;
        self.peers[key] = record;
        if (self.peers.count > 128) {
            // Cache-only hint; no persisted peer credentials.
            [self.peers removeAllObjects];
            self.peers[key] = record;
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = self.visibleChat;
        MxPurgeContext *ctx = vc ? objc_getAssociatedObject(vc, kMxPurgeContextKey) : nil;
        if (ctx && !ctx.cancelled && [ctx.peerKey isEqualToString:key] && !ctx.busy) {
            [self lookupContext:ctx];
        }
    });
}
// Telegram/VoidGram draw their own navigation header and ignore UIKit
// UINavigationItem.rightBarButtonItems. Attach an always-visible floating
// control to the chat's REAL view, above its ASDisplayNode subtree.
//
// A gray button is only a diagnostic/unverified state: no delete is permitted
// until the visible chat, the MTProto service, and the account all match.
- (void)positionButton:(MxPurgeContext *)ctx {
    UIViewController *vc = ctx.controller;
    UIView *host = vc.view;
    UIWindow *window = host.window;
    if (!host || !ctx.button || !window || ctx.cancelled) return;
    CGFloat width = CGRectGetWidth(host.bounds);
    CGFloat height = CGRectGetHeight(host.bounds);
    if (width < 100 || height < 200) return;
    CGFloat safeTop = host.safeAreaInsets.top;
    // The AsyncDisplayKit chat view constantly inserts its own overlay nodes,
    // so a button hosted inside vc.view can be visible while taps pass through
    // to a message below. Host it above the chat in the same UIWindow.
    // Convert the exact chat-local position; never guess screen coordinates.
    CGFloat y = MIN(MAX(safeTop + 132.0, 124.0), height - host.safeAreaInsets.bottom - 72.0);
    CGFloat x = width - host.safeAreaInsets.right - 54.0;
    CGRect localFrame = CGRectMake(MAX(8.0, x), y, 44.0, 44.0);
    ctx.button.frame = [host convertRect:localFrame toView:window];
    if (ctx.button.superview != window) {
        [ctx.button removeFromSuperview];
        [window addSubview:ctx.button];
    }
    // Telegram may mount later window subviews during chat transitions.
    [window bringSubviewToFront:ctx.button];
}
- (void)settingsChanged {
    if (![self enabled]) {
        @synchronized (self) { [self.peers removeAllObjects]; }
        UIViewController *vc = self.visibleChat;
        MxPurgeContext *ctx = vc ? objc_getAssociatedObject(vc, kMxPurgeContextKey) : nil;
        if (ctx) {
            ctx.cancelled = YES;
            [ctx.button removeFromSuperview];
        }
    }
}
- (void)appeared:(UIViewController *)controller {
    if (!controller) return;
    self.visibleChat = controller;
    MxPurgeContext *old = objc_getAssociatedObject(controller, kMxPurgeContextKey);
    if (![self enabled]) {
        old.cancelled = YES;
        [old.button removeFromSuperview];
        return;
    }
    NSString *key = [MxPurgeCodec chatKeyForController:controller];
    // KVC cannot reliably read Swift ChatControllerImpl.context.
    NSNumber *own = [MxPurgeCodec accountIdForController:controller];
    // Force a new per-chat verification on every entry. A callback from an
    // earlier appearance must never reauthorize deletion after navigation.
    old.cancelled = YES;
    [old.button removeFromSuperview];
    MxPurgeContext *ctx = [MxPurgeContext new];
    ctx.deletedIds = [NSMutableSet set];
    ctx.peerKey = key ?: @"";
    objc_setAssociatedObject(controller, kMxPurgeContextKey, ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ctx.controller = controller;
    ctx.cancelled = NO;
    ctx.accountId = own;
    if (!key.length) {
        ctx.failureReason = mxPurgeText(@"تعذّر قراءة هوية هذه المحادثة من إصدار تيليجرام.",
                                        @"This Telegram build did not expose the chat identity.");
    } else if (own.longLongValue <= 0) {
        ctx.failureReason = mxPurgeText(@"تعذّر قراءة هوية الحساب الحالي من واجهة المحادثة.",
                                        @"Could not read the account identity from the chat.");
    } else {
        ctx.failureReason = mxPurgeText(@"لم تتوفر بعد بيانات الاتصال الموثقة لهذه المحادثة.",
                                        @"No authenticated request for this chat has been captured yet.");
    }
    if (!ctx.button) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(0, 0, 44, 44);
        button.accessibilityLabel = mxPurgeText(@"حذف كل رسائلي في هذه المحادثة",
                                                  @"Delete my messages in this chat");
        button.tag = 91017;
        button.layer.cornerRadius = 22.0;
        button.layer.borderWidth = 1.0;
        button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
        button.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.98];
        button.exclusiveTouch = YES;
        button.userInteractionEnabled = YES;
        // VoidGram's chat view installs pan/swipe recognizers over the whole
        // surface. They may cancel TouchUpInside before it reaches a floating
        // control. TouchDown fires immediately; it never deletes directly,
        // it only opens the verification/confirmation UI.
        [button addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchDown];
        ctx.button = button;
    }
    [self style:ctx];
    [self positionButton:ctx];
    if (key.length && own.longLongValue > 0 && !ctx.scanned)
        [self lookupContext:ctx];
}
- (void)layout:(UIViewController *)controller {
    if (![self enabled] || self.visibleChat != controller) return;
    MxPurgeContext *ctx = objc_getAssociatedObject(controller, kMxPurgeContextKey);
    if (!ctx || ctx.cancelled) return;
    [self positionButton:ctx];
}
- (void)disappeared:(UIViewController *)controller {
    MxPurgeContext *ctx = objc_getAssociatedObject(controller, kMxPurgeContextKey);
    if (ctx) {
        ctx.cancelled = YES;
        [ctx.button removeFromSuperview];
    }
    if (self.visibleChat == controller) self.visibleChat = nil;
}
- (void)style:(MxPurgeContext *)ctx {
    if (!ctx.button) return;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
        configurationWithPointSize:21 weight:UIImageSymbolWeightSemibold];
    UIImage *img = [[UIImage systemImageNamed:@"trash.fill"] imageByApplyingSymbolConfiguration:cfg];
    [ctx.button setImage:img forState:UIControlStateNormal];
    UIColor *color = [UIColor systemGrayColor];
    if (!ctx.busy && ctx.scanned) {
        if (ctx.verifiedEmpty) color = [UIColor systemGreenColor];
        else if (ctx.partial) color = [UIColor systemOrangeColor];
        else color = [UIColor systemRedColor];
    }
    ctx.button.tintColor = color;
    ctx.button.layer.borderColor = [color colorWithAlphaComponent:0.80].CGColor;
    // IMPORTANT: an unverified/working/empty trash must still receive taps.
    // Disabling UIControl made it translucent and caused a silent no-op. The
    // action handler alone decides whether verification/deletion is allowed.
    ctx.button.enabled = !ctx.cancelled;
    ctx.button.userInteractionEnabled = !ctx.cancelled;
    ctx.button.alpha = 1.0;
    ctx.button.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.98];
}
- (void)message:(NSString *)message title:(NSString *)title context:(MxPurgeContext *)ctx {
    UIViewController *vc = ctx.controller;
    if (!vc || !vc.view.window) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:mxPurgeText(@"حسناً", @"OK")
                                              style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}
- (void)send:(NSData *)data service:(MTRequestMessageService *)service
       done:(MxPurgeResult)done {
    if (!data.length || !service) {
        if (done) done(nil, @"No authenticated request service or invalid peer.");
        return;
    }
    // MTRequest is provided by the host Telegram binary at runtime. A direct
    // [MTRequest new] emits an undefined link-time class symbol in injected dylibs.
    Class requestClass = objc_getClass("MTRequest");
    if (!requestClass) {
        if (done) done(nil, @"Telegram MTRequest class unavailable.");
        return;
    }
    MTRequest *request = [(id)requestClass new];
    MxPurgePending *pending = [MxPurgePending new];
    [request setPayload:data metadata:@"MxPurge" shortMetadata:@"MxPurge"
         responseParser:^id(NSData *response) { return response; }];
    request.completed = ^(id result, __unused MTRequestResponseInfo *info, MTRpcError *error) {
        @synchronized (pending) {
            if (pending.resolved) return;
            pending.resolved = YES;
        }
        NSString *description = error ? [error errorDescription] : nil;
        NSData *response = [result isKindOfClass:[NSData class]] ? result : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (done) done(response, description ?: (response ? nil : @"No server response."));
        });
    };
    [service addRequest:request];
    // Do not keep deleting if an RPC request never returns.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 35 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        @synchronized (pending) {
            if (pending.resolved) return;
            pending.resolved = YES;
        }
        if (done) done(nil, @"Request timed out; deletion may be partial.");
    });
}
- (BOOL)stillCurrent:(MxPurgeContext *)ctx {
    UIViewController *vc = ctx.controller;
    if (![self enabled] || !ctx || ctx.cancelled || self.visibleChat != vc ||
        !vc.view.window || !ctx.service || !ctx.peerData.length ||
        ctx.accountId.longLongValue <= 0) return NO;
    // ChatControllerImpl may reuse the same UIViewController for a different
    // location. Never continue an old chat's job after a navigation change.
    if (objc_getAssociatedObject(vc, kMxPurgeContextKey) != ctx) return NO;
    return [[MxPurgeCodec chatKeyForController:vc] isEqualToString:ctx.peerKey];
}
- (void)lookupContext:(MxPurgeContext *)ctx {
    if (!ctx || ctx.busy || ctx.cancelled || !ctx.accountId || ![self enabled]) return;
    MxPurgePeer *peer = nil;
    @synchronized (self) { peer = self.peers[ctx.peerKey]; }
    if (!peer.service || !peer.peerData.length) {
        ctx.failureReason = mxPurgeText(@"لم يصل بعد طلب موثق يخص هذه المحادثة. لا يمكن الحذف بدون التحقق من وجهة الرسائل.",
                                        @"No authenticated request for this chat was observed. Cannot delete without proving the destination.");
        return;
    }
    ctx.service = peer.service;
    ctx.peerData = peer.peerData;
    ctx.busy = YES;
    [self style:ctx];
    // Strong identity proof: the service being used must be the account of
    // the visible ChatController. This blocks a second logged-in account.
    [self send:[MxPurgeCodec makeSelfCheck] service:ctx.service
          done:^(NSData *response, NSString *error) {
        if (ctx.cancelled || ![self stillCurrent:ctx]) { ctx.busy = NO; return; }
        NSNumber *serverId = error ? nil : [MxPurgeCodec selfIdFromResponse:response];
        if (!serverId || ![serverId isEqualToNumber:ctx.accountId]) {
            ctx.busy = NO;
            ctx.scanned = NO;
            ctx.failureReason = error.length
                ? [NSString stringWithFormat:mxPurgeText(@"فشل تحقق الحساب: %@",
                                                         @"Account verification failed: %@"), error]
                : mxPurgeText(@"تعذّرت مطابقة جلسة تيليجرام الحالية مع الحساب. لن يتم الحذف.",
                              @"Telegram session did not match the current account. Nothing will be deleted.");
            [self style:ctx];
            return; // fail closed, never guess session ownership
        }
        NSData *query = [MxPurgeCodec makeSearchForPeer:ctx.peerData offset:0 limit:2];
        [self send:query service:ctx.service done:^(NSData *data, NSString *searchError) {
            ctx.busy = NO;
            if (ctx.cancelled || ![self stillCurrent:ctx]) { [self style:ctx]; return; }
            NSDictionary *parsed = searchError ? nil : [MxPurgeCodec searchResult:data];
            if (parsed) {
                NSUInteger count = [parsed[@"ids"] count];
                NSUInteger returned = [parsed[@"returned"] unsignedIntegerValue];
                ctx.scanned = YES;
                ctx.failureReason = nil;
                ctx.verifiedEmpty = count == 0 && returned == 0;
                if (ctx.verifiedEmpty) ctx.partial = NO;
            } else {
                ctx.scanned = NO;
                NSString *diagnostic = data.length
                    ? [MxPurgeCodec searchResponseDiagnostic:data]
                    : @"No response payload";
                ctx.failureReason = searchError.length
                    ? [NSString stringWithFormat:mxPurgeText(@"رفض الخادم البحث: %@",
                                                             @"Server rejected the search: %@"), searchError]
                    : [NSString stringWithFormat:mxPurgeText(@"تعذّر تحليل جواب البحث من تيليجرام (%@).",
                                                             @"Could not parse Telegram search response (%@)."), diagnostic];
            }
            [self style:ctx];
        }];
    }];
}
- (void)tapped:(UIButton *)button {
    MxPurgeContext *ctx = objc_getAssociatedObject(self.visibleChat, kMxPurgeContextKey);
    if (!ctx || ctx.button != button || ctx.cancelled) return;
    if (ctx.busy) {
        [self message:mxPurgeText(
            ctx.batchCount > 0 ? @"الحذف جارٍ الآن في هذه المحادثة. لا تبدأ عملية ثانية."
                               : @"جار التحقق من هذه المحادثة والحساب، ولم يبدأ حذف أي رسالة.",
            ctx.batchCount > 0 ? @"Deletion is running only in this chat. Do not start another job."
                               : @"Verifying this chat and account. No messages have been deleted.")
                 title:mxPurgeText(@"حالة السلة", @"Trash status") context:ctx];
        return;
    }
    if (ctx.verifiedEmpty) {
        [self message:mxPurgeText(@"السلة الخضراء تعني أن بحث تيليجرام لم يجد رسائل مرسلة منك في هذه المحادثة. ماكو شي ينحذف.",
                                  @"Green means Telegram found no messages sent by you in this chat. Nothing to delete.")
                 title:mxPurgeText(@"لا توجد رسائل", @"No messages found") context:ctx];
        return;
    }
    if (!ctx.scanned || ![self stillCurrent:ctx]) {
        // Always explain gray (unverified). Retry only if we have the verified
        // chat/account prerequisites. Never infer IDs from visible message UI.
        NSString *reason = ctx.failureReason ?: mxPurgeText(
            @"السلة الرمادية تعني أن التحقق لم يكتمل، ولم يبدأ أي حذف.",
            @"Gray means verification has not finished. Nothing has been deleted.");
        [self message:reason
                 title:mxPurgeText(@"السلة بحاجة للتحقق", @"Trash needs verification")
               context:ctx];
        if (!ctx.busy && ctx.peerKey.length && ctx.accountId.longLongValue > 0) {
            [self lookupContext:ctx];
        }
        return;
    }
    NSString *chat = ctx.controller.navigationItem.title ?: ctx.controller.title ?: ctx.peerKey;
    NSString *title = mxPurgeText(@"حذف كل رسائلي", @"Delete My Messages");
    NSString *description = mxPurgeText(
        [NSString stringWithFormat:@"سيتم حذف الرسائل التي أرسلتها في «%@» فقط، وعند الجميع حيث يسمح تيليجرام. لا يمكن التراجع عن هذا الإجراء. هل تؤكد؟", chat],
        [NSString stringWithFormat:@"Delete only YOUR messages in “%@” for everyone where Telegram permits it? This cannot be undone.", chat]);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:description
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:mxPurgeText(@"إلغاء", @"Cancel")
                                              style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:mxPurgeText(@"نعم، احذف رسائلي", @"Delete my messages")
                                              style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        if (![self stillCurrent:ctx]) return;
        ctx.busy = YES;
        ctx.batchCount = 0;
        ctx.repeatCount = 0;
        ctx.deletedCount = 0;
        ctx.verifiedEmpty = NO;
        [ctx.deletedIds removeAllObjects];
        [self style:ctx];
        [self purgeNext:ctx];
    }]];
    [ctx.controller presentViewController:alert animated:YES completion:nil];
}
- (void)finish:(MxPurgeContext *)ctx fully:(BOOL)fully detail:(NSString *)detail {
    ctx.busy = NO;
    ctx.scanned = YES;
    ctx.verifiedEmpty = fully;
    ctx.partial = !fully && ctx.deletedCount > 0;
    [self style:ctx];
    NSString *msg = fully
        ? mxPurgeText([NSString stringWithFormat:@"تم حذف %lu رسالة، وتأكدنا من عدم بقاء رسائل منك في هذه المحادثة.", (unsigned long)ctx.deletedCount],
                      [NSString stringWithFormat:@"Deleted %lu messages. A new server search found no remaining messages from you in this chat.", (unsigned long)ctx.deletedCount])
        : mxPurgeText([NSString stringWithFormat:@"تم حذف %lu رسالة على الأقل. بقيت رسائل أو تعذّر التأكد من اكتمال الحذف. %@", (unsigned long)ctx.deletedCount, detail ?: @""],
                      [NSString stringWithFormat:@"At least %lu messages deleted. Some may remain or verification failed. %@", (unsigned long)ctx.deletedCount, detail ?: @""]);
    [self message:msg title:mxPurgeText(fully ? @"اكتمل الحذف" : @"حذف جزئي", fully ? @"Deletion complete" : @"Partial deletion")
         context:ctx];
}
- (void)purgeNext:(MxPurgeContext *)ctx {
    if (![self stillCurrent:ctx]) { [self finish:ctx fully:NO detail:@""]; return; }
    if (++ctx.batchCount > 150) {
        [self finish:ctx fully:NO detail:mxPurgeText(@"توقفنا عند حد الأمان، اضغط السلة لإكمال الباقي.",
                                                     @"Safety batch limit reached; tap to retry.")];
        return;
    }
    NSData *search = [MxPurgeCodec makeSearchForPeer:ctx.peerData offset:0 limit:80];
    [self send:search service:ctx.service done:^(NSData *response, NSString *error) {
        if (![self stillCurrent:ctx]) { [self finish:ctx fully:NO detail:@""]; return; }
        NSDictionary *result = error ? nil : [MxPurgeCodec searchResult:response];
        if (!result) { [self finish:ctx fully:NO detail:error]; return; }
        NSArray<NSNumber *> *ids = result[@"ids"];
        if (!ids.count && [result[@"returned"] unsignedIntegerValue] > 0) {
            [self finish:ctx fully:NO detail:mxPurgeText(@"بعض الرسائل لا يمكن حذفها بهذه الطريقة.",
                                                         @"Some service messages cannot be deleted.")];
            return;
        }
        if (!ids.count) {
            // Search again after a brief settle period. A successful delete
            // request alone is NOT evidence that all messages are gone.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (![self stillCurrent:ctx]) { [self finish:ctx fully:NO detail:@""]; return; }
                NSData *check = [MxPurgeCodec makeSearchForPeer:ctx.peerData offset:0 limit:2];
                [self send:check service:ctx.service done:^(NSData *verified, NSString *checkError) {
                    NSDictionary *last = checkError ? nil : [MxPurgeCodec searchResult:verified];
                    BOOL clear = last && [last[@"ids"] count] == 0 &&
                                 [last[@"returned"] unsignedIntegerValue] == 0;
                    [self finish:ctx fully:clear detail:checkError];
                }];
            });
            return;
        }
        NSMutableArray *batch = [NSMutableArray arrayWithCapacity:ids.count];
        for (NSNumber *msg in ids) {
            if (![ctx.deletedIds containsObject:msg]) [batch addObject:msg];
        }
        if (!batch.count) {
            // Avoid repeatedly deleting the same IDs while search indexing
            // catches up. Do not paint green on a stale query.
            if (++ctx.repeatCount > 3) {
                [self finish:ctx fully:NO detail:mxPurgeText(@"التحديث على الخادم متأخر. حاول مجدداً.",
                                                             @"Server search has not caught up; retry.")];
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self purgeNext:ctx]; });
            return;
        }
        ctx.repeatCount = 0;
        NSData *deleteRequest = [MxPurgeCodec makeDeleteForPeer:ctx.peerData ids:batch];
        [self send:deleteRequest service:ctx.service done:^(NSData *resultData, NSString *deleteError) {
            if (![self stillCurrent:ctx]) { [self finish:ctx fully:NO detail:@""]; return; }
            if (deleteError || ![MxPurgeCodec deleteSucceeded:resultData]) {
                [self finish:ctx fully:NO detail:deleteError]; return;
            }
            [ctx.deletedIds addObjectsFromArray:batch];
            ctx.deletedCount += batch.count;
            // Respect API rate limits. Errors and timeouts stop the loop.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self purgeNext:ctx]; });
        }];
    }];
}
@end

void MxPurgeCaptureRequest(MTRequest *request, MTRequestMessageService *service) {
    [[MxPurgeManager shared] capture:request service:service];
}
void MxPurgeChatAppeared(UIViewController *controller) {
    [[MxPurgeManager shared] appeared:controller];
}
void MxPurgeChatDisappeared(UIViewController *controller) {
    [[MxPurgeManager shared] disappeared:controller];
}
void MxPurgeChatLayout(UIViewController *controller) {
    [[MxPurgeManager shared] layout:controller];
}
void MxPurgeSettingsChanged(void) {
    [[MxPurgeManager shared] settingsChanged];
}
