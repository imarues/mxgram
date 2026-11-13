#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../Constants.h"
#import "../Logger/Logger.h"

// ============================================================
// MxDownloadBoost
//
// Swiftgram modifies defaultPartSize and maxPendingParts at the
// Swift object level before TL serialization. We replicate this
// by finding the FetchingState init method at runtime and
// intercepting it to boost the parameters.
//
// FetchingState is a private nested class inside FetchImpl inside
// TelegramCore. Its mangled ObjC name contains a module hash that
// changes between Telegram builds, so we scan all registered
// classes at runtime to find it by name pattern.
//
// The init signature (from source):
//   initWithFetchLocation:partSize:minPartSize:maxPartSize:
//   partAlignment:partDivision:maxPendingParts:decryptionState:
// ============================================================

@interface MxDownloadBoost : NSObject
+ (void)install;
@end

typedef id (*FetchingStateInitIMP)(id, SEL, id, long long, long long, long long, long long, long long, int, id);
static FetchingStateInitIMP originalFetchingStateInit = NULL;

static id boostedFetchingStateInit(id self, SEL _cmd,
                                   id fetchLocation,
                                   long long partSize,
                                   long long minPartSize,
                                   long long maxPartSize,
                                   long long partAlignment,
                                   long long partDivision,
                                   int maxPendingParts,
                                   id decryptionState) {
    NSInteger boost = [[NSUserDefaults standardUserDefaults] integerForKey:kDownloadSpeedBoost];
    if (boost > 0 && partSize > 4096) {
        long long newPartSize = (boost == 1) ? 512 * 1024 : 1024 * 1024;
        int newPendingParts   = (boost == 1) ? 8 : 12;
        if (newPartSize > maxPartSize) newPartSize = maxPartSize;
        if (newPartSize < minPartSize) newPartSize = minPartSize;
        partSize       = newPartSize;
        maxPendingParts = newPendingParts;
    }
    return originalFetchingStateInit(self, _cmd, fetchLocation, partSize,
                                     minPartSize, maxPartSize, partAlignment,
                                     partDivision, maxPendingParts, decryptionState);
}

@implementation MxDownloadBoost

+ (void)install {
    // Scan all ObjC classes for FetchingState (private nested class in TelegramCore)
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) return;

    Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * classCount);
    classCount = objc_getClassList(classes, classCount);

    Class target = nil;
    for (int i = 0; i < classCount; i++) {
        const char *name = class_getName(classes[i]);
        if (!name) continue;
        // Looking for something like _TtCCC12TelegramCore9FetchImpl12FetchingState
        // or _TtCC12TelegramCore9FetchImpl12FetchingState
        if (strstr(name, "TelegramCore") &&
            strstr(name, "FetchImpl") &&
            strstr(name, "FetchingState")) {
            target = classes[i];
            customLog2(@"[Kira] Found FetchingState class: %s", name);
            break;
        }
    }
    free(classes);

    if (!target) {
        customLog2(@"[Kira] FetchingState class not found — boost unavailable");
        return;
    }

    // Find the init method — it has 8 parameters after self/cmd
    // Selector: initWithFetchLocation:partSize:minPartSize:maxPartSize:partAlignment:partDivision:maxPendingParts:decryptionState:
    SEL initSel = @selector(initWithFetchLocation:partSize:minPartSize:maxPartSize:partAlignment:partDivision:maxPendingParts:decryptionState:);
    Method m = class_getInstanceMethod(target, initSel);
    if (!m) {
        // Try finding any init method with the right number of args
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(target, &methodCount);
        for (unsigned int j = 0; j < methodCount; j++) {
            if (method_getNumberOfArguments(methods[j]) == 10) { // self + cmd + 8 params
                m = methods[j];
                customLog2(@"[Kira] Found init by arg count: %s", sel_getName(method_getName(m)));
                break;
            }
        }
        free(methods);
    }

    if (!m) {
        customLog2(@"[Kira] FetchingState init not found");
        return;
    }

    originalFetchingStateInit = (FetchingStateInitIMP)method_getImplementation(m);
    method_setImplementation(m, (IMP)boostedFetchingStateInit);
    customLog2(@"[Kira] Download boost installed on %s", class_getName(target));
}

@end
