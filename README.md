# 🚀 MountMate

_A simple macOS menu bar app to manage your external drives._

<p align="center">
  <img src="https://raw.githubusercontent.com/homielab/mountmate/main/docs/assets/icon.png" alt="MountMate Icon" width="100" height="100" style="border-radius: 22%; border: 0.5px solid rgba(0,0,0,0.1);" />
</p>

<p align="center">
  <a href="https://github.com/homielab/mountmate/actions/workflows/release.yml">
    <img src="https://github.com/homielab/mountmate/actions/workflows/release.yml/badge.svg" />
  </a>
  <a href="https://github.com/homielab/mountmate/releases">
    <img src="https://img.shields.io/github/v/release/homielab/mountmate?label=release&style=flat-square" />
  </a>
  <a href="https://github.com/homielab/mountmate">
    <img src="https://img.shields.io/github/downloads/homielab/mountmate/total?style=flat-square" />
  </a>
  <a href="https://brew.sh">
    <img src="https://img.shields.io/badge/homebrew-supported-blue?style=flat-square" />
  </a>
</p>

---

## ⚡️ Quick Start

Install via [Homebrew](https://brew.sh):

```bash
brew install mountmate
```

Or [download the latest .dmg](https://github.com/homielab/mountmate/releases) and drag MountMate.app into your Applications folder.

## 🧩 What is MountMate?

MountMate is a lightweight macOS menu bar utility that lets you **mount and unmount external drives with a single click** – no Terminal, no Disk Utility, no hassle.

Whether you're dealing with a noisy spinning HDD or want finer control over when your drives are active, MountMate gives you a clean, no-nonsense solution right from your menu bar.

## 🧠 Why I Built It

I have a 4TB external HDD plugged into my Mac mini 24/7. Since it's a spinning drive, macOS constantly spins it up – just for trivial things like opening Finder or running Spotlight. That meant:

- Unwanted noise
- System slowdowns
- Wasted energy

I tried:

- Disk Utility – too slow and clunky
- Custom shell scripts – too technical
- Existing third-party apps – too bloated or didn’t work right

So I built **MountMate**.

## ✅ Features

- View all connected **external drives**
- See which ones are **mounted**
- **Mount/unmount** any drive with a click
- Check **free space** for drives and for mounted network shares (used / total)
- **Keyboard Shortcuts**: Unmount All with `⌘⌥⇧U` and Mount All with `⌘⇧M` by default; change both in Settings (the key shown follows your keyboard layout)
- **Block USB Auto-Mount**: stop selected disks from mounting when plugged in or at login; **Block at Startup** (optional) also writes a rule to `/etc/fstab` and asks for your admin password
- **Custom mount point**: mount a volume at a path you choose (right-click → Custom Mount Point…), or a network share at a folder you choose
- **Encrypted APFS volumes**: unlock them from MountMate, with the password optionally saved in the Keychain ("Forget Saved Password" in the right-click menu removes it)
- **RAID**: Apple RAID sets show up as one disk instead of their members
- **Hide EFI Partitions**: optional (Settings → General → Display)
- **Network Shares**: Auto-mount SMB, NFS, and AFP shares at login
- **Keep Alive**: Auto-reconnect shares and volumes when they drop, after network changes, on wake, and at login
- **Unmount When Idle**: Per volume on an external drive (right-click → Unmount When Idle), unmount it after 1–60 minutes without reads or writes on its disk; never forced, so a volume in use stays mounted and is tried again after another idle period
- **Notifications** (optional, off by default; Settings → General → Behavior): get told when Keep Alive cannot reconnect a mount and when it is back (once per outage, not on every retry), when a blocked disk could not be unmounted, when unmounting before sleep ran out of time, and when a volume was unmounted because it was idle
- **Force Eject**: Safely force eject drives that are in use
- **VoiceOver**: icon-only buttons and the menu bar icon are announced by name
- **Localized** in 7 languages, with correct plural forms
- Runs quietly in the **menu bar**
- Fully native – no Electron; the only dependency is [Sparkle](https://sparkle-project.org), used for automatic updates (Settings → About & Updates)

## ✨ Why Use MountMate?

macOS automatically mounts drives when they’re plugged in – but gives you **no easy way to remount them later** unless you use Terminal or Disk Utility. MountMate is perfect for:

- External HDDs you don’t always need
- Drives used only for backup
- Reducing wear and tear or noise
- Improving system responsiveness
- Network shares that silently drop and need reconnecting

## 🔐 Private, Fast, and Safe

MountMate runs **entirely offline**, using native macOS APIs and command-line tools. It:

- Does **not** track anything
- Does **not** need the internet, except to check for updates (Sparkle)
- Does **not** access your files
- Does **not** run as root: it asks for your admin password only to write `/etc/fstab` (custom mount points of volumes, Block at Startup)

Just a clean utility that does one job well.

## 🖼️ Screenshots

<img src="https://raw.githubusercontent.com/homielab/mountmate/main/docs/screenshots/light.png" width="300" /><img src="https://raw.githubusercontent.com/homielab/mountmate/main/docs/screenshots/dark.png" width="300" />

![Full Screenshot](https://raw.githubusercontent.com/homielab/mountmate/main/docs/screenshots/light-full.png)

## 🛠️ Installation

### Manual Installation

1. [Download the latest `.dmg` release](https://github.com/homielab/mountmate/releases)
2. Open the `.dmg` file
3. Drag `MountMate.app` into the **Applications** folder
4. Eject the installer disk image
5. Launch MountMate from **Applications**

### Install via Homebrew

If you have [Homebrew](https://brew.sh) installed, you can install MountMate directly from this repository:

```bash
brew install mountmate
```

## 🧑‍💻 Development

Open `MountMate.xcodeproj` in Xcode, or from the command line:

```bash
# Unit tests (ad-hoc signed, same command as CI)
xcodebuild test -project MountMate.xcodeproj -scheme MountMate \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  -only-testing:MountMateTests CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO

# Code style (configured in .swift-format)
swift format lint -r MountMate MountMateTests
```

The app builds in the Swift 5 language mode with strict concurrency checking set to `targeted`; the unit tests use the Swift 6 language mode. Mark new value types in `Models/` and `Utilities/` `Sendable` when they are passed between queues, and keep the build free of concurrency warnings.

Log with `Log.<category>` (`MountMate/Utilities/Log.swift`), never `print()`. Mark share/volume names, paths and error text `privacy: .private`, never log a password, and pass command lines through `redactedArguments`; `LoggingHygieneTests` checks this.

A refresh runs `diskutil list` once and `diskutil info` only for whole disks that are new, whose size or partition layout changed, or whose cached info is older than 30 seconds (`WholeDiskInfoCache`); the fetches run concurrently without blocking a thread. Each refresh logs how many `diskutil info` runs it needed at debug level: `log stream --predicate 'subsystem == "com.homielab.mountmate" AND category == "drive"' --level debug`.

The disk list is built by `DiskListParser` (`MountMate/Managers/DiskListParser.swift`), which runs no process itself: statfs and the Disk Arbitration fallback are passed in. `DiskListParserTests` run it against a recorded `diskutil list -plist` in `MountMateTests/Fixtures/`; add a fixture there when a new disk layout needs covering.

CI runs both on every pull request and push to `main`. The style check reports findings without failing the build until the existing ones are cleaned up.

## 🔐 Network Share Errors

When an SMB or AFP share fails to mount, MountMate names the cause and what to check, followed by the original error code (for example `Error code: 80 (EAUTH)`). Please include that line when you report a problem.

- **Authentication failed (`EAUTH`)**: wrong username or password. For a Windows domain account, enter the username as `DOMAIN\user` or `user@domain` (`DOMAIN;user` works too).
- **Access denied (`EACCES`)**: the server accepted the connection but refused this account for the share. Check the account's permissions; if it started after a server update, ask the administrator whether the server still accepts SMB 2/3 with NTLMv2 sign-in.
- **Password expired, policy, account restricted (`ENETFSPWDNEEDSCHANGE`, `ENETFSPWDPOLICY`, `ENETFSACCOUNTRESTRICTED`)**: the account must be fixed on the server side.
- **No supported sign-in method or protocol version (`ENETFSNOAUTHMECHSUPP`, `ENETFSNOPROTOVERSSUPP`)**: the server must allow NTLMv2/Kerberos and SMB 2 or 3.
- **Share not found (`ENOENT`)**, **connection refused (`ECONNREFUSED`)**, **server unreachable (`EHOSTUNREACH`)**: check the share name, that file sharing is on, and the network.

## 🪵 Sending Logs

When you report a problem (for example a network share that will not mount), logs help a lot. MountMate writes to the macOS unified log under the subsystem `com.homielab.mountmate`, with one category per area (`drive`, `network`, `keepAlive`, `persistence`, `mounter`, `hotkey`, `shell`, `app`).

Reproduce the problem, then run in Terminal and attach `mountmate.log` to your issue:

```bash
log show --predicate 'subsystem == "com.homielab.mountmate"' --last 1h --info > ~/Desktop/mountmate.log
```

To watch live while you mount or unmount: `log stream --predicate 'subsystem == "com.homielab.mountmate"' --level info`. You can also filter on the same subsystem in Console.app. Passwords are never logged; share names, volume names, paths and error details appear as `<private>`.

## 📫 Feedback & Contributions

MountMate was built to solve my personal workflow issue, but I’d love to improve it for others too.
Feel free to [open an issue](https://github.com/homielab/mountmate/issues) or suggest improvements!

## 🤝 Support

If you found MountMate helpful, please consider supporting its development:

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/homielab)
