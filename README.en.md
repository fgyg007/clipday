# ClipDay · Unified entry (unreleased integration)

The development source now offers local-only, NAS, and cloud-synced-folder modes in one desktop entry. Android currently supports NAS only. Native builds and real Baidu/OneDrive/iCloud interoperability are NOT verified. The current Mac source output is `轻贴.app`; the original NAS app IDs and stored data are retained, while each new mode has separate state. Mode switching stops operations and requires a manual restart.

The standalone local 1.2.0 feature source, E2E assets and historical documents are preserved. Its separate app identity and history have NOT been migrated. Do not remove old installations or repositories. See [consolidation and migration limits](docs/CONSOLIDATION.md) and [mode setup](Desktop/README.md).

AI setup help is copied only after user action and contains allowlisted generic information, not paths, server addresses, credentials, pairing keys or clipboard content. It is never sent directly to an AI service.

The following historical download instructions describe old NAS preview packages, NOT this integration branch.


**Copy on one computer, paste on another. Share text between macOS, Windows and Android through your own NAS, with a 24-hour history.**

[中文](README.md) · [Downloads](https://github.com/fgyg007/clipday-cloud/releases/tag/v0.1.0-preview.1) · [Setup](docs/INSTALL.md) · [Issues](https://github.com/fgyg007/clipday-cloud/issues)

This preview requires access to the same NAS share. Android is intended for the same Wi-Fi network. No ClipDay account or developer relay server is required. Mobile-network access is not configured by the app. The UI is Simplified Chinese.

Current source renames the existing NAS app to **轻贴 NAS 版** (ClipDay NAS). This display-only rename is not released: existing downloads retain their old labels, filenames and versions. Bundle/package IDs, storage, pairing and NAS protocol are unchanged; Android remains supported for NAS.

See [product/version boundaries](docs/PRODUCTS.md) for development tracks versus published builds. The separate Baidu desktop product is not connected to a safe authorization flow yet; OneDrive/iCloud are planned only, not implemented or included in downloads.

## Downloads

| Platform | Version | Package | Requirements |
| --- | --- | --- | --- |
| macOS | 0.1.1 | [ZIP](https://github.com/fgyg007/clipday-cloud/releases/download/v0.1.0-preview.1/ClipDay-Cloud-0.1.1-macos-arm64.zip) | Apple Silicon, macOS 14+ |
| Windows | 0.1.3 | [ZIP](https://github.com/fgyg007/clipday-cloud/releases/download/v0.1.0-preview.1/ClipDay-Cloud-0.1.3-windows-x64.zip) | x64; portable, .NET runtime included |
| Android | 0.1.0 | [APK](https://github.com/fgyg007/clipday-cloud/releases/download/v0.1.0-preview.1/ClipDay-Cloud-0.1.0-android.apk) | Android 8.0+, NAS reachable over Wi-Fi |

Use the [SHA-256 manifest](https://github.com/fgyg007/clipday-cloud/releases/download/v0.1.0-preview.1/SHA256SUMS.txt) to verify downloads. GitHub's automatic Source code archives are not installers. Client versions are independent and use the same sync protocol.

## How it works

1. Choose an existing folder that both desktop computers can read and write on your NAS.
2. Create a sync space on one desktop. It displays a six-digit code with a two-minute countdown.
3. Enter that code on another device accessing the same folder. Additional devices can join using a new code from an already paired desktop.

Mac and Windows synchronize recent copied text automatically during a continuous connection. First-load, offline backlog and concurrent updates may be added to history without replacing the clipboard. On Android, share text to ClipDay and confirm sending; open ClipDay to receive and copy an item manually. Android does not monitor the background clipboard.

## Installation

These steps describe existing release downloads. Current source builds `轻贴.app` on Mac and uses “轻贴 NAS 版” for Windows and Android display labels. The Windows executable remains `ClipDay.Cloud.exe`. Quit the old Mac copy before using the newly named copy; both retain the same app identity.

- Mac: unzip and move `轻贴云版.app` to Applications. Default shortcut: Control + Option + Shift + V. This is separate from the local-only ClipDay app.
- Windows: extract the entire ZIP and run `ClipDay.Cloud.exe`. Closing the window keeps the tray process running; use the tray menu to quit.
- Android: install the APK using the phone's normal installation flow. Future updates must keep the same signing identity; do not uninstall first if you want to preserve local state.

The Mac package is ad-hoc signed and not notarized. Windows has no Authenticode signature. Android uses a fixed release signing key. No development tools are needed to run the packages.

## Scope and data

Text only, at most 1 MiB per item, expiring after 24 hours. Cleanup requires an active client with NAS access and does not erase NAS snapshots or backups. Records are encrypted with AES-256-GCM. Space keys use platform protection; Mac's local history is not separately encrypted. See [data handling](docs/PRIVACY.md) and the [protocol](docs/CLOUD-PROTOCOL.md).

There is no individual device revocation, automatic key rotation, global recall or auto-updater. No iOS, Linux, Intel Mac or native Windows ARM package is provided.

Desktop functionality has been tried by the maintainer. Automated checks cover synchronization, pairing and cross-language interoperability. Android passed isolated Samba and Android 15 emulator journeys, including offline/restart recovery; physical-phone and personal-NAS acceptance is still pending. Other OS and NAS combinations are not exhaustively tested.

## Source

Swift/SwiftUI on Mac, C#/WinForms on Windows, native Java/SMBJ on Android. See [development](docs/DEVELOPMENT.md). This repository hosts public source and downloadable releases; it has no automated build workflow.

[MIT License](LICENSE), with third-party notices retained. Related projects: [ClipDay](https://github.com/fgyg007/clipday) · [AppSweep](https://github.com/fgyg007/appsweep).

## Reliability improvements in current source

These changes are not included in the existing release downloads. Failed local captures remain retryable; unreadable individual Mac history entries do not abort the whole history load. A separate privacy pause blocks new capture and synchronization without deleting history or queues; sync-only pause still permits local recording. Connection checks guide path/read/write validation and create-versus-join setup. Local persistence and NAS upload are distinct states: the protocol has no receiver receipt, so upload does not mean another device received or pasted the text. Already-issued I/O may finish after pausing; pause cannot retract data. Existing expiry rules still apply. See [privacy](docs/PRIVACY.md) and [development](docs/DEVELOPMENT.md) for limitations.
