# 轻贴云版 · 首次 NAS 预览发布

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
