# 0.4.0 发行验收

2026-11-12，Apple Silicon，macOS 26.6.2。本版合入 #84、#85、#86、#88、#90，以及此前已合入的 MOSS 解码额度修补 #55。

- **测试。** XCTest 3 项通过；Swift Testing 列出 88 项，82 项执行通过，6 项按条件跳过；Python 本地 runner 回归 11 项通过。未运行 CI。
- **制品。** release 构建、嵌套 Developer ID 签名、Apple 公证 Accepted、DMG staple 和 Gatekeeper 检查通过。App 与 CLI 均为 0.4.0、build 9，CLI 的嵌入 plist 也已核对。独立 CLI 与 App helper 字节一致，转写资源目录相同。
- **消费。** 最终 DMG 内 helper 通过既有离线验收器 17 步检查，总报告为 `PARTIAL`。从最终 DMG 提取的 App 临时身份副本保持执行代码及 helper 不变，实际检查资料库、波形、原文与译文、模型设置、关于页版本及正常退出。App/CLI 导出逐字节一致。
- **更新。** 最终 DMG 通过现有 Sparkle 工具签名；生成的 feed、下载签名、公钥、版本、build、URL 与长度已由发行脚本核对。更新脚本改为查找唯一 Sparkle 工具目录，与构建脚本一致，支持不同名称的任务 worktree。

同一生产代码此前完成 367 秒实际 SenseVoice 与 Apple 本地翻译的双路原生流程，包含字幕开关、历史阅读、停止、导出与退出重开；见[本地字幕收尾验收](local-caption-process-exit-2026-11-12.md)。纪要与术语见[纪要验收](meeting-notes-2026-11-09.md)。本轮发行消费检查使用复制的合成资料库，未重复执行模型推理或云端补齐请求。

真实豆包签名 App 重启补齐、物理采集与 AEC、设备/睡眠、跨 Space/全屏、macOS 14.2 实机及完整自动更新安装/重启周期继续沿既有验收记录追踪。

DMG SHA-256：`23353cbf7c5969bbe02db594a22c67bd0c8d35a4d7fac84f503bf9b196d2e5a9`。
