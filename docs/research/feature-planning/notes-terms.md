# 纪要来源与术语衔接调研

基线 MeetingTape `f7c010e81d60b9cc9f5adfbe71b3808929120c8e`，Cicada `38771f1a5ae691c848ea429f4a870defd92d9d26`；问题 [核验纪要来源与术语数据衔接](https://github.com/patrick-fu/meetingtape/issues/67)。本报告是静态源码核验，未运行模型、读取私人录音或验证 UI。下文路径均相对于仓库根目录；行号固定于上述基线。

## 现有事实：从录音到消费端

- 资料库 `RecordingItem` 保存 `SessionSnapshot`、标题及星标，身份优先录音输出路径、否则 session ID；发现流程检查完成状态和同路径 m4a 是否存在。双声道波形按声道 0/1 读取（[Library.swift:5](../../../Sources/MeetingTapeDesktop/Library.swift#L5)、[Library.swift:19](../../../Sources/MeetingTapeDesktop/Library.swift#L19)、[Library.swift:62](../../../Sources/MeetingTapeDesktop/Library.swift#L62)）。转写音源定义 system=0、microphone=1、merged 无独立声道；来源不是说话人身份（[TranscriptSource.swift:4](../../../Sources/MeetingTapeTranscription/TranscriptSource.swift#L4)）。
- 录后任务含 task ID、输入路径与 SHA256、可选 session ID、时长、各模型 run 和 recognition mode；每个 run 包含模型 `revision` 及各音源执行状态（[Models.swift:91](../../../Sources/MeetingTapeTranscription/Models.swift#L91)、[Models.swift:118](../../../Sources/MeetingTapeTranscription/Models.swift#L118)）。Qwen、MOSS、豆包可分别形成结果，`revision` 来自安装模型版本或豆包服务标识，不是文本快照版本（[TaskManager.swift:34](../../../Sources/MeetingTapeTranscription/TaskManager.swift#L34)）。segment 含整数 ID、起止秒、文本、可选 speaker、precision、source；分离音源的 ID 按序号奇偶分配，merged 直接用序号，因此不跨任务或重跑保证语义不变（[Models.swift:33](../../../Sources/MeetingTapeTranscription/Models.swift#L33)、[TranscriptSource.swift:22](../../../Sources/MeetingTapeTranscription/TranscriptSource.swift#L22)）。本地分块可能只有 `chunk` 粗粒度时间（[TaskManager.swift:228](../../../Sources/MeetingTapeTranscription/TaskManager.swift#L228)）。
- 读取结果按模型和音源组合，核验 revision、ID 唯一、来源和时间范围；缺失或损坏的音源会记录 unavailable，部分结果仍可读，结果按时间排序（[Storage.swift:79](../../../Sources/MeetingTapeTranscription/Storage.swift#L79)）。跨模型对照仅用同音源的时间重叠或起点相近匹配，不能证明两段语义相同（[Models.swift:155](../../../Sources/MeetingTapeTranscription/Models.swift#L155)）。
- 豆包实时归档以 session 为单位，段含字符串 ID、时间、final、source、connectionID、文本 revision 及可选译文；归档还有覆盖、连接和 updateRevision。连接更新替换该连接的段并保存当前归档，非历史快照（[LiveCaptionModels.swift:3](../../../Sources/MeetingTapeTranscription/LiveCaptionModels.swift#L3)、[LiveCaptionModels.swift:133](../../../Sources/MeetingTapeTranscription/LiveCaptionModels.swift#L133)）。草稿变更递增段 revision，译文需匹配 ID 和 revision（[CaptionDraftBuffer.swift:21](../../../Sources/MeetingTapeTranscription/CaptionDraftBuffer.swift#L21)）。未覆盖、失败、未定稿不可视作完整会议。
- 资料库分别加载实时归档与录后模型结果；两种正文各有从 segment.start 回听按钮，播放定位最终设置播放器 currentTime（[LibraryView.swift:188](../../../Sources/MeetingTapeDesktop/LibraryView.swift#L188)、[TranscriptionModel.swift:63](../../../Sources/MeetingTapeDesktop/TranscriptionModel.swift#L63)、[LiveCaptionArchiveView.swift:29](../../../Sources/MeetingTapeDesktop/LiveCaptionArchiveView.swift#L29)、[TranscriptionViews.swift:91](../../../Sources/MeetingTapeDesktop/TranscriptionViews.swift#L91)、[AppModel.swift:341](../../../Sources/MeetingTapeDesktop/AppModel.swift#L341)）。这是时间回听，并非现成的纪要引用解析器。
- Markdown 加载关联任务与实时稿，要求明确选择主稿，可附其他版本；正文呈现时间、音源、粗粒度标记、实时定稿/翻译及覆盖，未输出可解析的段 ID 或回链锚点（[MarkdownExport.swift:36](../../../Sources/MeetingTapeTranscription/MarkdownExport.swift#L36)、[MarkdownExport.swift:59](../../../Sources/MeetingTapeTranscription/MarkdownExport.swift#L59)、[MarkdownExport.swift:75](../../../Sources/MeetingTapeTranscription/MarkdownExport.swift#L75)）。导出文本本身不能恢复完整引用身份。

## 引用稳定性矩阵

| 引用依据 | 在原结果内 | 变更或跨版本 | 限制及处理 |
| --- | --- | --- | --- |
| session ID + task ID + model + source + segment ID | 已读取的录后结果中可定位 | 重跑、新任务或结果覆盖后不保证同一内容 | 另保存输入身份、精确稿本快照或内容摘要；解析时核对文本和时间，失败显示失效而非静默跳转 |
| session ID + 实时 connection ID + segment ID + segment revision | 当前归档能检查身份与修订 | 草稿修订、连接替换或归档更新可使旧内容不可得 | 引用时保存原文快照与时间；revision 只检测变化，不提供历史版本 |
| start/end + source | 同一录音可回听近似区间 | 模型分段不同、重叠、粗块及时间偏差使匹配不唯一 | 用于人工回听及候选查找，不自动宣称精确证据；检查录音存在及时间范围 |
| Markdown 显示时间和文本 | 可人工阅读 | ID、连接及完整稿本身份丢失 | 若需机器回链须设计可移植元数据/锚点；普通 Markdown 阅读器不保证支持 App 内跳转 |
| 模型 revision 或实时 updateRevision | 分别反映模型版本或归档更新 | 均非永久唯一稿本标识 | 不可独立作为证据地址；保存快照或校验摘要 |

## Cicada 对照

Cicada 为送入模型的当前行数组生成 `L1…`，携带时间和说话人；返回证据行号经过范围检查，取最早证据行时间。其结果适合当前数组映射，并不天然跨重排、重新转写或不同稿本稳定；数量不等于事实正确性。[编号](https://github.com/wquguru/cicada/blob/38771f1a5ae691c848ea429f4a870defd92d9d26/Sources/LiveSubs/Notes.swift#L319-L326)、[解析](https://github.com/wquguru/cicada/blob/38771f1a5ae691c848ea429f4a870defd92d9d26/Sources/LiveSubs/Notes.swift#L423-L439)。纪要提示要求证据和 `name/note/heard`，模型推测的规范名或误识别不等于已验证事实；解析过滤空值及同名，限制术语量。[协议](https://github.com/wquguru/cicada/blob/38771f1a5ae691c848ea429f4a870defd92d9d26/Sources/LiveSubs/Notes.swift#L362-L375)、[解析](https://github.com/wquguru/cicada/blob/38771f1a5ae691c848ea429f4a870defd92d9d26/Sources/LiveSubs/Notes.swift#L478-L484)。前 30 个术语进入翻译提示；这只是提示，不能保证译文遵循，也不能反向修正原文。[术语表](https://github.com/wquguru/cicada/blob/38771f1a5ae691c848ea429f4a870defd92d9d26/Sources/LiveSubs/Notes.swift#L121-L125)、[翻译提示](https://github.com/wquguru/cicada/blob/38771f1a5ae691c848ea429f4a870defd92d9d26/Sources/LiveSubs/Translator.swift#L114-L115)。

## 最小方案建议，非已实现行为

1. 将纪要作为独立派生资料，记录所选录音和具体来源稿本的身份、覆盖/partial 状态、生成时的不可变原文快照或可验证摘要；每条证据保留来源段身份、原文片段、时间及精度。模型返回的临时行号只在该次输入快照内映射，保存前验证范围。多段证据保留全部映射，不能仅保留最早时间。
2. 解析时核验原稿和原文；缺失、变化、音频不可用分别展示，允许用户查看保存的摘录；时间回听是近似定位，尤其 chunk。重跑或换模型后保留旧纪要来源，不自动改指新稿。若仅存摘要而原稿被覆盖，无法恢复原文，需明确这一取舍。
3. 可编辑术语数据与原文分离，记录规范名、别名、来源及人工确认状态；搜索时以别名扩展匹配并保留原文上下文，允许冲突和同名消歧。可在纪要生成或翻译时作为可选提示，但需区分模型建议与人工确认，防止错误规范名污染后续输出。当前源码未见该术语数据模型或搜索集成，以上为提案。
4. 导出若要保持引用，可设计附带版本身份和来源摘录的可移植标记，同时提供普通可读时间；兼容现有 Markdown 主稿选择和 partial 提示，不能假定外部阅读器能打开本地录音。

## 待用户选择

- 纪要选哪些内容、语言和结构？允许编辑及重新生成时如何保留用户修改？
- 以实时、某个录后模型还是用户明确选择的版本为来源？部分音源、未定稿及缺失区间如何提示或限制生成？
- 采用哪个模型及本地/云端服务、何时生成、是否发送原文和术语？
- 术语作用域为单次录音还是跨录音；别名建议由谁确认，冲突如何处理？Markdown 回链期望在应用内还是跨设备工作？

验证范围：静态阅读上述实现及 Cicada 源码；没有合成数据的端到端执行、精度测量、迁移或导出互操作验证。报告不证明真实模型内容、时间对齐或引用正确性。
