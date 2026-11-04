<div align="center">

# AY Translate

**Translate text anywhere on your iPhone—without losing the original screen layout.**

[![Swift](https://img.shields.io/badge/Swift-5.0-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![Platform](https://img.shields.io/badge/Platform-iOS-000000?logo=apple&logoColor=white)](https://developer.apple.com/ios/)
[![UI](https://img.shields.io/badge/UI-SwiftUI-007AFF?logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![License](https://img.shields.io/badge/License-Apache%202.0-D22128?logo=apache&logoColor=white)](LICENSE)
[![Build IPA](https://github.com/AtlanYuey/translate-screen/actions/workflows/release-ipa.yml/badge.svg)](https://github.com/AtlanYuey/translate-screen/actions/workflows/release-ipa.yml)
[![Built with](https://img.shields.io/badge/Built%20with-Vision%20%2B%20Translation-5856D6)](https://developer.apple.com/documentation/)

See foreign text → press the Action Button → see the translated screen.

</div>

## 1.5：补查、模型参数与原生缩放

增加未覆盖竖排列的有限本机补查、遗漏 AI 译文的单次修复，以及独立服务参数预设和自定义 Body JSON。译文加重描边、优化笔画消除；点字详情默认关闭，可在显示设置开启。双指缩放、平移与双击改用系统原生交互，更新桌面图标并修正服务商品牌图标。

详见 [1.5 开发记录](docs/AY-Translate-1.5.md)。

## 1.4：识别、背景与日常操作

默认 Apple Vision + 苹果本机翻译，无需 API Key。新版本使用原生文档识别读取竖排方向与文字位置，减少重复 OCR；AI 翻译使用紧凑 ID 和最多两批并发。背景按文字笔画局部处理，保留未遮罩的画面，不再为默认译文绘制整块底色。具体真机耗时取决于图片、语言模型及供应商，可长按原图图标查看处理耗时。

首页只保留语言与单一图片入口，显示、隐私、翻译历史进入各自二级设置；内置蓝色 AY Translate 截屏快捷指令和品牌服务商图标。iCloud 设置同步可选，首次上传已配置设备的设置，其他设备读取；API Key、截图、历史和授权保留在本机。自签需要描述文件支持对应 iCloud 权限。

实现、验证范围与限制：[1.4 开发记录](docs/AY-Translate-1.4.md)。现有系统 Share 宿主仍可能以卡片显示，无边框全屏尚未解决，真实快捷指令与签名权限需要设备验收。

## Preview (original version)

<p align="center">
  <img
    src="screenshots/screenshotExample.png"
    alt="AY Translate displaying English translations over text in a Chinese shopping app"
    width="420"
  />
</p>

<p align="center">
  <sub>原始版本示意。新版界面及全屏扩展的最新截图随 Actions 的 validation 附件提供。</sub>
</p>

## Overview

AY Translate is a native iPhone utility that recognizes text in a screenshot, translates it on-device, and places the translation over the original text in approximately the same location.

Instead of reducing a screen to a plain list of sentences, the app preserves the visual context of menus, websites, maps, messages, social media, and other interfaces. It is designed around a fast Action Button workflow, with manual screenshot import available when needed.

> [!IMPORTANT]
> AY Translate is an early-stage open-source project. APIs, storage formats, and UI behavior may change as the project evolves.

## Features

- **Layout-aware translation** — Uses Vision bounding boxes to position translated text over the original screenshot.
- **Action Button workflow** — Receives the output of Shortcuts' **Take Screenshot** action and opens the translated result.
- **Free local defaults** — Apple Vision and Apple Translation work without an account, ads, or an API key.
- **Optional AI engines** — Independently select OpenAI-compatible image OCR or contextual translation, with custom HTTPS endpoints, models, and device-only Keychain credentials.
- **Verified OCR positions** — AI text uses local Vision anchors for overlays; uncertain positions remain in Full Text.
- **Readable results** — Pinch repeatedly to zoom, drag to pan, reset the view, and adjust overlay type size; tap any translated region for its complete translation.
- **Automatic language detection** — Detects the source language or allows explicit language selection.
- **Multiple languages** — Supports English, Arabic, Chinese, Japanese, Korean, Spanish, French, German, Italian, Portuguese, and Russian.
- **First-class Arabic support** — Right-to-left layout, alignment, and mixed text handling.
- **Interactive overlays** — Tap a translated region to inspect and copy the original or translated text.
- **Original comparison** — Switch between the original and translated screenshot at any time.
- **Press-and-hold reveal** — Temporarily reveal the original text underneath an overlay.
- **Full-text mode** — Read and copy all recognized content outside the image layout.
- **Manual import** — Choose an existing screenshot from Photos.
- **Optional history** — Save up to 20 recent translations locally, with history disabled by default.
- **Appearance controls** — Choose background matching, high contrast, or text-only overlays in Settings.
- **Native design** — Built with SwiftUI and supports Light and Dark Mode.

## How It Works

```text
Take Screenshot
      │
      ▼
Share with AY Translate
      │
      ▼
Vision text recognition
      │
      ▼
On-device batch translation
      │
      ▼
Layout-preserving overlays
```

1. Shortcuts captures the current screen.
2. The Share extension receives the screenshot through `NSItemProvider`, above the invoking app. The current UIActivity host still presents it in a system sheet; borderless full-screen presentation remains unfinished.
3. Vision recognizes text and returns normalized bounding boxes.
4. Apple's Translation framework translates the recognized blocks in a batch.
5. SwiftUI renders the translated blocks over the original image using their detected positions. Close or swipe up to finish the extension and return to its host.

## Action Button Setup

Run AY Translate once after installing it, then open **Settings → Action Button & Shortcuts → Add Screenshot Shortcut**. Open the bundled file in Shortcuts and confirm **Add Shortcut**. Its two actions are already connected. Then assign it in **Settings → Action Button** or **Accessibility → Touch → Back Tap**.

For manual setup or a build with a changed bundle identifier, create this workflow:

1. Add **Take Screenshot**.
2. Add **Share with AY Translate** directly below it (the installed Share extension).
3. Confirm that the Screenshot output from the first action is connected to the Screenshot input of the second action.
4. Name the shortcut `AY Translate`.
5. Open **Settings → Action Button → Shortcut**.
6. Select `AY Translate`.

Use **Take Screenshot → Share with AY Translate** for the Share extension. Install version 1.2.1 or later: version 1.2 incorrectly registered an Action extension, which does not satisfy Shortcuts' “Share with App” lookup. Existing two-action shortcuts can be kept if signing preserves the app identifier. Apple Translation prepares models through system UI. The legacy **Translate Screenshot in App** action remains a foreground fallback.

The resulting workflow is:

```text
Take Screenshot → Share with AY Translate → Extension result → Return to host
```

No photo picker, conditional action, or separate Open action is required. iOS asks you to confirm importing the shortcut; third-party apps cannot silently capture the contents of other apps. If signing changes the app's bundle identifier, regenerate the signed template with the matching `WFAppIdentifier` or use the manual setup above.

Devices without an Action Button can run the same shortcut from Shortcuts, Siri, a Home Screen shortcut, or another supported automation trigger.

## Requirements

- Xcode 26.6 or later
- iOS 26.5 or later
- A physical iPhone is recommended for Translation and Action Button testing
- An Apple Development team for installing on a physical device
- Downloaded Apple translation language models for the selected language pair

The current deployment target follows the project configuration. Contributors are welcome to help evaluate a lower deployment target while preserving the existing functionality.

## Getting Started

1. Clone or fork the repository.
2. Open `ScreenTranslate.xcodeproj` in Xcode.
3. Select the **ScreenTranslate** target.
4. Choose your development team under **Signing & Capabilities**.
5. Select a physical iPhone or simulator.
6. Build and run.

You can also verify the project from the command line:

```bash
xcodebuild \
  -project ScreenTranslate.xcodeproj \
  -scheme ScreenTranslate \
  -sdk iphoneos \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The first translation may ask permission to download the required Apple language model.

## Optional AI Engines

Apple Vision and Apple Translation remain selected by default. In **Settings → AI Services**, add named providers with their own HTTPS Base URL (including `/v1` if required), model ID, and optional API key. Choose a saved service independently under OCR or Translation. Multiple profiles and their keys are retained when switching. Each saved service uses its own Keychain entry. OCR and translation can select different services. Self-hosted services that do not require a key are supported.

Before the first request to an endpoint/model, the app discloses the destination and asks permission. AI OCR sends a resized screenshot; AI translation sends recognized text and screen context. Switching only the translation engine does not upload an image. Changing endpoints clears the previous key unless you supply a replacement. Revoke permission under **Privacy**. External provider fees and retention policies apply.

AI-generated coordinates are not trusted by themselves. Only locally verified positions become overlays; remaining text appears in Full Text. Failed AI OCR falls back to available Vision results, and failed recognition can be retried using another engine without importing the screenshot again. Speed/Quality options control context grouping and the selected translation strategy.

Developer details, test coverage, privacy behavior, manual acceptance checks and limitations: [开发与验证（中文）](docs/开发与验证.md). ReplayKit/PiP are [a separate future investigation](docs/实时翻译评估.md); this app currently translates individual screenshots.

## Tests

```bash
# Shared production core, including mocked HTTP protocol tests (no API key)
swift test --jobs 3
```

The shared Xcode scheme also includes `ScreenTranslateTests`: local-only defaults, failure/retry, cloud consent, cancellation, Vision OCR, temporary screenshot cleanup and Keychain integration. Run it on an available iOS 26.5+ simulator using Xcode 26.6+. Linux can run the Foundation core but cannot build or execute the iOS application.

## IPA Releases

GitHub Actions tests the shared core and iOS workflow, then builds an unsigned IPA for pull requests, manual runs, and version tags. Tag builds also attach the IPA to the corresponding GitHub Release. The default Intel `macos-26-intel` runner avoids dependence on ARM64 capacity; manual runs can select a standard ARM64 runner as a fallback. Runner allocation failures are infrastructure results, not source compilation failures. Unsigned IPAs cannot be installed directly on a standard iPhone; users must sign them with their own Apple ID or certificate using a compatible sideloading tool.

Each release includes:

- `TranslateScreen-<version>-unsigned.ipa`
- `TranslateScreen-<version>-unsigned.ipa.sha256`

To publish a release:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The tag version becomes the app's `CFBundleShortVersionString`. GitHub automatically generates release notes and uploads the IPA after a successful build.

To test IPA creation without publishing a release, open **Actions → Build IPA → Run workflow**. Choose the runner (Intel by default). The IPA and SHA-256 file will be available under the successful workflow run's **Artifacts → TranslateScreen-<version>-unsigned**. Diagnostic logs, xcresult bundles and exported interface screenshots are uploaded separately, including on test/build failure when available.

> [!WARNING]
> Never commit Apple signing certificates, private keys, provisioning profiles, or App Store Connect credentials. A future signed distribution workflow should store them as encrypted GitHub Actions secrets.

## Project Structure

| File | Responsibility |
| --- | --- |
| `ScreenTranslateApp.swift` | App entry point and shared dependency setup |
| `ContentView.swift` | Home screen, screenshot import, processing, and translation result UI |
| `OnboardingView.swift` | First-run onboarding and Action Button setup guide |
| `ScreenTranslateShare/ShareViewController.swift` | Share extension used by the screenshot sharing workflow |
| `TranslateScreenshotIntent.swift` | Alternative foreground App Intent for older shortcuts |
| `TranslationEngine.swift` | Vision text recognition and bounding-box extraction |
| `AppState.swift` | Translation workflow and UI state coordination |
| `Models.swift` | Languages, recognized blocks, settings, and history models |
| `HistoryView.swift` | Optional local translation history |
| `SettingsView.swift` | Languages, appearance, privacy, and shortcut settings |

## Privacy

Privacy is a core design constraint:

- Screenshots are recognized and translated using Apple frameworks on the device by default; cloud AI is opt-in and destination-specific.
- AY Translate does not include analytics, advertising SDKs, or its own screenshot-upload service.
- Translation history is disabled by default.
- When history is off, the shared-screen extension keeps its input and results in memory until Close. Only the alternative foreground shortcut uses a protected temporary handoff file, removed on consumption or expiry; nothing is added to Photos.
- Optional provider keys stay in the device-only Keychain. Cloud requests use ephemeral sessions and refuse redirects; provider error bodies and credentials are never logged.
- When history is enabled, screenshots and text are stored in the app's private local container.
- Saved history can be removed from the History or Settings screen.

Review all privacy behavior before distributing a modified build, especially if adding analytics, cloud translation providers, crash reporting, or synchronization.

## Known Limitations

- Overlay backgrounds sample the surrounding color; they cannot reconstruct gradients or photo textures hidden by the original text.
- Vision may split or combine text differently depending on typography and screen complexity.
- Translation quality and supported language pairs depend on Apple's installed translation models.
- Highly stylized, curved, handwritten, very small, or low-contrast text may not be recognized accurately.
- The system **Take Screenshot** action must be added to the shortcut once by the user.
- A native Share Extension is not yet included.

## Roadmap

- [ ] Downloadable, preconfigured Apple Shortcut
- [ ] Share Sheet extension
- [ ] Smarter paragraph and interface-element grouping
- [ ] Improved background sampling and overlay blending
- [ ] More supported languages
- [x] Simplified Chinese, Traditional Chinese, English and follow-system interface languages
- [x] Core OCR alignment/context regression tests and iOS workflow/Keychain tests
- [ ] Accessibility audit
- [ ] Performance profiling on older supported devices

## Contributing

Contributions are welcome. Bug fixes, accessibility improvements, translations, documentation, tests, and focused feature proposals are especially valuable.

1. Search existing issues before opening a new one.
2. Fork the repository and create a focused branch.
3. Keep changes scoped and follow the existing SwiftUI style.
4. Build the project and test the affected workflow.
5. Open a pull request explaining the problem, approach, and testing performed.

For substantial behavior or architecture changes, open a discussion or issue before investing in a large implementation.

Please avoid committing:

- Personal signing identifiers or provisioning profiles
- User-specific Xcode data
- Screenshots containing private information
- Proprietary translation services or credentials
- Generated build output and Derived Data

## Security

Do not report vulnerabilities involving screenshot exposure, local data access, unsafe file handling, or privacy leaks in a public issue. Use the repository owner's private security reporting channel once it is configured.

## License

AY Translate is licensed under the [Apache License 2.0](LICENSE). You may use, modify, and distribute the project, including in commercial applications, subject to the license terms.

Unless explicitly stated otherwise, contributions submitted to this repository are licensed under the same terms.

---

<div align="center">

Built with SwiftUI, Vision, App Intents, and Apple Translation.

</div>
