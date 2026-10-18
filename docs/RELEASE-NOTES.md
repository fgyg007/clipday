# 版本与构建记录

## 2026-10-18：统一版验收构建（尚未发布 Release）

Mac 已完成原生构建与本机安装；Windows 与 Android 预览版本为 `0.2.0-preview.1`。这是一轮构建和回归验证，不代表 Windows/手机或真实同步环境已验收，也没有替换旧 Release。

| 平台 | 产物 | 状态 |
| --- | --- | --- |
| Mac | `轻贴.app`；包版本 0.1.1、开发标记 0.2.0-dev | 原生构建及 ad-hoc 签名检查通过，本机启动诊断通过；未上传新归档 |
| Windows | `ClipDay-0.2.0-preview.1-windows-x64.zip` | 自包含 x64，约 46.4 MiB；已本地生成和校验，无 PDB，尚未上传 Release |
| Android | `ClipDay-0.2.0-preview.1-android.apk` | versionCode 2，约 3.1 MiB；云端签名构建成功，证书与旧 APK 相同 |

Android [构建记录与 artifact](https://github.com/fgyg007/clipday/actions/runs/39104194060) 对应源码 `b6949d9`，需 GitHub 登录，保留 30 天。下载 APK artifact 后校验随附 SHA256SUMS，覆盖安装，不要先卸载。

本轮内容：桌面统一三种模式、加密图片同步、隐私暂停与失败重试、设置引导；恢复配对预览与续接说明。Mac 修复系统临时路径别名误拒、图片目录重复创建失败和配对桥接测试漏编图片模块。

验证：Mac/Swift/C# 核心回归、文字密文互通、原生配对桥接和合成网盘测试通过；Android 64 项 JVM 测试通过，lint 无错误、6 项警告。详见[完整构建记录](DEVELOPMENT.md)。仍待 Mac 视觉/直接粘贴、Windows UI/DPAPI、手机升级/图片 URI、真实 NAS/网盘跨设备验收；旧本地历史导入尚未实现。

## 历史：旧 NAS 预览发布


Release：`v0.1.0-preview.1`。这是本次多平台发布集合的标签，各客户端保留自己的版本号。

| 平台 | 版本 | 文件 |
| --- | --- | --- |
| Mac | 0.1.1 | `ClipDay-Cloud-0.1.1-macos-arm64.zip` |
| Windows | 0.1.3 | `ClipDay-Cloud-0.1.3-windows-x64.zip` |
| Android | 0.1.0 | `ClipDay-Cloud-0.1.0-android.apk` |

## 本次提供

- 独立的公开源码仓库、MIT 许可、中英文介绍、安装说明、协议和测试代码。
- Mac／Windows NAS 加密文字同步、6 位短码配对、2 分钟倒计时、离线队列和 24 小时历史。
- Windows 托盘图标、浅色界面、配对成功后的状态保护及更高的默认历史窗口。
- 安卓同一 Wi-Fi 下分享发送、前台接收和手动复制，可加入已有桌面空间。
- 三个平台的可下载包与 `SHA256SUMS.txt`；Mac、安卓使用此前已验证的包，Windows 以相同应用逻辑重打包并移除开发机调试路径。

这是预览版本：只同步文字，没有移动网络接入配置、安卓后台自动同步、设备撤销、自动密钥轮换或自动更新。安卓通过模拟器和隔离 Samba 测试，用户真机与实际 NAS 仍待验收。Mac 包未公证，Windows EXE 未做 Authenticode 签名。

更新时退出旧桌面程序再替换，安卓覆盖安装；不要为更新先清除数据或重建同步空间。Source code ZIP/TAR 是源码，不是安装包。

[项目介绍](https://github.com/fgyg007/clipday-cloud) · [安装与配对](https://github.com/fgyg007/clipday-cloud/blob/v0.1.0-preview.1/docs/INSTALL.md) · [问题反馈](https://github.com/fgyg007/clipday-cloud/issues)
