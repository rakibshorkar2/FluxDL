# ⚡ FluxDL

```
███████╗██╗     ██╗   ██╗██╗  ██╗██████╗ ██╗
██╔════╝██║     ██║   ██║╚██╗██╔╝██╔══██╗██║
█████╗  ██║     ██║   ██║ ╚███╔╝ ██║  ██║██║
██╔══╝  ██║     ██║   ██║ ██╔██╗ ██║  ██║╚═╝
██║     ███████╗╚██████╔╝██╔╝ ██╗██████╔╝██╗
╚═╝     ╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚═════╝ ╚═╝
```

**The all-in-one iOS download powerhouse** — files, torrents, browsing and proxy in a single SwiftUI app. Built for iOS 18. No App Store. No limits.

<p align="center">
  <a href="https://github.com/rakibshorkar2/FluxDL/releases"><img alt="Latest Release" src="https://img.shields.io/github/v/release/rakibshorkar2/FluxDL?style=for-the-badge&label=release&color=8b5cf6"></a>
  <img alt="Platform" src="https://img.shields.io/badge/platform-iOS%2018-black?style=for-the-badge&logo=apple&logoColor=white">
  <img alt="Language" src="https://img.shields.io/badge/language-Swift-F05138?style=for-the-badge&logo=swift&logoColor=white">
  <img alt="Engine" src="https://img.shields.io/badge/engine-libtorrent-1a9e63?style=for-the-badge">
</p>

---

## ✨ Features

| | | |
|---|---|---|
| ⬇️ **Downloads** | 🧭 **Browser** | 🔀 **Proxy** |
| Resume, mirrors, checksums, history & folder downloads | WebKit tabs, private mode, ad-block, find-in-page & torrent links | SOCKS5, per-site rules & one-tap YAML import |
| 🧲 **Torrents** | 🎫 **Live Activities** | 🛡️ **Privacy** |
| Full libtorrent engine, magnets, pause/resume & undo removal | Real-time download progress on the Lock Screen | Private tabs, no tracking, keys in Keychain |

---

## 📲 Install

1. Grab the newest `.ipa` from the **[Releases](https://github.com/rakibshorkar2/FluxDL/releases)** page — unsigned, built automatically by CI.
2. Sideload with **[SideStore](https://sidestore.io)**, AltStore, or run it inside **LiveContainer**.
3. Done. ⚡

> 🔒 No jailbreak needed. Just a signed IPA and 7 days of bliss (or LiveContainer for unlimited).

---

## 🛠️ Tech Stack

| Layer | Choice |
|---|---|
| UI | SwiftUI · WidgetKit · Live Activities |
| Torrents | `LibTorrent` (C++ engine, static build) |
| Networking | URLSession · Network.framework (SOCKS5) |
| Parsing | Yams (YAML proxy configs) |

---

## 🚧 Build

CI builds an unsigned IPA on every push via GitHub Actions (`build-ipa.yml`). Local build:

```bash
cd Submodules/LibTorrent-Swift && bash make.sh
xcodebuild -project FluxDL.xcodeproj -scheme FluxDL -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO build
```

---

## ⚖️ License

Free for personal use. Torrent features respect content licensing — use responsibly. 🌊
