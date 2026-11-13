#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#define kAccountUpdateOnlineStatus 1713919532
#define kMessagesSetTypingAction 1486110434
#define kMessagesReadHistory 238054714
#define kStoriesReadStories -1521034552
#define kGetSponsoredMessages -1680673735
#define kSendScreenshotNotification -1589618665
// messages.readMessageContents#36a73f77 — sent when TTL/disappearing media is
// opened
#define kMessagesReadMessageContents 917472119
// upload.getFile#be5335be / upload.getCdnFile#2000bcc3 — file chunk downloads
#define kUploadGetFile      -1101843010
#define kUploadGetCdnFile   -1691921240

// Outgoing media sends, rewritten by Video to Voice
#define kMessagesSendMedia 53536639
#define kMessagesSendMultiMedia 469278068
#define kMessagesUploadMedia 345405816

#define kActionIDTyping 381645902           // .sendMessageTypingAction
#define kActionIDRecordingVideo -1584933265 // .sendMessageRecordVideoAction
#define kActionIDUploadingVideo -378127636  // .sendMessageUploadVideoAction
#define kActionIDRecordingAudio -718310409  // .sendMessageRecordAudioAction
#define kActionIDUploadingVoice -212740181  // .sendMessageUploadAudioAction
#define kActionIDUploadingPhoto -774682074  // .sendMessageUploadPhotoAction
#define kActionIDUploadingFile -1441998364  // .sendMessageUploadDocumentAction
#define kActionIDChoosingLocation 393186209 // .sendMessageGeoLocationAction
#define kActionIDChoosingContact 1653390447 // .sendMessageChooseContactAction
#define kActionIDPlayingGame -580219064     // .sendMessageGamePlayAction
#define kActionIDRecordingRoundVideo                                           \
  -1997373508                                   // .sendMessageRecordRoundAction
#define kActionIDUploadingRoundVideo 608050278  // .sendMessageUploadRoundAction
#define kActionIDSpeakingInGroupCall -651419003 // .speakingInGroupCallAction
#define kActionIDReserverHistoryImport                                         \
  -606432698                                 // .sendMessageHistoryImportAction
#define kActionIDChoosingSticker -1336228175 // .sendMessageChooseStickerAction
#define kActionIDEmojiInteraction 630664139  // .sendMessageEmojiInteraction
#define kActionIDEmojiAcknowledgement                                          \
  -1234857938 // .sendMessageEmojiInteractionSeen

#define kGhostModeEnabled @"MxGhostModeEnabled"
#define kGhostDetailsToggle @"MxGhostDetailsToggle"
#define kDisableOnlineStatus @"disableOnlineStatus"

#define kDisableTypingStatus @"disableTypingStatus"
#define kDisableRecordingVideoStatus @"disableRecordingVideoStatus"
#define kDisableUploadingVideoStatus @"disableUploadingVideoStatus"
#define kDisableRecordingVoiceStatus @"disableRecordingVoiceStatus"
#define kDisableUploadingVoiceStatus @"disableUploadingVoiceStatus"
#define kDisableUploadingPhotoStatus @"disableUploadingPhotoStatus"
#define kDisableUploadingFileStatus @"disableUploadingFileStatus"
#define kDisableChoosingLocationStatus @"disableChoosingLocationStatus"
#define kDisableChoosingContactStatus @"disableChoosingContactStatus"
#define kDisablePlayingGameStatus @"disablePlayingGameStatus"
#define kDisableRecordingRoundVideoStatus @"disableRecordingRoundVideoStatus"
#define kDisableUploadingRoundVideoStatus @"disableUploadingRoundVideoStatus"
#define kDisableSpeakingInGroupCallStatus @"disableSpeakingInGroupCallStatus"
#define kDisableChoosingStickerStatus @"disableChoosingStickerStatus"
#define kDisableEmojiInteractionStatus @"disableEmojiInteractionStatus"
#define kDisableEmojiAcknowledgementStatus @"disableEmojiAcknowledgementStatus"

#define kDisableMessageReadReceipt @"disableMessageReadReceipt"
#define kDisableStoriesReadReceipt @"disableStoriesReadReceipt"
#define kDisableScreenshotNotification @"disableScreenshotNotification"

// FIX: was incorrectly mapped to "disableOnlineStatus" — now has its own key
#define kDisableAllAds @"disableAllAds"
#define kDisableForwardRestriction @"disableForwardRestriction"

// Anti-features
#define kAntiRevoke @"MxAntiRevoke"
#define kAntiEdit @"MxAntiEdit"
// Key for preventing disappearing/self-destruct media from being marked as read
#define kAntiSelfDestruct @"MxAntiSelfDestruct"
#define kAntiAutoDelete @"MxAntiAutoDelete"
#define kConfirmCalls @"MxConfirmCalls"
#define kHideStories @"MxHideStories"
#define kDownloadStories @"MxDownloadStories"

#define FAKE_LOCATION_ENABLED_KEY @"MxFakeLocation"
#define FAKE_LATITUDE_KEY @"MxSavedLatitude"
#define FAKE_LONGITUDE_KEY @"MxSavedLongitude"

#define FILE_PICKER_FIX_KEY @"MxFixFilePicker"
#define FILE_PICKER_PATH @"MxFileFixUsingSomeUglyHacks"

// Download speed boost: 0 = off, 1 = medium (512KB/8 parts), 2 = maximum (1MB/12 parts)
#define kDownloadSpeedBoost @"MxDownloadSpeedBoost"

// Send audio/video files as voice messages
#define kSendAsVoice @"MxSendAsVoice"

// Video to Voice: strip the video track off a picked video and send only its
// audio. Honours the trim handles set in the preview.
#define kVideoToVoice @"MxVideoToVoice"

// Send a picked video as a proper Telegram circular/round video message.
// Mutually exclusive with the Video to Voice preview toggle.
#define kVideoToNote @"MxVideoToNote"

// Ghost Exceptions: peers that keep seeing your real typing/read activity
// while Ghost Mode stays enabled for everyone else.
#define kGhostExceptions @"MxGhostExceptions"

// Hide the "dissapearing message" marker prepended to intercepted TTL media
#define kHideDisappearingLabel @"MxHideDisappearingLabel"

// Custom Stars balance. Display only: the number is swapped into the server's
// reply on the way in, so every screen agrees, and nothing you buy with it
// succeeds.
#define kCustomStarsEnabled @"MxCustomStarsEnabled"
#define kCustomStarsValue @"MxCustomStarsValue"

// The two addresses this tweak reaches out to. Kept here so both the settings
// screen and the first-run welcome alert open the same channel.
#define kKiraChannelURL @"https://t.me/iKiraPlus"
#define kKiraAnnouncementsURL                                                    \
  @"https://raw.githubusercontent.com/imarues/mxgram/main/announcements.json"
