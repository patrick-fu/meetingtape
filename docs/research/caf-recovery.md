# CAF 强退后的读取与 m4a 导出验证

2026-10-23，为 [#7](https://github.com/patrick-fu/meetingtape/issues/7) 核查可恢复中间音频的可行性。用户已接受强退时保留恢复材料，并以最多丢失最后 5 秒已采集音频作为验收目标。

本次通过了一个有限条件：同步写入 12 秒合成 PCM CAF、调用 `fsync`、保持 writer 未关闭，然后由父进程发送 SIGKILL；独立进程仍能使用 AVFoundation 读取该 CAF 并导出双声道 AAC m4a。没有验证生产录音或 5 秒损失上界。

## 方法与环境

- macOS 26.6.2、arm64，Apple Swift 6.2.3；编译目标默认为 `arm64-apple-macosx26.0`，没有验证 macOS 14.2。
- 不打开麦克风或系统音频，只生成左声道 440 Hz、右声道 880 Hz、幅度各 0.15 的合成信号。
- `AVAudioFile` 同步顺序写入 float32 interleaved PCM：48 kHz、2 声道、每块 480 帧、1200 块，总计 576000 帧。
- 写完后用另一个文件描述符对同一 CAF 调用 `fsync`，通知父进程 READY，保留 `AVAudioFile`；父进程立即强杀并确认退出码为 -9。没有执行正常 close/deinit。
- 独立消费者通过 `AVAudioFile(forReading:)` 检查采样帧数，再由 `AVAssetExportSession` 的 AppleM4A preset 导出 m4a；通过 ffprobe 和解码后的分声道信号复核。

本次 Swift 消费程序使用当前 SDK 的异步 export 接口；生产实现仍需选择与 macOS 14.2 兼容的接口并复测。

## 实际消费结果

| 项目 | 结果 |
| --- | --- |
| 未关闭的 CAF | 4612096 字节；末尾 `data` chunk 位于偏移 4080，size 为 -1 |
| CAF 读取 | AVFoundation 读到 576000 帧、48 kHz、2 声道；ffprobe 报时长 12.000000 秒 |
| m4a | AAC、48 kHz、2 声道；容器/流时长 12.053333 秒 |
| m4a 解码 | 576448 帧，即 12.009333 秒；仍有编码尾部长度差异，不能声称精确恢复到输入帧数 |
| 声道语义 | 在中间 1 秒窗口，左声道 440 Hz 幅度约 0.150001、880 Hz 小于 4e-8；右声道 880 Hz 约 0.150003、440 Hz 小于 7e-8 |

## 规范与设计约束

Apple 的 [CAF Audio Data chunk 规范](https://developer.apple.com/library/archive/documentation/MusicAudio/Reference/CAFSpec/CAF_spec/CAF_spec.html) 允许将末尾 data chunk 的大小设为 -1，读者据 EOF 得到长度。这是容器的可解析性规则；本实验另外确认了本机 `AVAudioFile` 在上述条件下确实输出这种文件，不能推导所有版本、格式或写入 API 都如此。

音频帧的 `mHostTime` 使用不包含睡眠的 `mach_absolute_time`，会话实际经过时间应使用包含睡眠的 [`mach_continuous_time`](https://developer.apple.com/documentation/kernel/1646199-mach_continuous_time)。需按采集 epoch 映射两者，唤醒时重新建立锚点；不能把旧缓存套用唤醒后的偏移，也不能用编码器收到数据的时刻替代采集时间。

生产保全需要完整头部、帧对齐、短写处理、数据和 metadata 的一致提交边界，以及最终编码成功前保留恢复材料。采集缓存、3A 等待、写盘队列和提交间隔之和共同占用 5 秒预算；单独设置周期 `fsync` 不能建立该上界。有效静音、缺失帧补零、处理降级也必须保持可区分。

## 尚未验证

没有验证真实采集、处理卡住、持续写入时的任意强杀点、metadata/checkpoint 原子性、部分尾帧、磁盘满、睡眠/唤醒、OS 崩溃或断电；没有确认 AAC priming/padding 的生产处理方式或最长录音的存储开销。上述路径及 5 秒目标由 [#8](https://github.com/patrick-fu/meetingtape/issues/8) 验收。

原始材料位于当轮系统临时目录 `meetingtape-capture-design-pabkrfco`：`CafProbe.swift`、`RecoverProbe.swift`、`unclean-result.json`、`recovered-result.json`、`recovered-signals.json`。临时数据不作为永久可用的下载资源；本文件保留了环境、步骤和实际消费结果。
