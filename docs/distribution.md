# MeetingTape 安装与使用

本发布包面向 Apple Silicon Mac。将 MeetingTape.app 拖到 Applications 后打开。CLI 用户请将整个 CLI 文件夹复制到固定位置，保留可执行文件旁的 Transcription 文件夹，再把 CLI 目录加入 PATH。

首次录音需允许麦克风与系统音频录制权限。声音保存在用户选择的本地目录；默认不上传或自动转写。启用豆包识别会上传所选声音并使用自备账户计费。

本地 Qwen/MOSS 模型从设置中按需安装，当前要求至少16GB内存；权重不包含在此包中。Apple 本地字幕文字翻译需要macOS26及系统语言包。豆包文本翻译需另有 `volc.speech.mt` 权限；本地翻译不自动切云端，实时语音识别仍使用豆包。

资料库可选择主稿导出Markdown；勾选其他版本时，分别附上实时与录后稿件及观测明细。命令行运行 `meetingtape help transcribe` 查看同一导出入口。

首版为预发布。AEC、长录音、设备/睡眠、最低系统和窗口行为的未完成验证不因签名或公证通过而消失；详见随附Change Log及仓库验收记录。
