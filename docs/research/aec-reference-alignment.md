# 外放 AEC 的参考时序

2026-10-25。用户试听发现右声道仍包含扬声器声音；近端语音被保留不能证明回声已消除。

## 社区实现

| 项目与读取版本 | 有用的机制 | 适用边界 |
| --- | --- | --- |
| [Echoless `0b7a77c`](https://github.com/Haor/echoless/tree/0b7a77cf152af0b545cdeb16849ec812c2511418) | macOS Process Tap 的参考可能晚于麦克风里的回声，默认给近端增加 25 ms 延时；探测器有质量门禁，不能拿低可信结果覆盖校准值。 | 使用 Rust AEC3 实现及虚拟麦克风，不能假定配置、内部延时和本项目的 APM 2.1 一致。 |
| [Echoff `e0f1e41`](https://github.com/KoljaB/echoff/tree/e0f1e41193b0ca7bd9ac972ec5deb99ea010fc72) | 采样序号保持连续，时间戳用于启动对齐；每对先送 reference，再送 microphone；间断后重置处理状态。 | 没有 macOS 原生采集后端。启动锁定后的时钟偏差主要是观测，不等于持续漂移修正。 |
| [tobi/recorder](https://github.com/tobi/recorder#out-of-scope-possible-future-work) | 原生双声源采集与左右声道输出可作结构参考。 | README 明确将 AEC 排除在范围外并假定使用耳机，不能作为外放消回声效果依据。 |

Echoless 的 [macOS 默认延时](https://github.com/Haor/echoless/blob/0b7a77cf152af0b545cdeb16849ec812c2511418/crates/echoless-core/src/lib.rs#L37-L45)、[实际处理路径](https://github.com/Haor/echoless/blob/0b7a77cf152af0b545cdeb16849ec812c2511418/crates/echoless-cli/src/realtime.rs#L580-L735) 和 [探测器](https://github.com/Haor/echoless/blob/0b7a77cf152af0b545cdeb16849ec812c2511418/crates/echoless-cli/src/probe_delay.rs#L1314) 支持“先解决因果余量，再评价 AEC”的方向。Echoff 的 [职责说明](https://github.com/KoljaB/echoff/blob/e0f1e41193b0ca7bd9ac972ec5deb99ea010fc72/docs/architecture.md#L42-L74) 与 [启动对齐](https://github.com/KoljaB/echoff/blob/e0f1e41193b0ca7bd9ac972ec5deb99ea010fc72/src/echoff/alignment.py#L343-L441) 支持分开采集、对齐和处理状态。

## 本机反例与当前修补

对生产 native capture + timeline 的无损输出做传递函数估计，麦克风主回声比系统参考早约 15.5 ms。已保存双讲的离线重放也支持这个方向。调整 `set_stream_delay_ms` 或只关闭 AGC 没有解决该时序问题。

当前修补从已有 400 ms 渲染缓冲中预读 40 ms 的系统参考，仅改变送给 APM 的 reference。写入文件的系统声、麦克风、raw、会话帧数不因此移位。未来参考不完整时保留 raw 并记录降级；下一个完整输入对重置 APM。合法静音参考与缺失参考分别处理。

没有照搬社区的 25 ms：它在本机无损材料的 6–7 秒窗口出现可重复的启动泄漏。40 ms 离线结果更好，但真实 signed release `90decd68…9299c1` 的 29.634625 秒纯外放录音再次暴露了反例：

| 窗口 | raw RMS | 最终 AAC 右声道 RMS | 判断 |
| --- | --- | --- | --- |
| 6–7 s | −34.85 dBFS | −27.69 dBFS | 回声仍被放大，未通过 |
| 10–15 s | −36.30 dBFS | −38.60 dBFS | 仍有参考相关残留 |
| 15–25 s | 约 −35.3 dBFS | 约 −55.9 dBFS | 明显改善，但不能代表启动与整段通过 |

这些 RMS 包含降噪、增益和残留，不能称为 ERLE。当前记录没有稳态采集缺口，但不能据此排除 APM 收敛或处理输入问题。进一步扩大固定偏移尚无跨材料一致证据；下一步需重放失败材料，或在确认非静音激励有效后复用追踪工具。

固定 APM 2.1 的 [AEC3 配置](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing/-/blob/v2.1/webrtc/api/audio/echo_canceller3_config.h) 也有 2.5 秒初始阶段；[实现](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing/-/blob/v2.1/webrtc/modules/audio_processing/aec3/aec_state.cc) 累计有效、未饱和的 render 块，不是简单经过 2.5 秒墙钟时间。这是核查收敛的线索，不能证明当前泄漏属于可接受结果。

随后在隔离调试版追踪了 2914 对实际 APM 输入、输出及重置事件。真实 C ABI 与直接 APM 重放均逐样本完全匹配，麦克风输入也与最终 raw CAF 对应位置完全相同。但这次麦克风只有约 −56 dBFS 底噪；只读设备检查确认系统音量为 0 且静音。该材料没有复现声学回声，已停止其参数对照。下一次必须先确认声学激励有效，再复用追踪工具判定失败原因。

证据入口：本机 `<LOCAL_EVIDENCE_PATH>`。社区源码快照在其 `community/`；真实消费文件及 SHA 在 `fixed-pure-result.json`，独立解码指标在 `fixed-pure-ede8m76e/root-analysis.json`；隔离追踪结果在 `trace-pure-result.json` 和 `trace-pcm/integrity.json`。录音未上传。

当前 AEC 音质验收仍未通过。固定 40 ms 也不是跨设备校准结论；真实双讲、设备变化、长期漂移及听感仍需各自验证。
