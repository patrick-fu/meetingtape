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
- 名称和标记存放于 `~/Library/Application Support/MeetingTape/library.json`，不改动原始音频文件名或引擎元数据。索引不可读/写时明确显示只读状态，禁用无法保存的整理操作。
- 资料库启动时扫描已选择文件夹的一层 `meetingtape-*.json`，只接受 completed、实际同名 m4a 存在的记录。CLI 在 GUI 关闭期间完成的录音会被发现；未知文件夹不进行全盘扫描。

录制电平来自实际系统与麦克风输入，回听波形从实际文件分段解码取样。麦克风语音处理的历史降级和音源中断保留在录音状态记录中；当前 [AEC 未通过结论](local-verification.md)不因 GUI 实现而改变。

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

已编译 debug/release 并检查嵌套签名。38 项现有与新增契约测试通过；实际打包 helper 的离线验收覆盖恢复输出、格式、样本前缀、元数据和不覆盖旧文件，报告仍为 PARTIAL。

原生 release 资料库已通过 CUA 操作实际发现打包 helper 恢复出的五秒双声道文件，显示解码波形，完成回听、改名、标记、已标记筛选与搜索。该文件来自本地合成恢复夹具，不代表真实声学录音已通过。

原生 App 的首次真实录制在新身份的系统音频授权处阻塞；系统设置要求人工验证。GUI 的开始→停止→入库完整链路、悬浮窗拖动/展开与全局焦点、跨 Space/全屏显示仍不能报告通过。首次启动还暴露子进程管道结束处理问题，已改为独立并发读取并关闭父端写句柄；后续仍需在授权后的真实流程确认。
