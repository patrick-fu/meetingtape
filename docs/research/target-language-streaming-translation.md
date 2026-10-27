# 实时字幕翻译能力核验

日期：2026-10-28。基线：df5bcdd。范围：官方能力与现有实现的只读研究；无音频上传、凭据读取或生产修改。研究由 Sol 完成，主 agent 核对接口边界后留存。部分火山文档为 JavaScript 页面，正文通过默认 Chrome 阅读；主 agent 的普通网页读取只能得到页面壳，不把它当作额外正文验证。

## 已核实的候选

| 路线 | 能力与限制 |
| --- | --- |
| 现有 bigmodel_async | 实时 ASR，可修订草稿与二遍定稿；不是通用字幕翻译。enable_lid 为中英/部分方言标签，允许未知，不能等同可靠的混语片段检测；当前页面未列 enable_auto_lang，不能套用 nostream 参数。 |
| ASR 后接 matx_translate | 单目标 HTTP 文本翻译，支持请求内自动检测源语言；每请求最多16条，每条最多1024 tokens。当前文档未定义流式响应。 |
| AST v2 S2T | 真正流式音频输入，具有原文/译文 Start、Response、End 与时间戳。文档给出源20语和粤语/上海话、目标20语，一端须中英；同会话不能切语言或mode。语言检测在原文End返回。zhen 是中英反转，不是固定目标语言规则。 |
| 旧 SpeechTranslate | WebSocket 音频到字幕，源语言需指定中/英/日，使用 IAM AK/SK 签名，与现有凭据形态不同。 |
| 本地 Qwen/MOSS | 官方定位为 ASR；未核实通用翻译接口。Qwen 官方流式在 vLLM，不代表当前 MLX 录后分块路径具备实时输入能力。 |

## 接入与仍需决策的边界

新版文本翻译与 AST 支持 X-Api-Key，资源分别为 volc.speech.mt 与 volc.service_type.10053；同一个 Key 不证明资源已经开通。AST 旧鉴权使用 X-Api-App-Id，不能照抄 ASR 的 X-Api-App-Key。

ASR后文本翻译更容易独立控制保存/展示与翻译开关；定稿后翻译可减少修订与反复请求，代价是等待定稿。若翻译草稿，必须绑定原句版本并丢弃过期响应。AST S2T 可直接返回原文/译文，但 Response 是增量还是快照、稳定配对办法在当前正文不够明确，需要官方 demo 或另行获准实验。

未核实：账号实际权限/并发、已为目标语言就跳过且完全不产生费用、任意混语的可靠路由。文本翻译的检测发生在请求内，不能据此保证请求前跳过。待用户确定字幕或译音范围、延迟偏好、未知语言与混语策略后，再选择路线。没有实际服务测试。

## 原始来源

- [豆包实时语音识别 WebSocket](https://docs.volcengine.com/docs/doubao-voice/bidirectional-streaming-automatic-speech-recognition-websocket?lang=zh)
- [定稿与识别接入说明](https://docs.volcengine.com/docs/DoubaoVoice/Accessmust-read_1?lang=en)
- [机器翻译大模型接口](https://docs.volcengine.com/docs/DoubaoVoice/MachineTranslationLargeModel-APIAccessDocumentation?lang=en)
- [同声传译2.0](https://docs.volcengine.com/docs/doubao-voice/simultaneous-interpretation2-0-api-access-documentation?lang=zh)
- [旧实时语音翻译](https://docs.volcengine.com/docs/machine-translation/real-time-speech-translation-api?lang=zh)
- [Qwen3-ASR 官方仓库](https://github.com/QwenLM/Qwen3-ASR)
- [MOSS 官方仓库](https://github.com/OpenMOSS/MOSS-Transcribe-Diarize)
