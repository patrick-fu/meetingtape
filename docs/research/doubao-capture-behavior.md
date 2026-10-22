# 豆包录音的设备与睡眠行为

2026-10-22，为 [#7](https://github.com/patrick-fu/meetingtape/issues/7) 核查系统声音范围、麦克风切换和睡眠策略。本文记录参考实现及证据边界；MeetingTape 的采纳范围见文末与 ADR 0003。

## 结论

| 问题 | 已有证据 | 仍未确认 |
| --- | --- | --- |
| 系统声音范围 | Voixcap 可以配置火山 RTC 的 process dual tap；SDK 包含全局排除式 stereo tap 和多种采集后端。 | 安装中的会议录音实际启用哪个后端，以及是否限定输出设备；尚不能承诺多设备输出全部覆盖。 |
| 麦克风切换 | 库支持跟随系统默认输入或指定设备；麦克风变化时重启该路采集。打包的录音业务代码接收变化事件；设备消失时提示只录系统声音。 | 当前传入的路由开关、设备模式和 ID；切换缺口、时间戳与最终文件表现。 |
| 系统睡眠 | 打包的录音业务代码在系统挂起时暂停，恢复后仅自动继续由系统事件暂停的录音。另有全局保持唤醒设置。 | 锁屏、合盖和真实睡眠事件是否及时送达；暂停期间最终文件如何表达时间；实际恢复成功率。 |

没有主动开启豆包录音、改变音频设备、锁屏或让电脑睡眠。业务代码结论来自安装包静态逻辑；只有设置状态与电源断言来自被动运行时观察。

## 目标与取证范围

安装的 `/Applications/Doubao.app` 为 2.32.6，内嵌浏览器框架为 147.0.7727.149。以下路径均相对于 `Contents/Helpers/Doubao Browser.app/Contents/Frameworks/Doubao Browser Framework.framework/Versions/147.0.7727.149/`。

| 文件 | SHA-256 |
| --- | --- |
| `Libraries/libvoixcap.dylib` | `7931a9a9e862902489faa5835b424d6a6ac5c03f586cfae9af8ea9ed83b9795a` |
| `Libraries/libVolcEngineRTC.dylib` | `a06c82f2efff51c59dceae6e44fb8ef47ef6ad5521d66236530eca610b661945` |
| `Resources/local_webcontents/biz/biz.pak` | `c712c646a0628a807f32e92bf066145b6de8d84da679bcb559b8f3bde82ceff2` |

原生伪代码使用 REA CLI 6.7.0、Ghidra 12.1.4。符号表、字符串和本地资源解析仅作相应层级的静态证据，不代表函数实际执行。没有访问账号数据库、录音正文或网络请求。

`biz.pak` 是 v5 DataPack，10586 个资源，其中资源 1 是路径清单。按清单读取 JavaScript，并解压 gzip 资源；搜索限制在这一文件，单资源上限 16 MiB、累计解码上限 512 MiB、22 秒超时。实际检查 8026 个 JS 资源、约 414 MB 解码内容，未跳过资源。只在系统临时目录保留相关候选文件，没有将豆包代码复制进仓库。

## 系统声音

`VoixcapRecorderImpl::CreateRTCEngine`（`0x5c534`）存在受配置控制的分支，向 `rtc.mac_system_capture_audio_config` 传入 `capture_model: mac_process_dual_tap`、`voip_delay_size` 和 `ignore_list`。分支中排除列表包含一个第三方音频服务 bundle ID；不能据此推断所有采集模式都使用同一排除规则。

REA Evidence：`ev_92e9550d5704dd5c772a126d976ee067cc916c34763da92727a06121f7e55b4c`。

SDK 包含 `mac_process_tap`、`mac_process_dual_tap`、`mac_process_single_tap` 及 audio-unit/core-audio 后端，也包含 `initStereoGlobalTapButExcludeProcesses:`。这些证明存在候选实现，不能单独证明豆包当前选用的路径。Apple 对这个 [初始化接口](https://developer.apple.com/documentation/coreaudio/catapdescription/initstereoglobaltapbutexcludeprocesses%3A) 的定义是混合未被排除的进程；是否另外设置 `deviceUID` 仍须追踪调用方。

本轮尝试对 SDK 追踪该初始化调用，Ghidra 全量分析超过 REA 的 330 秒启动期限；禁用耗时的 `Decompiler Switch Analysis` 后，受限重试仍超过 120 秒期限，因此停止重试。没有获得这一调用链的反编译结果，系统声音覆盖范围保留未确认。

## 麦克风

`DeviceConfig::SetVoixcapConfig`（`0x59e74`）复制路由开关、采集/播放设备模式与设备 ID。`DeviceController::Initialize`（`0x3fbb4`）读取配置并调用 `RestoreDevice`（`0x41064`）；模式为 0 时走 `SystemSetDevice`，其他模式尝试指定 ID，并在缺失时使用设备顺序回退。`SystemSetDevice`（`0x46ca0`）的输入路径调用 `FollowSystemCaptureDevice(true)`。

`OnSystemDeviceChanged`（`0x45f40`）在路由启用且当前选择跟随系统默认时重新设置并更新设备。`OnDeviceRemoved`（`0x4588c`）和自动切换辅助方法处理设备移除。这不能证明会议录音当前传入的配置必然开启这些选项。

`VoixcapRecorderImpl::HandleDefaultMicrophoneDeviceChanged()`（`0x67ff4`）比较采集设备 ID；变化时短暂停用并重新启用麦克风采集和发布；没有设备时关闭麦克风采集。这里没有停止整场录音的调用。

业务消费端也存在对应路径：DataPack 资源 7574，`static/js/async/32405.af46743000.js` 中，`kMicrophoneDeviceChanged` 映射为录音 SDK 事件，错误处理器订阅 `ON_MICROPHONE_DEVICE_CHANGED`。`handleMicrophoneDeviceChanged` 维护前后设备 ID，切换时提示改用其他输入设备，缺失时提示改录系统声音。它提高了“录音继续”的静态证据强度，但尚未测出最终文件的时间连续性，也没有证明缺口补静音。

关键 REA Evidence：配置 `ev_01067a08ebbad6ffe3c9cb4efc1fe86a904d18c4a6269af494ae91b42a77a43c`；初始化 `ev_7760769da39475587973e82181c5349e68ae09f3068efc2415db01ad08d3354e`；默认设备变化 `ev_c72fdbe3bc43999f51066e1e60734ec3656cb064e677fa34277fd5b5acc6031f`；录音侧重启 `ev_9fa2e1db607ec7bb651f10de1cbcc00d2d528868e5d53fc302fde0c482690f21`。

## 睡眠与保持唤醒

DataPack 资源 7387，`static/js/async/23875.23e9c586bb.js`，SHA-256 `ce2dc63b54b4ab5c32c48583bc914c57817efe6a00657f68df7759eb5dd610f4`：

- `initializeRecordingRuntime` 订阅 `system.onSuspend` 和 `system.onResume`。
- `handleSystemSuspend` 在录音可操作且尚未暂停时调用 `pauseForSystemEvent`。
- `changeRecordingPaused` 记录 `isRecordingPausedBySystemEvent`，并调用录音和会议处理器；会议处理器调用 `voixcapSDK.pauseRecording` / `resumeRecording`。
- `handleSystemResume` 只有在暂停来自系统事件且录音仍暂停时自动恢复；不会恢复用户主动暂停的录音。

同一策略也存在于资源 7406，`static/js/async/24508.15459a25a5.js`。这证明打包的录音业务明确实现了系统暂停/恢复；尚未观测本机真实睡眠后的执行结果。

另一路是全局设置：豆包“设置 → 工作模式设置 → 让这台设备保持唤醒状态”当前开启。`Local State` 中仅核对相关布尔字段 `saman.system_keep_alive_enabled = true`。资源 9613 的 `setKeepActive` 调用 `setSystemKeepAliveStatus({disableSleep: ...})`，原生框架也有 `DispatchModule::SetSystemKeepAliveRequested` 及电源状态处理逻辑。

2026-10-22 17:02:46 +0800 的 `pmset -g assertions` 显示 `Doubao Browser` 持有名为 `Chromium Active Content` 的 `NoIdleSleepAssertion`。当时未开启录音，因此不能把这个断言归因于录音功能，也不能推导锁屏和合盖的具体策略。

MeetingTape 若仅在录音期间持有 [`PreventUserIdleSystemSleep`](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep)，系统仍可息屏，且合盖、Apple 菜单主动睡眠、低电量等仍可能导致睡眠。该 API 的限制与豆包的产品策略是两个独立事实。

## 对 MeetingTape 的影响

2026-10-23，用户确认系统声音以覆盖各输出设备为目标并实测；麦克风跟随系统默认并自动切换；仅录音期间防止空闲睡眠，允许锁屏息屏。实际睡眠时暂停采集，唤醒后在同一会话自动续录，CLI 不增加公开 pause/resume 命令。决策见 [ADR 0003](../adr/0003-capture-scope-and-automatic-recovery.md)；系统声音覆盖范围和默认输入属于 MeetingTape 的要求，不能据此推断豆包已有同样行为。

这替换了此前建议的“睡眠时结束、唤醒另开”。随后用户确认：中断保留真实时长并补静音，单路故障继续另一声源，清醒时两路均不可用超过 30 秒则报错结束；允许保留恢复材料，以强退最多丢失最后 5 秒音频为验收目标。这些是 MeetingTape 的决策；不得将豆包静态逻辑直接作为 #8 的真实录音验收结论。
