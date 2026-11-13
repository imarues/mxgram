#import "Headers.h"
#include <zlib.h>

// Forward declaration — defined later in this file, used inside hooked_block
static NSData *neutralizePayload(NSData *data, BOOL antiRevoke,
                                 BOOL antiSelfDestruct);

// YES when any feature needs server responses rewritten before Telegram parses
// them.
//
// Every one of these routes through TLParser.stripAntiSelfDestruct, so the check
// has to list them all: gating on a single feature leaves the others switched on
// in the UI but never actually invoked.
static BOOL mxNeedsResponsePatching(void) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  // Which account this is running as is learned from the `self` flag on a users
  // vector, and that vector only reaches TLParser through this hook. With every
  // feature switched off the hook was never installed, so the id stayed unknown
  // for the whole session — and the one thing that needs it, hiding the Ghost
  // Exception button on your own profile, silently compared against nothing.
  //
  // Self-limiting: the first users vector settles it and this term goes false.
  if ([defaults integerForKey:@"MxLastKnownUserId"] == 0) {
    return YES;
  }
  return [defaults boolForKey:kDisableForwardRestriction] ||
         [defaults boolForKey:kAntiSelfDestruct] ||
         [defaults boolForKey:kAntiEdit] ||
         [defaults boolForKey:kAntiRevoke];
}

#define kChannelsReadHistory -871347913

%hook MTRequest %property(nonatomic, strong) NSData *fakeData;
%property(nonatomic, strong) NSNumber *functionID;

- (void)setPayload:(NSData *)payload
          metadata:(id)metadata
     shortMetadata:(id)shortMetadata
    responseParser:(id (^)(NSData *))responseParser {

  // Extract Function id
  int32_t functionID;
  [payload getBytes:&functionID length:4];
  self.functionID = [NSNumber numberWithInt:functionID];

  // Video to Voice: the audio is already extracted and uploading by now, but
  // Telegram described it as a plain document. Give it the voice attribute and
  // the measured waveform before the request goes out — nothing later in the
  // pipeline can still change what the recipient receives.
  if (functionID == kMessagesSendMedia || functionID == kMessagesSendMultiMedia ||
      functionID == kMessagesUploadMedia) {
    NSData *asVoice = [TLParser rewriteVoiceUpload:payload];
    if (asVoice) {
      customLog2(@"[Kira] rewrote outgoing media as voice or round video note");
      payload = asVoice;
    }
  }

  id (^hooked_block)(NSData *) = ^(NSData *inputData) {
    NSNumber *functionIDNumber = [NSNumber numberWithUnsignedInt:functionID];
    NSData *parsed =
        [TLParser handleResponse:inputData functionID:functionIDNumber];
    NSData *toUse = parsed ?: inputData;

    // Strip noforwards from request responses (messages.getHistory, etc.)
    // so the save/forward button appears for newly fetched restricted messages.
    if ([[NSUserDefaults standardUserDefaults]
            boolForKey:kDisableForwardRestriction]) {
      NSData *cleared = neutralizePayload(toUse, NO, NO);
      if (cleared)
        toUse = cleared;
    }

    return responseParser(toUse);
  };

  switch (functionID) {
  case kAccountUpdateOnlineStatus:
    handleOnlineStatus(self, payload);
    break;
  case kMessagesSetTypingAction:
    handleSetTyping(self, payload);
    break;
  case kMessagesReadHistory:
    handleMessageReadReceipt(self, payload);
    break;
  case kStoriesReadStories:
    handleStoriesReadReceipt(self, payload);
    break;
  case kGetSponsoredMessages:
    handleGetSponsoredMessages(self, payload);
    break;
  case kChannelsReadHistory:
    handleChannelsReadReceipt(self, payload);
    break;
  case kSendScreenshotNotification:
    handleSendScreenshotNotification(self, payload);
    break;
  case kMessagesReadMessageContents:
    handleReadMessageContents(self, payload);
    break;
  default:
    break;
  }

  if (mxNeedsResponsePatching()) {
    %orig(payload, metadata, shortMetadata, hooked_block);
  } else {
    %orig(payload, metadata, shortMetadata, responseParser);
  }
}

%end

        // Manager which handles requests
        %hook MTRequestMessageService

    - (void)addRequest : (MTRequest *)request {
  if (request.fakeData) {
    @try {
      if (request.completed) {
        NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];

        MTRequestResponseInfo *info = [[%c(MTRequestResponseInfo)
            alloc] initWithNetworkType:1 timestamp:currentTime duration:0.045];

        id result = request.responseParser(request.fakeData);
        request.completed(result, info, nil);
      }
    } @catch (NSException *exception) {
      customLog2(@"Exception in MTRequestMessageService hook: %@", exception);
    }
    return;
  }
  %orig;
}

%end

        // ============================================================
        // Screenshot Protection Bypass
        // Telegram overlays a hidden UITextField with secureTextEntry=YES
        // which causes iOS to black out the screen during screenshots.
        // We hook setSecureTextEntry: and _setSecureContents: to prevent this.
        // ============================================================

        %hook UITextField

    - (void)setSecureTextEntry : (BOOL)enabled {
  if (enabled && [[NSUserDefaults standardUserDefaults]
                     boolForKey:kDisableScreenshotNotification]) {
    %orig(NO);
    return;
  }
  %orig;
}

%end

        %hook UIView

    // iOS 16+ uses _setSecureContents: instead of UITextField trick
    - (void)_setSecureContents : (BOOL)secure {
  if ([[NSUserDefaults standardUserDefaults]
          boolForKey:kDisableScreenshotNotification]) {
    return; // noop — allow screenshots
  }
  %orig;
}

%end

// ============================================================
// Anti-Revoke: block incoming delete-message updates from server.
// Strategy: Replace the update constructor word with an unknown
// dummy value (0x00000001) so Telegram discards the entire update.
// Zeroing IDs is unreliable — killing the constructor is definitive.
//
// updateDeleteMessages       constructor: -1576161051 (0xA20DB722)
// updateDeleteChannelMessages constructor: -1020437742 (0xC37521C9)
// ============================================================

#define kUpdateDeleteMessages -1576161051
#define kUpdateDeleteChannelMessages -1020437742

#define kUpdateEditMessage -469536605
#define kUpdateEditChannelMessage 457133559

#define kMessageConstructor -356721331
#define kChatConstructor 1103884886
#define kChannelConstructor 1954681982

#define kVectorConstructor 481674261

// Dummy constructor Telegram will not recognize — causes update to be silently
// skipped
#define kDummyConstructor 0x00000001

// gzip_packed#3072cfa1 — Telegram wraps large updates in gzip to save bandwidth
#define kGzipPackedCtor ((int32_t)0x3072CFA1)

    // ============================================================
    // decompressGzip — inflate a raw gzip/zlib byte stream.
    // Returns decompressed NSData, or nil on failure.
    // ============================================================

    static NSData *neutralizePayload(NSData *data, BOOL antiRevoke,
                                     BOOL antiSelfDestruct) {
  if (!data || data.length < 8)
    return nil;

  // Handle gzip_packed: Telegram compresses large updates to save bandwidth.
  // Decompress, patch inside, return the raw (uncompressed) data so MtProtoKit
  // can still parse it — it accepts raw TL objects regardless of prior
  // compression.
  {
    int32_t top4 = 0;
    memcpy(&top4, data.bytes, 4);
    if (top4 == kGzipPackedCtor && data.length >= 8) {
      const uint8_t *b = (const uint8_t *)data.bytes;
      uint32_t offset = 4;
      uint32_t gzipLen = 0;
      uint8_t first = b[offset];
      if (first < 0xFE) {
        gzipLen = first;
        offset += 1;
      } else if (first == 0xFE && data.length > offset + 3) {
        gzipLen = (uint32_t)b[offset + 1] | ((uint32_t)b[offset + 2] << 8) |
                  ((uint32_t)b[offset + 3] << 16);
        offset += 4;
      }
      if (gzipLen > 0 && offset + gzipLen <= data.length) {
        NSData *inner = decompressGzip(b + offset, gzipLen);
        NSData *patched = neutralizePayload(inner, antiRevoke,
                                            antiSelfDestruct);
        // Return the raw decompressed+patched TL — MtProtoKit handles it fine
        return patched ? patched : nil;
      }
    }
  }

  if (data.length < 16)
    return nil;

  BOOL modified = NO;
  NSMutableData *mData = [NSMutableData dataWithData:data];
  uint8_t *bytes = (uint8_t *)mData.mutableBytes;
  NSUInteger len = mData.length;

  int32_t top_w = 0;
  memcpy(&top_w, bytes, 4);
  // DO NOT scan file blobs (upload.file, upload.cdnFile, etc.) to prevent false
  // positives in binary media.
  if (top_w == 157948117 || top_w == -242427324 || top_w == -1449145777 ||
      top_w == 568808380 || top_w == -290921362) {
    return nil;
  }

  for (NSUInteger i = 0; i + 8 <= len; i += 4) {
    int32_t w = 0;
    memcpy(&w, bytes + i, 4);

    // 1. Anti-Revoke & Anti-Self-Destruct: updateDeleteMessages#A20DB0E5
    // Layout: [ctor:4][vecCtor:4][count
    // N:4][id1:4]...[idN:4][pts:4][ptsCount:4] Fix: zero ALL message IDs (keep
    // count=N, pts, ptsCount intact). Telegram processes "delete messages
    // [0,0,...]" — ID 0 never exists → no-op. TL structure is completely
    // preserved, no parse failure, no re-fetch.
    if ((antiRevoke || antiSelfDestruct) && w == kUpdateDeleteMessages &&
        i + 12 <= len) {
      int32_t vec = 0;
      memcpy(&vec, bytes + i + 4, 4);
      if (vec == kVectorConstructor) {
        int32_t count = 0;
        memcpy(&count, bytes + i + 8, 4);
        if (count > 0 && count <= 65536) {
          NSUInteger idsEnd = i + 12 + (NSUInteger)count * 4;
          if (idsEnd <= len) {
            NSMutableArray *deletedIdsArr = [NSMutableArray array];
            // Save original IDs so the bubble can draw its trash icon on the
            // next load.
            // updateDeleteMessages carries no peer, and needs none: it covers
            // private chats and basic groups, whose ids all come from one
            // per-account sequence. 0 is the key for that sequence.
            for (int32_t k = 0; k < count; k++) {
              int32_t origId = 0;
              memcpy(&origId, bytes + i + 12 + k * 4, 4);
              [NSClassFromString(@"TLParser") addDeletedId:origId peer:0];
              [deletedIdsArr addObject:@(origId)];
            }
            if (antiRevoke) {
              if (deletedIdsArr.count > 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                  [[NSNotificationCenter defaultCenter]
                      postNotificationName:@"MxMessageDeletedRealtime"
                                    object:nil
                                  userInfo:@{@"ids" : deletedIdsArr}];
                });
              }
              memset(bytes + i + 12, 0, (NSUInteger)count * 4);
              modified = YES;
            } else if (antiSelfDestruct) {
              for (int32_t k = 0; k < count; k++) {
                int32_t origId = 0;
                memcpy(&origId, bytes + i + 12 + k * 4, 4);
                if ([NSClassFromString(@"TLParser")
                        isMessageSelfDestructing:@(origId)]) {
                  int32_t zero = 0;
                  memcpy(bytes + i + 12 + k * 4, &zero, 4);
                  modified = YES;
                }
              }
            }
          }
        }
      }
    }
    // Anti-Revoke & Anti-Self-Destruct: updateDeleteChannelMessages#C32D5B12
    // Layout: [ctor:4][channelId:8][vecCtor:4][count
    // N:4][ids][pts:4][ptsCount:4]
    else if ((antiRevoke || antiSelfDestruct) &&
             w == kUpdateDeleteChannelMessages && i + 20 <= len) {
      int32_t vec = 0;
      memcpy(&vec, bytes + i + 12, 4);
      if (vec == kVectorConstructor) {
        int32_t count = 0;
        memcpy(&count, bytes + i + 16, 4);
        if (count > 0 && count <= 65536) {
          NSUInteger idsEnd = i + 20 + (NSUInteger)count * 4;
          if (idsEnd <= len) {
            NSMutableArray *deletedIdsArr = [NSMutableArray array];
            // This one does name its channel — channel_id sits right after the
            // constructor. Channel numbering restarts per peer, so without it
            // the icon lands on whatever else shares the number.
            int64_t channelId = 0;
            memcpy(&channelId, bytes + i + 4, 8);
            int64_t channelPeer = -(1000000000000LL + channelId);
            for (int32_t k = 0; k < count; k++) {
              int32_t origId = 0;
              memcpy(&origId, bytes + i + 20 + k * 4, 4);
              [NSClassFromString(@"TLParser") addDeletedId:origId peer:channelPeer];
              [deletedIdsArr addObject:@(origId)];
            }
            if (antiRevoke) {
              if (deletedIdsArr.count > 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                  [[NSNotificationCenter defaultCenter]
                      postNotificationName:@"MxMessageDeletedRealtime"
                                    object:nil
                                  userInfo:@{@"ids" : deletedIdsArr}];
                });
              }
              memset(bytes + i + 20, 0, (NSUInteger)count * 4);
              modified = YES;
            } else if (antiSelfDestruct) {
              for (int32_t k = 0; k < count; k++) {
                int32_t origId = 0;
                memcpy(&origId, bytes + i + 20 + k * 4, 4);
                if ([NSClassFromString(@"TLParser")
                        isMessageSelfDestructing:@(origId)]) {
                  int32_t zero = 0;
                  memcpy(bytes + i + 20 + k * 4, &zero, 4);
                  modified = YES;
                }
              }
            }
          }
        }
      }
    }
  }

  return modified ? mData : nil;
}

// ============================================================
// MTProto.parseMessage: receives raw TL bytes BEFORE the Swift
// API layer parses them into objects. This is the correct hook
// point for push updates (deleteMessages, editMessage, noforwards)
// because by the time MTIncomingMessage is created the body is
// already a pre-parsed ObjC/Swift object — not NSData.
// ============================================================
%hook MTProto

    - (id)parseMessage : (NSData *)data {
  if (data && data.length >= 4) {
    int32_t ctor = 0;
    memcpy(&ctor, data.bytes, 4);
    // customLog2(@"[Kira] parseMessage: len=%lu ctor=0x%08X", (unsigned
    // long)data.length, (uint32_t)ctor);

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL antiRevoke = [defaults boolForKey:kAntiRevoke];
    BOOL antiSelfDestruct = [defaults boolForKey:kAntiSelfDestruct];
    BOOL modified = NO;

    if (antiRevoke || antiSelfDestruct) {
      NSData *modifiedData = neutralizePayload(
          data, antiRevoke, antiSelfDestruct);
      if (modifiedData) {
        customLog2(@"[Kira] parseMessage: NEUTRALIZED (antiRevoke=%d "
                   @"antiSelfDestruct=%d)",
                   antiRevoke, antiSelfDestruct);
        data = modifiedData;
        modified = YES;
      }
    }

    // Rewrite push updates: strips TTL/NoForwards, and restores the original
    // text of edited messages for Anti-Edit.
    if (mxNeedsResponsePatching()) {
      NSData *uncompressed = data;
      int32_t top4 = 0;
      memcpy(&top4, data.bytes, 4);
      if (top4 == kGzipPackedCtor && data.length >= 8) {
        const uint8_t *b = (const uint8_t *)data.bytes;
        uint32_t offset = 4;
        uint32_t gzipLen = 0;
        uint8_t first = b[offset];
        if (first < 0xFE) {
          gzipLen = first;
          offset += 1;
        } else if (first == 0xFE && data.length > offset + 3) {
          gzipLen = (uint32_t)b[offset + 1] | ((uint32_t)b[offset + 2] << 8) |
                    ((uint32_t)b[offset + 3] << 16);
          offset += 4;
        }
        if (gzipLen > 0 && offset + gzipLen <= data.length) {
          NSData *inner = decompressGzip(b + offset, gzipLen);
          if (inner)
            uncompressed = inner;
        }
      }

      NSData *strippedData =
          [NSClassFromString(@"TLParser") stripAntiSelfDestruct:uncompressed];
      if (strippedData) {
        customLog2(@"[Kira] parseMessage: STRIPPED SELF-DESTRUCT");
        data = strippedData;
        modified = YES;
      }
    }

    if (modified) {
      return %orig(data);
    }
  }
  return %orig;
}

%end

    %ctor {
  // Load persisted deleted-message IDs from UserDefaults into memory on launch.
  [TLParser loadPersistedIds];
}
