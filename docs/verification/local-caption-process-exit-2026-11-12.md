# 本地字幕停止收尾验收 · 2026-11-12

签名 release App 使用实际 SenseVoice 和 Apple 本地翻译，输入由合成双声道 Host 经生产 RecoveryStore 提供。验收环境为 Apple Silicon、16 GiB、macOS 26.6.2；未启用 CI。

## 问题与修补

基线 `b518fa3` 在 325.75 秒录音停止后保留了最终字幕，但两条连接仍为 `running`，且没有结束耗时。进程采样显示两个 stdout reader 停在 `NSConcreteTask.waitUntilExit`；识别子进程已退出。事件流因此没有结束，会话无法写入终态，也会阻塞等待字幕收尾的导出和退出路径。

沿用仓库 `TranscriptionProcess` 的退出通知方式：启动前注册 `terminationHandler`，stdout EOF 后等待其信号。继续校验尾包、JSON 边界与退出码。

```diff
+ register exit callback before launch
  consume stdout through EOF
- waitUntilExit()
+ wait for exit callback
  require finished event and exit 0
  persist connection state and elapsed time
```

## 结果

| 消费端 | 实际结果 |
| --- | --- |
| 原生 App | 367 秒双路识别；原文/翻译四种开关组合、展开/收起、历史阅读与回到最新、停止入库通过 |
| 收尾归档 | 最后两条连接 `completed`、结束于 367 秒且该连接的字幕全部定稿；前六条主动切换连接为 `cancelled` |
| 翻译 | 所有任务进入终态；定稿翻译失败 0，草稿翻译失败 5，明细保留实际状态 |
| 导出 | App 与内嵌 CLI Markdown 均为 45,219 字节，逐字节一致；保留未开启区间、未定稿片段和运行明细 |
| 正常退出与重开 | App 正常退出；重开显示录音和字幕，归档 SHA-256 不变 |
| 音频 | 基线与修补后 AAC 均为 48 kHz 双声道；解码帧数等于已提交帧数，首/中/尾左右声道比较通过 |
| 既有验收器 | 内嵌 CLI 完成 17 步离线恢复检查，报告按既有口径为 `PARTIAL` |

release 构建与严格嵌套签名校验通过。XCTest 3 项通过；Swift Testing 列出 88 项，83 项执行通过、5 项按条件跳过，其中实际本地模型 smoke 已执行。直接链接本轮生产模块的进程探针完成 26 次快速退出、正常 finish、非零退出、缺少尾包、残缺/额外事件及取消检查。Sol Max、Grok、GLM 独立审查未留下重要问题。

本轮输入是合成音频；物理采集、AEC 音质、设备/睡眠、跨 Space 和最低系统实机继续沿既有设备验收追踪。云端接口及识别/翻译准确率未纳入本轮结论。

## 制品与证据

临时隔离 App 只修改测试身份、目录环境和签名；执行代码与同轮 production release 的代码段一致。

| 已运行制品 | SHA-256 |
| --- | --- |
| 隔离 App 可执行文件 | `4393020d59f5c6a87833fd8690a992bfa9360dc5844b28b0afe02af71f075d58` |
| 隔离 App 内嵌 CLI | `2944e49a399356202da9d797c4cca5b00b874a4c557f2606ab8bf151ae877626` |
| App/CLI 相同的 Markdown | `2dff4e37cb18fc0f5445345ab84e428ce981dacf457847837a397555698a3dbf` |

本机证据索引为 `state/run.json`、`evidence/fixed-consumer-verification.json`、`media-verification.json`、`process-exit-boundaries.json` 与 `fixed-swift-test-rerun.log`；证据与签名制品保留在项目私有验收备份。
