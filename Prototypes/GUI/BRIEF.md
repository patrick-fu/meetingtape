# MeetingTape GUI 形态探索

问题：同样的本地双源录音任务，哪种桌面入口和信息结构最顺手？五套可交互高保真原型，在一个入口通过 `?variant=A` 至 `E` 切换。用户尚未选择方向。

这是浏览器中的桌面界面原型。所有录音状态与列表只存在内存，操作使用演示数据；试听与导出提供本地生成的双声道 AAC 示例。保留真实引擎的边界：录音只有开始、停止；系统音频与麦克风分别记录；可保留原始麦克风；有输出位置；没有转写、AI 摘要、云账户和公开的录音暂停功能。

| 方案 | 结构与气质 | 参考入口 |
| --- | --- | --- |
| A 资料库 | macOS 双栏资料库，大幅波形与录音详情，轻灰与冷蓝 | [语音备忘录 Mac](https://support.apple.com/guide/voice-memos/welcome/mac) |
| B 菜单栏 | 桌面右上角的小型下拉面板，快捷开始与最近录音 | [CleanShot](https://cleanshot.com/) |
| C 录音机 | 暖色实体设备，双 VU 表、机械按钮与计时显示 | [Piezo](https://rogueamoeba.com/piezo/) |
| D 启动器 | 深色命令面板，以搜索、键盘和动作列表组织录音 | [Raycast](https://manual.raycast.com/search-bar) |
| E 伴随条 | 会议场景中的轻量悬浮控件，可展开来源与最近录音 | [Superwhisper](https://superwhisper.com/) 的全局快捷入口与浮层形态 |

只参考产品形态，不复刻品牌素材。根目录的 `index.html`、`bridge.js` 和 `serve.py` 由主 agent 拥有；每个变体独立布局，不共享页面模板。

变体文件 `variants/a.html` 至 `e.html` 使用原生 HTML/CSS/JS，无外部依赖。页面载入 `../bridge.js`，每次操作后调用 `window.reportState({ variant: 'A', status: 'ready', ... })`。桥接脚本将状态提供给外层原型控制器，不在产品界面显示调试信息。示例音频位于 `../assets/sample-stereo.m4a`。

以 1440×900 和 1280×800 为主要桌面视口；为外层左上角原型标识和底部切换器留出空间。所有可见按钮和输入都应响应操作，至少能完成开始、计时、停止、保存到列表与试听，以及标题、输出位置、保留原麦设置。正常文案简短，使用中文；图标用 SVG 或 CSS。形态差异应体现在窗口结构和操作路径，而非仅换色。
