# MeetingTape 安装与使用

本发布包面向 Apple Silicon Mac。将 MeetingTape.app 拖到 Applications 后打开。CLI 用户请将整个 CLI 文件夹复制到固定位置，保留可执行文件旁的 Transcription 文件夹，再把 CLI 目录加入 PATH。

首次录音需允许麦克风与系统音频录制权限。声音保存在用户选择的本地目录；默认不上传或自动转写。启用豆包识别会上传所选声音并使用自备账户计费。

App 默认自动检查并下载更新，在正常退出时安装；录音、保存或转写进行中会延后。可在 MeetingTape 菜单中手动检查或关闭自动更新。旧版未内置更新器，需先手动安装 0.1.0 一次；独立 CLI 目录继续手动替换。

本地 Qwen/MOSS 模型从设置中按需安装，当前要求至少16GB内存；权重不包含在此包中。实时语音识别可选择本地 SenseVoice 或豆包，在模型设置中安装本地字幕模型。Apple 本地字幕文字翻译需要macOS26及系统语言包。豆包文本翻译需另有 `volc.speech.mt` 权限；本地翻译不自动切云端。

资料库可选择主稿导出Markdown；勾选其他版本时，分别附上实时与录后稿件及观测明细。命令行运行 `meetingtape help transcribe` 查看同一导出入口。

当前版本面向 Apple Silicon。现场 AEC、短断档、设备/睡眠、全新机器权限、最低系统和窗口矩阵的验证范围见随附 Change Log 及仓库验收记录。

## 本地发行维护

每次递增 SemVer 和 App/CLI 的 `CFBundleVersion`，更新 Change Log 后运行 `scripts/package-release.sh <major.minor.patch>`。App 使用固定版本的 Sparkle，构建过程会按层级签名其框架和组件。

更新私钥保存在 macOS Keychain 的 `com.paaatrickfu.meetingtape` 账户，公钥在 App 内；首次生成使用 SwiftPM 下载的 Sparkle `bin/generate_keys --account com.paaatrickfu.meetingtape`。不导出或提交私钥。

公证包验收后，运行 `python3 scripts/update-appcast.py <major.minor.patch>` 生成并核验签名 feed。先把同一 DMG 和校验和发布到 GitHub Release，确认匿名下载一致，再将生成的 `appcast.xml` 复制到 `docs/appcast.xml` 并发布 Pages；最后核对公开 feed 字节与本地签名文件一致。禁止对签名后的 feed 再修改内容。
