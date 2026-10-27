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

## 🖼️ Screenshots

<img src="https://raw.githubusercontent.com/homielab/mountmate/main/docs/screenshots/light.png" width="300" /><img src="https://raw.githubusercontent.com/homielab/mountmate/main/docs/screenshots/dark.png" width="300" />

![Full Screenshot](https://raw.githubusercontent.com/homielab/mountmate/main/docs/screenshots/light-full.png)

## ✅ Features

- Mount, unmount, mount read-only and force eject any external drive from the menu bar with one click.
- See free space for drives and mounted network shares at a glance.
- Unmount All, Mount All and Eject All External Disks from the popover or with global keyboard shortcuts.
- Unmount disks when the Mac sleeps or after they sit idle, and mount them again on wake.
- Stop USB disks from auto-mounting at plug-in or login, optionally also at startup (`/etc/fstab`).
- Mount a volume or network share at a mount point you choose.
- Unlock encrypted APFS volumes, with the password saved in the Keychain if you want.
- Auto-mount SMB and NFS shares at login (existing AFP shares supported with deprecation notice), and let Keep Alive reconnect them when they drop.
- Get "Almost full" and SMART warnings, plus optional notifications.
- Ignore, Protect or Pin volumes, show Apple RAID as one disk, and tune what the popover lists.
- Automate it with seven Shortcuts actions (Spotlight, Siri and Automator too).
- Fully native (no Electron), localized in 7 languages, with keyboard and VoiceOver support; the only dependency is Sparkle for updates.

See [Feature Details](#-feature-details) for what each one does.

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

## 📖 Feature Details

Everything in the list above, in full:

- View all connected **external drives**
- See which ones are **mounted**
- **Mount/unmount** any drive with a click
- **Mount Read-Only**: right-click an unmounted volume to mount it read-only (protect a backup drive, inspect a damaged or NTFS drive); the row shows a "Read-only" badge
- **Verify Volume**: right-click a mounted external volume to verify its file system data structures with diskutil in the background (never repairs); shows a "Verifying…" status and alert results with Disk Utility repair suggestions if issues are found
- **Rename Volume…**: right-click a mounted, writable external volume to give it a new name (`diskutil rename`); the name is checked first (no `/` or `:`, at most 11 characters on FAT/exFAT), and file systems macOS cannot rename (such as NTFS) get a clear error
- Check **free space** for drives and for mounted network shares (used / total)
- **Eject All External Disks**: one button (next to Unmount All), an optional shortcut (none by default) or a Shortcuts action unmounts and ejects every external disk so you can unplug them; internal disks, disk images and disks with a protected volume are skipped, nothing is forced, and failures are listed in one alert
- **Keyboard Shortcuts**: Unmount All with `⌘⌥⇧U` and Mount All with `⌘⇧M` by default (Eject All External Disks has none until you record one); change them in Settings (the key shown follows your keyboard layout)
- **Keyboard and VoiceOver**: rows in the popover take keyboard focus (Tab, Up/Down; Return or Space mounts or unmounts on macOS 14+), VoiceOver gets row actions, and animations stop with Reduce motion
- **Block USB Auto-Mount**: stop selected disks from mounting when plugged in or at login; **Block at Startup** (optional) also writes a rule to `/etc/fstab` and asks for your admin password
- **Custom mount point**: mount a volume at a path you choose (right-click → Custom Mount Point…), or a network share at a folder you choose
- **Encrypted APFS volumes**: unlock them from MountMate, with the password optionally saved in the Keychain ("Forget Saved Password" in the right-click menu removes it)
- **RAID**: Apple RAID sets show up as one disk instead of their members
- **Display options** (Settings → General → Display): **Show Count in Menu Bar** puts the number of mounted volumes and shares (protected volumes not counted) next to the icon; **Show Internal Disks** lists the Mac's own disks too; **Show Only Volumes** hides the disk rows and lists just the volumes; **Hide EFI Partitions**
- **Ignore, Protect, Pin**: right-click a volume to **Ignore** it (hide it, for example system partitions), **Protect** it from "Unmount All" and the sleep unmount, or **Pin to Top** to list it first; review the lists under Settings → Management
- **Network Shares**: Auto-mount SMB and NFS shares at login (existing AFP shares supported with deprecation notice); "Browse Network…" in the share sheet lists SMB and NFS servers found on the local network and fills in the address
- **Keep Alive**: Auto-reconnect shares and volumes when they drop, after network changes, on wake, and at login; a share or volume that is waiting shows when the next try is and a "Reconnect Now" button
- **Copy Path / Open in Terminal**: right-click a mounted volume or network share to copy its mount path or open a Terminal window in that folder
- **Unmount All Disks on Sleep** (Settings → General → Behavior): unmount every removable disk before the Mac sleeps. **Mount Again on Wake** (on by default, shown when the sleep unmount is on) mounts those disks again after wake; disks you unmounted yourself, disks that were unplugged and blocked disks stay unmounted. With notifications on, you are told about disks that could not be unmounted before sleep
- **Open in Finder after mounting** (Settings → General → Behavior, off by default): a volume or share you mount from the popover (Mount, Mount Read-Only), with Mount All or with a Shortcuts action opens in a Finder window once it is mounted. Disks mounted when plugged in, at login, by Keep Alive or after wake never open a window, and neither do failed mounts or blocked disks.
- **Unmount When Idle**: Per volume on an external drive (right-click → Unmount When Idle), unmount it after 1–60 minutes without reads or writes on its disk; never forced, so a volume in use stays mounted and is tried again after another idle period
- **Almost-full warning** (Settings → General → Behavior; on by default, from 80%, 90% or 95% used): a mounted volume at or above the limit gets an orange "Almost full" badge and ring (hover or VoiceOver: "Almost full: 94% used, 12 GB free"); with Notifications on you also get one notice per volume each time it is mounted. Disk images, system volumes and read-only volumes are skipped, and nothing is unmounted or deleted.
- **SMART warning**: a disk whose own health check (`diskutil` SMART status) says "Failing" gets a red warning triangle next to its name (hover or VoiceOver: "SMART status: failing — back up this disk"); with Notifications on you also get one notice per disk. Drives that report Verified, Not Supported or nothing show nothing, and MountMate never unmounts or ejects a disk because of it.
- **Notifications** (optional, off by default; Settings → General → Behavior): get told when Keep Alive cannot reconnect a mount and when it is back (once per outage, not on every retry), when a blocked disk could not be unmounted, when unmounting before sleep ran out of time, and when a volume was unmounted because it was idle. Clicking a notification opens MountMate, and the "Cannot Reconnect" one has a "Reconnect Now" button.
- **Shortcuts**: the Shortcuts app (and Spotlight, Siri, Automator via "Run Shortcut") gets seven actions: Mount All Volumes, Unmount All Volumes, Eject All External Disks, Mount Network Share and Unmount Network Share (pick any saved share), and Mount Volume and Unmount Volume (pick a volume or type its name; case is ignored, an unknown name is an error, a protected volume is not unmounted). Build "arrive home → mount the NAS" or "before bed → unmount all" automations; a failure is shown as the shortcut's error. Needs MountMate to be installed; it starts in the background when a shortcut runs
- **Force Eject**: Safely force eject drives that are in use
- **Force Unmount for network shares**: if ejecting a share fails because it is busy or its server is gone, MountMate explains why (translated) and offers a confirmed Force Unmount
- **VoiceOver**: icon-only buttons and the menu bar icon are announced by name
- **Localized** in 7 languages, with correct plural forms
- Runs quietly in the **menu bar**
- Fully native – no Electron; the only dependency is [Sparkle](https://sparkle-project.org), used for automatic updates (Settings → About & Updates, where you can switch automatic checks off; the popover header has a Check for Updates button). An update found by an automatic check never opens a window over your work: the menu bar icon gets a dot and the popover shows "MountMate X.Y is available — View…"; click View… to open the update window

## 🛠️ Installation

### Requirements

- macOS 13 Ventura or later

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

### First launch

- If macOS warns about an app from an unidentified developer, go to **System Settings → Privacy & Security → Open Anyway**.
- Stay online so macOS can verify the app; later updates are downloaded by Sparkle (Settings → About & Updates).
- Some features need extra permission: MountMate asks for your administrator password only to edit `/etc/fstab` ("Also Block at Startup", custom mount points), and Full Disk Access (System Settings → Privacy & Security) lets it read volumes in protected folders.

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

`/etc/fstab` code is split in three: `FstabRules` (`MountMate/Managers/FstabRules.swift`) builds, finds and removes MountMate's lines and validates every field, as pure functions without file access; `FstabVolumeLookup` asks `diskutil` for the file system and startup-block eligibility of a volume; `FstabWriter` reads `/etc/fstab` and writes it through the administrator prompt. Test rule changes in `FstabRulesTests` and `BlockedFstabRuleTests`; the privileged command is tested against a temporary file, never the real `/etc/fstab`.

Network shares are read from the kernel mount table by `MountTable` (`MountMate/Utilities/MountTable.swift`, `getfsstat` with `MNT_NOWAIT`: no process, never waits on a server). `MountedNetworkShare` (`MountMate/Models/`) is one SMB/NFS/AFP entry and knows which saved share it is; `NetworkMountManager.importedShare(from:)` turns a share connected in Finder into an importable `NetworkShare`, and the NetFS error texts live in `MountMate/Utilities/NetFSErrorMessages.swift`. Tests: `MountTableTests` and `NetworkShareParsingTests`.

CI runs both on every pull request and push to `main`; the style check is strict. See [CONTRIBUTING.md](CONTRIBUTING.md) for conventions.

### Releasing

Push a version tag (`git tag v6.4 && git push origin v6.4`, or `scripts/create-draft-release.sh`): the release workflow sets the version and build number, builds, signs and notarizes the app and DMG, updates `docs/appcast.xml` and the Homebrew cask on `main`, and publishes the GitHub release with the version's `CHANGELOGS.md` section. Write that section for users: `scripts/2-build.sh` turns it into HTML (`scripts/changelog-to-html.sh`) and embeds it in the new appcast item, so Sparkle's update window shows it. The appcast keeps the newest three versions.

To check the zip and appcast locally without a DMG, signing or notarization (`docs/appcast.xml` stays unchanged; output in `Dist/Final/`):

```bash
# Dist/Release/MountMate.app = any local Release build; use a throwaway EdDSA key file
SPARKLE_PRIVATE_KEY=/path/to/test_key scripts/2-build.sh --dry-run
```

`scripts/0-run-all.sh` runs the whole build locally (needs `.env.local` with the signing identity, notary profile and Sparkle key) and publishes nothing.

## 🔐 Network Share Errors

When an SMB or AFP share fails to mount, MountMate names the cause and what to check, followed by the original error code (for example `Error code: 80 (EAUTH)`). Please include that line when you report a problem.

- **Authentication failed (`EAUTH`)**: wrong username or password. For a Windows domain account, enter the username as `DOMAIN\user` or `user@domain` (`DOMAIN;user` works too).
- **Access denied (`EACCES`)**: the server accepted the connection but refused this account for the share. Check the account's permissions; if it started after a server update, ask the administrator whether the server still accepts SMB 2/3 with NTLMv2 sign-in.
- **Password expired, policy, account restricted (`ENETFSPWDNEEDSCHANGE`, `ENETFSPWDPOLICY`, `ENETFSACCOUNTRESTRICTED`)**: the account must be fixed on the server side.
- **No supported sign-in method or protocol version (`ENETFSNOAUTHMECHSUPP`, `ENETFSNOPROTOVERSSUPP`)**: the server must allow NTLMv2/Kerberos and SMB 2 or 3.
- **Share not found (`ENOENT`)**, **connection refused (`ECONNREFUSED`)**, **server unreachable (`EHOSTUNREACH`)**: check the share name, that file sharing is on, and the network.

## 🪵 Sending Logs

When you report a problem (for example a network share that will not mount), logs help a lot. MountMate writes to the macOS unified log under the subsystem `com.homielab.mountmate`, with one category per area (`drive`, `network`, `keepAlive`, `persistence`, `mounter`, `hotkey`, `shell`, `app`).

Easiest: reproduce the problem, open **Settings → General → Logs** and click **Copy Diagnostics**, then paste the result into your issue. The report has the MountMate and macOS versions, your on/off settings and the last hour of MountMate's log. It has no passwords, paths, or disk and share names (only how many disks report a failing SMART status and how many volumes are almost full).

Fallback: run this in Terminal and attach `mountmate.log` to your issue:

```bash
log show --predicate 'subsystem == "com.homielab.mountmate"' --last 1h --info > ~/Desktop/mountmate.log
```

To watch live while you mount or unmount: `log stream --predicate 'subsystem == "com.homielab.mountmate"' --level info`. You can also filter on the same subsystem in Console.app. Passwords are never logged; share names, volume names, paths and error details appear as `<private>`.

## 📫 Feedback & Contributions

MountMate was built to solve my personal workflow issue, but I’d love to improve it for others too.
Feel free to [open an issue](https://github.com/homielab/mountmate/issues) (the form asks for the error code and a log) or suggest improvements! Pull requests are welcome too: see [CONTRIBUTING.md](CONTRIBUTING.md).

## 🤝 Support

If you found MountMate helpful, please consider supporting its development:

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/homielab)
