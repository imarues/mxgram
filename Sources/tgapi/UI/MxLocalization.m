#import "EmbeddedLangs.h"
#import "Headers.h"
#import <dlfcn.h>
#import <objc/runtime.h>

// ============================================================
// MxBundlePath() — shared function used by MxLocalization
// and LanguageSelector to find Kira.bundle.
//
// Search order:
//  1. Next to the dylib via dladdr (covers Frameworks/ layout)
//  2. Parent of dylib directory (app bundle root)
//  3. Two levels up (some nested layouts)
//  4. Classic jailbreak path via jbroot()
//  5. NSBundle.mainBundle.bundlePath (IPA embed)
//  6. NSBundle.mainBundle.resourcePath (fallback)
// ============================================================
NSString *MxBundlePath(void) {
  static NSString *cachedPath = nil;
  static dispatch_once_t token;
  dispatch_once(&token, ^{
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1. Fallback to dylib-relative path (dladdr)
    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (dladdr((const void *)MxBundlePath, &info) && info.dli_fname) {
      NSString *dylibPath = [NSString stringWithUTF8String:info.dli_fname];
      NSString *dylibDir = [dylibPath stringByDeletingLastPathComponent];

      NSArray *candidates = @[
        [dylibDir stringByAppendingPathComponent:@"Kira.bundle"],
        [[dylibDir stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"Kira.bundle"],
        [[[dylibDir stringByDeletingLastPathComponent]
            stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"Kira.bundle"]
      ];

      for (NSString *c in candidates) {
        if ([fm fileExistsAtPath:c]) {
          cachedPath = c;
          return;
        }
      }
    }

    // 2. Classic jailbreak path
    NSString *jbPath = [NSString
        stringWithFormat:@"%@/Kira.bundle",
                         jbroot(@"/Library/Application Support/Kira")];
    if ([fm fileExistsAtPath:jbPath]) {
      cachedPath = jbPath;
      return;
    }

    // 3. Final desperate scan in the main bundle's subdirectories
    NSString *bundlePath = [NSBundle mainBundle].bundlePath;
    NSArray *subDirs = @[ @"Kira.bundle", @"Frameworks/Kira.bundle" ];
    for (NSString *sub in subDirs) {
      NSString *path = [bundlePath stringByAppendingPathComponent:sub];
      if ([fm fileExistsAtPath:path]) {
        cachedPath = path;
        return;
      }
    }
  });
  return cachedPath;
}

// Private interface to store our own strings dict
@interface MxLocalization ()
@property(nonatomic, strong) NSDictionary *strings;
@end

@implementation MxLocalization

+ (instancetype)shared {
  static MxLocalization *instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    instance = [MxLocalization new];
    [instance loadDefault];
  });
  return instance;
}

// Which of the ten languages Mx ships comes closest to what the device is set
// to, or nil when none does.
//
// This only ever decides the *initial* value. Once someone picks a language in
// the tweak it is written to MxLanguage and this is never consulted again — an
// explicit choice outranks a guess, which is the whole point.
//
// It matters most for the one screen a user cannot come back to: the first-run
// alert that explains how to open the tweak at all. Defaulting that to English
// meant its translations were written for a screen nobody would ever see them
// on, since MxLanguage is by definition unset the first time it appears.
static NSString *MxLanguageMatchingDevice(void) {
  NSString *preferred = [NSLocale preferredLanguages].firstObject;
  if (preferred.length == 0) return nil;
  NSString *tag = [preferred lowercaseString];

  // Chinese first: the script matters more than the region, and the region is
  // not always there to read (zh-Hans, zh-Hant-TW, zh-HK).
  if ([tag hasPrefix:@"zh"]) {
    BOOL traditional = [tag containsString:@"hant"] || [tag containsString:@"tw"] ||
                       [tag containsString:@"hk"] || [tag containsString:@"mo"];
    return traditional ? @"tw" : @"cn";
  }

  // Everything else keys off the base subtag. Mx spells Vietnamese "vn", which
  // is not the ISO code the system reports.
  NSString *base = [tag componentsSeparatedByString:@"-"].firstObject;
  if ([base isEqualToString:@"vi"]) return @"vn";
  NSArray *shipped = @[ @"ar", @"ja", @"en", @"es", @"it", @"ru", @"fr" ];
  return [shipped containsObject:base] ? base : nil;
}

- (void)loadDefault {
  NSString *lang =
      [[NSUserDefaults standardUserDefaults] stringForKey:@"MxLanguage"]
          ?: MxLanguageMatchingDevice() ?: @"en";

  NSDictionary *dict = GetAllTranslations(lang);
  if (!dict || dict.count == 0) {
    // Unknown language code — reset to English so next launch doesn't repeat
    [[NSUserDefaults standardUserDefaults] setObject:@"en"
                                              forKey:@"MxLanguage"];
    lang = @"en";
    dict = GetAllTranslations(@"en");
  }

  self.strings = dict;

  if (dict && dict.count > 0) {
    self.localization =
        [[objc_getClass("TGLocalization") alloc] initWithVersion:96929692
                                                            code:lang
                                                            dict:dict
                                                        isActive:NO];
  }
}

+ (NSString *)localizedStringForKey:(NSString *)key {
  if (!key)
    return nil;

  // 1. Direct dict lookup from loaded bundle file — always most accurate
  NSString *result = [MxLocalization shared].strings[key];
  if (result)
    return result;

  // 2. Fallback to TGLocalization wrapper
  result = [[MxLocalization shared].localization get:key];
  if (result && ![result isEqualToString:key])
    return result;

  // 3. Hardcoded English fallback — guarantees readable UI even without a
  // bundle
  static NSDictionary *sBuiltinEnglish = nil;
  static dispatch_once_t sOnce;
  dispatch_once(&sOnce, ^{
    sBuiltinEnglish = @{
      /* Round video notes: safe fallback for languages not yet translated */
      @"VIDEO_TO_NOTE_ON_TOAST" : @"This video will be sent as a circular video note",
      @"VIDEO_TO_NOTE_OFF_TOAST" : @"Sending as a normal video again",
      @"VIDEO_TO_NOTE_CONVERTING" : @"Converting video to a round video note…",
      @"VIDEO_TO_NOTE_SUCCESS" : @"Round video ready — sending",
      @"VIDEO_TO_NOTE_FAILED" : @"Could not convert video — sending the original video instead",
      /* Sections */
      @"GHOST_MODE_SECTION_HEADER" : @"Ghost Mode",
      @"READ_RECEIPT_SECTION_HEADER" : @"Read Receipts",
      @"MISC_SECTION_HEADER" : @"Privacy & Extras",
      @"FILE_FIXER_SECTION_HEADER" : @"File Picker Fix",
      @"FAKE_LOCATION_SECTION_HEADER" : @"Fake Location",
      @"LANGUAGE_SECTION_HEADER" : @"Language",
      @"CREDITS_SECTION_HEADER" : @"Credits",
      /* Ghost Mode */
      @"DISABLE_ONLINE_STATUS_TITLE" : @"Hide Online Status",
      @"DISABLE_ONLINE_STATUS_SUBTITLE" :
          @"Prevent others from seeing when you are online. Applies to this "
          @"device only — your other logged-in sessions still report you as "
          @"online.",
      @"DISABLE_TYPING_STATUS_TITLE" : @"Hide Typing Status",
      @"DISABLE_TYPING_STATUS_SUBTITLE" :
          @"Hide the 'typing…' indicator when composing a message.",
      @"DISABLE_RECORDING_VIDEO_STATUS_TITLE" : @"Hide Recording Video Status",
      @"DISABLE_RECORDING_VIDEO_STATUS_SUBTITLE" :
          @"Hide the indicator when recording a video.",
      @"DISABLE_UPLOADING_VIDEO_STATUS_TITLE" : @"Hide Uploading Video Status",
      @"DISABLE_UPLOADING_VIDEO_STATUS_SUBTITLE" :
          @"Hide the indicator when uploading a video.",
      @"DISABLE_VC_MESSAGE_RECORDING_STATUS_TITLE" :
          @"Hide Voice Recording Status",
      @"DISABLE_VC_MESSAGE_RECORDING_STATUS_SUBTITLE" :
          @"Hide the indicator when recording a voice message.",
      @"DISABLE_VC_MESSAGE_UPLOADING_STATUS_TITLE" :
          @"Hide Voice Uploading Status",
      @"DISABLE_VC_MESSAGE_UPLOADING_STATUS_SUBTITLE" :
          @"Hide the indicator when uploading a voice message.",
      @"DISABLE_UPLOADING_PHOTO_STATUS_TITLE" : @"Hide Uploading Photo Status",
      @"DISABLE_UPLOADING_PHOTO_STATUS_SUBTITLE" :
          @"Hide the indicator when uploading a photo.",
      @"DISABLE_UPLOADING_FILE_STATUS_TITLE" : @"Hide Uploading File Status",
      @"DISABLE_UPLOADING_FILE_STATUS_SUBTITLE" :
          @"Hide the indicator when uploading a file.",
      @"DISABLE_CHOOSING_LOCATION_STATUS_TITLE" :
          @"Hide Choosing Location Status",
      @"DISABLE_CHOOSING_LOCATION_STATUS_SUBTITLE" :
          @"Hide the indicator when choosing a location to share.",
      @"DISABLE_CHOOSING_CONTACT_TITLE" : @"Hide Choosing Contact Status",
      @"DISABLE_CHOOSING_CONTACT_SUBTITLE" :
          @"Hide the indicator when selecting a contact to share.",
      @"DISABLE_PLAYING_GAME_STATUS_TITLE" : @"Hide Playing Game Status",
      @"DISABLE_PLAYING_GAME_STATUS_SUBTITLE" :
          @"Hide the indicator when playing an inline game.",
      @"DISABLE_RECORDING_ROUND_VIDEO_STATUS_TITLE" :
          @"Hide Recording Round Video Status",
      @"DISABLE_RECORDING_ROUND_VIDEO_STATUS_SUBTITLE" :
          @"Hide the indicator when recording a round video message.",
      @"DISABLE_UPLOADING_ROUND_VIDEO_STATUS_TITLE" :
          @"Hide Uploading Round Video Status",
      @"DISABLE_UPLOADING_ROUND_VIDEO_STATUS_SUBTITLE" :
          @"Hide the indicator when uploading a round video message.",
      @"DISABLE_SPEAKING_IN_GROUP_CALL_STATUS_TITLE" :
          @"Hide Speaking in Group Call Status",
      @"DISABLE_SPEAKING_IN_GROUP_CALL_STATUS_SUBTITLE" :
          @"Hide the indicator when speaking in a group call.",
      @"DISABLE_CHOOSING_STICKER_STATUS_TITLE" :
          @"Hide Choosing Sticker Status",
      @"DISABLE_CHOOSING_STICKER_STATUS_SUBTITLE" :
          @"Hide the indicator when picking a sticker.",
      @"DISABLE_EMOJI_INTERACTION_STATUS_TITLE" :
          @"Hide Emoji Interaction Status",
      @"DISABLE_EMOJI_INTERACTION_STATUS_SUBTITLE" :
          @"Hide the indicator when interacting with emoji.",
      @"DISABLE_EMOJI_ACKNOWLEDGEMENT_STATUS_TITLE" :
          @"Hide Emoji Reaction Status",
      @"DISABLE_EMOJI_ACKNOWLEDGEMENT_STATUS_SUBTITLE" :
          @"Hide the indicator when reacting with emoji to a message.",
      /* Read Receipts */
      @"READ_RECEIPTS" : @"Read Receipts",
      @"DISABLE_MESSAGE_READ_RECEIPT_TITLE" : @"Disable Message Read Receipts",
      @"DISABLE_MESSAGE_READ_RECEIPT_SUBTITLE" :
          @"Others won't see that you've read their messages.",
      @"DISABLE_STORY_READ_RECEIPT_TITLE" : @"Disable Story View Receipts",
      @"DISABLE_STORY_READ_RECEIPT_SUBTITLE" :
          @"Others won't see that you've viewed their stories.",
      /* Privacy & Extras */
      @"MISC" : @"Privacy & Extras",
      @"DISABLE_ALL_ADS_TITLE" : @"Disable All Ads",
      @"DISABLE_ALL_ADS_SUBTITLE" :
          @"Remove sponsored messages and promotional content from the app.",
      @"ENABLE_SAVING_PROTECTED_CONTENT_TITLE" : @"Save Restricted Media",
      @"ENABLE_SAVING_PROTECTED_CONTENT_SUBTITLE" :
          @"Bypass forwarding restrictions — save and forward media from "
          @"protected chats and channels.",
      @"ANTI_REVOKE_TITLE" : @"Save Deleted Messages",
      @"ANTI_REVOKE_SUBTITLE" :
          @"Keep messages in your chat even after the sender deletes them. "
          @"Deleted messages stay visible to you.",
      @"ANTI_EDIT_TITLE" : @"Save Original Edited Messages",
      @"ANTI_EDIT_SUBTITLE" :
          @"Keeps every version of a message someone edits. The chat still "
          @"shows the latest text; tap the pencil on the bubble to read what "
          @"was written before.",
      @"ANTI_SCREENSHOT_TITLE" : @"Disable Screenshot Notifications",
      @"ANTI_SCREENSHOT_SUBTITLE" :
          @"Take screenshots in secret chats and protected channels without "
          @"sending a notification to the other person.",
      @"ANTI_SELF_DESTRUCT_TITLE" : @"View Disappearing Media Freely",
      @"ANTI_SELF_DESTRUCT_SUBTITLE" :
          @"Open one-time and disappearing photos/videos without triggering "
          @"the self-destruct timer. The media stays visible locally.",
      @"ANTI_AUTO_DELETE_TITLE" : @"Save Auto-Delete Messages",
      @"ANTI_AUTO_DELETE_SUBTITLE" :
          @"Prevent messages in chats with auto-delete (1 day, 7 days, etc.) "
          @"from being deleted. Messages stay visible even after the timer "
          @"expires.",
      /* Download Speed Boost */
      @"DOWNLOAD_BOOST_SECTION_HEADER" : @"Download Speed",
      @"DOWNLOAD_BOOST_TITLE" : @"Download Speed Boost",
      @"DOWNLOAD_BOOST_SUBTITLE" : @"Increases chunk size and parallel connections for faster file downloads. Medium is recommended for most users.",
      @"DOWNLOAD_BOOST_OFF" : @"Off (Default)",
      @"DOWNLOAD_BOOST_MEDIUM" : @"Medium (512 KB / 8 parts)",
      @"DOWNLOAD_BOOST_MAX" : @"Maximum (1 MB / 12 parts)",
      /* Calls & Voice */
      @"CONFIRM_CALLS_TITLE" : @"Confirm Calls",
      @"CONFIRM_CALLS_SUBTITLE" : @"Show a confirmation dialog before answering incoming calls.",
      @"SEND_AS_VOICE_TITLE" : @"Send Audio as Voice Message",
      @"SEND_AS_VOICE_SUBTITLE" : @"Audio files you send will appear as voice bubbles instead of file attachments.",
      @"EDIT_HISTORY_TITLE" : @"Edit History",
      @"EDIT_HISTORY_ORIGINAL" : @"Original:",
      @"EDIT_HISTORY_EDIT" : @"Edit",
      @"EDIT_HISTORY_COPY_LATEST" : @"Copy Latest Version",
      @"CLOSE" : @"Close",
      @"VIDEO_TO_VOICE_TITLE" : @"Video to Voice",
      @"VIDEO_TO_VOICE_SUBTITLE" :
          @"Send only the sound of a picked video, as a real voice message. "
          @"Trim handles in the preview are respected, so just the selected "
          @"segment is sent. You can also flip this per video with the waveform "
          @"button in the top-left corner of the preview.",
      @"VIDEO_TO_VOICE_ON_TOAST" : @"This video will be sent as a voice message",
      @"VIDEO_TO_VOICE_OFF_TOAST" : @"Sending as a normal video again",
      @"VIDEO_TO_VOICE_EXTRACTING" : @"Extracting audio…",
      @"VIDEO_TO_VOICE_SUCCESS" : @"Audio ready — sending",
      @"VIDEO_TO_VOICE_FAILED" : @"Could not extract audio — sending the video instead",
      @"VIDEO_TO_VOICE_NO_AUDIO" : @"This video has no sound — sending the video instead",
      /* Custom Stars */
      @"CUSTOM_STARS_TITLE" : @"Custom Stars Balance",
      @"CUSTOM_STARS_SUBTITLE" :
          @"Show any Stars balance you like. Display only — the server keeps "
          @"its own count, so nothing you buy with it goes through.",
      @"CUSTOM_STARS_ACTIVE" : @"Showing %lld Stars",
      @"CUSTOM_STARS_PROMPT" : @"How many Stars should be displayed?",
      @"CUSTOM_STARS_RESET" : @"Show the real balance",
      @"DOWNLOAD_STORIES_TITLE" : @"Auto-Save Stories",
      @"DOWNLOAD_STORIES_SUBTITLE" : @"Automatically save stories to your camera roll when you open them.",
      @"HIDE_STORIES_TITLE" : @"Hide Stories Bar",
      @"HIDE_STORIES_SUBTITLE" : @"Remove the stories row from the top of your chats list.",
      /* File Picker */
      @"FIX_FILE_PICKER_TITLE" : @"Fix File Picker",
      @"FIX_FILE_PICKER_SUBTITLE" :
          @"Fixes the issue where you can't pick files from the Files app on "
          @"sideloaded versions.",
      @"CLEAR_FILE_PICKER_CACHE_TITLE" : @"Clear File Picker Cache",
      @"CLEAR_FILE_PICKER_CACHE_SUBTITLE" :
          @"File Picker copies files to a temp directory. Tap here to clear "
          @"that cache and free up storage.",
      @"CACHE_CLEAR_WARNING_TITLE" : @"Confirm",
      @"CACHE_CLEAR_WARNING_MESSAGE" :
          @"Are you sure you want to clear the file picker cache?",
      /* Fake Location */
      @"ENABLE_FAKE_LOCATION_TITLE" : @"Enable Location Spoofing",
      @"ENABLE_FAKE_LOCATION_SUBTITLE" :
          @"Override your device's GPS and share a custom location instead.",
      @"SELECT_FAKE_LOCATION_TITLE" : @"Select Fake Location",
      /* Common */
      @"APPLY" : @"Apply",
      @"APPLY_CHANGES" :
          @"The app will close and restart to apply your changes. Continue?",
      @"OK" : @"OK",
      @"CANCEL" : @"Cancel",
      @"SAVE" : @"Save",
      /* Ghost Exceptions */
      @"GHOST_EXCEPTIONS_SECTION_HEADER" : @"Ghost Exceptions",
      @"GHOST_EXCEPTIONS_SECTION_FOOTER" :
          @"These people still see your typing indicators and read receipts "
          @"while Ghost Mode stays on for everyone else. Online status is not "
          @"covered: Telegram sends it to everyone at once, so it cannot be "
          @"revealed to one person only.",
      @"GHOST_EXCEPTIONS_EMPTY_TITLE" : @"No exceptions yet",
      @"GHOST_EXCEPTIONS_EMPTY_SUBTITLE" :
          @"Open someone's profile and tap the eye button in the top-right "
          @"corner to add them.",
      @"GHOST_EXCEPTIONS_RENAME_TITLE" : @"Rename",
      @"GHOST_EXCEPTIONS_RENAME_MESSAGE" :
          @"Choose the name shown in this list. Leave empty to use the profile "
          @"name.",
      @"GHOST_EXCEPTION_ADDED_TOAST" :
          @"Ghost Exception added — this person sees your real activity",
      @"GHOST_EXCEPTION_REMOVED_TOAST" :
          @"Ghost Exception removed — Ghost Mode applies again",
      @"GHOST_MODE_NEEDS_SUBFEATURE" :
          @"Please enable at least one feature in Advanced Settings first.",
      @"ANTI_EDIT_UNAVAILABLE_SUBTITLE" :
          @"Unavailable on this Telegram version — edit updates cannot be read "
          @"until the API layer is refreshed.",
      /* Disappearing media label */
      @"HIDE_DISAPPEARING_LABEL_TITLE" : @"Hide Disappearing Label",
      @"HIDE_DISAPPEARING_LABEL_SUBTITLE" :
          @"Stop prepending the \"dissapearing message\" marker to intercepted "
          @"one-time media.",
      /* First-run alert. WELCOME_HOWTO_IME takes two substitutions, gift row
         first and support row second; the others take one or none. */
      @"WELCOME_BODY" : @"Kira is installed.\n\nTo open the Kira menu:\n%@",
      @"WELCOME_HOWTO" : @"Open Settings and long-press the \"%@\" row.",
      @"WELCOME_HOWTO_IME" :
          @"Open Settings and long-press the \"%@\" row.\n\nIn iMe the \"%@\" "
          @"row will not work — iMe opens its own menu on it.",
      @"WELCOME_HOWTO_TURRIT" :
          @"Open Settings and long-press the \"About Turrit\" row.",
      @"WELCOME_JOIN_CHANNEL" : @"Join Channel →",
      @"DISCLAIMER" : @"Disclaimer",
      @"AUTHOR_MESSAGE" :
          @"This Telegram tweak is for personal and educational use only. We "
          @"are not affiliated with Telegram in any way. All trademarks, "
          @"including the Telegram name and logo, belong to their respective "
          @"owners. Don't use this to break rules or violate Telegram's terms "
          @"— we're not responsible if things go sideways. Use at your own "
          @"risk.\n\nAlso… if you like it, say something. I seriously live off "
          @"validation.\n\nIf you want to support the project, feel free to "
          @"reach out on Telegram.",
    };
  });

  result = sBuiltinEnglish[key];
  return result ?: key;
}

@end
