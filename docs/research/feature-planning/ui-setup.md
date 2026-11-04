# 字幕阅读与首次配置现状

基线 MeetingTape `f7c010e81d60b9cc9f5adfbe71b3808929120c8e`，2026-11-04。关联[核验字幕阅读与首次配置的界面状态](https://github.com/patrick-fu/meetingtape/issues/68)。以下是源码核验与原型输入；交互方案留在功能票讨论。

## 字幕阅读的现有行为

| 部分 | 当前代码行为 | 来源 |
| --- | --- | --- |
| 紧凑窗 | 宽 196 点；初始化高 54 点，显示时按开关/内容调整为 39、73、106 或 120 点；转写和翻译分别最多两行 | [RecordingPanel.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/RecordingPanel.swift#L10)、[LiveCaptionModel.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/LiveCaptionModel.swift#L58) |
| 展开窗 | 380×320；包含历史正文、时间、音源、标题、复制和录音控制 | [RecordingPanel.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/RecordingPanel.swift#L34)、[RecordingPanel.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/RecordingPanel.swift#L107) |
| 置顶 | pinned 使用 floating 及 all-Spaces/full-screen-auxiliary 标记；取消后 normal；窗口声明 nonactivating、可成为 key、不可成为 main | [RecordingPanel.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/RecordingPanel.swift#L5)、[RecordingPanel.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/RecordingPanel.swift#L26) |
| 历史阅读 | 已有滚动后暂停跟随和“回到最新”；接近底部 24 点恢复跟随 | [RecordingPanel.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/RecordingPanel.swift#L150)、[RecordingPanel.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/RecordingPanel.swift#L227) |
| 内容状态 | 原文临时/定稿，译文 pending、sameLanguage、translated、failed；复制定稿以 ASR final 过滤 | [CaptionTextView.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/CaptionTextView.swift#L9)、[LiveCaptionModel.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/LiveCaptionModel.swift#L68) |
| 控制可用性 | 紧凑窗保留停止、pin、展开；停止中显示进度并限制操作；hosting view 接受首击 | [RecordingPanel.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/RecordingPanel.swift#L45)、[RecordingPanel.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/RecordingPanel.swift#L84)、[RecordingPanel.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/RecordingPanel.swift#L217) |

这些窗口标记表达实现意图；焦点、跨 Space、全屏和多显示器表现仍需实际 App 验证。

[字幕阅读与悬浮窗交互](https://github.com/patrick-fu/meetingtape/issues/61)的原型可在已有跟随行为上比较：新内容提示、字幕区悬停淡化、静音呈现和按显示器记忆位置。鼠标穿透需要同时验证停止、pin 和展开的可达性。

Cicada 的[字幕条](https://github.com/wquguru/cicada/blob/38771f1a5ae691c848ea429f4a870defd92d9d26/Sources/LiveSubs/Overlay.swift#L3-L59)为独立展示窗口，使用不同宽度、层级和鼠标事件策略；其[历史阅读](https://github.com/wquguru/cicada/blob/38771f1a5ae691c848ea429f4a870defd92d9d26/Sources/LiveSubs/NotesViews.swift#L483-L515)可作为交互参考。

## 首次配置的现有入口与状态

| 部分 | 已有入口及状态 | 来源 |
| --- | --- | --- |
| 设置 | 独立设置窗，含通用、录音、模型、实时字幕、存储与导出、关于 | [SettingsView.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/SettingsView.swift#L15) |
| 云端凭据 | 未配置、测试中、已配置、失败；API Key 与旧凭据输入；测试文件转写连接后保存 | [SettingsView.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/SettingsView.swift#L371)、[TranscriptionModel.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/TranscriptionModel.swift#L115) |
| 本地录后模型 | 硬件不支持、未安装、安装/验证中、已就绪、安装失败；支持查找已有模型与版本选择 | [LocalModels.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeTranscription/LocalModels.swift#L17)、[LocalModels.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeTranscription/LocalModels.swift#L100)、[SettingsView.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/SettingsView.swift#L424) |
| 本地翻译 | 查询语言对 installed/supported/unsupported/unknown，提供语言包准备入口 | [LocalTranslationSetup.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/LocalTranslationSetup.swift#L13) |
| 权限与实时开启 | 起录前申请麦克风权限；实时开启有云端确认；未见集中式首次使用向导 | [AppModel.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/AppModel.swift#L196)、[LiveCaptionModel.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/LiveCaptionModel.swift#L140) |

原型输入至少包括：无 Key、文件连接已验证、缺模型、安装中/失败、语言包待下载/不支持、权限未授予、已有完整配置，以及不同系统版本。文件连接测试的结果只对应其实际调用的服务；实时 ASR 与翻译的可用性分别呈现。

[首次使用与模型配置引导](https://github.com/patrick-fu/meetingtape/issues/62)可据此讨论示例入口、配置顺序、跳过与返回方式。[Cicada 首次使用流程](https://github.com/wquguru/cicada/blob/38771f1a5ae691c848ea429f4a870defd92d9d26/Sources/LiveSubs/Onboarding.swift#L344-L378)提供参考。

## 系统版本边界

当前本地翻译调用 `TranslationSession(installedSource:target:)`，该初始化方法官方标为 macOS 26+；源码的 26 门槛有具体 API 依据。较早系统的其他 Translation 接入方式属于另一路径评估，修改可用性标记本身不足以支持当前调用。

来源：[TextTranslation.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeTranscription/TextTranslation.swift#L23)、[Apple 初始化方法文档](https://developer.apple.com/documentation/translation/translationsession/init(installedsource:target:))。本地实时 ASR 的兼容性另见[本地实时转写](https://github.com/patrick-fu/meetingtape/issues/57)。

## 验证范围

已读取相关窗口、设置、配置与参考项目源码；主 agent 复核窗口尺寸、滚动逻辑和 Translation API 版本。本轮没有运行 GUI、触发授权或安装模型；动态焦点、多个屏幕、真实连接与长时间使用留待原型/实现验收。
