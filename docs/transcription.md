# 语音转写与自备 Key

保存完成的录音可以交给本地 Qwen3 ASR、MOSS，或豆包文件语音转写 2.0。资料库负责保存和查看结果，录音悬浮窗保持精简。首次使用在设置的「转写与模型」中选择默认模型；每次转写也可另选。

## 设置与安装

本地推理需要 Apple Silicon 与至少 16 GB 内存。16–31 GB 推荐 4-bit 节省内存版，32 GB 以上推荐 8-bit 标准版。推荐是安装档位建议，不代表机器性能基准；内存仍受其他应用占用影响。

「一键安装」按需下载选中的模型，准备固定版本的 Python 与依赖，校验模型文件并执行一次静音推理，通过后才标记为就绪。两个模型共享 Python 运行时，权重分别下载。首次完整安装预计 4.5 GB / 6 GB，需保留至少 10 GB / 12 GB 空间。中断或失败后可重新安装；未验证的安装不会替换当前可用模型。模型、运行时和缓存位于 `~/Library/Application Support/MeetingTape/transcription/local`。

「查找已有模型」通过系统文件夹选择器选择包含 `active.json` 的运行时目录，并保存可恢复的目录访问凭据，可复用 `audio-transcription` 工具的有效配置；仍会执行实际推理检查。日常启动不扫描其他应用的数据目录。本地转写使用离线标志与限制后的子进程环境，不传递豆包凭据。

豆包支持 API Key，也兼容 App ID + Access Token。设置页可打开[火山引擎控制台](https://console.volcengine.com/speech/new/setting/apikeys)，填写后存入 macOS 钥匙串，service 为 `com.paaatrickfu.meetingtape.transcription`。配置和任务 JSON 不保存 Key，CLI 不返回凭据。命令行也兼容现有 `DOUBAO_API_KEY` 或 `DOUBAO_APPID` + `DOUBAO_ACCESS_TOKEN` 环境变量；钥匙串优先。移除钥匙串记录不删除宿主环境变量。

「测试连接」上传应用生成的一秒静音；服务接受请求即表示凭据和资源可用，不作为识别准确率验证。

## 选择模型与结果

默认手动转写。可打开「录完自动转写」，仅处理此后实际保存完成的新录音。启用豆包自动转写时，设置页明确提示上传和账户计费。不会自动扫描并上传历史资料库。

多选时按所选模型分别保留原稿，首个模型作为主稿；默认主稿优先级可在设置中调整。展开正文可查看同一时间范围的其他模型文本并定位回听。差异标记忽略标点、空格与大小写；它表示文本存在差异，不判断哪个模型正确，不合成一份未经确认的终稿。

Qwen 当前使用 30 秒音频块时间范围，界面明确标为「音频块」，没有伪造逐字时间戳。MOSS 和豆包保留模型实际返回的分段时间。MOSS 的说话人标识仅在每个块内有效，保存时带块前缀，不推断跨块身份。重叠区间用于比较，不按段落下标强行配对。

任务与每个模型的原始/规范化结果保存在 `~/Library/Application Support/MeetingTape/transcription/tasks/<UUID>`，目录权限 700、JSON 权限 600。任务冻结输入指纹、识别模式、音源、模型版本、主稿和安装路径；任务启动或重试时发现输入变化，会拒绝继续该任务。每个模型下的系统音频和麦克风分别保留进度、云请求和重试记录；单路失败不丢弃另一条正文，已成功结果不会重跑。需要改用新安装版本时重新发起转写。

转写在独立 helper 中继续运行，退出 GUI 不终止任务。本地推理按音频块顺序执行，录音开始时终止当前块推理、释放资源；录音结束后从已完成块继续。worker 异常退出时，实际模型进程检测到父进程失效后退出；其持有的推理锁保证提前释放父进程锁不会让录音与残留推理并行。

## 音源与 Markdown 导出

已确认声道布局的 MeetingTape 录音默认分开识别系统音频和麦克风，正文沿共同录音时钟排序并标注音源。设置可改为合并识别以减少调用与资源使用；新任务冻结选择，已有结果不改写。任意外部音频默认合并；不能仅凭双声道推断系统/麦克风来源，显式分开识别但无有效元数据时会拒绝。

资料库中点击「导出 Markdown」，选择主稿，默认只导出这一版。勾选「包含其他版本」后，实时稿与其他录后任务/模型稿分别置于展开区块，不自动融合文字；运行状态和观测另放入「运行统计」展开区块。每个模型、每个音源的尝试分别保留总耗时、执行耗时、CPU 累计时间和单独 runner 的峰值 RSS；未采集不按零，GPU、整机和云服务端资源不作推算。CLI 与 App 使用同一导出器，App 调用包内 helper 后保存其 UTF-8 输出。

## 录音中的实时字幕

在「设置 → 转写与模型」或展开录音窗中分别开关「实时转写」和「字幕翻译」。首次启用会明确确认：此后的录音会将系统与麦克风声音实时发送至豆包，并使用你的账户计费。默认关闭，复用上述钥匙串或环境凭据。它使用实时语音识别 2.0 的 `bigmodel_async` WebSocket 接口和 `volc.seedasr.sauc.duration` 资源，与录后文件转写分别请求。

字幕任务独立读取录音已经提交的音频，按这段录音开始时冻结的识别模式，分别建立两路连接或合并为一路 16 kHz PCM；不持有录音写入锁，也不在采集回调执行网络请求。正文随服务端修订，定稿后逐段保存；停止时发送尾部并等待最终响应。恢复材料已被正常完成流程清理时，从完成的 m4a 补读尚未发送的尾部。

断网、服务拒绝、发送超时或积压超过十秒时，字幕停止并保留现有文字，录音继续。不会自动重传；点击「重连」从当前录音时钟继续，此前未识别区间会标为部分字幕。退出 GUI 会结束仍在录制的字幕连接；选择继续后台录音后重开，字幕也从当前时刻继续。上一段录音的字幕收尾可与下一段录音并存，同一段的重连等待旧任务保存完毕，避免覆盖结果；单路失败可单独重连，另一条连接继续运行。

实时字幕以录音 sessionID 保存在 `~/Library/Application Support/MeetingTape/LiveCaptions/<UUID>.json`，目录权限 700、文件权限 600；测试隔离时位于 `MEETINGTAPE_LIBRARY_DIR/LiveCaptions`。资料库显示时间戳、正文与是否只有部分结果，支持复制和定位回听。它与录后多模型原稿分别保存，不自动互相覆盖。

本轮使用合成中文音频实测了连续修订、停止定稿、尾部补读、保存重载与原生资料库回听。实际麦克风声音通过原生 GUI 发送到云端的组合路径，以及长录音、断网和跨 Space/全屏行为仍未完成实机验收。本地 Qwen/MOSS 的准实时延迟及与录音并发尚需独立实验，目前不提供本地实时字幕。

## 基础字幕翻译

只需设置目标语言。相同语言保留一次文字并标「无需翻译」；其他语言进行文字翻译，不合成或播放语音。原文先出现，短句译文随修订更新，定稿后校正。译文绑定连接、音源、语句修订和目标语言，旧请求不能覆盖新内容；更改目标语言只影响之后的内容。

默认使用 Apple 本地翻译，实时无界面推理需要 macOS 26，首次在设置中「准备语言包」通过系统下载页安装。当前提供的准备入口覆盖英语与所选目标语言，其他源语言缺包时明确报错。本地翻译不会自动切换到云端；语音识别仍使用豆包，不能把这条组合链路称为完全离线。

用户可手动选择豆包文本翻译，使用相同 BYOK 凭据但还需开通 `volc.speech.mt`。接口与实际服务返回的 token 用量依据[官方机器翻译文档](https://docs.volcengine.com/docs/doubao-voice/machine-translation-large-model-api-access-documentation)。ASR 可用不代表翻译权限可用；缺少权限会显示错误，录音与原文转写继续。

四种开关组合均可使用：只转写、只翻译、两者都开或都关。只翻译时内部识别原文不作为独立原稿保存；原话已是目标语言时，保留目标字幕一次。两者都关不停止录音。开关和目标语言区间按公共录音时钟保存，导出注明「该期间未开启转写/字幕翻译」。断线与中途接管的未知区间分别保留，不自动补传或伪造全程成功。

## CLI

所有任务命令返回 JSON。`state` 为 queued、running、waitingForRecording、completed、partial 或 failed；每个模型另有自己的状态。返回 task ID 后可退出终端并稍后查询。

```sh
meetingtape transcribe models
meetingtape transcribe models --existing
meetingtape transcribe install qwen --profile low-memory
meetingtape transcribe install moss --reuse
meetingtape transcribe settings
meetingtape transcribe settings --save-stdin < preferences.json
meetingtape transcribe credentials status
meetingtape transcribe credentials save-stdin < private-credential.json
meetingtape transcribe credentials test
meetingtape transcribe start /absolute/saved.m4a --models qwen,moss
meetingtape transcribe start /absolute/saved.m4a --models qwen,doubao --allow-cloud
meetingtape transcribe list
meetingtape transcribe status <task-id>
meetingtape transcribe result <task-id> qwen --text
meetingtape transcribe retry <task-id> moss --source microphone
meetingtape transcribe start /absolute/native-recording.m4a --models qwen --mode separate
meetingtape transcribe export <session-id> --primary <task-id>:qwen --output transcript.md
meetingtape transcribe export <session-id> --primary live --include-versions --output all-versions.md
```

凭据 JSON 使用 `apiKey`，或 `appID` 与 `accessToken`。优先通过设置页或安全的 stdin 来源写入，避免把真实 Key 放在 shell 参数或历史中。偏好 JSON 可先读取 `settings` 再修改 `models`、`automatic`、`profile`、`recognitionMode`；保存偏好不会覆盖安装过程刚激活的模型。

## 豆包协议与边界

服务使用 `volc.seedasr.auc`、异步 submit/query 和 `ssd_version=300`。依据[官方任务提交文档](https://docs.volcengine.com/docs/DoubaoVoice/task-submission-http-1?lang=zh)和[查询文档](https://docs.volcengine.com/docs/DoubaoVoice/result-query-http-1?lang=zh)检查业务状态码，而非只检查 HTTP 200。

当前把录音转换为 16 kHz 单声道 WAV，以 `audio.data` base64 直接提交。2026-10-26 已用授权账户和合成语音实际成功；官方公开文档主要描述 `audio.url`，故直接提交仍有兼容性风险。这里没有把录音另行托管成公开 URL。单文件上限 512 MB、五小时以内，转换后超过体积上限会明确失败。

提交前持久化 request ID。已经受理或提交结果不确定时，重试只查询同一 ID，避免自动重复上传；如果服务未实际收到不确定提交，需要用户显式重新转写。服务明确拒绝提交时，修正配置后可重试提交。查询终态错误保留原始请求身份，不自动重新计费。

安装锁定的包版本、哈希、模型 revision 见 `Resources/Transcription`，第三方授权见其中 `NOTICE.md`。本地验收及未完成项见[本地构建与验收](local-verification.md)。
