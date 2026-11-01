# MeetingTape

[English](README.en.md) | 简体中文

面向 Apple Silicon Mac 的原生会议录音与转写工具。系统音频与麦克风分别保留在左右声道，资料库整理录音和转写，精简悬浮窗显示录音状态与实时双语字幕。录后可选择本地模型或自备 Key 的豆包云端模型，保留不同版本供对照。

## 下载与安装

最新预发布版本为 [v0.1.0-beta.1](https://github.com/patrick-fu/meetingtape/releases/tag/v0.1.0-beta.1)，提供已完成 Apple 签名与公证的安装镜像。

- **图形应用**：下载 [MeetingTape-0.1.0-beta.1-arm64.dmg](https://github.com/patrick-fu/meetingtape/releases/download/v0.1.0-beta.1/MeetingTape-0.1.0-beta.1-arm64.dmg)，将 `MeetingTape.app` 拖入 `/Applications`。首次运行按系统提示授予麦克风与系统音频录制权限。
- **CLI 工具**：DMG 内附带完整 `CLI` 目录。将该目录（保持可执行文件与同级 `Transcription` 文件夹在同一路径）复制到本地持久路径并加入 `PATH`。使用 `meetingtape doctor` 检查环境。

## 主要功能

- **分声道录音**：单一 `.m4a` 立体声文件，左声道保存系统音频，右声道保存麦克风语音；语音处理若降级会保留记录。分声道录制不等同于物理隔绝，亦不保证消除扬声器串音。
- **本地与云端转写**：支持本地 Qwen3 ASR、MOSS，以及自备 Key（BYOK）的豆包文件语音转写 2.0。已确认声道布局的原生录音默认分路识别，也可在设置中合并以减少资源使用；未知外部音频默认合并。
- **独立原稿对比**：各模型文本分别留存，可在 App 中按区间对比差异、定位回听，不自动融合各版本。
- **悬浮窗与实时字幕**：小窗显示录音状态与字幕，可展开或取消置顶。实时转写（豆包云端 ASR）与字幕翻译（Apple 本地或豆包文本翻译）分别开关，显示原文与译文，无语音播报。
- **Markdown 导出**：App 与 CLI 共用同一导出逻辑。选择一版主稿，可折叠附带其他版本与实际记录的耗时、CPU 和进程内存统计。未开启或断线区间如实标注，不自动补传。

## 使用与 CLI

### 界面使用

从状态栏或资料库窗口开始录音；录音期间主窗口可关闭，后台录音持续运行。悬浮窗可收起、展开或取消置顶；停止后录音自动入库。在资料库中可按需发起转写并导出 Markdown。

首次转写前，在「设置 → 转写与模型」选择默认模型。本地模型可按机器推荐档位一键安装；豆包凭据在此配置并保存在 macOS 钥匙串。实时转写与字幕翻译默认关闭，可分别开启。

### CLI 常用操作

`start`、`status`、`stop` 默认输出易读纯文本，添加 `--json` 可获得结构化输出。

```sh
# 检查环境并开始录音（需提前创建输出目录）
meetingtape doctor
mkdir -p ~/Documents/MeetingTape
meetingtape start --out ~/Documents/MeetingTape

# 查看状态与停止
meetingtape status
meetingtape stop

# 本地模型安装（按需联网下载固定依赖与权重）
meetingtape transcribe install qwen --profile low-memory

# 将此路径替换为 stop 输出的实际录音文件
RECORDING="/absolute/path/to/saved-recording.m4a"
meetingtape transcribe start "$RECORDING" --models qwen

# 可选：配置豆包凭据后改用云端，会上传音频
# meetingtape transcribe start "$RECORDING" --models doubao --allow-cloud

# 将此值替换为本地转写返回的任务 ID，查询至完成后导出
TASK_ID="replace-with-returned-task-id"
meetingtape transcribe status "$TASK_ID"
meetingtape transcribe export "$TASK_ID" --primary "$TASK_ID:qwen" --include-versions --output notes.md
```

## 系统要求与数据边界

- **系统要求**：
  - 仅支持 Apple Silicon（M 系列芯片）。
  - 录音部署目标为 macOS 14.2，但 14.2 实机兼容性尚未验证。
  - 本地转写（Qwen3 ASR / MOSS）需要至少 16 GB 统一内存（16–31 GB 推荐 low-memory，32 GB 以上推荐 standard）。
  - Apple 本地实时字幕文字翻译需要 macOS 26 及已下载的系统语言包。
- **数据与网络边界**：
  - 录音文件默认仅保存在本地指定目录，不自动转写，不自动上传。
  - 本地模型与依赖需要联网安装，安装完成后可离线转写录音。
  - 实时字幕 ASR 目前仅支持豆包云端，启用后会上传音频；豆包文本翻译则向云端发送文字请求。两者均使用自备凭据并在设置页配置，由用户账户计费。使用豆包实时 ASR + Apple 本地翻译时，整条链路不可称为完全离线。

## Beta 状态与已知限制

当前版本为 `v0.1.0-beta.1` 预发布，存在以下未完成项与限制：

- **AEC 回声消除未通过**：扬声器播放的声音可能串入麦克风声道，串音幅度尚未测定，建议佩戴耳机录音。
- **环境与场景待验证**：macOS 14.2 实机、长时录音、系统休眠唤醒恢复、全新机器首次权限冷启动、跨 Space 与全屏场景下的浮窗行为均尚未全面实机验证。
- **字幕与翻译验收**：大小悬浮窗的直接双语画面验收尚未完成。豆包文本翻译需单独开通 `volc.speech.mt` 权限，当前测试账号尚无此权限，云端翻译未验收通过；缺少权限会明确报错，不自动切换服务。

详细验收与限制记录见 [功能验收与限制](docs/feature-acceptance.md) 与 [本地验收记录](docs/local-verification.md)。

## 源码构建

构建需 Xcode（已在本机 Xcode 26.2 验证）、Python 3 以及项目支持的 SDK。构建脚本会自动准备固定版本的 Meson/Ninja 并编译静态 APM 库。

当前 `scripts/build-local.sh` 固定校验维护者团队 `TeamIdentifier=9N7UKH59LC`。其他开发者需先调整团队校验，并将 `MEETINGTAPE_SIGN_IDENTITY` 设置为自己的有效 Developer ID Application 签名身份；仅设置环境变量不足以通过校验。

```sh
# 维护者环境下的本地构建与测试示例
./scripts/build-desktop.sh debug
swift test
```

## 相关文档与许可

- [转写与模型配置](docs/transcription.md)：本地模型安装档位、运行目录与豆包协议说明。
- [资料库与悬浮窗](docs/desktop.md)：GUI 交互细节与会话恢复机制。
- [安装与使用说明](docs/distribution.md)：DMG 文件结构与权限说明。
- [功能验收备忘](docs/feature-acceptance.md)：已验证项目与未通过项详细清单。

项目自有源码使用 [MIT License](LICENSE)。第三方许可见 [Resources/ThirdParty](Resources/ThirdParty) 和[模型与依赖说明](Resources/Transcription/NOTICE.md)；模型权重不随 App 或仓库分发。
