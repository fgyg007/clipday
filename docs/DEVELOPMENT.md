# 从源码开发

> 当前集成源码统一显示为“轻贴”，桌面可选仅本机、NAS、网盘文件夹；Android仅支持NAS。下文原发布包名称/版本是历史安装信息，未发布新包。完整模式引导与未完成的历史迁移见 [统一说明](../Desktop/README.md) 和 [合并计划](CONSOLIDATION.md)。


本仓库是轻贴 NAS 版（原显示名“轻贴云版”）的独立公开源码与下载入口。Mac 的通用组件来自 [ClipDay](https://github.com/fgyg007/clipday)，保留 MIT 许可。Android 已配置 GitHub Actions 签名构建（见下方工作流说明），源码不包含维护者签名私钥。

当前源码仅更改 NAS 客户端的显示名称，未发布新安装包，也未改动现有版本号。现有 Release 的 Mac 仍为 `轻贴云版.app`。保留所有 bundle/package/assembly、可执行文件、互斥锁、存储、钥匙串与图片 provider 标识，避免把改名变成数据迁移。NAS 协议、路径以及 Android NAS 支持不变。

可在无原生工具链环境运行 `python3 scripts/test-nas-branding.py` 检查显示名称与兼容标识；它不替代平台编译、资源布局和升级验收。

## 工程

| 目录 | 内容 |
| --- | --- |
| `Sources/` | Mac Swift／SwiftUI、系统剪贴板与 NAS 同步 |
| `Windows/ClipDay.Cloud/` | Windows WinForms 客户端 |
| `Windows/ClipDay.Sync/` | C# 同步与 SRP 配对核心 |
| `Windows/ClipDay.Pairing/` | Mac 随包携带的 Native AOT 配对组件 |
| `Android/` | Java 安卓客户端、SMB 适配、测试与 Gradle wrapper |
| `Tests/`、`scripts/` | 测试、互通 fixture、构建脚本 |

## Mac 和 Windows

Mac 需要 Apple Silicon Mac、Xcode Command Line Tools、Python 3、ripgrep 和 .NET 10 SDK。Windows 版本可在 Mac 使用 .NET 10 SDK 交叉构建；运行时已经随便携包附带。

```sh
git clone https://github.com/fgyg007/clipday-cloud.git
cd clipday-cloud
zsh scripts/test.sh
zsh scripts/test-cloud.sh
zsh scripts/build-cloud.sh
zsh scripts/test-pairing-bridge.sh
zsh scripts/build-windows.sh
```

若 `dotnet` 不在 PATH，设置 `CLIPDAY_DOTNET` 为其绝对路径。产物分别为 `build/轻贴.app` 与 `build/windows-x64/ClipDay.Cloud.exe`。Windows 发布脚本禁用调试符号，避免在下载包中携带开发机 PDB 路径。Mac 编译采用 ad-hoc 签名。

测试使用合成文本、公开 fixture 密钥、临时目录和独立命名剪贴板；不要把 fixture 脚本指向真实 NAS 同步目录。`test-pairing-bridge.sh` 需先生成 Mac 配对组件。

## Android

构建需要 JDK 17、Android SDK 35／Build Tools 35.0.0，仓库 wrapper 使用 Gradle 8.11.1，AGP 8.9.2。这些工具可在选定的本地或云端构建环境提供，安装使用 APK 不需要它们。详见 [Android README](../Android/README.md)。

## 贡献与验收

改动后运行受影响平台的测试。纯文档或发布元数据不需要重新构建所有客户端。桌面单元测试不能验证真实 Windows 托盘、DPAPI、手机厂商系统或实际 NAS 权限，需按变更范围补充人工验收。

首次公开发布沿用已验证的 Mac 0.1.1 和 Android 0.1.0 包；Windows 0.1.3 使用相同应用源码重新打包以移除调试路径。发布记录和校验清单见 [发布说明](RELEASE-NOTES.md)。测试结果不构成所有系统或 NAS 的兼容保证。

## 本轮可靠性改动的验收

详见 [可靠性验收清单](RELIABILITY-ACCEPTANCE.md)。新增源码不等于已发布安装包；没有变更版本号或签名，也未新增自动发布工作流。平台测试未执行时必须明确记录，不能用静态检查替代编译通过或实机验收。

### 2026-10-17 云端验证记录

- Android：隔离 JVM 核心回归测试 21 项通过；应用 Java 源文件通过 Android 15 框架桩的编译检查。没有生成 APK，也未运行 Android lint、设备／模拟器或真实 SMB 验收。
- Windows：新增 35 项回归断言，覆盖持久化失败重试、隐私暂停、路径诊断和队列幂等；本环境没有 .NET SDK，未执行 C# 编译或这些测试。
- Mac：新增 33 项回归断言，覆盖历史隔离、重试、暂停、诊断和队列幂等；Linux 无 Xcode/AppKit，未执行 Swift 编译或这些测试。
- 辅助检查：全部 15 个 C# 文件和 14 个 Swift 文件通过 tree-sitter 语法解析；项目 XML 与补丁空白检查通过。**语法解析不等于类型检查、编译或平台运行通过。**
- 加密记录版本、配对协议、现有空间和 24 小时到期未迁移。跨平台互通需在具备全部工具链的隔离环境再验收。

## 自动图片同步开发分支

图片协议、保护边界与人工验收分别见 [图片协议](IMAGE-PROTOCOL.md)、[隐私说明](PRIVACY.md) 和 [图片验收](IMAGE-ACCEPTANCE.md)。旧文字 v1 及配对不迁移；图片单独使用 `images-v1` 目录。本分支没有发布新安装包。

新增测试入口：

```sh
python3 scripts/test-image-protocol-vector.py
KEEP_TEST_ARTIFACTS=1 bash scripts/test-android-core-jvm.sh --compile-app
# 具备原生工具链后：
zsh scripts/test-cloud.sh
dotnet run --project Windows/ClipDay.Sync.Tests -c Release -- images
```

Python 检查使用公开合成图片与固定测试密钥，验证认证加密、AAD、摘要及篡改拒绝；固定 nonce 只用于公开测试向量，产品始终使用随机 nonce。Python 需要 cryptography。Java 编译检查使用已有的固定校验和 Maven 测试依赖，不替代 APK 打包、Android 设备授权或真实 SMB 行为。Windows／Mac 测试源码须在对应工具链运行，静态解析不构成编译通过。

### 2026-10-17 图片分支验证记录

- 隔离 JVM 测试61项通过（原可靠性测试与新增图片协议、队列、剪贴板门控回归合计）。主应用 Java 源文件通过固定 Android15 框架编译检查，仅保留3项既有过时API警告；没有 APK、资源打包、Lint 或设备运行结果。
- Python 独立解密共享固定向量，也成功解密 Java 使用随机 nonce 生成的公开测试密文，核对完整 PNG、尺寸、SHA-256、AAD 与篡改拒绝。此项不代表三端原生运行互通已验证。
- 全部18个 C# 文件、16个 Swift 文件通过语法解析，5个工程 XML 与6个资源/配置 XML 可解析，补丁空白检查通过。
- 新增 Windows 协议/图像/UI逻辑回归，以及 Mac 图像协议和隔离剪贴板回归源码；本环境无 .NET/Xcode，未编译或执行。不得把语法解析和代码审查称为原生测试通过。
- 专项代码审查修正了文字与图片交错覆盖、暂停恢复基线、部分扫描自动应用、Mac入队确认与上传之间的重启竞态及待发意图误删。发布前仍须按图片验收清单验证真实剪贴板、URI授权和隔离SMB故障。


## 更名源码检查

2026-10-17：4组 NAS 显示名称和身份兼容性 Python 检查通过；原61项 JVM 回归通过，更名后的 Android Java 编译通过，仅有3项既有过时API警告。Mac/Windows 原生编译运行、Android实际UI布局及升级路径仍未验收；未构建或发布安装包。

## 独立云盘版源码（未发布）

见 [Desktop/README.md](../Desktop/README.md)。构建目标为 `scripts/build-drive.sh` / `Windows/ClipDay.Drive`；不使用百度 API 实验或授权服务器。`Desktop/products.json` 区分产品身份、开发版本、平台和未验证的提供方。

源码契约检查：`scripts/test-drive-contracts.py`、`scripts/test-drive-mac-source.py`、`scripts/test-windows-drive-source.py`。Windows 脚本在没有 tree-sitter 时会明确跳过解析检查；不能把跳过计为通过。`scripts/test-nas-branding.py`继续守护 NAS 身份与旧下载。

原生合成回归入口：`scripts/test-drive-native.sh`；仅测试临时本地复制目录，无真实网盘和剪贴板。测试覆盖独立命名空间、秘密配对前缀隔离、空间证明延迟、部分文字补齐、延迟接收与去重；C#另外覆盖图片清单先到/分块后到。本次缺少.NET/Xcode，未执行此入口，也未执行原生应用编译或真机验收。


## 2026-10-18 Mac 本机验证

统一版在 Apple Silicon / macOS 上使用已有 Swift 与 .NET 10 工具链完成以下检查：

- `test.sh`：52 项本机历史、采集、粘贴决策与快捷键检查通过。
- `test-cloud.sh`：56 项 Swift 图片协议/队列、43 项文字同步、29 项模型检查通过；C# 可靠性 35 项、图片 57 项、文字同步 22 项、短码配对 19 项以及配对回归通过；Swift/C# 双向文字密文互通通过。
- `test-drive-native.sh`：Swift 合成文件夹复制测试及 C# 31 项测试通过，不涉及真实云盘账户。
- `build.sh`：完整 Mac 应用与 Native AOT 配对组件构建成功，`codesign --verify --deep --strict` 通过（ad-hoc 签名）。`test-pairing-bridge.sh` 四项真实组件桥接检查通过。
- 修复图片路径检查误拒 macOS `/var`、`/tmp` 系统固定别名，继续拒绝用户目录符号链接；新增回归断言。修复图片轮询在共享目录已存在时抛错。补齐配对桥接测试对图片模块的编译依赖。
- 恢复合成配对 UI 预览及仓库续接说明。预览目标单独编译通过。

本机 C# 测试需使用无符号链接的临时根目录。在仓库根目录先执行 `mkdir -p build/test-tmp` 和 `export TMPDIR="$PWD/build/test-tmp"`，然后执行上述脚本；未放宽 C# 的路径保护。工具不在 PATH 时通过 `CLIPDAY_DOTNET` 指定已有 SDK。

已将构建的 `轻贴.app` 安装至用户 Applications，并使用 `-selectedSyncMode local -paused YES` 启动。应用自带诊断确认窗口可见、快捷键已注册、暂停记录且没有采集错误；启动参数不改变下次启动所用的原有持久配置。UI 自动化连接超时，视觉布局尚未验收；辅助功能权限未授权，真实直接粘贴待验证。Windows 客户端构建/UI、Android APK/设备、真实 NAS/云盘跨设备互通及旧本地历史导入未在本轮验收，未发布新安装包。


## Android GitHub Actions 构建

工作流为 `.github/workflows/build-android.yml`，沿用独立云端构建方法，原生 Java 工程不需要 Node/Capacitor。使用 JDK 17、SDK/Build Tools 35 和仓库 Gradle wrapper，执行核心测试、release lint、签名 APK 构建及 apksigner 校验。源码改动在 main 或当前验证分支触发，支持手动触发；不在 PR 事件中解密签名密钥。

仓库 Secrets 名称为 `CLIPDAY_ANDROID_KEYSTORE_BASE64` 与 `CLIPDAY_ANDROID_STORE_PASSWORD`。必须使用轻贴已有正式密钥，不能使用其他 App 的密钥。密钥仅还原至 runner 临时目录，不作为 artifact 上传，最后清理。APK 与 SHA256SUMS artifact 保留 30 天，测试报告单独上传。本次预览版本为 `0.2.0-preview.1`，Android `versionCode=2`，包名与签名身份保持不变。Actions artifact 是验收产物，不自动创建 Release。


### 2026-10-18 Windows / Android 构建结果

- Windows `0.2.0-preview.1`：使用现有 .NET 10 SDK 成功交叉发布 win-x64 自包含应用，便携 ZIP 约 46.4 MiB，包含程序及第三方许可，无 PDB。ZIP 完整性和 SHA-256 已检查；尚未在 Windows 真机验证托盘、剪贴板及 DPAPI。
- Android `0.2.0-preview.1` / versionCode 2：[GitHub Actions 构建 39104194060](https://github.com/fgyg007/clipday/actions/runs/39104194060) 成功，构建源码提交 `b6949d9`。64 项 JVM 测试全部通过，无失败或跳过；release lint 无错误，有 6 项警告（目标 API、测试依赖更新与字符串拼接）。
- APK 约 3.1 MiB，APK v2 签名验证成功。下载后的校验值与 artifact 清单一致，签名证书 SHA-256 与旧 0.1.0 APK 完全相同，保留覆盖升级所需的签名与包名。未在手机验证实际升级、URI 图片授权或 NAS 互通；安装更新不要先卸载旧版。
- 本机没有安装 Android SDK/JDK/Gradle。产物位于 `dist/ClipDay-0.2.0-preview.1-windows-x64.zip` 与 `dist/android/ClipDay-0.2.0-preview.1-android.apk`，校验清单随包保留。未创建新的 GitHub Release。
