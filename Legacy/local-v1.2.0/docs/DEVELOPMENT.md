# Development / 开发与打包

## Requirements / 开发环境

Apple Silicon Mac, Xcode or Command Line Tools with a Swift 6 compiler and macOS SDK (the SDK must include macOS 15.4 APIs for ClipDay), Python 3, ripgrep (`rg`), Git, and zsh. Tested with Swift 6.2.4. Swift sources compile in Swift 5 language mode. No third-party Swift packages are used.

需要 Apple Silicon Mac、Xcode 或 Command Line Tools、Swift 6 编译器和 macOS SDK（轻贴需含 macOS 15.4 API）、Python 3、ripgrep、Git、zsh。开发工具不需要随应用安装。验证编译器为 Swift 6.2.4，以 Swift 5 语言模式编译。

```sh
git clone https://github.com/fgyg007/clipday.git
cd clipday
zsh scripts/test.sh
zsh scripts/build.sh
zsh scripts/package.sh
```

The `.app` is produced under `build/`; DMG and checksums under `dist/`. `package.sh` builds from source, requires a clean Git checkout, includes the source commit in `BUILD-INFO.txt`, verifies the app signature and architecture, and creates a read-only compressed DMG with an Applications shortcut. The scripts do not install or replace your existing app.

`build/` 为应用产物，`dist/` 为 DMG 与校验文件。打包脚本要求 Git 工作区干净，重新从源码构建，写入源码提交信息，校验签名和架构后制作只读压缩 DMG。脚本不会替换本机已安装应用。

The VFS overlay in `scripts/swift-env.sh` only handles a duplicate SwiftBridging module map present in some upgraded Command Line Tools installations. It is compiler-local and never edits the system SDK. Release builds currently use ad-hoc signing. Developer ID signing/notarization are not configured.

测试优先使用临时样本。不要把真实剪贴板内容、卸载记录、密钥或个人目录截图提交到仓库。发布前核对版本、运行环境、签名状态和校验值。

## Contributions / 贡献

Open an issue describing the macOS version, chip architecture, app version, exact steps, and expected/actual behavior. Remove personal clipboard text and file paths before posting. Small focused pull requests with relevant tests are welcome. Contributions are provided under the repository's MIT license.

欢迎 Issue 和小范围 PR。反馈请注明系统、芯片、应用版本、复现步骤和预期/实际行为；请删去剪贴板正文与私人文件路径。贡献遵循本仓库 MIT 许可。
