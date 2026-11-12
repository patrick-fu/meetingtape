# Change Log

## v0.4.0 — 2026-11-12

- Add SenseVoice on-device live captions, with installation and repair from Settings or CLI.\
  新增 SenseVoice 本地实时字幕，可从设置或 CLI 安装、验证与修复模型。
- Keep translation work across caption reconnects and setting changes; complete missing translations after restart as a separate version.\
  字幕重连或切换设置时保留翻译任务，重启后可补齐缺失译文并保存为独立版本。
- Generate editable meeting notes with version history and citations back to the transcript and audio, using local or BYOK text models.\
  支持用本地或自备 Key 的文字模型生成可编辑会议纪要，保留版本历史，引用可定位到原文与录音。
- Confirm names, terms, aliases, and translations for one recording or the whole library.\
  支持确认人名、术语、别名与译名，可应用于单份录音或整个资料库。
- Show per-source recognition and translation timing, request states, and local runner CPU and memory in the App, CLI, and Markdown export.\
  App、CLI 与 Markdown 导出统一展示分音源识别及翻译耗时、请求状态，以及本地识别进程的 CPU 与内存开销。
- Keep long captions on the latest words in the compact window, preserve full history, and convert Chinese captions to the selected script.\
  小窗长字幕跟随最新文字，保留完整历史，并按所选简繁体显示中文字幕。
- Finish local-caption connections after stopping so exports and normal App shutdown can complete.\
  修复停止录音后本地字幕连接无法收尾、进而阻塞导出或正常退出的问题。
- Report an error when local MOSS decoding exhausts its generation budget instead of publishing repeated text as a successful transcript.\
  本地 MOSS 解码耗尽生成额度时明确报错，不再将重复文本作为成功转写结果。

## v0.3.0 — 2026-11-06

- Start with a guided sample, recording permissions, and model setup. Skip setup when ready, or reopen it from General settings.\
  首次使用可分步体验示例、了解录音权限并配置模型；可稍后设置，也可从通用设置重新进入。
- Keep pending model and recording preferences in sync between onboarding and Settings.\
  首次引导与设置窗共享未保存的模型和录音偏好，切换入口继续编辑。
- Read earlier captions without new content pulling you to the bottom. A new-caption hint takes you back to the latest text and resumes following.\
  回看历史字幕时保留阅读位置；出现新内容时轻提示，点击回到最新并恢复跟随。
- Remember the caption window position for each display and keep restored windows within the visible screen area.\
  按显示器记忆字幕窗位置，重开恢复时保持窗口处于屏幕可见区域。

Local builds, automated checks, and native UI verification are documented in the [first-use](docs/verification/first-use.md) and [caption-window](docs/verification/caption-window.md) records, including remaining hardware checks.\
本地构建、自动化检查和原生界面验收见[首次使用](docs/verification/first-use.md)与[字幕窗](docs/verification/caption-window.md)记录，包含待补的实机检查。

## v0.2.3 — 2026-11-03

- Reduce runaway repetition in local Qwen transcription with a mild repetition penalty and a generation budget based on audio duration.\
  为本地 Qwen 转写加入轻度重复惩罚，并按音频时长限制生成长度，减少异常复读。
- Report an error when Qwen exhausts its generation budget, preserve completed chunks and diagnostics, and let you retry from the unfinished chunk.\
  Qwen 耗尽生成额度时明确报错，保留已完成分块与诊断信息，可从未完成的音频块继续重试。

## v0.2.2 — 2026-11-03

- Blend the library and Settings title bars into their content in dark mode, matching the unified appearance in light mode. Keep native window controls and content spacing when switching appearance or reopening windows.\
  修复资料库与设置窗在深色模式下顶部色带分割的问题，标题栏与正文融合，浅色外观保持一致。切换外观、关闭重开时保留原生窗口按钮和正文间距。

## v0.2.1 — 2026-11-03

- Fix recording startup failing when microphone preparation is slow, including Bluetooth format changes. Audio enters the recording queues after both devices are prepared; preparation time is excluded from the recording start.\
  修复麦克风准备较慢时录音启动溢出的问题，涵盖蓝牙格式切换触发的等待。两路设备准备完成后再接收音频，准备耗时不再计入录音起点。

- Keep the same receiving sequence when capture restarts after sleep, and re-enable replacement streams during device recovery.\
  睡眠后重新启动采集沿用同一接收顺序，设备重建后的音源继续开启接收。

- Hide “Recover Recording” when the committed recovery timeline is empty. Keep the original recording failure visible if a recovery attempt fails, and preserve the recovery materials.\
  已提交恢复时间线为空时隐藏“恢复录音”；恢复失败时保留最初录音错误，恢复材料继续留存。

Runtime device switching, physical sleep/wake, and existing audio-quality and hardware acceptance gaps remain tracked separately. No change to transcription providers or credential storage.\
运行中设备切换、物理睡眠唤醒及既有音质和硬件验收缺口继续单独跟踪。转写服务与凭据存储保持原有行为。

## v0.2.0 — 2026-11-03

- Add an independent global settings window. Open it from the library, menu bar, or ⌘, and navigate General, Recording, Models, Live Captions, Storage & Export, and About.\
  新增独立全局设置窗，可从资料库、菜单栏或 ⌘, 打开，统一管理通用、录音、模型、实时字幕、存储与导出、关于。

- Group live-transcription setup, default post-recording models, and subtitle translation by purpose. Keep independent transcripts from multiple post-recording models and choose a primary transcript.\
  按用途管理实时转写设置、录后默认模型和字幕翻译；录后支持多模型对照及主稿优先顺序。

- Manage Doubao BYOK connections, installed local models, recommended model versions, and translation language packs in one place. A replacement key is tested before it is saved to Keychain; a failed test leaves the existing key unchanged.\
  集中管理豆包 BYOK、本地已安装模型、推荐版本和翻译语言包。更新 Key 时先测试再存入钥匙串，测试失败保留原凭据。

- Add light, dark, and system appearance options, plus a default for including other transcript versions in Markdown exports. Recording, caption, and update preferences use the existing app services.\
  支持浅色、深色和跟随系统外观；新增 Markdown 默认附加其他稿件版本的选项，录音、字幕和更新偏好接入现有功能。

- Fix pending preference edits being lost during background refresh, and allow an unavailable model to be removed from a multi-model selection while keeping at least one model selected.\
  修复后台刷新可能丢失未保存编辑的问题；支持从多选中移除不可用模型，同时保留至少一个所选模型。

Apple Silicon, macOS 14.2 or later. Apple local text translation requires macOS 26 and installed language packs. The connection test checks file-transcription request acceptance; live transcription and text translation need their own service permissions. Existing audio, device, sleep, first-run permission, and window-coverage limitations remain documented in the acceptance records.\
支持 Apple Silicon、macOS 14.2 及以上。Apple 本地文字翻译需要 macOS 26 和已安装的语言包。连接测试只验证文件转写请求被接受，实时转写与文字翻译需分别开通服务。音频、设备、睡眠、首次权限及窗口场景的既有验证边界继续见验收记录。

## v0.1.0

- 新增 Sparkle 自动更新：后台检查与下载，在正常退出时安装；菜单提供检查更新与自动更新开关。
- 录音、保存、模型安装及后台转写未完成时延后安装；手动安装的重试会重新检查任务状态并保护新录音入口。
- 使用 HTTPS 更新源和 Ed25519 签名，下载后先验签再解包；App、内嵌组件和更新制品保留 Developer ID 签名与公证流程。
- 版本按 SemVer 发布，当前为 0.1.0；后续更新保留录音、资料库、模型与 BYOK 设置。独立 CLI 继续手动更新。
- 豆包云端文字翻译已用现有项目 API Key 完成中英互译与目标语言跳过测试；本次账户旧版 Token 路径仍报未授权，不将其解释为接口不支持旧版认证。

旧版未内置更新器，需要手动安装本版一次。现场 AEC、短暂麦克风断档、睡眠/唤醒、全新机器首次权限、最低系统实机及完整窗口矩阵的既有验收缺口继续保留，详见 `docs/feature-acceptance.md`。

## v0.1.0-beta.2

- 保留立体声的两路独立回声参考，修复参考被平均为单路后无法分别建模左右声学路径的问题。

确定性双声源对照的参考相关残留降低约 26 dB，单声道对照结果不变；这不是物理外放 AEC 或真人双讲已通过的结论。既有设备、权限与声学验收边界继续保留，详见 `docs/feature-acceptance.md`。

## v0.1.0-beta.1

- 原生 macOS 录音和资料库；系统音频保留左声道，处理后的麦克风保留右声道，处理失败如实降级。
- 默认分音源转写，可选择合并；Qwen、MOSS 与豆包各自保留正文、失败重试和运行观测。
- 实时转写与基础字幕翻译分别开关，支持 Apple 本地文字翻译及手选豆包 BYOK，保留缺失区间和目标语言变化。
- 196 宽的字幕悬浮窗支持展开、收起和取消置顶；资料库与 CLI 可导出主稿、其他版本和运行明细。
- 新增黑白字幕气泡 App 图标，包含 Retina 与小尺寸资源。
- 修复历史字幕读取失败后的原稿覆盖、单路失败无法重连及迟到重试影响新录音的问题。
- 正文文件缺失时明确标记音源，保留其他可读取正文；修复重叠讲话时小窗停留在旧短句的问题。
- 单路正文损坏时保留其他音源及可恢复的部分稿；缺失旧稿不再阻断独立完好主稿导出，并保留失败任务的状态记录。
- 运行明细的总耗时计入各音源的排队时间；多路统计保持在同一张表中，资源测量范围另列说明。

首版面向 Apple Silicon。Apple 本地文字翻译需要 macOS 26 与系统语言包；豆包文字翻译另需 `volc.speech.mt` 资源权限，当前测试账户尚未完成正向验收。AEC、长录音、设备/睡眠、最低系统实机及跨 Space/全屏缺口见 `docs/local-verification.md` 与 `docs/feature-acceptance.md`；预发布不代表这些检查通过。
