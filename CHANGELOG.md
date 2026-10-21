# Changelog / 更新记录

## v0.2.0-preview.1 — 2026-10-21

- 发布 Mac、Windows、Android 预览包及 SHA-256 校验文件；更新中英文下载与安装入口。
- 沿用已完成的构建，应用功能未变，真实设备与跨设备验收仍待完成。
- [Release](https://github.com/fgyg007/clipday/releases/tag/v0.2.0-preview.1)

## 统一版验收构建 / Unified validation builds — 2026-10-18

当日尚无新 Release；10 月 21 日发布记录见上文。 / No new Release on that date; see the October 21 release above.

- Mac 原生、Windows x64 自包含、Android GitHub Actions 签名构建完成；Windows/Android 版本 0.2.0-preview.1，Android versionCode 2。
- 桌面统一仅本机/NAS/网盘模式，Android 仅 NAS；新增加密图片同步、隐私暂停、失败重试、路径诊断与设置帮助。
- 修复 Mac 图片队列系统路径误拒与重复目录创建；补齐配对桥接依赖，恢复配对预览和续接入口。
- 核心与互通测试通过，Android 64 项测试通过、lint 无错误；实际设备互通仍待验收。保留原签名与应用身份，不自动导入旧本地历史。
- Native Mac, self-contained Windows and cloud-signed Android builds passed. Image sync, privacy controls and setup guidance are included; real-device acceptance remains pending. Existing identities/signing are preserved; legacy local history migration is not implemented.

构建产物、历史下载与限制见 [版本记录](docs/RELEASE-NOTES.md)。

## 独立本地版 1.2.0 — 2026-10-15

首次公开发布 / First public release.

- 24 小时滚动文字/图片剪贴板历史、搜索与下载导出。
- 自定义快捷键与系统/全局占用检测，辅助功能授权后的直接粘贴。
- 延迟剪贴板交付重试，标准编辑菜单，选择历史前捕获尚未轮询的新复制。
- 中英文文档、MIT 许可、arm64 DMG 与 SHA-256 校验。

- Rolling 24-hour text/image history, search, and export to Downloads.
- Custom shortcuts, system/global conflict checks, and Accessibility-enabled direct paste.
- Retry delayed pasteboard delivery, standard editing menu, and capture pending copies before history selection.
- Bilingual documentation, MIT license, arm64 DMG, and SHA-256 checksum.

Runtime: Apple Silicon (arm64), macOS 14+. Chinese app UI; Chinese/English documentation. Ad-hoc signed, not notarized.
运行环境：Apple Silicon（arm64）、macOS 14+。中文应用界面，中英文文档。ad-hoc 签名，未公证。
