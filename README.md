# AY Translate

<p><img src="ScreenTranslate/BrandAssets.xcassets/AYBrandIcon.imageset/AYBrandIcon.png" width="112" alt="AY Translate 应用图标"></p>

iPhone / iPad 截图翻译工具：识别画面里的文字，把译文画回原来的位置，随时切换原图对照。漫画气泡、竖排日文、手写字、游戏和网页截图都能处理。

最低支持 **iOS / iPadOS 26.5**。[下载最新版本](https://github.com/AtlanYuey/AY_Translate/releases/latest)

## 安装

发布页提供的是**未签名**的 `AY-Translate-<版本>-unsigned.ipa`，需要用你自己的证书签名后安装（Xcode、fastlane、Feather 等均可）。

应用由两部分组成，各需一个描述文件：

| 部分 | Bundle ID | 需要的能力 |
| --- | --- | --- |
| 主程序 | `com.atlanyuey.translate` | App Groups；如需 iCloud 同步，再开 iCloud（键值存储） |
| 分享扩展 | `com.atlanyuey.translate.ShareExtension` | App Groups |

两者使用同一个 App Group：`group.com.atlanyuey.translate`。截屏后在当前应用上方显示译图，靠的就是这个分享扩展，所以必须分别签名，不能省掉。用通配符描述文件也能装上，但没有 App Group 和 iCloud：设置会改走钥匙串在主程序和扩展之间中转，iCloud 同步不可用。具体步骤见 [签名与 iCloud 配置](docs/Signing-and-iCloud.md)。

## 能做什么

- **在原图上读译文**：按原文的位置、字号和方向排版，竖排就竖排。原文从背景上干净地擦除，不留灰块。
- **漫画气泡**：自动找出对话气泡，一个气泡算一句话，在气泡里排版、不出框。连在一起的两个气泡会分开翻译；注音假名不会混进正文；数字、水印、版权行这类不需要翻译的内容保持原样。
- **本机免费，AI 可选**：默认用 Apple Vision 识别、Apple 翻译，不需要 API Key。也可以添加 OpenAI 兼容的 AI 服务（Gemini、OpenAI、DeepSeek、通义千问、Kimi、智谱、硅基流动、OpenRouter 或自建服务），识别和翻译分别选。
- **AI 按顺序使用，出错自动接替**：识别和翻译各有一个服务顺序。第一个出错或达到花销上限时，下一个接手，最后由本机引擎兜底；发生切换时会提示。
- **只在需要时用 AI**：开启“AI 辅助识别”后，先用本机识别；只有读得不可靠时（手写、艺术字、气泡里还有没读出的字）才交给 AI，可以设为先问你。
- **用量和花销**：每个服务记录本月和累计的输入、输出 token 和金额，可设每月花销上限。公布价格的服务商（如 OpenRouter）自动取价，其余手动填写；国内服务商可选人民币或美元。
- **截屏即翻译**：内置快捷指令，绑定操作按钮或轻点背面，在当前应用上方直接看译图，关闭后回到原处。
- **可选的历史与 iCloud 同步**：历史默认关闭。iCloud 同步语言、显示、AI 服务配置；API 密钥要另外勾选才同步。截图和历史永远不上传。

## 开始使用

1. 打开“翻译”页，选好源语言（可自动检测）和目标语言。第一次用苹果翻译时，按系统提示下载语言模型。
2. 点“选择图片翻译”，或在任意应用的分享菜单里选 AY Translate。
3. 截屏触发：设置 → 快捷操作 → 操作按钮与快捷指令 → 添加截图翻译指令，再到系统设置里绑定操作按钮或轻点背面。
4. 使用 AI：设置 → AI 服务 → 添加 AI 服务，填地址、API Key、模型，可以先测试翻译或测试图片识别。然后在“识别引擎”或“翻译引擎”的使用顺序里加入它。加入时会询问是否允许把截图或文字发给这个服务，翻译过程中不再弹窗。

## 设置在哪里

| 想调整什么 | 位置 |
| --- | --- |
| 软件界面语言 | 设置 → 界面 → 软件语言 |
| 识别用哪些服务、按什么顺序 | 设置 → 文字识别 → 识别引擎 → 使用顺序 |
| 只在需要时用 AI 识别、是否先问 | 设置 → 文字识别 → 识别引擎 → AI 辅助识别 / 使用 AI 前先询问 |
| 翻译用哪些服务、目标语言 | 设置 → 译文 → 翻译引擎、目标语言 |
| 添加、编辑 AI 服务 | 设置 → AI 服务（模型列表、请求参数、测试） |
| 价格、用量、每月花销上限 | 设置 → AI 服务 → 选中服务 → 费用 |
| 译文样式、字号、默认显示 | 设置 → 显示 |
| 保存或清空历史 | 设置 → 翻译历史 |
| iCloud 同步、同步 API 密钥、复制配置 | 设置 → 配置同步 |
| 撤销云端许可、隐私说明 | 设置 → 隐私 |
| 版本、开源许可、处理诊断 | 设置 → 关于 AY Translate |

## 译图页面

- 双指缩放、拖动；双击切换缩放。
- 点右下角的图标：在译图和原图之间切换。
- 长按这个图标：菜单最上面是这次的耗时，以及 AI 识别、AI 翻译各自的输入/输出 token 和花费；下面是目标语言、全文阅读、复制（译文或原文）、识别说明和“打开 AY Translate”。
- 点 × 关闭；从快捷指令或分享菜单进入时会回到原来的应用。

## 隐私

- 默认全部在本机处理，没有服务器、账号、统计或广告。
- 只有你选了 AI 服务并允许后，才会把截图（识别）或识别出的文字（翻译）发给**你自己配置的**服务；费用和数据保留政策以服务商为准。
- API Key 只存在钥匙串里，不写入日志或历史；开启“同时保存 API 密钥”后才会进入你的 iCloud。

## 开发

- 核心逻辑（识别结果整理、气泡检测、排版、AI 请求）在 `ScreenTranslate/Core`，是一个可在 Linux 上测试的 Swift 包：`swift test`。
- 带真实 Apple Vision、模拟器界面和打包的完整验证在 GitHub Actions：`.github/workflows/release-ipa.yml`，可手动运行，推送 `v*` 标签时还会发布未签名 IPA。
- `Tests/ScreenTranslationCoreTests/LiveServiceTests.swift` 可对真实 AI 服务做端到端检查，默认跳过；用法见文件开头的说明。
- 更新记录见 [CHANGELOG](CHANGELOG.md)，各版本说明在 [docs/releases](docs/releases)，设计和实测记录在 [docs/AY-Translate-1.1.0.md](docs/AY-Translate-1.1.0.md)。

---

基于 Bahaa 及贡献者的 [Translate Screen](https://github.com/0xffvirus/translate-screen) 修改，以 [Apache 2.0](LICENSE) 发布；原作者声明和第三方许可见 [NOTICE](NOTICE)，修改清单见 [MODIFICATIONS](MODIFICATIONS.md)。
