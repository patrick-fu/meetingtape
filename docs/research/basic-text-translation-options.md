# 基础文本翻译路线与系统兼容核验

日期：2026-10-28。源基线df5bcdd。Sol只读研究，主agent补核公开SDK定义。没有安装、下载模型、调用翻译/云端或读取凭据。

## 本机与已有安装

当前机器为Apple M4、16GiB。已核对MeetingTape明确配置的Qwen3-ASR 1.7B 4-bit与MOSS 4-bit，模型配置和Python存在；两者是ASR，不是文本翻译模型。仅查询了三个常见缓存根，不是整机模型扫描。Apple语言包安装状态未知。

## 候选路线

- **Apple Translation**：系统管理设备内语言模型，适合基础字幕文本翻译。LanguageAvailability可判断语言对与是否installed；supported不等于已安装。未安装时prepareTranslation可请求用户下载许可。官方指出一个批次混入不同源语言会影响结果；逐条AsyncSequence不是译文token流。没有官方固定内存/延迟指标。
- **TranslateGemma 4B**：Google专用翻译模型，官方55语且含中英，模板需要源/目标语言代码；自动检测、混语和目标语言跳过不保证。MLX Community 4-bit制品约2.18GB，仅为权重大小，不是推理峰值；16GiB下与ASR/录音并发须实测。遵循Gemma模型条款，不能当作MIT模型分发。
- **豆包matx_translate**：基本HTTP文本翻译，单目标，省略源语言时可请求内检测；每次≤16条，每条≤1024 tokens，当前文档无流式响应约定。资源volc.speech.mt，已有ASR Key不证明已开通；请求内检测不能保证请求前跳过或零计费。
- HY-MT1.5-1.8B有小体积官方GGUF候选，但社区许可有地域适用边界，暂不建议未经核对纳入公开默认路线。

## Apple兼容边界

| 能力 | 最低macOS | 限制 |
| --- | --- | --- |
| 系统翻译浮层translationPresentation | 14.4 | UI浮层，不是程序化字幕流水线 |
| TranslationSession、translationTask、LanguageAvailability | 15.0 | session由SwiftUI视图提供，可呈现语言包下载授权 |
| installedSource无界面初始化、isReady、canRequestDownloads | 26.0 | 仅已安装语言，不自行请求下载；缺包会失败 |

主agent直接核验本机SDK公开swiftinterface的available声明；项目最低14.2不能无条件启用Apple后端。保持旧系统支持时可做版本条件下的可选后端。无界面CLI调用须区别26+能力；CLI导出已存在结果不受该限制。

## 未实测及待决定

全部候选的冷/热启动、P50/P95延迟、峰值内存和并发录音影响尚未基准测试，不承诺够快。建议后续用合成文本覆盖中英互译、目标语言相同、专名/数字/否定、句内混语与连续修订，再选实际默认。译文需绑定原句版本，丢弃过期响应。

用户决定基础字幕翻译而非AST/TTS；是否优先Apple本地、旧系统或缺包时提示而不自动切云端，留待产品收口。

## 官方来源

- [Apple Translation说明](https://developer.apple.com/videos/play/wwdc2024/10117/)
- [TranslationSession](https://developer.apple.com/documentation/translation/translationsession)
- [LanguageAvailability状态](https://developer.apple.com/documentation/translation/languageavailability/status)
- [准备语言包](https://developer.apple.com/documentation/translation/translationsession/preparetranslation%28%29)
- [无界面初始化](https://developer.apple.com/documentation/translation/translationsession/init%28installedsource%3Atarget%3A%29)
- [TranslateGemma原模型](https://huggingface.co/google/translategemma-4b-it)
- [MLX转换制品](https://huggingface.co/mlx-community/translategemma-4b-it-4bit)
- [Gemma条款](https://ai.google.dev/gemma/terms)
- [豆包机器翻译接口](https://docs.volcengine.com/docs/DoubaoVoice/MachineTranslationLargeModel-APIAccessDocumentation?lang=en)
- [HY-MT官方制品](https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF)
- [HY-MT许可](https://github.com/Tencent-Hunyuan/HY-MT/blob/main/License.txt)
