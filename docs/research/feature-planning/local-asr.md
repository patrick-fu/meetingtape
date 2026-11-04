# 本地实时转写：能力与兼容事实

基线 `f7c010e81d60b9cc9f5adfbe71b3808929120c8e`，2026-11-04。下文将官方契约、仓库源码推断和本机实测分开；不代表产品选择或准确率评估。

## 能力矩阵

| 维度 | Apple SpeechAnalyzer + SpeechTranscriber | MeetingTape 现有 Qwen / MOSS | 现有实时字幕（对照） |
| --- | --- | --- | --- |
| 系统与设备 | macOS 26+ API；运行时还须检查 `isAvailable`，不能只凭系统版本判断。一个 analyzer 同时只处理一个输入序列。 | 项目最低 macOS 14.2（[Package.swift](../../../Package.swift#L11)）；本地安装检查 arm64、至少 16 GiB（[LocalModels.swift](../../../Sources/MeetingTapeTranscription/LocalModels.swift#L33)）。这不是模型所有可能运行环境的声明。 | 当前实时路径为豆包 WebSocket，非本地（[LiveCaptionSession.swift](../../../Sources/MeetingTapeTranscription/LiveCaptionSession.swift#L157)）。 |
| 语言 | 动态查询 `supportedLocales`、`installedLocales`；支持不等于已下载，设备也可能不支持。下表为本机快照。 | 现有调用没有实时语言选择或实时语言能力契约；具体模型版本的语言覆盖、混语表现未在本次验证。 | 未测试。 |
| 资产 | `AssetInventory` 管理系统资产，需检查状态，缺失时可能需要下载；本次未安装。 | 安装器支持复用或下载，验证通过才标记 ready，模型与 Python 路径记在安装记录中（[LocalModels.swift](../../../Sources/MeetingTapeTranscription/LocalModels.swift#L42)）。本次未检查或运行用户已有 Qwen/MOSS 资产。 | 需要服务凭据及网络。 |
| 音源 | 输入序列由调用者提供；两路可分别建立 analyzer，这是设计推断，实际并行、资源及时间对齐未测。多个相似配置的 transcriber 可共享底层引擎和模型不等于保证并行吞吐。 | 录后任务按音源、音频块处理并保存结果（[TaskManager.swift](../../../Sources/MeetingTapeTranscription/TaskManager.swift#L179)）；不是当前实时字幕后端。 | 每个 source 建立独立会话（[LiveCaptionSession.swift](../../../Sources/MeetingTapeTranscription/LiveCaptionSession.swift#L48)）；读取器选择左右声道或混合（[LiveAudioReader.swift](../../../Sources/MeetingTapeTranscription/LiveAudioReader.swift#L125)）。 |
| 结果生命周期 | 支持临时和最终结果；具体行为由配置决定。见下述范围和停止语义。 | runner 完成模型生成后输出 text、segments（[local_runner.py](../../../Resources/Transcription/local_runner.py#L118)）；当前接入没有实时草稿生命周期。Qwen 内部以 30 秒 chunk 生成，不能据此宣称已有流式 UI。 | 草稿与定稿由服务结果驱动；结束时发送最终音频并等待服务终帧，最多等待 12 秒（[LiveCaptionSession.swift](../../../Sources/MeetingTapeTranscription/LiveCaptionSession.swift#L220)）。 |

官方依据：[SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)、[SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)、[AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)、[WWDC25 SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)。

## 已送入、识别与停止边界

Apple 的 [`volatileRange`](https://developer.apple.com/documentation/speech/speechanalyzer/volatilerange) 包含尚未返回结果但已交付分析的音频，也包含可能变化的结果；范围之外结果不会被替换。送入时间不是已识别、已定稿时间。此前可变结果若定稿时未变化，模块不一定再次发出最终结果；消费端不能假设每个草稿都会有新 final 事件。`finalize(through:)` 返回时结果已发布，但消费任务未必已读完；[`finalizeAndFinishThroughEndOfInput()`](https://developer.apple.com/documentation/speech/speechanalyzer/finalizeandfinishthroughendofinput()) 等输入结束、完整消费和结果定稿，消费端仍须等待结果序列结束。普通 `finish(after:)` 不保证已完成分析。

现有 `connection.end` 是音频发送后按 reader cursor 更新的边界（[LiveCaptionSession.swift](../../../Sources/MeetingTapeTranscription/LiveCaptionSession.swift#L209)），不是服务已经识别的覆盖边界。快速长句中，用送入时间强制截断可能跨过未返回的音频；Cicada 的[公开问题](https://github.com/wquguru/cicada/issues/1)报告漏字，但本次未复现，也不能归因于 Apple 引擎。应以合成参考全文对照最终保存文本，分别记录输入、可变范围、结果范围和停止后尾句，验证静音、快速长句及两路并行。

## 本机只读资产查询与合成文件实测

macOS 26.6.2，arm64，Apple Swift 6.2.3。`xcrun swiftc -parse-as-library ../evidence/inventory.swift -o ../evidence/inventory && ../evidence/inventory` 返回 `isAvailable=true`。安装语言：`en_AU en_CA en_GB en_IE en_IN en_NZ en_SG en_US en_ZA zh_CN zh_TW`。支持语言另含 `de_AT de_CH de_DE es_CL es_ES es_MX es_US fr_BE fr_CA fr_CH fr_FR it_CH it_IT ja_JP ko_KR pt_BR pt_PT yue_CN zh_HK`；该清单是本机该时刻的查询结果，不是所有 macOS 设备的承诺。

使用 `say -v Samantha -o ../evidence/sample.aiff` 生成两句英文，`xcrun swiftc -parse-as-library ../evidence/file.swift -o ../evidence/file && ../evidence/file ../evidence/sample.aiff` 以 `en_US`、`progressiveTranscription` 和文件输入执行，随后调用 `finalizeAndFinishThroughEndOfInput()` 并等待结果序列。观察到逐步变化的 `final=false`，两句均出现 `final=true`，包括末句 “This last sentence must appear before the transcription session ends.”。这仅证明该文件、设备和配置下的行为；文件输入并非实时节奏测试，也不证明所有尾句或停止时机均可靠。探测源码和文本输出见[证据目录](evidence/local-asr/)，未播放、采集或上传音频，也未触发资产下载。

## 补充实测：中文、双进程及快速长句

同机 `say -v '?'` 列出 Tingting，使用 `say -v Tingting` 本地生成中文文件；将探测程序改为接受 locale 参数后运行 `../evidence/file ../evidence/zh.aiff zh_CN`。得到临时结果和一条最终结果：`这是一个合成语音测试最后依据也应该在转写结束之前出现。` 参考为 `这是一个合成语音测试。最后一句也应该在转写结束之前出现。`；“一句”识别成“依据”，句中标点也不同，尾部文字仍出现。这是单条合成样本，不构成中文准确率评估。

用 Samantha 以 `say -r 300` 生成一条较快英文长句，和原英文文件各启动一个独立进程、各自创建 analyzer，并在同一 shell 中并发等待：两者退出码均为 0，均取得最终结果。长句的最终文本包含从开头到末尾 `silver lantern at the very end` 的参考词，标点有所变化。此实验是两个进程并行文件输入，并非同一进程双音源或实时节奏；不证明持续并发吞吐、延迟、普遍不漏字或中途停止安全。

可复核材料：[探测源码](evidence/local-asr/file.swift)、[资产查询源码](evidence/local-asr/inventory.swift)及[输出](evidence/local-asr/inventory-output.txt)、[中文参考](evidence/local-asr/zh-expected.txt)及[输出](evidence/local-asr/zh-output.txt)、[英文参考](evidence/local-asr/en-expected.txt)、[快速长句参考](evidence/local-asr/fast-expected.txt)、并发[输出一](evidence/local-asr/concurrent-one.txt)、[输出二](evidence/local-asr/concurrent-two.txt)及[退出状态](evidence/local-asr/concurrent-status.txt)。文件音频均由本机语音合成。未安装新资产、采集或播放音频。

关于未变内容：Apple [`volatileRange` 文档](https://developer.apple.com/documentation/speech/speechanalyzer/volatilerange)明确写道模块无需为此前 volatile、但定稿时未变化的音频范围提供新的 final results；这是一项面向模块的通用契约，并非本次对 SpeechTranscriber 所有配置的实测，也不能单凭它判断某条 `SpeechTranscriber.Result.isFinal` 一定会或不会再次发布。范围冻结和结果流消费需分别处理。

## 当前验证范围与未决问题

已测本机资产列表、英文和中文合成文件、一次加速英文长句及两个独立进程并发文件输入。未测混语、实时速率、停止中断、同进程双音源、资源消耗、系统性精度及其他硬件/系统；Qwen/MOSS 的实际安装和识别也未测。不能据此次文件测试推断快速语音普遍不漏字。产品仍需决定旧系统行为、缺资产提示/下载授权、语言选择与混语策略，以及中途停止和失败时如何显示覆盖范围。
