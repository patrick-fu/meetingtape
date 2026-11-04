# 本地实时识别：同进程双路节奏探测

2026-11-05，MeetingTape 基线 `f7c010e81d60b9cc9f5adfbe71b3808929120c8e`，macOS 26.6.2、Apple Silicon。补充[本地实时转写](https://github.com/patrick-fu/meetingtape/issues/57)的能力依据。

## 方式

用本机 `say` 生成约 5 秒的英文、中文文件，在同一进程创建两个独立 SpeechAnalyzer，分别以 en_US、zh_CN 识别。每路使用 16 kHz 单声道 Int16，按 0.2 秒块的音频时长等待并持续送入，最后结束输入、执行 `finalizeAndFinishThroughEndOfInput()`，等待结果序列消费完毕。

未采集麦克风或系统音频，未播放音频、调用云端或安装语言资产。格式只读查询表明，本机这两种 locale 的 `bestAvailableAudioFormat` 均为单声道 16 kHz Int16。

## 观测

| 输入 | 开始 | 首次草稿 | EOF | 最终结果 |
| --- | ---: | ---: | ---: | ---: |
| 中文 | 0.000 s | 1.055 s | 5.270 s | 5.373 s |
| 英文 | 0.088 s | 1.143 s | 5.136 s | 5.289 s |

所有时间共享探针顶层的同一个 Date 起点。两路都返回草稿和包含尾句的最终结果，进程退出 0；英文正文与参考一致，中文文字一致、标点有差异。这些时间是该次短样本观测。

Float 输入的早期尝试在 `SpeechRecognizerWorker.preRunRecognition` 出现 SIGTRAP，单流对照也失败；文件输入基线成功。改为上述 Int16 格式后双路节奏探测成功。输入路径和格式之间仍有未解释因素，崩溃根因尚未确定。

## 证据与范围

[探针和运行命令](evidence/local-live-paced/commands.txt)、[识别源码](evidence/local-live-paced/dual.swift)、[参考与结果](evidence/local-live-paced/result.json)、[完整成功日志](evidence/local-live-paced/run4.log)、[格式查询](evidence/local-live-paced/formats.log)及失败尝试日志随本分支保留。音频可按命令由系统声音重新生成。

本次只证明这台设备、这两条合成文件的同进程并发与正常 EOF 尾句。真实录音接入、混语、快速长句、中途开关、输入缺口、资源开销和其他设备/系统仍需验证；没有将该探针接入 App。
