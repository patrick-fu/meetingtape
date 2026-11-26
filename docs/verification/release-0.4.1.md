# 0.4.1 发行验收

2026-11-26，Apple Silicon，macOS 26.6.2。本版合入 #93（隔离本地 Qwen/MOSS 解码耗尽音频块，并区分推理锁排队与录音优先让路状态）。

- **测试。** XCTest 4 项通过；Swift Testing 92 项通过（6 项按条件跳过）；Python 本地 runner 回归（`test_local_runner.py`）7 项通过。未运行 CI。
- **制品。** release 构建、嵌套 Developer ID 签名、Apple 公证 Accepted（`33bec454-c6d4-4d77-9d9a-e561566f612a`）、DMG staple 和 Gatekeeper 检查通过。App 与 CLI 均为 0.4.1、build 10，CLI 的嵌入 plist 也已核对。独立 CLI 与 App helper 字节一致，转写资源目录相同。
- **消费。** 最终 DMG 内 helper 通过既有离线验收器 17 步检查，总报告为 `PARTIAL`。本轮未重新执行签名 App GUI 目视巡检与真实 MOSS 模型端到端推理。
- **更新。** 最终 DMG 通过现有 Sparkle 工具签名；生成的 feed、下载签名、公钥、版本、build、URL 与长度已由发行脚本核对。

真实豆包签名 App 重启补齐、物理采集与 AEC、设备/睡眠、跨 Space/全屏、macOS 14.2 实机及完整自动更新安装/重启周期继续沿既有验收记录追踪。

DMG SHA-256：`0d4e97089ee7736a2e9caa87b621643ba88e38464db9fdec661984d4bcb4f35b`。
