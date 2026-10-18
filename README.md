# 轻贴 · ClipDay

**保存一天的剪贴板历史，也让文字和图片在自己的设备间流转。**

[English](README.en.md) · [安装与配对](docs/INSTALL.md) · [版本与构建记录](docs/RELEASE-NOTES.md) · [反馈问题](https://github.com/fgyg007/clipday/issues)

桌面端在同一个“轻贴”里选择**仅本机、NAS、网盘同步文件夹**；Android 当前仅支持 NAS。无需轻贴账号，没有开发者中转服务器。应用界面为简体中文。

## 当前进度与下载

截至 **2026-10-18**，统一版已完成 Mac 原生构建、Windows x64 交叉构建和 Android GitHub Actions 签名构建，正在进行设备验收。**尚未发布新的 GitHub Release，编译通过不代表三端真实互通已验收。**

| 平台 | 当前构建 | 获取方式与要求 |
| --- | --- | --- |
| macOS | 统一版开发构建；包内版本仍为 0.1.1，开发标记 0.2.0-dev | 已本机编译安装；公开新包尚未上传。源码构建见[开发说明](docs/DEVELOPMENT.md)。Apple Silicon、macOS 14+ |
| Windows | 0.2.0-preview.1 | 已生成约 46.4 MiB 的自包含 x64 ZIP，尚未上传 Release；解压运行 `ClipDay.Cloud.exe`，无需另装 .NET |
| Android | 0.2.0-preview.1，versionCode 2 | [云端构建与 APK artifact](https://github.com/fgyg007/clipday/actions/runs/39104194060)，约 3.1 MiB；Android 8.0+ |

下载 Android artifact 需登录 GitHub，在构建页面 Artifacts 中选择 `clipday-android-b6949d9dd606e0961b44cac5c2b04aa69ca33fc5`，解压后有 APK 与 `SHA256SUMS.txt`。artifact 保留 30 天，过期后需重新构建。签名与旧 APK 相同，**覆盖安装，不要先卸载**；实际手机升级仍待验收。

历史公开包继续保留：[独立本地版 v1.2.0](https://github.com/fgyg007/clipday/releases/tag/v1.2.0) · [旧 NAS 预览包](https://github.com/fgyg007/clipday-cloud/releases/tag/v0.1.0-preview.1)。后者为 Mac 0.1.1 / Windows 0.1.3 / Android 0.1.0，仍只同步文字，不含统一引导、网盘模式和新增图片同步。GitHub 的 Source code ZIP/TAR 是源码，不是安装包。

## 按场景选择

| 场景 | 模式 | 说明 |
| --- | --- | --- |
| 只找回这台电脑复制过的内容 | 仅本机 | 不连接 NAS 或网盘 |
| Mac、Windows、Android 之间同步 | NAS | 各设备访问同一个共享目录，首台电脑创建空间，其他设备输入 6 位码加入 |
| 电脑之间已有双向云盘客户端 | 网盘文件夹 | 复用完整保留在本机的同步文件夹；不调用网盘 API，不需要轻贴服务器 |

网盘文件夹模式已实现并通过合成目录测试；百度网盘、OneDrive、iCloud 的真实双机互通仍未验收，不能把单向备份、虚拟盘或未下载的占位文件视为可用同步目录。详见[模式设置](Desktop/README.md)。模式切换需要重启，各模式的历史和队列隔离，不自动迁移或补传旧历史。

## 功能

- **24 小时历史**：文字和图片按原始产生时间到期，支持历史查找与复制；Mac 支持导出 TXT/PNG、快捷键及授权后的直接粘贴。
- **文字与图片同步**：桌面自动捕获；Android 文字通过主动分享/输入发送，图片仅在应用聚焦且获得系统 URI 读取授权时采集。文件、文件夹和压缩包不传输。
- **加密与配对**：同步记录使用 AES-256-GCM；NAS 使用 6 位数字、2 分钟有效期配对，网盘模式使用完整秘密配对信息，两种配对格式不能混用。
- **离线与失败恢复**：持久队列、重试、去重、损坏历史隔离；首次连接和离线追赶保守进入历史，避免旧内容覆盖当前剪贴板。
- **隐私暂停**：停止新采集、发送和接收；“只暂停同步”仍允许本机记录。暂停不清空旧数据，也不能撤回已经完成的传输。
- **设置帮助**：路径读写诊断、创建/加入引导，以及可预览、手动复制的脱敏 AI 求助说明；不会直接发送给第三方。

图片上限 20 MiB、最长边 8192、总像素不超过 16,777,216，具体平台存储边界见[图片协议](docs/IMAGE-PROTOCOL.md)。“已写入同步目录”不代表对端已收到，另一端是否收到需实际核实。

## 开始使用

1. 桌面选择适用模式。需要手机参与时选择 NAS，先确认共享目录可读写。
2. 第一台电脑创建空间，其他设备加入同一个空间。Android 填 NAS 地址、共享名和子目录，不填电脑盘符或 Mac 挂载路径。
3. 用无敏感内容的短句和小图片测试双向收发，再检查暂停、重启与离线恢复。

Mac 新应用名为 `轻贴.app`，沿用旧 NAS 身份；运行前退出旧副本。Windows 关闭窗口后仍留在托盘，托盘菜单“退出”才停止运行。完整步骤见[安装说明](docs/INSTALL.md)。

**旧独立本地版 v1.2.0 的历史导入尚未实现**，不会因统一仓库而自动迁移。保留原数据与备份，详见[数据保留与迁移](docs/CONSOLIDATION.md)。

## 已验证与待验证

已通过：Mac 基础 52 项、Swift 图片 56 项、同步 43 项、模型 29 项；C# 同步/图片/可靠性/配对回归；Swift/C# 文字密文互通；原生配对桥接；合成网盘文件夹测试。Android 64 项 JVM 测试全部通过，release lint 无错误、6 项警告，APK 签名与旧包一致。完整证据见[开发记录](docs/DEVELOPMENT.md)。

待验证：Mac 窗口布局和真实直接粘贴（本轮辅助功能未授权）、Windows 真机托盘/剪贴板/DPAPI、Android 手机覆盖升级与图片 URI、真实 NAS 及各网盘双机互通。旧版曾有桌面试用和模拟器记录，不替代新版验收。

## 数据与边界

Mac 本机历史未额外加密；空间密钥由 Mac 钥匙串、Windows DPAPI、Android Keystore 保护。未标记的敏感文字仍可能被记录。到期清理需要客户端运行且存储可达，不能删除 NAS/网盘备份、快照或其他应用的副本。Android 不后台监听剪贴板，不提供移动网络接入配置。详见[隐私说明](docs/PRIVACY.md)。

Mac 为 ad-hoc 签名，未做 Developer ID 公证；Windows 未做 Authenticode 签名。暂无自动更新、设备撤销、密钥自动轮换或全设备撤回，也未提供 iOS、Linux、Intel Mac 或 Windows ARM 原生包。

## 开发与开源

Mac 使用 Swift/SwiftUI，Windows 使用 C#/WinForms，Android 使用 Java/SMBJ。阅读[开发说明](docs/DEVELOPMENT.md)或[续接入口](docs/RESUME.md)。Android 已配置 GitHub Actions 签名构建，源码不包含签名私钥或用户数据。

[MIT License](LICENSE) · [第三方声明](licenses/THIRD-PARTY-NOTICES.txt) · 配套工具：[轻卸 AppSweep](https://github.com/fgyg007/appsweep)。反馈时请使用合成内容，不公开真实剪贴板、NAS 密码或配对秘密。

旧 NAS 包直链（Mac 应用名 `轻贴云版.app`，不含新功能）：

[Mac 0.1.1](https://github.com/fgyg007/clipday-cloud/releases/download/v0.1.0-preview.1/ClipDay-Cloud-0.1.1-macos-arm64.zip) · [Windows 0.1.3](https://github.com/fgyg007/clipday-cloud/releases/download/v0.1.0-preview.1/ClipDay-Cloud-0.1.3-windows-x64.zip) · [Android 0.1.0](https://github.com/fgyg007/clipday-cloud/releases/download/v0.1.0-preview.1/ClipDay-Cloud-0.1.0-android.apk) · [SHA256SUMS](https://github.com/fgyg007/clipday-cloud/releases/download/v0.1.0-preview.1/SHA256SUMS.txt)
