# MeetingTape 原生 GUI

资料库主窗口负责浏览、搜索、改名、标记和回听；录制时使用独立的可置顶悬浮窗。收起态只呈现时间、电平波形、停止与展开；展开态可编辑正在录制的标题、检查两路音源状态和打开资料库。

## 本地构建

```sh
./scripts/build-desktop.sh debug
./scripts/build-desktop.sh release
```

打开 `.build/local/debug/MeetingTape.app` 或 release 对应路径。构建复用已有固定版本 APM 和 Team `9N7UKH59LC` 的 Developer ID，内嵌的 `Contents/Helpers/meetingtape` 与外层 App 均独立签名。本轮无 CI、发布、合并或安装到 Applications。

SwiftPM 的桌面产品名是 `MeetingTapeDesktop`，App 显示名为 `MeetingTape`；产品名与 CLI `meetingtape` 必须在不区分大小写的文件系统中也不同。

## 使用与文件

- 从资料库或状态栏开始录音。首次使用需要允许麦克风和仅系统录音；系统设置可能要求触控 ID 或密码。GUI 不申请录屏、辅助功能或完全磁盘访问权限。
- 资料库关闭后，录音仍在后台继续；从状态栏重新打开即可。悬浮窗使用 nonactivating NSPanel，设置 floating level、canJoinAllSpaces 和 fullScreenAuxiliary。实际跨桌面、全屏应用和焦点行为仍需实机验收。
- 停止会等待后台录音完成文件与元数据发布，再把实际 outputPath 加入资料库。关闭的资料库保持关闭，保存提示在重新打开时可见。
- 退出时可以停止并退出、继续后台录音并退出，或取消。正在准备、保存或恢复时禁止直接退出，避免中途切断命令。
- 保存失败会保留恢复材料并提供恢复入口。没有已提交音频时可以保留材料后继续使用，不要求恢复成功才能新建录音。
- 默认输出目录为 `~/Documents/MeetingTape`，可以在录音设置中选择其他文件夹。CLI 的“必须显式提供已存在目录”行为不变，创建目录是 GUI 的职责。
- 名称和标记存放于 `~/Library/Application Support/MeetingTape/library.json`，不改动原始音频文件名或引擎元数据。进行中的自定义标题按 sessionID 缓存在偏好中，继续录音并退出后重开仍可恢复；不会覆盖已有资料库名称。索引不可读/写时明确显示只读状态，禁用无法保存的整理操作。
- 资料库启动时扫描已选择文件夹的一层 `meetingtape-*.json`，只接受 completed、实际同名 m4a 存在的记录。CLI 在 GUI 关闭期间完成的录音会被发现；未知文件夹不进行全盘扫描。

录制电平来自实际系统与麦克风输入，回听波形从实际文件分段解码取样。麦克风语音处理的历史降级和音源中断保留在录音状态记录中；当前 [AEC 未通过结论](local-verification.md)不因 GUI 实现而改变。

## 语音转写

资料库现可手动或自动发起本地 Qwen3 ASR、MOSS 与豆包 2.0 转写。默认模型、本地安装、版本选择和豆包钥匙串配置集中在「设置 → 转写与模型」；多模型结果在正文处展开比较、定位回听。完整用法与精度边界见[语音转写说明](transcription.md)。

## CLI 交互

GUI 通过 App 内嵌 CLI 的绝对路径调用命令，不另起一套录音引擎。默认与普通 CLI 使用同一会话路由；`MEETINGTAPE_STATE_DIR` 可按现有约定隔离。内部库索引可用 `MEETINGTAPE_LIBRARY_DIR` 隔离，不改变录音路径。

```sh
meetingtape start --out <existing-directory> --json
meetingtape status --json
meetingtape stop --session <session-id> --json
meetingtape recover <recovery-directory> --out <existing-directory> --json
```

`--json` 成功输出一个 schemaVersion 1 快照；idle 是独立对象，失败保留原退出码与 stderr。条件停止在 host 内比较 sessionID，拒绝过期 UI 操作，旧版无条件 stop 的字符串协议保持兼容。stdout 和 stderr 分别并发排空，避免大快照堵塞及非 JSON 日志混入。

## 本轮验收边界

已编译 debug/release 并检查嵌套签名。41 项检查通过（38 项引擎/CLI 测试与 3 项桌面组件测试）；实际打包 helper 的离线验收覆盖恢复输出、格式、样本前缀、元数据和不覆盖旧文件，报告仍为 PARTIAL。

原生 release 资料库已通过 CUA 操作实际发现打包 helper 恢复出的五秒双声道文件，显示解码波形，完成回听、改名、标记、已标记筛选与搜索。该文件来自本地合成恢复夹具，不代表真实声学录音已通过。

2026-10-26 用户完成系统授权后，原生 release 已实际走通开始→关闭资料库继续录音→展开/收起与编辑标题→从悬浮窗停止→自动入库→回听；名称与标记在重开后保留。另一段录音通过“继续录音并退出”后重开接管同一个 host，并从精简伴随条停止。四秒本地测试音在最终文件的系统声道解码出非零信号。最终 release 另验证进行中自定义标题随退出重开保留，以及“停止并退出”，确认 GUI 与录音 host 均退出，重开可读到带该标题的完成文件。

授权后发现初始状态查询卡在 GUI 的同步 `Process.waitUntilExit()`，阻止后续开始命令；已改为启动前注册退出回调并显式保活 Process，继续并发读取 stdout/stderr。桌面组件测试覆盖连续命令、大输出、启动失败和信号退出；无输出异常退出现在也有可读提示。短命令测试在旧实现也通过，原生卡住样本与修复后的实际业务流程才是该阻塞的前后证据。

拖动操作已执行，但 CUA 返回单个窗口的截图，不能独立确认屏幕位置变化。全局焦点、跨 Space/全屏应用中的置顶显示仍未完成验收；当前 AEC FAIL、设备/睡眠等引擎验收缺口不变。短暂采集缺口和原始麦克风降级如实保留在录音状态记录中。
