# WebRTC APM 本地构建与 Swift 接入验证

2026-10-22，为 [#6](https://github.com/patrick-fu/meetingtape/issues/6) 验证独立 APM 的接入可行性。

结论：freedesktop WebRTC APM v2.1 与固定版本 Abseil 可在本机构建为静态库；Swift 通过 C 接口调用这些库的验证已通过。生产录音引擎和 SwiftPM 打包尚未实现，真实录音效果仍由 [#8](https://github.com/patrick-fu/meetingtape/issues/8) 验收。

## 构建条件

- 本机：macOS 26.6.2，arm64；Apple clang 17、Swift 6.2.3，SDK 26.2。
- APM：[v2.1 源包](https://gstreamer.freedesktop.org/data/src/mirror/webrtc-audio-processing/webrtc-audio-processing-2.1.tar.xz)，SHA-256 `ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe`。
- Abseil：强制使用上游 wrap 固定的 20240722.0 源码及其构建补丁，没有使用本机 Homebrew 的 Abseil。
- 临时工具环境：Python 3.9.6、Meson 1.11.2、Ninja 1.13.2；未安装到全局环境。
- 上游 Meson 构建，C++17、release、静态库，设置 `MACOSX_DEPLOYMENT_TARGET=14.2`。这验证了构建目标，尚未在 macOS 14.2 实机运行。

配置参数为 `--default-library=static --buildtype=release --wrap-mode=forcefallback -Dcpp_std=c++17`，编译并发数为 4。添加验证 target 后，重新配置时显式传入规范化的 build 和 source 绝对路径，再编译 target，避免使用旧的 target 列表。

## 消费端检查

隔离原型通过 APM 的 float 接口处理 20 秒合成音频：系统声音为两声道，麦克风为单声道，48 kHz，每块 480 帧（10 ms），共 2000 块。合成麦克风信号包含延迟 40 ms、衰减后的系统声音；调用方设置对应延迟。

配置启用 AEC、降噪和 AGC2 自适应数字增益，关闭 AGC1 及 AGC2 的输入音量控制。每块检查接口返回码、输入缓冲未被修改、输出采样均为有限数值。

同一验证通过 C++ 可执行文件及 Swift → C 接口 → C++ APM 两条路径执行，结果均为：

```text
PASS rate=48000 block_samples=480 frames=2000 audio_seconds=20 input_preserved=true output_finite=true digital_agc=true
PASS Swift consumer called C ABI bridge
```

`otool -L` 确认 Swift 验证程序只依赖系统框架、libSystem、libc++ 和系统 Swift 运行库；没有额外的 APM、Abseil 或 Homebrew 动态库依赖。`vtool -show-build` 确认该程序的最低系统版本标记为 14.2。

## 边界与后续

初步集成采用上游构建生成静态库、薄 C 接口供 Swift 使用的方向，生产构建仍需固定工具和依赖、保留许可证并提供可重建流程；本次没有把上游 Meson 源清单迁移为 SwiftPM C++ target。

本次未打开麦克风或系统音频采集，没有验证 m4a 写入、权限、声道对齐、外放 AEC 听感、双人同时说话、降噪失真、长时间漂移、设备切换或 3A 失败后的降级路径。合成音频的能量变化不作为真实会议音质的验收结论。

参考上游 [APM 项目说明](https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/) 和 [v2.1 接口源码](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing/-/blob/v2.1/webrtc/api/audio/audio_processing.h)。
