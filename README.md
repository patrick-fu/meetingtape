# MeetingTape

原生 macOS 会议录音工具，同时保留系统音频和麦克风。资料库整理已保存的内容，精简悬浮窗显示录音状态、字幕与文字翻译。

- 一个双声道录音文件：左侧系统声音，右侧处理后的麦克风；处理失败如实保留原麦并记录状态。
- 已确认声道布局的录音默认分路转写，也可合并以减少资源使用。Qwen、MOSS、豆包各自保留结果和失败重试。
- 实时转写与字幕翻译分别开关。译文跟随原句修订，关闭或断线区间保留记录，不自动补传。
- App 与 CLI 使用同一 Markdown 导出入口，可选择主稿、其他版本和实际运行观测。

当前为 `v0.1.0-beta.1` 开发版，尚未发布可公证安装包。图标、云端翻译账户权限及发行验收仍待闭合；[功能验收与限制](docs/feature-acceptance.md)记录了实际通过和未通过的路径。AEC、长录音及设备/睡眠等缺口见[本地验收](docs/local-verification.md)。

## 使用与数据

要求 Apple Silicon Mac，录音最低 macOS 14.2。本地 Qwen/MOSS 需要至少16GB内存，模型从设置中按需安装；Apple 本地实时文字翻译需要 macOS26和系统语言包。

默认不自动转写或上传。豆包识别需要自备 Key，保存在 macOS 钥匙串；启用后会上传声音并使用你的账户计费。豆包文字翻译还需 `volc.speech.mt` 权限。选择本地文字翻译不会自动切云端，但当前实时语音识别仍使用豆包。

详细说明：[转写与模型](docs/transcription.md)、[资料库与悬浮窗](docs/desktop.md)、[安装包使用](docs/distribution.md)。

## 本地构建

需要 Xcode、Python 和有效 Developer ID Application 签名身份。签名团队可按本地项目配置调整，签名私钥不属于仓库内容。

```sh
./scripts/build-desktop.sh debug
swift test
```

构建脚本校验固定版本的 WebRTC Audio Processing、Abseil 与包哈希。硬件验收按 `docs/local-verification.md` 执行；普通单元检查通过不等于麦克风、系统声音或音质验收通过。本地流程不依赖 CI。

项目自有代码使用 [MIT](LICENSE)。原生依赖许可保存在 `Resources/ThirdParty`，本地模型与 Python 包条款见 `Resources/Transcription/NOTICE.md`；模型权重不随 App 分发。
