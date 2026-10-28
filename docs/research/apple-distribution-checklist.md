# Apple 图标与分发核对表

2026-10-29。只读研究，项目起点为 `p/patrick/live-captions` / `df5bcdd`。Luna 独立核查，主 agent 复读官方资料和实际脚本后留存。本报告明确方案与验收条件，不代表已签名、公证、生成图标或完成消费者验收。

## 当前项目事实

- `Resources/Desktop-Info.plist` 指定最低 macOS 14.2，缺少图标声明；`scripts/build-desktop.sh` 目前不复制图标资源。生产包仍是 SwiftPM 构建后手工组装的 `.app`。
- `scripts/build-local.sh:29` 先签 CLI，`scripts/build-desktop.sh:19` 把其放入 `Contents/Helpers`，再签外层 App。两个签名命令均启用 runtime，却使用 `--timestamp=none`；不能原样用于正式公证。
- CLI 与 GUI 的签名标识不同，不能据旧 ADR 的“复用同一标识”表述判断现状。当前共用音频 entitlement，但这不是 Apple 要求二者 entitlement 必须相同的依据；应核对各进程实际权限和 TCC 归属。
- 当前 SHA-256 文件只覆盖程序二进制，没有最终分发包摘要；没有公证、staple 和发布脚本。

## 图标与旧系统

[当前 Apple HIG](https://developer.apple.com/design/human-interface-guidelines/app-icons/)采用多图层与 Icon Composer 工作流；1024×1024 的方形图层由系统遮罩，不能在图层上预先画死圆角和静态系统光效。这些是当前分层图标规则，不能不加区分地当成所有旧系统静态图标的渲染保证。

[Icon Composer](https://developer.apple.com/icon-composer/)仍是当前工具，不是已退役工具。[集成说明](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)要求将图标纳入实际 Xcode 构建目标；仅把 `.icon` 拷贝进当前手工包不等于完成集成。

Apple 的 [Core Foundation 图标键说明](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html#//apple_ref/doc/uid/TP40009249-SW10)保留 macOS 的 `CFBundleIconFile` 资源路径规则；传统 `.icns` 可以包含多分辨率图像。基于当前构建流程，先接入 `.icns` 是最小兼容方案的工程推断，并非 Apple 要求所有新项目只用它。

若增加分层图标，则同时准备兼容图标资源并验证实际编译产物。没有资料或本项目实测证明这套手工构建在 macOS 14.2 自动生成回退，因此回退必须显式核对；也没有官方依据要求通用“824 像素蒙版”。最后必须检查最终 App 在 Finder、Dock 和小尺寸中的实际图标，而非仅检查源 PNG。

## 签名与公证

[公证要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)包括正确的 Developer ID、所有可执行代码有效签名、hardened runtime、安全时间戳和适当 entitlement。发布构建需使用安全时间戳，不能继承当前本地脚本的 `--timestamp=none`。

先完成资源组装，再逐项签嵌套代码，最后签外层；不要用 `--deep` 代替逐项签名。递归验证签名可以使用 `--deep`。嵌套顺序依据 [TN2206](https://developer.apple.com/library/archive/technotes/tn2206/) 与[分发签名流程](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)。helper 和 App 的 entitlement 按实际需要分别验证，不把签名成功当作录音授权连续性的证明。

公证凭据通过已有本机安全凭据引用使用，不进入仓库或命令输出。证书存在不等于已配置可用的 notarytool 认证；本研究没有访问它们。

## 分发容器与顺序

| 路线 | 正确顺序与限制 |
| --- | --- |
| App ZIP | 签 App → 用 `ditto` 打 ZIP 提交 → 查看 Accepted 和日志 → 对 App staple/validate → 重建最终 ZIP。ZIP 自身不能签名或 staple |
| DMG | 先签内部代码与 App → 制作并签 DMG → 提交最外层 DMG → Accepted 后对 DMG staple/validate → 生成最终包摘要 |
| 独立 CLI | 签名、公证适用，但裸二进制不能直接 staple。若承诺离线首次运行，需使用可 staple 的外层容器并实测消费者路径；不承诺任意裸 CLI ZIP 都能离线首次运行 |
| PKG | 需要适当的 Installer 签名；适合需要安装到指定位置或多个组件的产品，不是所有 App 的必需项 |

依据：[软件打包](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)、[自定义公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。嵌套容器通常只公证最外层；格式、签名和装订顺序不能互换。staple 之后应重建最终 ZIP 和摘要，不能把此前上传包的摘要误标成最终消费者资产摘要。

App 与独立 CLI 都需要携带实际使用的转写脚本资源。发布清单不能只列一个裸 CLI 二进制而遗漏运行所需资源；具体清单由最终构建与运行时资源定位核对。

## 消费者验收

Apple DTS 的[公证产品测试方法](https://developer.apple.com/forums/thread/130560)强调从未运行过产品的干净机器/VM、带 quarantine 的实际下载及安装运行。macOS 14+ 的 `syspolicy_check distribution` 是辅助检查；公证 Accepted、签名验证通过和实际首次使用成功分别是不同证据。

- 从最终分发资产下载，核对最终 SHA-256；检查 App、helper 与容器签名以及 staple 票据。
- 在最低支持版本和当前系统上检查图标、首次打开、权限请求、包内 helper 启动、录音保存、BYOK 与导出。
- 离线首次运行若属于承诺，只在隔离 VM/测试机内验证；不切换宿主机 Wi-Fi、代理或 VPN。
- 已有开发机和缓存不能代替干净环境。缺少设备/系统版本时明确保留验收缺口，不宣布兼容已通过。

## GitHub 发布

先准备实际提交/tag、明确的 Change Log、许可证/NOTICE、资产和摘要；使用 draft 组织上传与回下载校验，全部完成后再发布 pre-release。`--verify-tag` 可防止误把默认分支自动打成 tag；`--draft` 保留未发布状态。创建、上传与发布是分开的请求，不是原子操作，见 [GitHub CLI](https://cli.github.com/manual/gh_release_create)。

不可变发布和 attestation 是独立策略选择，不是 Apple 公证要求。本阶段沿用本地构建，不因研究增加 CI。用户决定的是交付形态与公开历史策略；签名参数、最小权限验证及实际资源完整性由实现和验收负责。

## 已清楚与仍未实测

研究已明确官方要求、当前项目差距和可选容器，可以进入图标/发布决策；未实测 macOS 14.2 图标回退、TCC 归属、签名时间戳、公证账号、staple、干净下载或离线首次运行。后续的发布门槛必须保留这些证据要求。
