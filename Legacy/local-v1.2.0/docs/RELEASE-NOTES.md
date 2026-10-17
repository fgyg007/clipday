# 轻贴 · ClipDay v1.2.0

## 中文

首次开源发布，MIT 许可。

- 24 小时滚动文字/图片剪贴板历史、搜索与下载导出。
- 自定义快捷键与系统/全局占用检测，辅助功能授权后的直接粘贴。
- 延迟剪贴板交付重试，标准编辑菜单，选择历史前捕获尚未轮询的新复制。
- 中英文文档、MIT 许可、arm64 DMG 与 SHA-256 校验。

**下载：`ClipDay-1.2.0-arm64.dmg`。** 自动生成的 Source code ZIP/TAR 是源码，不是安装包。

**运行环境：Apple Silicon（M 系列，arm64），macOS 14 Sonoma 或更新。**不支持 Intel。本次实际验证在 macOS 27.0.1 / Apple Silicon 完成，未覆盖所有旧版本。应用界面为简体中文。

打开 DMG，把 `轻贴.app` 拖到 Applications，推出映像后运行。发布包采用 ad-hoc 签名，**没有 Apple Developer ID 签名或公证**；首次启动可能需要系统设置中的“仍要打开”。

[中文介绍](https://github.com/fgyg007/clipday#readme) · [安装、权限与校验说明](https://github.com/fgyg007/clipday/blob/v1.2.0/docs/INSTALL.md)

## English

First public release under the MIT license.

- Rolling 24-hour text/image history, search, and export to Downloads.
- Custom shortcuts, system/global conflict checks, and Accessibility-enabled direct paste.
- Retry delayed pasteboard delivery, standard editing menu, and capture pending copies before history selection.
- Bilingual documentation, MIT license, arm64 DMG, and SHA-256 checksum.

**Download: `ClipDay-1.2.0-arm64.dmg`.** The auto-generated Source code ZIP/TAR files are not installers.

**Requires Apple Silicon (M-series, arm64), macOS 14 Sonoma or later.** Intel Macs are not supported by this package. Runtime verification was performed on macOS 27.0.1 / Apple Silicon, not every older OS version. The app UI is Simplified Chinese.

Open the DMG, drag `轻贴.app` to Applications, eject the image, and launch the installed app. This release is **ad-hoc signed, without Developer ID signing or Apple notarization**. macOS may require the Open Anyway flow on first launch.

[English overview](https://github.com/fgyg007/clipday/blob/v1.2.0/README.en.md) · [Installation and checksums](https://github.com/fgyg007/clipday/blob/v1.2.0/docs/INSTALL.md)

## SHA-256

Download `SHA256SUMS.txt` alongside the DMG, then run / 将校验文件与 DMG 放在同一目录，执行：

```sh
shasum -a 256 -c SHA256SUMS.txt
```

Direct paste requires Accessibility permission. After an ad-hoc-signed update, you may need to remove the old permission entry and add the current installed app again. / 直接粘贴需要辅助功能权限；更新后若旧授权失效，请移除旧项并重新添加当前安装的应用。

Native text-window validation included recording with the window hidden for 75 seconds; behavior in all third-party apps is not guaranteed. / 已验证原生文字窗口中隐藏 75 秒后的采集，未覆盖所有第三方软件。
