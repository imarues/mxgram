#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
@class MTRequest;
@class MTRequestMessageService;

// Native-selection-only integration. The legacy request capture symbol remains
// for hook compatibility but never sends or decodes deletion RPCs.
#ifdef __cplusplus
extern "C" {
#endif
void MxPurgeCaptureRequest(MTRequest *request, MTRequestMessageService *service);
void MxPurgeChatAppeared(UIViewController *controller);
void MxPurgeChatDisappeared(UIViewController *controller);
void MxPurgeChatLayout(UIViewController *controller);
void MxPurgeSettingsChanged(void);
#ifdef __cplusplus
}
#endif
