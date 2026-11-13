<p align="center">
  <img src="icon.png" width="160">
</p>

<h1 align="center">Kira</h1>

<p align="center">
  一款原生质感的 iOS Telegram 隐私与实用工具插件。
</p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.vi.md">Tiếng Việt</a> ·
  <b>简体中文</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-1.0.0-blue" alt="version">
  <img src="https://img.shields.io/badge/iOS-14.0%2B-lightgrey" alt="ios">
  <img src="https://img.shields.io/badge/arch-arm64%20%7C%20arm64e-informational" alt="arch">
  <img src="https://img.shields.io/badge/语言-10-success" alt="languages">
</p>

---

## 快速开始

安装 `.deb`（已越狱设备）或侧载已打补丁的 IPA，然后打开 Telegram。

> **打开 Kira 菜单：** 在 Telegram 设置中**长按 "Ask a Question"（提问）那一行**。

## 功能

### 👻 幽灵模式

一个总开关即可隐藏你发出的所有活动状态。可在 **Advanced Settings** 中逐项微调。

| 功能 | 说明 |
|---|---|
| 隐藏在线状态 | 别人看不到你何时在线 |
| 隐藏输入状态 | 编辑消息时不显示"正在输入…" |
| 隐藏录制／上传视频状态 | 同时隐藏录制和上传视频的提示 |
| 隐藏录制／上传语音状态 | 语音消息同理 |
| 隐藏录制／上传圆形视频状态 | 圆形视频消息同理 |
| 隐藏上传图片／文件状态 | 发送图片或文件时不显示提示 |
| 隐藏选择位置／联系人／贴纸状态 | 挑选分享内容时不显示提示 |
| 隐藏玩游戏状态 | 内联游戏不显示提示 |
| 隐藏群组通话发言状态 | 群组通话中隐藏你的发言指示 |
| 隐藏表情互动／回应状态 | 使用表情互动或回应时不显示提示 |
| 关闭已读回执 | 别人不会知道你已读他们的消息 |
| 关闭快拍已看回执 | 别人不会知道你看过他们的快拍 |

**幽灵模式例外** — 打开某人的个人资料，点右上角的眼睛按钮即可加入白名单。这些人仍能看到你的输入状态和已读回执，而幽灵模式对其他所有人保持开启。

> 在线状态**不在**例外范围内：Telegram 会一次性广播给所有人，因此无法只对某一个人公开。

### 🔒 隐私与增强

| 功能 | 说明 |
|---|---|
| 屏蔽所有广告 | 移除赞助消息和推广内容 |
| 保存受限媒体 | 绕过转发限制——保存并转发受保护聊天和频道中的媒体 |
| 防撤回 | 发送者撤回后消息仍留在你的聊天里 |
| 防自动删除 | 消息不受自动删除计时器（1 天、7 天等）影响 |
| 关闭截图通知 | 在密聊和受保护频道截图而不通知对方 |
| 自由查看阅后即焚 | 打开一次性照片／视频而不触发自毁计时 |
| 保留编辑前原文 | 对方编辑消息后，你这边仍保留最初的文本 |
| 隐藏"阅后即焚"标签 | 拦截到的一次性媒体不再加上该标记 |
| 通话确认 | 接听来电前弹出确认对话框 |
| 下载加速 | 更大的分块和更多并行连接——多数用户建议选 Medium |
| 自定义 Stars 余额 | 仅本地显示，服务器仍以自己的计数为准 |
| 视频转语音 | 只把视频的声音作为真正的语音消息发送，并遵循预览中的裁剪范围 |

### 🛠 工具

- **修复文件选择器** — 解决侧载版本无法从"文件"App 选取文件的问题。**清理文件选择器缓存**可清除它留下的临时副本。
- **虚拟定位** — 覆盖设备 GPS，改为分享自定义位置。
- **编辑历史** — 查看一条消息被编辑过的每一个版本。

### 🌍 语言

内置 10 种语言，可在 **Language → Change Language** 中随时切换：

阿拉伯语 · 简体中文 · 繁体中文 · 英语 · 西班牙语 · 法语 · 意大利语 · 日语 · 俄语 · 越南语

## 截图

<p align="center">
  <img src="Screenshots/1-main.jpg" width="32%">
  <img src="Screenshots/2-ghost.jpg" width="32%">
  <img src="Screenshots/3-privacy.jpg" width="32%">
</p>
<p align="center">
  <img src="Screenshots/4-tools.jpg" width="32%">
  <img src="Screenshots/5-localization.jpg" width="32%">
</p>

## 编译

需要 [Theos](https://theos.dev) 以及 iOS 16.5 SDK。

```bash
make package          # 编译 Kira.dylib 与 .deb
```

`.dylib` 同时会复制到 `packages/Kira.dylib`，方便直接侧载。

修改任意 `Kira.bundle/*.lproj/Localizable.strings` 后，重新生成内嵌翻译：

```bash
python3 generate_langs.py
```

## 兼容性

- iOS 14.0 及以上，支持 `arm64` 与 `arm64e`
- 可用于官方 Telegram 及 iMe 等分支客户端

部分功能取决于宿主 App 所使用的 Telegram API layer。若宿主版本的 layer 过旧、无法接收编辑更新，**保留编辑前原文**会显示"不可用"提示。

## 免责声明

本项目是面向 Telegram 应用的**独立修改（tweak）**，与 **Telegram Messenger LLP** 及其任何子公司或关联公司**没有隶属、关联、授权、认可或任何官方联系**。包括 Telegram 名称与标识在内的所有商标均归各自所有者。

本插件仅用于**个人与学习用途**，使用风险自负。请勿用它违规或违反 Telegram 服务条款——对于使用或滥用造成的任何问题、损害或后果，作者概不负责。

## 致谢

本项目 fork 自 [Aj3radi/TGExtra](https://github.com/Aj3radi/TGExtra)。

---

<p align="center">
  📢 Telegram 频道：<a href="https://t.me/iKiraPlus">t.me/iKiraPlus</a>
</p>
