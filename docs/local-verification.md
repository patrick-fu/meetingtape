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

## 前版实测结果（2026-10-25，源码 `494084b`）

在 macOS 26.6.2 上，生产源码提交 `494084b` 的 debug/release 均通过签名构建；35 项测试通过，其中恢复测试包含新旧 CAF 两种材料。对应制品：

| 制品 | SHA-256 |
| --- | --- |
| debug | `646d6ae24cb85ac00151da57d7b20f65e94cb7676d02acdd82a9e931a8d23d17` |
| release | `94ab151bcc9d39039b615d6e452cf6386ead6dfb5b621a9349e5870556235518` |

- 最终 release 正常 start/status/stop 录制 30.5385625 秒，独立解码确认 AAC 48 kHz stereo、raw 单声道与 metadata 帧数一致。左声道匹配两路系统声标记；稳态未出现此前的周期性麦克风缺口。启停边界仍有三段明确降级，未计为声音完整无缺。AAC 解码比 raw 多 453 帧，属本次实际时长差异。
- 最终 release 经真实 SIGKILL 后公共 recover 恢复，25 步检查通过：已提交 AAC 前缀误差、raw 逐样本一致、metadata 引用及无覆盖。此次尾损观测 0.743 秒，保守上界 0.765 秒；整体验收保持 `PARTIAL`。最终 debug 另通过 17 步无硬件公共 CLI 检查。
- 修补前一版 release `fe5094d0…e1b9e038` 完成三分钟无主动播放录制，raw 8,671,391 帧与 metadata 一致，稳态无新增中断或降级；它只支持该版这条短期稳定性路径。
- 有效短尾另用实际 render、RecoveryStore 和最终 CAF 消费验证：1001 帧目标保留最后 41 个有效样本；从第 100 帧续写时，首 380 帧 raw 后接完整处理块。该探针的采集和处理为 stub，未替代真实睡眠或 APM 音质验收。

本机原始步骤、制品与报告哈希入口为 `/var/folders/5c/f170nvbx6t7105zg26q08zvh0000gn/T/meetingtape-dev-hmb_2kka/live-artifacts.json`。累计审查、修复依据与消费者证据另回写关联的 GitHub 验收票。

这些是该版的历史证据，不能替代后续制品的验收。

## AEC 时序修补后的检查（2026-10-25）

用户真实试听发现外放仍混入处理后的麦克风。当前修补只为 APM 预读 40 ms 系统参考，保留输出与 raw 的原时间位置；参考缺失或不足完整处理块时保存 raw 并报告降级。36 项测试通过，包含未来参考读取不破坏当前音频的回归检查。生产 render 的独立隔离驱动核对了稳定输入、参考缺口、麦克风缺口和短尾的最终 CAF；其采集及处理 stub 不证明音质。

| 当前本地制品 | SHA-256 |
| --- | --- |
| debug | `f9b7f9de83dc55723eaebcf54ca5af1080b2a7eda06fe2bfa777e5c7c8dd81e9` |
| release | `90decd68e53d9cb7ec79fc96483190cf3990db423be0d69fc7d1be97fd9299c1` |

两种制品均通过签名、内嵌权限、动态依赖及部署目标检查。release 再次通过公共命令及真实 SIGKILL/recover 的 25 步检查，debug 通过 17 步无硬件检查；验收器仍报告 `PARTIAL`。

实际 release 纯外放录音 29.634625 秒，稳态无采集缺口。15–25 秒回声明显减弱，但 6–7 秒及 10–15 秒仍有泄漏，**AEC 音质未通过**。另一段隔离追踪在系统静音时运行，虽然处理链可逐样本重建，却没有声学激励，不能用于音质验收。社区经验、反例及下一项判定见 [AEC 参考时序](research/aec-reference-alignment.md)。

真实近端语音已有采样与包络保留证据，但主观清晰度和修补后的真实双讲仍未验收。物理多输出覆盖、设备变化、真实睡眠、长期漂移、故障时点矩阵、disk-full/OS crash/power-loss 和 macOS 14.2 运行仍未完成。本轮没有配置或执行 CI，未发布或合并。

## 原生 GUI 首版接入（2026-10-25，历史记录）

用户确认资料库加极简悬浮窗的融合方向，原生实现见 [桌面版说明](desktop.md)。debug/release App 及各自内嵌 CLI 完成签名检查，38 项测试通过。新增结构化开始/停止/恢复输出、条件停止与实际输入电平，复用已有录音引擎。

| 最终本地制品 | GUI SHA-256 | 内嵌 CLI SHA-256 |
| --- | --- | --- |
| debug | `a9fc09be4b1c8cab7634b13e8fba4f456a29edcecd5c18b0703ba9ec87262bb1` | `42947e801fb1084ee30476e4f89187893600871328ad6f832e0ca549608e467a` |
| release | `f40754b786edf6b00b048bf321402a301e0e3ade5444a4a730a8fb96f0b33374` | `936507f67031fc61b5f8735494774c5e9ca540b069bef27b7b36cf51f1029e29` |

最终打包 helper 分别通过 17 步离线检查，包括恢复 AAC/原麦 CAF、解码前缀、元数据与不覆盖旧文件；报告保持 PARTIAL，未把合成夹具当作真实采集。原生 release 资料库已消费实际恢复文件，完成波形显示、回听、改名、标记、搜索与重开后保留。

新原生 App 身份的真实录制在首次系统录音授权处阻塞，系统设置要求触控 ID 或密码验证。未绕过验证；原生开始→停止→自动入库、浮窗拖动/焦点/跨 Space/全屏仍未通过。本轮 AEC FAIL 和先前实机缺口不变，无 CI、发布或合并。

本机最终验收索引：`/var/folders/5c/f170nvbx6t7105zg26q08zvh0000gn/T/meetingtape-native-gui-eFl8PI/verification.json`。

## 原生 GUI 实录与启动修复（2026-10-26）

本次续跑确认首版临时目录及其合成样本已被清理，以上保留为已提交的历史结论，不能再作为可打开的本机原始证据。资料库正确提示旧样本丢失。麦克风与仅系统录音权限已开启，未修改 TCC 数据库。

初始状态查询在子进程退出后仍卡于 `NSConcreteTask.waitUntilExit`，采样 884/884 次均在该位置；主线程仍正常运行。同步等待占住 RecordingClient actor，导致新录音停留在准备状态。改为启动前注册 `terminationHandler`，异步等待退出并显式保活 Process，stdout/stderr 并发读取保持不变。跨线程 RunLoop 竞争是机制推断，阻塞位置有直接采样证据；[Apple 文档](https://developer.apple.com/documentation/foundation/process/waituntilexit%28%29)说明该方法轮询当前线程 RunLoop。

41 项测试通过（38 项原有引擎/CLI 测试，加 3 项桌面组件测试）。连续短命令在旧实现也通过，不能声称它复现了阻塞；大 stderr、无效可执行文件和 signal 退出已实际执行。无输出失败的两项断言在 fallback 修复前失败、修复后通过，signal 不会使 GUI 崩溃。Sol 与 Gemini 独立复核后，对 Process 生命周期加显式保护，修复空错误；“signal 必然抛异常”和“每次泄漏两个读端 FD”无事实支持，未据此扩大实现。取消不主动终止 helper 仍为已有边界，GUI 在准备/保存时阻止退出。

| 最终本地制品 | GUI SHA-256 | 内嵌 CLI SHA-256 |
| --- | --- | --- |
| debug | `357797bc9f611320f9b212dbb34f050b8e602dd4daa999e55ec448783cfe202b` | `c2ab3c87edb4454c0c4fabf0563afb5fb82d4ceb0de3ab6419058145adbea5d6` |
| release | `90279a6d60d610fc89a8313621de518caa5f0ef42309dfd4f658b55e09e20728` | `424549ad5a63c70cb06a44f40b4d914f917b902f6318c5718d5d4f25934898b3` |

debug/release 均通过嵌套签名、系统依赖与部署目标检查，最终打包 helper 各通过 17 步离线检查，保持 PARTIAL。

原生 release 的实际消费路径为 `.build/local/release/MeetingTape.app/Contents/MacOS/MeetingTape`，录音进程来自同一 App 的 `Contents/Helpers/meetingtape __host`。实际完成：

- 107.955979 秒实录：关闭资料库后悬浮窗继续计时；展开/收起、编辑标题、停止、自动入库、标记及回听，重开后名称和标记保留。
- 91.295813 秒实录：开始时自动停止资料库回听；四秒本地 440/660 Hz 测试音进入系统声道，解码峰值约 0.0761；麦克风声道也有非零采样。继续录音并退出后仅 host 存活，重开接管同一 session/进程，从精简伴随条停止保存。
- “停止并退出”保存后，确认 GUI 与 host 均退出，重开读取完成文件。文件格式为 AAC、48 kHz、双声道。
- 最终签名 release 另验证录制中自定义标题：命名后继续录音并退出，重开接管同一 session，展开显示原自定义标题；停止并退出后资料库索引仍保留该标题。标题按 sessionID 保存在偏好中，poll 先更新身份再恢复名称，防止错绑上一段录音，既有入库名称不被覆盖；Sol 对该差异只读复核完成。

前两段业务验收使用修复主阻塞后的中间签名制品（GUI `da61cd94737ea61a832fb6a7ce3f5ca0a8d367fc06111a666e2600e1bdee40f6`、helper `424322135d1efde435ad5ce1ab553fd031788e24afe4a1b57944d048edf2227e`）；21.945188 秒的停止退出检查使用后续中间制品（GUI `463d44b772156192edf8d2366cac5ae1bf0a004c67fb7ad806851eb9b41454a8`、helper `d1b1352778233981e3bedddd4764134789d939797bc218c5ac3cb3db1d65bb22`）。最后的标题保留、后台接管与停止退出使用表内最终 release。实际文件和元数据保存在 `~/Documents/MeetingTape`。

录音状态如实记录初始/收尾缺口及少量麦克风帧缺口；21 秒样本另报告 70 ms 处理超时和 20 ms 参考缺失的原麦旁路，不能称全程无缺口或无降级。系统声道测试不证明 AEC 音质；外放 AEC 仍 FAIL。拖动已执行但位置变化未独立观测；全局焦点、跨 Space/全屏置顶、设备/睡眠等此前缺口继续保留。没有运行 CI、上传录音、发布或合并。

本轮本机证据索引：`/var/folders/5c/f170nvbx6t7105zg26q08zvh0000gn/T/meetingtape-native-continue-20261026/verification.json`。其中的临时材料可能被系统清理，制品哈希及上述范围随本文件保留。


## 本地与豆包转写（2026-10-26）

本轮新增转写范围由 #12 确认，功能与 CLI 用法见[语音转写说明](transcription.md)。debug/release 均完成本地编译、嵌套签名与资源副本核对；44 项检查通过（41 项 Swift Testing 与 3 项桌面 XCTest）。最终打包 helper 各通过既有验收器的 17 步离线检查，原录音总报告仍为 PARTIAL。

| 最终本地制品 | GUI SHA-256 | 内嵌 CLI SHA-256 |
| --- | --- | --- |
| debug | `303bf447041030b68e25fdc0f9fb50f87652d8892a1c95c1c3f9a308ab62bc09` | `cfab63673f1a13f5b33ed4d70aa997bcc394d67ff800996c711ab396152408b9` |
| release | `e588a713e46684d5bd6e39579a372ca0a40b0090e1c8a9e473c40a4da0f23d26` | `79562d46513a251e10cf9acb624a21d74c8bb89ed46462c7bfbd4288a4805d3b` |

最终 release 内嵌 helper 对 8.391 秒合成中文语音实际完成 Qwen、MOSS 与豆包三模型识别，均含预期正文且时间范围落在原音频内。注入 MOSS 单独失败后，重试成功，另外两份结果逐字节不变，豆包请求 ID 未变化；本地子进程环境未继承豆包凭据。强杀已加载模型的 Swift worker 后，实际 Python 在 0.163 秒退出，推理锁释放，原任务可重试。实际开始录音抢占推理后约 0.531 秒就绪，转写等待，停止后继续；自动关闭时不生成录音转写任务，开启本地自动转写后，GUI 关闭期间只为新完成的录音生成一个任务。哈希计算和凭据读取在独立自动转写进程中进行，不阻塞录音停止响应。

Qwen 4-bit 完成从 App 自有目录冷安装与实际 smoke；MOSS 4-bit 复用已有环境完成真实推理。最初 GUI 复用外盘环境时，Python 在解释器路径初始化阶段挂起，终端调用则成功；TCC 日志确认 GUI 为责任主体并出现 AllFiles 拒绝。增加系统目录选择器与可恢复的访问凭据后，原生 GUI 重试成功；最终 release 退出重开后，无需再次选择目录，三模型再次全部成功。没有请求完全磁盘访问或修改 TCC 数据库。

CUA 在最终 App 中验证了发起转写、退出后后台继续、重开结果保留、三份原稿按时间展开与定位回听，以及设置页豆包连接测试。云端只使用合成语音和生成静音；真实短录音仅在本机用于抢占与自动转写检查。已有环境凭据的值对 192 个源码、设置、任务与验收文本文件扫描未发现明文；未导出钥匙串内容。录音保存目录已恢复为 `~/Documents/MeetingTape`，默认自动转写仍关闭。

Sol 与 Grok 独立审查覆盖任务重试、锁、设置及凭据。修复了设置覆盖新安装、状态查询覆盖完成状态、异常退出遗留推理、旧任务重试被判过期、拒绝提交不能重试、孤儿安装状态等已核实问题。Grok 提到的“不确定提交后仅查询原 ID”保留为避免重复计费的决策，同时增加重新转写的明确提示；其发现的移除钥匙串后仍有环境凭据却回报未配置已修复。Gemini 两次返回空终态、Grok 首次网络失败和一次超时都未作为有效审查；Grok 同会话恢复后提交了有效结论。

仍未验证：8-bit 安装与推理、MOSS 冷下载、无既有 uv 的全新机器引导、长录音准确率与资源基准、跨块说话人身份。豆包 `audio.data` base64 直传实测成功，但公开文档主要约定 `audio.url`，兼容风险明确保留；提交结果不确定时不自动重复上传。Qwen 只提供块级时间范围，MOSS 的说话人标识限定在每个块内。AEC FAIL、跨 Space/全屏浮窗与设备/睡眠等既有验收缺口不变；本轮无 CI、发布或合并。

本机证据索引：`/var/folders/5c/f170nvbx6t7105zg26q08zvh0000gn/T/meetingtape-transcription-implementation-20261026/verification.json`；该临时目录中的原始报告、截图和合成夹具可能被系统清理，以上提交记录保留验收结论。
