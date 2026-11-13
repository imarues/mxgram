<p align="center">
  <img src="icon.png" width="160">
</p>

<h1 align="center">Kira</h1>

<p align="center">
  A native-feeling privacy & utility tweak for Telegram on iOS.
</p>

<p align="center">
  <b>English</b> ·
  <a href="README.vi.md">Tiếng Việt</a> ·
  <a href="README.zh.md">简体中文</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-1.0.0-blue" alt="version">
  <img src="https://img.shields.io/badge/iOS-14.0%2B-lightgrey" alt="ios">
  <img src="https://img.shields.io/badge/arch-arm64%20%7C%20arm64e-informational" alt="arch">
  <img src="https://img.shields.io/badge/languages-10-success" alt="languages">
</p>

---

## Getting Started

Install the `.deb` (jailbroken) or sideload the patched IPA, then open Telegram.

> **To open the Kira menu:** long-press the **"Ask a Question"** row in Telegram Settings.

## Features

### 👻 Ghost Mode

One master toggle hides every activity indicator you send. Fine-tune each one under **Advanced Settings**.

| Feature | What it does |
|---|---|
| Hide Online Status | Others can't see when you're online |
| Hide Typing Status | No `typing…` indicator while you compose |
| Hide Recording / Uploading Video | Hides both the video recording and upload indicators |
| Hide Voice Recording / Uploading | Same for voice messages |
| Hide Round Video Recording / Uploading | Same for round video messages |
| Hide Uploading Photo / File | No indicator while sending photos or files |
| Hide Choosing Location / Contact / Sticker | No indicator while picking what to share |
| Hide Playing Game Status | No indicator for inline games |
| Hide Speaking in Group Call | Your speaking indicator stays hidden in group calls |
| Hide Emoji Interaction / Reaction | No indicator when you interact or react with emoji |
| Disable Message Read Receipts | Others won't see that you read their messages |
| Disable Story View Receipts | Others won't see that you viewed their stories |

**Ghost Exceptions** — open someone's profile and tap the eye button in the top-right to whitelist them. Those people still see your typing indicators and read receipts while Ghost Mode stays on for everyone else.

> Online status is **not** covered by exceptions: Telegram broadcasts it to everyone at once, so it cannot be revealed to one person only.

### 🔒 Privacy & Extras

| Feature | What it does |
|---|---|
| Disable All Ads | Removes sponsored messages and promotional content |
| Save Restricted Media | Bypasses forwarding restrictions — save and forward media from protected chats and channels |
| Save Deleted Messages | Messages stay in your chat after the sender deletes them |
| Save Auto-Delete Messages | Messages survive auto-delete timers (1 day, 7 days, …) |
| Disable Screenshot Notifications | Screenshot secret chats and protected channels silently |
| View Disappearing Media Freely | Open one-time photos/videos without triggering the self-destruct timer |
| Save Original Edited Messages | Keeps the original text when someone edits a message |
| Hide Disappearing Label | Drops the "disappearing message" marker from intercepted one-time media |
| Confirm Calls | Confirmation dialog before answering an incoming call |
| Download Speed Boost | Larger chunks and more parallel connections — Medium suits most users |
| Custom Stars Balance | Display-only Stars balance; the server keeps its own count |
| Video to Voice | Send only a video's audio as a real voice message, honouring the preview trim handles |

### 🛠 Tools

- **Fix File Picker** — repairs picking files from the Files app on sideloaded builds. **Clear File Picker Cache** frees the temp copies it leaves behind.
- **Fake Location** — override your device's GPS and share a custom location instead.
- **Edit History** — review every revision of an edited message.

### 🌍 Languages

10 built-in languages, switchable in-app under **Language → Change Language**:

Arabic · Simplified Chinese · Traditional Chinese · English · Spanish · French · Italian · Japanese · Russian · Vietnamese

## Screenshots

<p align="center">
  <img src="Screenshots/1-main.jpg" width="32%">
  <img src="Screenshots/2-ghost.jpg" width="32%">
  <img src="Screenshots/3-privacy.jpg" width="32%">
</p>
<p align="center">
  <img src="Screenshots/4-tools.jpg" width="32%">
  <img src="Screenshots/5-localization.jpg" width="32%">
</p>

## Building

Requires [Theos](https://theos.dev) with an iOS 16.5 SDK.

```bash
make package          # builds Kira.dylib and the .deb
```

The `.dylib` is also copied to `packages/Kira.dylib` for direct sideloading.

To regenerate the embedded translations after editing any `Kira.bundle/*.lproj/Localizable.strings`:

```bash
python3 generate_langs.py
```

## Compatibility

- iOS 14.0+, `arm64` and `arm64e`
- Works in official Telegram and forks such as iMe

Some features depend on the Telegram API layer the host app speaks. **Save Original Edited Messages** shows an "unavailable" note when the host build's layer is too old to deliver edit updates.

## Disclaimer

This project is an **independent modification (tweak)** for the Telegram app. It is **not affiliated, associated, authorized, endorsed by, or in any way officially connected with Telegram Messenger LLP** or any of its subsidiaries or affiliates. All trademarks, including the Telegram name and logo, belong to their respective owners.

This tweak exists for **personal and educational purposes**. Use it at your own risk. Don't use it to break rules or violate Telegram's terms of service — no responsibility is taken for any issue, damage, or consequence resulting from its use or misuse.

## Acknowledgements

This project is a fork of [Aj3radi/TGExtra](https://github.com/Aj3radi/TGExtra).

---

<p align="center">
  📢 Telegram channel: <a href="https://t.me/iKiraPlus">t.me/iKiraPlus</a>
</p>
