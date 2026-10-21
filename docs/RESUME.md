---
updated: 2026-10-18
---

# 轻贴续接

## 当前事实

开发主仓库为 `fgyg007/clipday`。统一源码已于 2026-10-17 通过 PR #1 合入 `main`，基线提交 `7706baf`；旧 `clipday-cloud` 仓库、分支与发布保留。当前本机工作目录是 `dev/projects/clipday-unified`，本轮验证分支为 `codex/unified-validation`，合入后以 `main` 继续；旧 `mac-clipboard` 的未提交开发现场保留，不要整目录覆盖或重复合并。

桌面统一入口支持仅本机、NAS、网盘文件夹，Android 当前仅支持 NAS。新增图片同步与可靠性改进已完成本轮 Mac 原生、Windows 交叉构建与 Android 云端 APK 构建，实际设备互通仍待验收。旧本地版历史导入尚未实现，模式切换不自动搬运历史。产品与数据边界见 [统一入口](../Desktop/README.md)、[合并说明](CONSOLIDATION.md)。历史验证按日期保留；当前 Git 状态以仓库为准。

既有验证应区分版本：旧 NAS 预览曾完成核心测试、跨语言互通、隔离 Samba 与 Android 15 模拟器测试，维护者反馈桌面可用；不代表统一版或用户手机、真实 NAS 已验收。统一源码合入时记录了 64 项 JVM 测试和 25 组源码检查通过，Mac/Windows 原生构建及真实网盘互通仍待验证，详见 [开发说明](DEVELOPMENT.md)。

长期目标与私有配置仍由 Notes 的轻贴项目管理资料维护。本文件仅作仓库续接导航，不复制私有配置或替代项目记忆。

## 30 秒检查

在当前仓库根目录执行：

```sh
git status --short --branch
git log -3 --oneline
git remote -v
```

先读本文件，再按任务读 `docs/DEVELOPMENT.md` 与对应验收清单。不要把旧目录续接文档中的“转到 clipday-cloud 开发”作为当前入口。

## 能跑的命令

Mac 需已有 Apple Silicon、Xcode Command Line Tools；完整桌面构建还需 .NET 10。若 `dotnet` 不在 PATH，设置 `CLIPDAY_DOTNET` 为现有可执行文件的绝对路径。

```sh
# 配对界面预览：仅编译，无需 .NET 或 NAS
zsh scripts/build-pairing-preview.sh
./build/pairing-preview

# C# 路径保护不接受 macOS 默认临时路径中的符号链接
mkdir -p build/test-tmp
export TMPDIR="$PWD/build/test-tmp"

# 完整桌面测试与构建，需相应工具链
zsh scripts/test.sh
zsh scripts/test-cloud.sh
zsh scripts/test-drive-native.sh
zsh scripts/build.sh
zsh scripts/test-pairing-bridge.sh
zsh scripts/build-windows.sh
```

预览复用正式 `PairingCodeCard` 与 `NASController`，只填入合成数字 `123456`，从 30 秒倒计时至过期，90 秒后自动退出。不启动控制器、不读取系统剪贴板、不连接 NAS、不运行配对组件；不是实际配对测试。完整 Mac 产物为 `build/轻贴.app`，Windows 为 `build/windows-x64/ClipDay.Cloud.exe`。现有 `package.sh` 仍禁用自动正式打包；2026-10-21 已将验证过的现有产物手动归档发布为 v0.2.0-preview.1，见 [版本记录](RELEASE-NOTES.md)。

2026-10-18：上述预览脚本已在本机成功编译并链接，shell 语法检查通过；尚未执行窗口视觉验收。这仅验证预览目标，不代表完整应用构建与运行验收。

## 环境与签名维护

- 旧记录显示，2026-10-16 清理了当次新增的本地 Android 工具链、模拟器及缓存；这不是对当前安装状态的重新检测。新 Android 开发或 APK 构建任务先弹窗选择云端构建、复用本地环境或安装新环境，选择前只读检查，不自动下载工具链。
- 维护者 Android 更新必须复用原正式签名密钥并递增 `versionCode`，保持包名；签名材料保留在 Git 之外，按 Notes 私有配置定位，不重新生成替代密钥、不提交密码或密钥。不要要求先卸载旧 APK。
- Mac 构建使用 ad-hoc 签名，不等于 Developer ID 签名或公证。统一版沿用 NAS 应用身份，运行前避免同时启动同身份新旧副本；回滚包可保留 ZIP，避免保留会被系统索引的重复应用副本。

## 端口

应用没有监听端口或开发者中转服务器。桌面 NAS 模式使用已挂载目录；Android SMB 默认连接 445。旧隔离 Samba 测试使用本机 1445，仅供合成 fixture，不代表当前有该服务运行。网盘模式依赖用户现有双向同步客户端。

## 唯一下一步

Mac 原生测试与完整构建现已通过，详见开发说明的 2026-10-18 记录。新版已安装并以仅本机、暂停记录启动，运行诊断确认窗口可见及快捷键已注册。下一步进行界面与真实直接粘贴验收（当前辅助功能权限未授权），随后在隔离环境验证实际双端同步；不把核心测试当成真实 NAS／网盘验收。启动参数只对本次进程生效，下次普通启动会使用原有保存设置。

下次可以直接说：“继续轻贴统一版，从 docs/RESUME.md 接上，先检查工作区和已有验证结果，再继续三端实机验收。”

## 不要做什么

- 不覆盖旧开发现场、旧安装、历史目录、钥匙串或签名材料；不自动迁移或跨模式发送历史。
- 不把真实剪贴板、NAS 地址和密码、配对秘密、运行数据写进 Git 或测试日志。
- 不用源码检查或旧版验收替代新版原生、实际设备与真实网盘验收。
- 不因源码已合并就删除、归档旧仓库或分支；提交、推送与发布按当前用户授权范围执行。


## Windows 与 Android 预览包

2026-10-18 已生成 `0.2.0-preview.1`：Windows 自包含 x64 ZIP 在 `dist/`；Android APK 在 `dist/android/`。安卓沿用原签名，版本码 2，64 项 JVM 测试与 release lint 通过（6 项警告、无错误），源码与构建记录见开发说明。Android 已按用户选择使用 GitHub Actions；同一任务不用重复询问构建方式，不在 Mac 恢复安卓工具链。重新构建按 `.github/workflows/build-android.yml`，Secrets 只保留在 GitHub/私有配置，不能写入源码。当前 Actions 产物仍属验收预览，不是正式发布；Windows UI、手机覆盖升级和真实 NAS 互通待用户设备验证。
