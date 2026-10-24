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

首次从 Codex 启动时，macOS 的权限请求可能归属于启动链中的 ChatGPT.app。已启用录屏权限不能证明独立的 AudioCapture 请求已经完成。应核对系统实际提示和 TCC 结果，不要反复重试或撤销其他应用权限。

还需分别完成正常 start/status/stop、可区分声源的左右归属、raw 与处理后麦克风对照、外放及双讲、默认输入切换、设备断连、锁屏、真实睡眠与唤醒、长录制漂移、故障时保全，以及 macOS 14.2 实机运行。这些项目不能由合成恢复或静态部署版本检查替代。
