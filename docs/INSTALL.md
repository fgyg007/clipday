# 安装、升级与配对

[项目首页](../README.md) · [当前构建与历史版本](RELEASE-NOTES.md) · [模式说明](../Desktop/README.md)

2026-10-21 已发布[统一版 v0.2.0-preview.1](https://github.com/fgyg007/clipday/releases/tag/v0.2.0-preview.1)，在 Release 的 Assets 中下载 Mac ZIP、Windows ZIP 或 Android APK，并核对 SHA256SUMS.txt。三端已完成构建，真实设备与同步互通仍待验收；旧 NAS Release 不包含统一版新增功能。

Android 请使用修复版 [0.2.0-preview.4](https://github.com/fgyg007/clipday/releases/tag/v0.2.0-preview.4)（versionCode 5），覆盖安装保留数据。应用私有文件夹由 Android 自动创建，不需要用户选择或授予共享存储权限；该版兼容厂商系统对私有目录父路径的映射。不要先卸载或清除数据。

## Mac

1. Apple Silicon、macOS 14+。取得新构建后，将 `轻贴.app` 放入 Applications 或 `~/Applications`；源码构建见[开发说明](DEVELOPMENT.md)。
2. 先退出旧“轻贴云版”或另一份统一版。新版沿用 NAS 身份 `io.jlmac.ClipDay.Cloud`，不要同时运行同身份副本。
3. 默认快捷键 `⌃⌥⇧V`，可在设置中更改。系统询问粘贴访问时按需授权；从历史直接切回目标应用粘贴还需要辅助功能权限。手动按 `⌘V` 不需要该权限。
4. 旧独立本地版 `io.jlmac.ClipDay` 的历史不会自动导入，不要据此清除旧数据。本轮本机启动验证使用了仅本机、暂停记录参数，正常重启仍使用已保存配置。

Mac 包为 ad-hoc 签名，未做 Developer ID 签名或公证。核对来源和校验值后按系统“隐私与安全性”提示处理，不关闭 Gatekeeper 或系统完整性保护。当前辅助功能直接粘贴及视觉布局仍待实机验收。

## Windows

1. 新预览文件为 `ClipDay-0.2.0-preview.1-windows-x64.zip`。解压整个 ZIP，在 `ClipDay` 文件夹中运行 `ClipDay.Cloud.exe`；自带 .NET 运行环境。
2. 更新前先从旧程序托盘菜单退出，再解压新版到独立目录。NAS 程序身份和用户数据目录保留；不要删除原配置或重新创建同名空间。
3. 关闭窗口仍留在托盘，双击托盘图标打开历史，菜单“退出”才停止运行。

EXE 未做 Authenticode 签名。核对来源及 SHA-256；Windows 实机托盘、DPI、剪贴板和 DPAPI 尚未完成本轮验收。

## Android

1. 从构建页面 Artifacts 下载 APK 包，解压取得 `ClipDay-0.2.0-preview.1-android.apk`。最低 Android 8.0，手机通过可访问 NAS 的局域网连接。
2. 本次 versionCode 为 2，包名 `io.jlmac.clipday.android`，签名证书与旧 0.1.0 APK 一致。按手机正常流程**覆盖安装，不要先卸载或清除数据**；真实设备升级仍需核对。
3. 桌面必须选择 NAS 模式。手机填写 NAS 主机、共享名称、共享内子目录和账号；不能填 Windows 盘符或 Mac 的 `/Volumes/…` 路径。
4. 用已配对电脑生成新的 6 位码加入。文字通过分享/输入确认发送，收到后打开历史手动复制；图片在前台及系统 URI 授权允许时采集/接收，不能保证后台同步。

旧包和自签名包不可混淆：其他签名无法覆盖维护者包。保留手机配对、历史及待发队列；详细说明见 [Android README](../Android/README.md)。

## 三种模式

- **仅本机**：保存本机历史，不创建同步连接。
- **NAS**：先确认所有设备能访问同一个共享目录。第一台电脑创建空间，后续设备加入，不要各自创建。6 位码有效 2 分钟，成功一次或累计输错 5 次后失效。
- **网盘文件夹**：仅桌面支持。使用已有双向同步客户端，将文件完整保留在本机；首台创建空间，另一台手动输入完整秘密配对信息，等待空间证明同步。它包含密钥，不能公开或放进同步文件夹。详见[网盘设置](../Desktop/README.md)。

切换模式需按提示重启，旧模式历史和队列保留，不自动迁移或跨模式补传。新安装默认本机；已有 NAS 配置可能自动保留 NAS 模式。

## 首次检查

1. NAS 模式下 Mac 先挂载共享，Windows 使用 UNC/盘符，手机填写 SMB 信息；路径文字可不同，但必须对应同一个目录。
2. 使用连接检查验证读写、重命名与删除权限。检查成功不等于已配对，更不代表另一台在线。
3. 先用合成短句，再用小图片测试双向收发。在两端分别确认历史和粘贴结果，不能以“已上传”代替接收确认。
4. 检查隐私暂停、仅暂停同步、离线恢复及重启。隐私暂停不撤回已传输数据，网盘客户端还可能上传已写入的密文。

真实 NAS/网盘兼容性仍待验证，详见[可靠性验收](RELIABILITY-ACCEPTANCE.md)和[图片验收](IMAGE-ACCEPTANCE.md)。

## 校验文件

Android artifact 包含 `SHA256SUMS.txt`；Windows 本地产物旁有 `windows-SHA256SUMS.txt`。例如：

```sh
shasum -a 256 ClipDay-0.2.0-preview.1-android.apk
```

```powershell
Get-FileHash .\ClipDay-0.2.0-preview.1-windows-x64.zip -Algorithm SHA256
```

比较对应文件的完整散列。校验值检查传输完整性，不替代签名或来源判断。旧 NAS 发布的文件名和清单以[历史 Release](https://github.com/fgyg007/clipday-cloud/releases/tag/v0.1.0-preview.1)为准。
