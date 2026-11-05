# 0.3.0 发行验收

2026-11-06，Apple Silicon，macOS 26.6.2。本版包含首次使用引导及字幕回看、位置恢复改进。

- **测试。** XCTest 3 项通过；Swift Testing 报告 65 项，其中 2 项云端 opt-in 跳过；Python 本地 runner 回归 4 项通过。
- **制品。** `scripts/package-release.sh 0.3.0` 完成 release 构建、嵌套 Developer ID 签名、Apple 公证 Accepted、DMG staple 和 Gatekeeper 检查。App/CLI 均为 0.3.0，build 8；DMG 中独立 CLI 与 App helper 字节一致。
- **消费。** 最终 DMG 内 helper 通过现有离线验收器 17 步检查，总报告保持 `PARTIAL`；真实采集与硬件边界沿已有记录。最终 App 的临时身份副本保持 Mach-O 各节及 helper 内容不变，实际走通三步引导、进入资料库、打开设置、关于页显示 0.3.0 及正常退出。数据和偏好独立，未启动录音或模型。
- **更新。** 使用最终 DMG 生成 Sparkle feed；feed 签名、下载签名、公钥、版本、build、URL 和长度均由已有脚本核验。

字幕窗明暗、回看、纠错、位置恢复检查见[字幕窗验收](caption-window.md)；首次引导起录与重启入库见[引导验收](first-use.md)。人工拖动写入、多屏插拔、跨 Space/全屏、macOS 14.2 实机、首次拒绝权限及既有音质/设备边界继续保留。未运行 CI。

DMG SHA-256：`15c44e603d211e3a889a770cfe73dc4e3b2bf3535a14c762b141a7af7c523594`。
