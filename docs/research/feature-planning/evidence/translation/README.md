# 翻译调度离线探测

MeetingTape基线 `f7c010e81d60b9cc9f5adfbe71b3808929120c8e`，执行于2026-11-04。[事实报告](../../translation.md)说明检查范围与限制。[result.txt](result.txt)保存本轮实际执行的13项通过结果。

仓库根目录运行：

```sh
bash docs/research/feature-planning/evidence/translation/run.sh
```

要求本机Swift编译器、Python 3，不需要整套构建或外部依赖。run.sh在系统临时目录生成和运行探测，退出时清理。

- `Main.swift`：手写输入、合成字幕与断言。假翻译适配器仅等待本地650ms并返回合成文字，有意忽略Task取消；不读取凭据或音频，不调用翻译服务。
- `make_probe.py`：从当前源码提取production schedule方法，复制完整LiveCaptionModels；SubtitleModels和CaptionDraftBuffer直接以原文件编译。生成副本中的TranscriptSource移除MeetingTapeCore import，RecognitionMode alias换为最小enum，TranscriptionFailure提供同语义最小类型。
- 调度探测的ingest复用生产receive的取消/调度步骤；apply只调用真实buffer并记录结果。未执行生产WebSocket、持久化回调或Desktop时序，因此不等同整条生产链验收。
- 可执行文件、生成的Models.swift/Schedule.swift和合成归档均可重新生成，不纳入分支。公开目录调整后未再次运行探测；主agent可用上述入口复现。
