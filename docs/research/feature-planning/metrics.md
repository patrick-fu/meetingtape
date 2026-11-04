# 实时处理统计的数据来源与计量边界

基线 MeetingTape `f7c010e81d60b9cc9f5adfbe71b3808929120c8e`，2026-11-04。关联[核验实时处理统计的数据来源与计量边界](https://github.com/patrick-fu/meetingtape/issues/69)。本次为字段与消费端的静态核验。

## 现有字段

| 数据 | 来源与当前含义 | 统计范围 |
| --- | --- | --- |
| 实时连接耗时 | `CaptionConnection.elapsedSeconds`；会话执行过程的 uptime 差 | 连接级，包含等待和收尾；不是逐句识别耗时 |
| 连接 start/end | 当前连接送入音频的录音时间范围 | 输入边界；不代表该范围已全部识别或定稿 |
| 原文 start/end、final | ASR 返回的音频时间与定稿状态 | 只有时间位置，没有独立的“结果到达”宿主时钟 |
| 翻译 elapsedSeconds | `TextTranslation` 在语言判断后启动 ContinuousClock，成功时保存选定 provider 路径耗时 | 包含该路径中的可用性查询/翻译等等待；不含先前防抖、ASR 或 UI 上屏；同语跳过提前返回 |
| 翻译 usage/provider | 保存服务返回的可解析用量字典与提供方 | 已保留译文的用量；被取消或覆盖请求的完整账本尚未保存 |
| 录后 queuedAt/startedAt | 每音源 attempt 的排队和开始时间 | 可计算等待时间；是调度时间戳，不是模型纯计算时间 |
| 录后 elapsedSeconds | attempt 开始到结束 | 包含等待录音优先资源等时间 |
| 录后 executionSeconds | 本地累加持有推理租约期间的切音频、启动 runner 等时间；云端沿 attempt elapsed | 包含准备和调用；不是单独 generate 的纯推理耗时 |
| CPU/RSS/observedChunks | Python `getrusage(RUSAGE_SELF)`；Swift 对有效统计累加 CPU、取 RSS 最大值并计数 | runner 进程，包括加载等开销；读取发生在退出状态判断前，可含失败调用的有效统计 |
| completedAudioSeconds | 从已完成块进度和成功状态更新 | 完成进度，不代表本次 attempt 新处理的唯一音频量 |

来源：[LiveCaptionSession.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeTranscription/LiveCaptionSession.swift#L185)、[TextTranslation.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeTranscription/TextTranslation.swift#L14)、[TaskManager.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeTranscription/TaskManager.swift#L140)、[TaskManager.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeTranscription/TaskManager.swift#L187)、[local_runner.py](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Resources/Transcription/local_runner.py#L167)。

## 消费端

- Markdown 重新读取任务与实时归档，输出可得的逐译文耗时/用量、连接与录后 attempt 明细；见 [MarkdownExport.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeTranscription/MarkdownExport.swift#L129)。
- CLI 通过任务/字幕 JSON 与 Markdown 导出提供数据；见 [TranscriptionCommand.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeCLI/TranscriptionCommand.swift#L82)。
- App 当前侧重任务状态与正文；完整的统计呈现方式在[实时处理耗时与资源统计](https://github.com/patrick-fu/meetingtape/issues/63)中讨论；见 [TranscriptionViews.swift](https://github.com/patrick-fu/meetingtape/blob/f7c010e81d60b9cc9f5adfbe71b3808929120c8e/Sources/MeetingTapeDesktop/TranscriptionViews.swift#L50)。

## 可计算与需要新增观测的部分

| 项目 | 当前可行范围 | 后续验证方法 |
| --- | --- | --- |
| 翻译 p50/p95 | 可对已保存且有 elapsedSeconds 的样本计算；需明确算法、provider、状态及样本量 | 固定数组核对算法；区分保留结果与全部请求总体 |
| 逐句 ASR 延迟 | 缺结果到达时钟及其与录音时间轴的映射 | 对已知时间的输入记录音频可用、送入与 final 到达；分别说明缓冲、网络、判停和识别的合并范围 |
| 防抖/队列等待 | 当前 450ms 为调度代码中的防抖，未单独落盘 | 记录 revision 到达与请求实际启动，区别主动防抖、排队和服务调用 |
| 所有请求与失败开销 | 当前归档保存的是结果快照，无法重建完整请求生命周期 | 用受控延迟/失败/取消适配器核对请求开始、结束、替换与结果落库 |
| 进程/模型资源 | 当前只有 runner CPU/RSS 的明确边界 | 需要单独设计 App、worker、加载、推理及系统服务的观测；RSS 不等同于 GPU/ANE 或整机用量 |
| 云端内部资源 | 当前服务响应及导出没有服务器 CPU、内存或 GPU 数据 | 以实际 API 返回为依据，缺失时显示可用性 |

系统服务资源即使能从整机观测，也不能直接归因到单模型或单句；当前实现没有提供这种归属。

Cicada [逐句诊断与汇总](https://github.com/wquguru/cicada/blob/38771f1a5ae691c848ea429f4a870defd92d9d26/Sources/LiveSubs/Diagnostics.swift#L6-L52)可作指标设计参考。其分位点代码采用排序后取索引；算法、样本分组与显示门槛在本项目讨论确定。

## 待讨论与验证范围

待讨论：逐句延迟的时间锚点、分组和失败样本口径、统计入口与导出形态。保留既有“资源数据标明范围”的约定，以真实字段说明可得性。

本轮没有测量云端 RTT、本地服务资源或实际性能分布。主 agent 已复核统计写入、runner 单位与导出消费；翻译调度的受控探测见[实时字幕修订与翻译调度现状](https://github.com/patrick-fu/meetingtape/issues/66)。
