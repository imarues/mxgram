#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
@class MTRequest;
@class MTRequestMessageService;

// Wire-only: identify authenticated peer/request service. No requests sent
// without explicit user confirmation in that exact currently visible chat.
void MxPurgeCaptureRequest(MTRequest *request, MTRequestMessageService *service);
void MxPurgeChatAppeared(UIViewController *controller);
void MxPurgeChatDisappeared(UIViewController *controller);
void MxPurgeSettingsChanged(void);
