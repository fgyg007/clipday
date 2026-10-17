# 轻贴 · ClipDay（统一入口开发中）

**复制在这台，粘贴到另一台。桌面端按场景选择仅本机、NAS 或网盘同步文件夹；Android 当前仅支持 NAS。**

[English](README.en.md) · [下载安装包](https://github.com/fgyg007/clipday-cloud/releases/tag/v0.1.0-preview.1) · [安装与配对](docs/INSTALL.md) · [反馈问题](https://github.com/fgyg007/clipday-cloud/issues)

下方已发布安装包为 **NAS 预览版**：设备需能访问同一份 NAS 共享，安卓首版面向同一 Wi-Fi。无需注册轻贴账号，没有开发者中转服务器；暂不提供移动网络接入配置。

当前未发布源码正在统一为一个“轻贴”入口，保留原 NAS 应用身份与历史，新增模式选择和设置引导。旧本地版 `fgyg007/clipday` 的功能与原始测试资产已经比对保留，但历史迁移尚未实现或验收，不能把当前源码视为已完整替换所有旧版本。

- 只在这台电脑用：选择仅本机，不连接 NAS 或网盘。
- 需要 Android 参与：选择 NAS；电脑先创建空间，手机加入。
- 只在电脑间同步且已有双向云盘客户端：选择网盘文件夹，并保证文件完整保留本机。百度网盘、OneDrive、iCloud 均尚未真机验收，不代表所有客户端、套餐或虚拟挂载均适用。

详见[模式选择、隐私与验收边界](Desktop/README.md)。模式切换保留旧队列和数据，不自动迁移、合并或同时发送；需要按界面提示重启后生效。设置帮助可生成不含路径、地址、账号、密钥或剪贴板内容的 AI 提示，由你预览并自行复制，不会直接发送给第三方。

下面下载仍是旧“轻贴云版”的 NAS 预览安装包，不含尚未发布的统一引导和网盘模式。未删除任何仓库、版本或用户数据。

## 下载

| 平台 | 当前版本 | 下载 | 要求 |
| --- | --- | --- | --- |
| macOS | 0.1.1 | [Mac ZIP](https://github.com/fgyg007/clipday-cloud/releases/download/v0.1.0-preview.1/ClipDay-Cloud-0.1.1-macos-arm64.zip) · 约 2.7 MiB | Apple Silicon（M 系列），macOS 14+ |
| Windows | 0.1.3 | [Windows ZIP](https://github.com/fgyg007/clipday-cloud/releases/download/v0.1.0-preview.1/ClipDay-Cloud-0.1.3-windows-x64.zip) | x64，便携版，随包附带 .NET 运行环境 |
| Android | 0.1.0 | [安卓 APK](https://github.com/fgyg007/clipday-cloud/releases/download/v0.1.0-preview.1/ClipDay-Cloud-0.1.0-android.apk) · 约 3.1 MiB | Android 8.0+，同一 Wi-Fi 下可访问 NAS |

[SHA-256 校验文件](https://github.com/fgyg007/clipday-cloud/releases/download/v0.1.0-preview.1/SHA256SUMS.txt)。Release 中自动生成的 **Source code** 是源码，不是安装包。三个客户端的版本号各自维护，可以加入同一个同步空间。

## 它能做什么

| 功能 | 行为 |
| --- | --- |
| 电脑间文字同步 | Mac、Windows 在连接正常时同步新复制的文字，另一端可直接粘贴 |
| 安卓主动收发 | 手机选中文字 → 分享到轻贴 → 发送；打开轻贴接收，点记录复制 |
| 6 位数字配对 | 随机数字、2 分钟倒计时；成功或到期后失效，无需复制长密钥 |
| 多设备加入 | 第三台及后续设备可通过新的配对码加入同一空间 |
| 自填 NAS 路径 | 电脑填各自的共享路径；安卓填写 NAS 地址、共享名、子目录和账号 |
| 24 小时文字历史 | 搜索、查看和复制历史；离线内容进入队列，恢复连接后重试 |
| 加密同步文件 | NAS 中的文字记录使用 AES-256-GCM 加密 |
| 后台桌面客户端 | 关闭 Windows 窗口后留在托盘；Mac 使用菜单栏和快捷键 |

同一时间在多个设备复制、首次打开或离线补回的内容会保守地进入历史，避免旧内容覆盖正在使用的剪贴板。图片和文件暂不跨设备同步。

## 自动图片同步开发分支

图片功能在独立开发分支中实现，**现有 Release 安装包仍仅同步文字**。目标是在电脑复制图片后自动加密同步，不要求每次点击发送；Android 仅在系统允许的聚焦前台读取剪贴板，不能承诺后台采集。图片限制20 MiB，文件传输暂不加入。

协议、隐私边界与原生验收要求见 [图片协议](docs/IMAGE-PROTOCOL.md) 和 [图片验收清单](docs/IMAGE-ACCEPTANCE.md)。不把 NAS 上传成功当作另一端已收到。

## 当前源码中的可靠性改进

以下为待验证、待发布的源码改进，**上方现有安装包不包含本次改动**：

- 保存失败保留重试机会，避免一次磁盘错误导致该次复制永久漏记；个别不可读历史不会让全部历史加载中止。
- 独立的“隐私暂停”阻止新的记录与同步；“暂停同步”仍保留本机记录，两者不混淆，暂停不删除旧记录。
- 首次连接按路径检查、读写诊断、创建／加入引导；明确区分本机保存与 NAS 上传，接收端状态没有回执时显示未知。

平台编译与实际设备验收边界见 [开发说明](docs/DEVELOPMENT.md)。

## 三步开始

1. **准备共享文件夹。** Mac 和 Windows 分别确认能读写同一个 NAS 文件夹；路径可以不同，例如 Mac 的 `/Volumes/共享/轻贴` 和 Windows 的 `\\NAS\共享\轻贴`。
2. **在一台电脑创建同步空间。** 打开轻贴 NAS 版（现有发布包显示“轻贴云版”），填入目录，点击“创建同步空间…”。已有空间时，点击“配对另一台电脑…”显示新的 6 位数字。
3. **其他设备输入数字加入。** 电脑填写对应共享路径，安卓填写 NAS 连接资料，在倒计时结束前输入配对码。不要为每台设备分别创建空间。

首次配对后先用一小段测试文字检查双向收发。详细步骤见[安装与配对](docs/INSTALL.md)和[安卓使用说明](Android/README.md)。

## 安装与升级

以下安装步骤对应现有 Release。自行构建当前源码时，Mac 产物为“轻贴.app”，Windows 窗口／托盘和 Android 应用／分享入口显示“轻贴”；Windows 启动文件仍为 `ClipDay.Cloud.exe`。Mac 更换显示名称不代表新应用身份：先退出旧副本，避免同时运行新旧名称的副本。

- **Mac：**解压后把“轻贴云版.app”放入 Applications。快捷键为 `⌃⌥⇧V`（Control + Option + Shift + V）。它与[轻贴本地版](https://github.com/fgyg007/clipday)使用独立设置和历史，可同时保留。
- **Windows：**解压整个文件夹，运行 `ClipDay.Cloud.exe`。双击托盘图标打开历史，右键“退出”才停止运行。没有看到图标时检查托盘折叠区。
- **安卓：**下载 APK 后按手机提示安装。更新时覆盖安装即可，不要先卸载；卸载会删除本机配对、历史和待发送数据。

Mac 包采用 ad-hoc 签名，未经过 Apple Developer ID 签名或公证；Windows EXE 未做 Authenticode 签名，首次运行可能遇到系统提示。安卓 APK 使用固定签名，普通使用无需安装任何开发工具。请先核对下载来源与校验值，参见[安装说明](docs/INSTALL.md)。

## 已发布预览包的数据与边界

- 当前只同步纯文字，每条最多 1 MiB；每条从产生时保留 24 小时。到期清理需要客户端运行并可访问 NAS；NAS 快照、回收站与备份不受应用控制。
- NAS 保存加密记录。空间密钥分别由 Mac 钥匙串、Windows DPAPI、Android Keystore 保护；**Mac 本机历史未额外加密**。详见[数据说明](docs/PRIVACY.md)。
- 账号、共享目录、NAS 权限由用户自己管理，不必发给维护者。同步依赖网络、共享权限、设备时钟和休眠状态。
- 安卓不监听后台剪贴板，也不在后台持续接收；需要主动分享，或打开轻贴查看。没有输入法或辅助功能服务。
- 暂无账号系统、设备撤销、自动密钥轮换、全设备撤回、自动更新或 Windows 安装器；未提供 iOS、Linux、Intel Mac 或 Windows ARM 原生包。

## 已发布预览包的既有验证记录（不代表新源码验收）

维护者已在 Mac／Windows 实际试用，并反馈桌面版可用。核心同步、短码配对和跨语言文件互通经过自动化验证；安卓经过隔离 Samba 和 Android 15 模拟器的配对、分享、复制、断线及重启恢复测试。**安卓用户真机与实际 NAS 尚待验收**，也未覆盖所有系统版本和 NAS 型号。

## 开发与开源

Mac 使用 Swift／SwiftUI，Windows 使用 C#／WinForms，安卓使用 Java 原生界面与 SMBJ。完整源码、测试、协议和构建说明见[开发文档](docs/DEVELOPMENT.md)及[同步协议](docs/CLOUD-PROTOCOL.md)。本仓库提供公开源码和版本下载，没有配置 GitHub Actions 打包工作流。

[MIT License](LICENSE)。第三方组件保留各自许可证。欢迎反馈可复现问题，请勿上传真实剪贴板、NAS 密码或配对码。

配套工具：[轻贴 · 本地剪贴板历史](https://github.com/fgyg007/clipday) · [轻卸 · AppSweep](https://github.com/fgyg007/appsweep)。

统一开发线的实际限制、旧版本资产和未实现的自愿历史导入见[合并与迁移计划](docs/CONSOLIDATION.md)。请勿据此删除旧安装或旧仓库。
