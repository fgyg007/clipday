# ClipDay · Unified clipboard history and sync

**Keep a day of clipboard history and move text and images between your own devices.**

[中文](README.md) · [Installation](docs/INSTALL.md) · [Build and version notes](docs/RELEASE-NOTES.md) · [Issues](https://github.com/fgyg007/clipday/issues)

One desktop app offers local-only, NAS and cloud-synced-folder modes. Android supports NAS only. No ClipDay account or developer relay server is required. The app UI is Simplified Chinese.

## Preview downloads — 2026-10-21

[Unified v0.2.0-preview.1](https://github.com/fgyg007/clipday/releases/tag/v0.2.0-preview.1) is now available. Builds and core regression checks passed; real-device interoperability remains pending.

| Platform | Download | Requirements |
| --- | --- | --- |
| macOS | [Mac ZIP](https://github.com/fgyg007/clipday/releases/download/v0.2.0-preview.1/ClipDay-0.2.0-preview.1-macos-arm64.zip) | Apple Silicon, macOS 14+; bundle retains 0.1.1 / 0.2.0-dev |
| Windows | [Windows ZIP](https://github.com/fgyg007/clipday/releases/download/v0.2.0-preview.1/ClipDay-0.2.0-preview.1-windows-x64.zip) | Self-contained x64; run ClipDay/ClipDay.Cloud.exe |
| Android | [APK](https://github.com/fgyg007/clipday/releases/download/v0.2.0-preview.1/ClipDay-0.2.0-preview.1-android.apk) | Android 8.0+, NAS only; versionCode 2 |

[SHA-256 checksums](https://github.com/fgyg007/clipday/releases/download/v0.2.0-preview.1/SHA256SUMS.txt). Android preserves the previous signing certificate: update in place without uninstalling. Release assets are not subject to the Actions artifact retention period. Physical-phone upgrade testing remains pending.

Historical downloads remain available: [standalone local v1.2.0](https://github.com/fgyg007/clipday/releases/tag/v1.2.0) and [old NAS preview](https://github.com/fgyg007/clipday-cloud/releases/tag/v0.1.0-preview.1). The old NAS packages are Mac 0.1.1 / Windows 0.1.3 / Android 0.1.0 and synchronize text only. They do not contain unified setup, cloud-folder mode or image sync. Source code ZIP/TAR downloads are not installers.

## Choose a mode

- **Local-only:** desktop history without connecting to a sync folder.
- **NAS:** desktops and Android access the same shared directory. Create a space on one desktop; join other devices with a six-digit, two-minute pairing code.
- **Cloud folder:** desktops reuse an existing bidirectional sync client and fully downloaded local files. Pairing uses a full secret token, not the NAS code. No provider API or OAuth service is used.

Cloud-folder logic has passed synthetic replica tests. Real Baidu, OneDrive and iCloud compatibility remains unverified. Backup-only clients, virtual mounts and online-only placeholders are not equivalent to a tested bidirectional folder. Switching modes requires restarting and retains separate histories and queues. See [mode setup](Desktop/README.md).

## Features and limits

- 24-hour text/image history. Mac supports search, TXT/PNG export, configurable shortcuts and direct paste after Accessibility authorization.
- Automatic desktop text/image capture; Android text is sent through explicit sharing/input. Android image capture requires foreground focus and a readable content URI, with no background clipboard bypass.
- AES-256-GCM sync records, persistent queues, retry, deduplication and damaged-history isolation. First connection and offline backlog do not blindly replace the current clipboard.
- Separate privacy pause and sync-only pause. Pausing does not erase history or retract completed transfers.
- Connection diagnostics and user-previewed, manually copied AI setup help; nothing is sent directly to an AI service.

Images are limited to 20 MiB, 8192 per dimension and 16,777,216 pixels. Arbitrary files are not transferred. A successful write does not prove receipt on another device. See [image protocol](docs/IMAGE-PROTOCOL.md) and [privacy](docs/PRIVACY.md).

## Installation and data

The Mac app is now `轻贴.app` and retains the NAS app identity. Quit an older copy before starting it. Windows runs `ClipDay.Cloud.exe`; closing the window leaves it in the tray. Android updates must preserve its package and signing identity. See [installation](docs/INSTALL.md).

Standalone local v1.2.0 has a separate identity; **history import is not implemented**. Mode switching does not migrate or upload old history. Preserve old data; see [consolidation](docs/CONSOLIDATION.md).

Mac local history is not separately encrypted. Space keys use Keychain, Windows DPAPI or Android Keystore. Expiry cleanup requires running clients and reachable storage; snapshots, backups and external copies are outside the app's control. Mac is ad-hoc signed and not notarized; Windows is not Authenticode-signed. No auto-updater, per-device revocation, automatic key rotation, global recall, iOS/Linux/Intel Mac or native Windows ARM package is provided.

## Verification

Passed: 52 Mac base checks; 56 Swift image, 43 sync and 29 model checks; C# reliability/image/sync/pairing suites; Swift/C# text encryption interoperability; native pairing bridge; synthetic cloud-folder replicas. Android passed all 64 JVM tests, release lint with zero errors and six warnings, and APK signature verification matching the old certificate.

Pending: Mac visual layout and actual direct paste, Windows UI/clipboard/DPAPI, Android physical-phone upgrades and URI grants, real NAS and provider-specific cross-device sync. Historical desktop/emulator results do not certify these new paths. Detailed evidence and commands are in [development](docs/DEVELOPMENT.md).

## Source

Swift/SwiftUI, C#/WinForms and native Java/SMBJ. Android signed builds run in GitHub Actions; signing secrets are not in source. [Resume guide](docs/RESUME.md) · [MIT License](LICENSE) · [Third-party notices](licenses/THIRD-PARTY-NOTICES.txt) · [AppSweep](https://github.com/fgyg007/appsweep).

Use synthetic content in bug reports. Do not upload clipboard contents, NAS credentials or pairing secrets.

Historical NAS files (Mac app `轻贴云版.app`; no new features):

[Mac 0.1.1](https://github.com/fgyg007/clipday-cloud/releases/download/v0.1.0-preview.1/ClipDay-Cloud-0.1.1-macos-arm64.zip) · [Windows 0.1.3](https://github.com/fgyg007/clipday-cloud/releases/download/v0.1.0-preview.1/ClipDay-Cloud-0.1.3-windows-x64.zip) · [Android 0.1.0](https://github.com/fgyg007/clipday-cloud/releases/download/v0.1.0-preview.1/ClipDay-Cloud-0.1.0-android.apk) · [SHA256SUMS](https://github.com/fgyg007/clipday-cloud/releases/download/v0.1.0-preview.1/SHA256SUMS.txt)
