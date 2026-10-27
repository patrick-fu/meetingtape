# Apple 图标与分发研究：部分结论与纠错

日期：2026-10-28。研究分支仅保留已核验事实与未决边界，不修改生产资源。

Gemini 3.8 Flash High 的受监控研究运行已结束，工具回执SUCCESS、退出0，但主 agent未验收其整体答案。答案将当前Icon Composer错误称为已退役，并给出未可靠核验的固定824像素蒙版、helper权限一致及TN3134链接；这些说法不得进入实施依据。已完成15次search_web工具调用不等于结论正确。

## 主 agent独立核验

- [当前 Icon Composer 官方页面](https://developer.apple.com/icon-composer/)明确提供Mac多图层图标设计与Xcode集成，存在下载入口；不是已退役工具。
- [当前HIG原文](https://developer.apple.com/design/human-interface-guidelines/app-icons.md)说明图层设计、Icon Composer与系统外观适配；不能沿用“一律手工套固定圆角和阴影”的旧版结论。新旧系统兼容、项目实际资源格式与图标原型仍需继续核对。
- [自定义公证流程原文](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow.md)明确ZIP不能直接staple，应为其中可支持的项目装订后重新打包；独立二进制虽有票据但当前不能直接staple。
- [GitHub官方CLI发布文档](https://cli.github.com/manual/gh_release_create)支持draft、prerelease、notes-file与verify-tag；创建并上传附件和发布不是单一原子操作。当前不创建tag或release。

## 尚未收口

继续从Apple原始资料核验最低macOS14.2的图标兼容/回退资源、嵌套签名与分发容器的项目适配，以及实际下载后的Gatekeeper/首次运行验收。不能把公证accepted等同于消费端成功。该研究票保持开放，不将未验收的外部答案当作完整研究成果。
