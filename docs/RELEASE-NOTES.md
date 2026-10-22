# 版本与构建记录

## 2026-10-22：Android 私有目录兼容修复 v0.2.0-preview.4

- 根据 preview.3 在真实手机显示的“本机状态初始化失败”继续缩小范围：排除密钥、普通 I/O 和目录同步错误，定位到图片缓存对系统父目录的符号链接检查。
- Android 厂商可能用系统映射路径提供 `/data/user/0`；新版信任由系统管理、应用无法替换的父路径，同时继续拒绝应用自有缓存根目录及缓存文件的符号链接。
- 应用私有目录继续由 Android 自动创建，不申请共享存储权限，也不需要用户手动选择文件夹。
- Android 版本 0.2.0-preview.4，versionCode 5；包名和签名保持不变，覆盖安装保留原数据。

## 2026-10-22：Android 启动兼容修复 v0.2.0-preview.3

- 修复部分 Android 文件系统不支持目录 `fsync` 时，图片缓存初始化导致整个应用启动失败的问题；缓存文件内容仍在原子替换前完成持久化。
- 未清理缓存时不再执行无意义的目录同步，增加干净启动与清理后同步回归测试。
- 启动失败提示现在区分密钥不匹配、存储文件错误和文件系统操作错误，不再统一要求重启手机。
- Android 版本 0.2.0-preview.3，versionCode 4；沿用原包名和签名，必须覆盖安装以保留原数据。
- 这是基于代码路径和旧版格式对比得到的修复；真实问题手机仍需覆盖安装验证。

## 2026-10-21：Android 连接反馈修复 v0.2.0-preview.2

[Android APK 与校验文件](https://github.com/fgyg007/clipday/releases/tag/v0.2.0-preview.2)；Mac/Windows 仍使用 preview.1。

- 修复 NAS 测试/配对结果只出现在长表单顶部、会被自动同步覆盖的问题；新增按钮下方独立结果区，并在点击后自动滚动到结果。
- 执行中显示按钮进度并避免重复提交；暂停、初始化和忙碌状态提供明确说明。
- 在联网前校验地址与配对码，拒绝 HTTPS 网页和 QuickConnect 地址；域名必须可直连 SMB。区分域名解析、连接超时、端口不可达和登录权限错误。
- Android 版本 0.2.0-preview.2，versionCode 3；沿用原包名与签名，覆盖安装，不先卸载。
- 云端验证：[构建 39573580905](https://github.com/fgyg007/clipday/actions/runs/39573580905) 通过；67 项核心测试及 6 项 Android 界面回归测试全部通过，release lint 无错误。APK 签名证书与上一版一致。构建源码为 `13d9c31`，后续提交仅更新文档。
- 自动化验证不替代用户手机与实际 NAS 验收；此版本仍为预览版。

## 2026-10-21：统一版预览发布 v0.2.0-preview.1

[下载三端预览包与 SHA256SUMS.txt](https://github.com/fgyg007/clipday/releases/tag/v0.2.0-preview.1)。

- 发布源码基线：`67ef36e656911d90b57905e5595e99de76f5ce2e`；本次只整理已有构建和更新发布说明，未改变应用功能。
- Mac：10 月 18 日本机原生构建，重新验证 ad-hoc 签名并归档；包内版本保留 0.1.1、开发标记 0.2.0-dev。发布集合标签不等于各端内部版本号。
- Windows：10 月 18 日生成的 0.2.0-preview.1 x64 自包含 ZIP，校验与原构建一致。
- Android：使用主分支 [Actions 构建 39104716050](https://github.com/fgyg007/clipday/actions/runs/39104716050)，签名验证成功，证书与旧包一致，versionCode 2。
- 三端附件与 SHA-256 校验文件已发布；保留旧正式版本，不将此预览标记为最新稳定版。
- 验证沿用 10 月 18 日构建/回归记录；本次验证归档完整性、Mac 签名、Android 构建签名记录与文件校验值，不宣称新增实机验收。
- 仍待 Mac 界面/直接粘贴、Windows 真机、Android 覆盖升级与图片授权、真实 NAS/网盘互通。旧本地版历史导入未实现。Mac 未公证，Windows 未做 Authenticode 签名。
- 更新前退出旧桌面程序，Android 覆盖安装；保留原数据，不先卸载或清除配置。旧版下载保留，但不保证新版数据可直接降级。

## 2026-10-18：统一版验收构建（当日尚未发布 Release）

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
