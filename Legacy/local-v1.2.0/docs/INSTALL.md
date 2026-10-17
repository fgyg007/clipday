# 轻贴 / ClipDay — 安装与运行 · Installation

[中文项目说明](../README.md) · [English overview](../README.en.md)

## 中文

### 运行环境

- Apple Silicon Mac（M 系列，arm64）。本次 DMG **不支持 Intel Mac**，也不能用于 Windows、Linux 或 iOS。
- macOS 14 Sonoma 或更新版本。最低部署目标为 14.0；实际验证环境为 macOS 27.0.1 / Apple Silicon，未逐一验证所有系统版本。
- 应用界面为简体中文；无需 Xcode、Swift、Python 或其他开发环境，无需账号和网络连接。

### 下载与安装

1. 从 [GitHub Releases](https://github.com/fgyg007/clipday/releases/latest) 下载 `ClipDay-版本号-arm64.dmg`，不要把自动生成的 Source code ZIP 当作安装包。
2. 打开 DMG，将 `轻贴.app` 拖到其中的 **Applications** 文件夹快捷方式。没有权限写入 `/Applications` 时可复制到 `~/Applications`。
3. 推出磁盘映像，从安装目录启动应用。不要从 DMG 内长期运行，也不要同时运行多个副本。
4. 更新时先退出应用，再替换安装目录中的旧版本。退出不会删除本地数据。

### 首次打开与签名

此版本为 **ad-hoc 签名，未使用 Apple Developer ID，未经过 Apple 公证**。这是可下载的社区版本，不是 App Store 安装包。

macOS 可能阻止首次启动。确认文件来自上面的官方仓库、校验值匹配且你信任该软件后，尝试打开一次，再到 **系统设置 → 隐私与安全性 → 仍要打开**，按系统提示确认。若组织策略不允许此操作，需要联系管理员。不要关闭 Gatekeeper 或系统完整性保护。

请参阅 [Apple 官方打开应用说明](https://support.apple.com/102445)。系统提示和按钮名称可能随版本变化。

### 校验下载

将 DMG 和同一 Release 的 `SHA256SUMS.txt` 放在同一目录，打开终端进入该目录执行：

```sh
shasum -a 256 -c SHA256SUMS.txt
```

应显示 `OK`。校验值验证传输完整性，不等同于 Apple 签名或公证。

## English

### Requirements

- An **Apple Silicon Mac (M-series, arm64)**. This DMG does **not** support Intel Macs, Windows, Linux, or iOS.
- macOS 14 Sonoma or later. The deployment target is 14.0; runtime checks were performed on macOS 27.0.1 / Apple Silicon, not every supported OS version.
- The app UI is **Simplified Chinese**. No development tools, account, or internet connection are required to run it.

### Install and update

1. Download `ClipDay-version-arm64.dmg` from [GitHub Releases](https://github.com/fgyg007/clipday/releases/latest). The automatically generated Source code ZIP is not an installer.
2. Open the DMG and drag `轻贴.app` onto the **Applications** shortcut. You may instead copy it to `~/Applications` if you cannot write to `/Applications`.
3. Eject the image and launch the installed copy. Avoid running from the image or keeping multiple running copies.
4. Quit the app before replacing it during an update. Quitting does not delete local data.

### First launch and signing

This release is **ad-hoc signed, without an Apple Developer ID certificate or Apple notarization**. It is a community download, not an App Store package.

If macOS blocks it, first verify the source and checksum and decide whether you trust it. Attempt to open it, then use **System Settings → Privacy & Security → Open Anyway** if available, and follow the system prompts. Managed Macs may prohibit this; contact your administrator. Do not disable Gatekeeper or System Integrity Protection. See [Apple's official instructions](https://support.apple.com/102445).

For integrity verification, download `SHA256SUMS.txt` alongside the DMG and run `shasum -a 256 -c SHA256SUMS.txt` in that folder. Expect `OK`. A checksum is not a substitute for Developer ID signing or notarization.
