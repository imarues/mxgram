#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>
#import <roothide.h>
#import "../Constants.h"

@interface Mx : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

@interface TGLocalization : NSObject
- (NSString *)get:(NSString *)queryString;
- (id)initWithVersion:(int)a code:(id)b dict:(id)c isActive:(BOOL)d;
@end

@interface MxLocalization  : NSObject
@property (nonatomic, strong ) TGLocalization *localization;
+ (instancetype)shared;
+ (NSString *)localizedStringForKey:(NSString *)key;
@end

// Returns the path to Kira.bundle regardless of installation method.
// Works on jailbreak, SwiftGram, AltStore, and any sideloaded IPA.
// Both MxLocalization and LanguageSelector must use this function.
NSString *MxBundlePath(void);

// Defined in UIHooks.xm, which Theos compiles as Objective-C++. Without this
// the names come out mangled and plain .m callers fail to link.
#ifdef __cplusplus
extern "C" {
#endif

// Brief message floating above the bottom of the key window. Safe to call from
// any thread; it hops to main itself.
void MxShowToast(NSString *text);

// Opens a tg:// link inside *this* app.
//
// -[UIApplication openURL:] hands the scheme to whichever app iOS has it
// registered to, which on a device with official Telegram installed means the
// link leaves the fork the tweak is running in. Handing the URL straight to
// this app's own delegate keeps it here.
void MxOpenTelegramURL(NSURL *url);

#ifdef __cplusplus
}
#endif


@interface LanguageSelector : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

@interface MxDownloadBoost : NSObject
+ (void)install;
@end

@interface LocationSelector : UIViewController <MKMapViewDelegate>
@end

