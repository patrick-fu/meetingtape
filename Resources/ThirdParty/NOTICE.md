# 原生音频处理依赖

MeetingTape 静态链接 webrtc-audio-processing 2.1 及 Abseil 20240722.0；本目录保留对应源码发行包与其音频处理第三方组件的许可证。来源、固定 SHA-256 与构建选项见 `scripts/build-apm.sh`。这些条款不因 MeetingTape 自有代码使用 MIT 而被替换。

- WebRTC Audio Processing：COPYING、WebRTC-LICENSE.txt。
- Abseil：Apache License 2.0，见 Abseil-LICENSE.txt。
- 内含第三方音频代码：PFFFT、RNNoise、FFT、SplSqrtFloor、Ooura 的许可各自保留。

本地转写模型与 Python 包在安装时下载，不包含在原生二进制中；对应条款见另附的 `Transcription/NOTICE.md`，安装器保留模型随附许可。
