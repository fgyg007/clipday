# 从源码开发与验证

主仓库为 `fgyg007/clipday`，桌面统一仅本机/NAS/网盘文件夹模式，Android 仅 NAS。2026-10-18 已完成 Mac 原生、Windows x64 交叉、Android Actions 签名构建；真实设备验收仍有待办，详见下方当日记录。公开历史包与当前构建分开列在[版本记录](RELEASE-NOTES.md)。

## 工程入口

| 路径 | 内容 |
| --- | --- |
| `Sources/` | Mac Swift/SwiftUI、历史、NAS/网盘同步 |
| `Windows/ClipDay.Cloud/` | 统一 Windows 客户端，保留旧 NAS 身份 |
| `Windows/ClipDay.Sync/` | C# 同步、图片及配对核心 |
| `Windows/ClipDay.Pairing/` | Mac 随包的 Native AOT 配对组件 |
| `Android/` | Java/SMBJ、Gradle wrapper、核心及设备测试 |
| `Tests/`、`scripts/` | 合成 fixture、测试、构建与配对 UI 预览 |
| `Legacy/local-v1.2.0/` | 独立本地版历史文档和脚本的原始副本，不覆盖修改 |

## Mac 与 Windows 构建

Mac 需要 Apple Silicon、Xcode Command Line Tools、Python 3、ripgrep 和 .NET 10 SDK。Windows x64 可通过现有 .NET SDK 交叉构建；WinForms 界面、剪贴板与 DPAPI 需要 Windows 实机验收。

```sh
git clone https://github.com/fgyg007/clipday.git
cd clipday
# dotnet 未在 PATH 时，先 export CLIPDAY_DOTNET=/absolute/path/to/dotnet
# C# 图片路径保护拒绝符号链接，Mac 使用项目内隔离临时根目录
mkdir -p build/test-tmp
export TMPDIR="$PWD/build/test-tmp"
zsh scripts/test.sh
zsh scripts/test-cloud.sh
zsh scripts/test-drive-native.sh
zsh scripts/build.sh
zsh scripts/test-pairing-bridge.sh
zsh scripts/build-windows.sh
```

产物为 `build/轻贴.app` 和 `build/windows-x64/ClipDay.Cloud.exe`。Mac 使用 ad-hoc 签名；Windows 自包含运行时，无需单独安装 .NET，构建参数关闭 PDB。这些命令不会自动发布 Release 或安装应用。配对桥接测试依赖先构建 Mac 组件。

配对 UI 辅助预览只用合成数字、不连接 NAS：

```sh
zsh scripts/build-pairing-preview.sh
./build/pairing-preview
```

当前默认 `build.sh` 构建统一版。`build-drive.sh` 只是兼容转发，独立 Windows Drive 产品已停用；不要把它们当另一个发布目标。`package.sh` 保留未完成正式发布验收的阻止提示；Windows/Android 本轮文件是验收产物，未创建 Release。

## Android 云端构建

当前采用 GitHub Actions，参考 [工作流](../.github/workflows/build-android.yml)。云端 JDK 17、SDK/Build Tools 35、Gradle 8.11.1、AGP 8.9.2；不需要在 Mac 安装安卓工具链。执行核心测试、lint、签名构建及 apksigner 校验，APK/清单和报告作为 artifact 提供，详见下方云端记录与 [Android README](../Android/README.md)。

签名密钥只能放私有配置/GitHub Secrets。升级复用轻贴原密钥与包名、递增 versionCode；不使用其他 App 的密钥，不先卸载旧包。

## 验证范围

测试使用合成文字/图片、公开 fixture 密钥、独立剪贴板和临时目录，不指向个人 NAS 或历史。原生编译、核心逻辑测试、模拟器记录与真实设备验收分别报告。纯说明更新只做文档/契约检查，不重复构建三端。设备清单见[图片验收](IMAGE-ACCEPTANCE.md)、[可靠性验收](RELIABILITY-ACCEPTANCE.md)。

## 历史验证记录（2026-10-17）

以下记录保留当时环境与限制；当时“未编译”的状态已由后面的 2026-10-18 构建记录更新，不是当前构建结论。

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

## 历史：独立云盘源码阶段（已统一入口）

当前入口以 [Desktop/README.md](../Desktop/README.md) 为准，独立 Windows Drive 目标已停用。以下为统一前的验证范围记录；`Desktop/products.json` 提供当前身份、构建状态和未验证的网盘提供方。

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

已将构建的 `轻贴.app` 安装至用户 Applications，并使用 `-selectedSyncMode local -paused YES` 启动。应用自带诊断确认窗口可见、快捷键已注册、暂停记录且没有采集错误；启动参数不改变下次启动所用的原有持久配置。UI 自动化连接超时，视觉布局尚未验收；辅助功能权限未授权，真实直接粘贴待验证。此处记录的是 Mac 阶段；随后完成的 Windows/Android 构建见下节。Windows UI、手机设备、真实 NAS/云盘跨设备互通及旧本地历史导入仍未验收，未发布新 Release。


## Android GitHub Actions 构建

工作流为 `.github/workflows/build-android.yml`，沿用独立云端构建方法，原生 Java 工程不需要 Node/Capacitor。使用 JDK 17、SDK/Build Tools 35 和仓库 Gradle wrapper，执行核心测试、release lint、签名 APK 构建及 apksigner 校验。源码改动在 main 或当前验证分支触发，支持手动触发；不在 PR 事件中解密签名密钥。

仓库 Secrets 名称为 `CLIPDAY_ANDROID_KEYSTORE_BASE64` 与 `CLIPDAY_ANDROID_STORE_PASSWORD`。必须使用轻贴已有正式密钥，不能使用其他 App 的密钥。密钥仅还原至 runner 临时目录，不作为 artifact 上传，最后清理。APK 与 SHA256SUMS artifact 保留 30 天，测试报告单独上传。本次预览版本为 `0.2.0-preview.1`，Android `versionCode=2`，包名与签名身份保持不变。Actions artifact 是验收产物，不自动创建 Release。


### 2026-10-18 Windows / Android 构建结果

- Windows `0.2.0-preview.1`：使用现有 .NET 10 SDK 成功交叉发布 win-x64 自包含应用，便携 ZIP 约 46.4 MiB，包含程序及第三方许可，无 PDB。ZIP 完整性和 SHA-256 已检查；尚未在 Windows 真机验证托盘、剪贴板及 DPAPI。
- Android `0.2.0-preview.1` / versionCode 2：[GitHub Actions 构建 39104194060](https://github.com/fgyg007/clipday/actions/runs/39104194060) 成功，构建源码提交 `b6949d9`。64 项 JVM 测试全部通过，无失败或跳过；release lint 无错误，有 6 项警告（目标 API、测试依赖更新与字符串拼接）。
- APK 约 3.1 MiB，APK v2 签名验证成功。下载后的校验值与 artifact 清单一致，签名证书 SHA-256 与旧 0.1.0 APK 完全相同，保留覆盖升级所需的签名与包名。未在手机验证实际升级、URI 图片授权或 NAS 互通；安装更新不要先卸载旧版。
- 本机没有安装 Android SDK/JDK/Gradle。产物位于 `dist/ClipDay-0.2.0-preview.1-windows-x64.zip` 与 `dist/android/ClipDay-0.2.0-preview.1-android.apk`，校验清单随包保留。未创建新的 GitHub Release。
