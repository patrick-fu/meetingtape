# 本地构建与验收

所有检查在本地执行。当前没有 CI 工作流。macOS 14.2 及以上、Apple Silicon、Xcode 命令行工具和有效的 Developer ID Application 签名身份是构建前提。

```sh
./scripts/build-local.sh debug
swift test
```

脚本首次运行会下载并校验固定版本的 WebRTC APM 与 Abseil，随后静态链接。已签名制品位于 `.build/local/debug/meetingtape`。脚本核验签名、嵌入的权限说明、动态依赖和 macOS 14.2 最低版本。`release` 参数可生成本地 release 制品。

## 无硬件恢复验收

安装 `ffmpeg`、`ffprobe`，选用一个已存在的可写目录。

```sh
python3 scripts/verify-local.py \
  --binary .build/local/debug/meetingtape \
  --out /absolute/existing/output-directory
```

验收器为本轮创建独立状态目录，运行公共帮助、doctor、status 和 recover 命令。它使用生产 RecoveryStore 生成已提交 PCM、时间线空洞和未提交尾部，确认活跃 writer 无法被恢复，然后只强杀自己启动的 fixture 进程。

恢复通过公共 CLI 执行。检查包括 AAC、48 kHz、双声道、已提交前缀的逐块误差、空洞静音、raw PCM 样本一致、metadata 引用和原有文件未被覆盖。结果、命令输出、二进制 SHA-256 和保留材料位于输出目录下的 `meetingtape-acceptance-*`。

即使这些检查全部通过，整体验收仍报告 `PARTIAL`。合成材料不证明真实采集、源声道归属、3A 音质或五秒尾损上界。

## 真实录音

取得麦克风和系统录音授权后，可添加 `--record`。这会录制约 12 秒、读取真实 status、核对宿主身份、强杀本轮宿主，再恢复已提交前缀。`--seconds` 支持 8 至 60 秒。

```sh
python3 scripts/verify-local.py \
  --binary .build/local/debug/meetingtape \
  --out /absolute/existing/output-directory \
  --record --seconds 12
```

该路径会实际使用麦克风并录制系统播放的声音。结束后保留录音和证据。启动超时必须由 CLI 清理自己创建的宿主；脚本成功启动后的异常路径会请求 stop。

实录尾损检查同时记录最后一次 status 的观测差，以及从 start 调用前到确认宿主退出的保守上界。单次通过不能证明任意强杀时点都满足五秒目标。

首次从 Codex 启动时，macOS 的权限请求可能归属于启动链中的 ChatGPT.app。已启用录屏权限不能证明独立的 AudioCapture 请求已经完成。应核对系统实际提示和 TCC 结果，不要反复重试或撤销其他应用权限。

完整设备验收还包括可区分声源的左右归属、raw 与处理后麦克风对照、外放及双讲、默认输入切换、设备断连、锁屏、真实睡眠与唤醒、长录制漂移、故障时保全，以及 macOS 14.2 实机运行。这些项目不能由合成恢复或静态部署版本检查替代。

## 本轮实测结果（2026-10-25）

在 macOS 26.6.2 上，生产源码提交 `494084b` 的 debug/release 均通过签名构建；35 项测试通过，其中恢复测试包含新旧 CAF 两种材料。对应制品：

| 制品 | SHA-256 |
| --- | --- |
| debug | `646d6ae24cb85ac00151da57d7b20f65e94cb7676d02acdd82a9e931a8d23d17` |
| release | `94ab151bcc9d39039b615d6e452cf6386ead6dfb5b621a9349e5870556235518` |

- 最终 release 正常 start/status/stop 录制 30.5385625 秒，独立解码确认 AAC 48 kHz stereo、raw 单声道与 metadata 帧数一致。左声道匹配两路系统声标记；稳态未出现此前的周期性麦克风缺口。启停边界仍有三段明确降级，未计为声音完整无缺。AAC 解码比 raw 多 453 帧，属本次实际时长差异。
- 最终 release 经真实 SIGKILL 后公共 recover 恢复，25 步检查通过：已提交 AAC 前缀误差、raw 逐样本一致、metadata 引用及无覆盖。此次尾损观测 0.743 秒，保守上界 0.765 秒；整体验收保持 `PARTIAL`。最终 debug 另通过 17 步无硬件公共 CLI 检查。
- 修补前一版 release `fe5094d0…e1b9e038` 完成三分钟无主动播放录制，raw 8,671,391 帧与 metadata 一致，稳态无新增中断或降级；它只支持该版这条短期稳定性路径。
- 有效短尾另用实际 render、RecoveryStore 和最终 CAF 消费验证：1001 帧目标保留最后 41 个有效样本；从第 100 帧续写时，首 380 帧 raw 后接完整处理块。该探针的采集和处理为 stub，未替代真实睡眠或 APM 音质验收。

本机原始步骤、制品与报告哈希入口为 `<LOCAL_EVIDENCE_PATH>`。累计审查、修复依据与消费者证据另回写关联的 GitHub 验收票。

仍未验证真实近端语音及双讲 3A、物理多输出覆盖、设备变化、真实睡眠、长期漂移、故障时点矩阵、disk-full/OS crash/power-loss 和 macOS 14.2 运行。本轮没有配置或执行 CI，未发布或合并。
