# Changelog

All notable changes to this project will be documented in this file.

## 6.2.2

### Changed

- **Clear Confirmation After Entering Your Password**: After you enter your administrator password, a short confirmation now appears at the top of the screen, for example "“Backup” is now blocked at startup." It shows when turning Block at Startup on or off, blocking or unblocking a disk with it on, and saving or removing a custom mount point. It appears even if MountMate's menu has closed. Settings also shows the progress and how many disks are blocked at startup, right under the option.

---

## 6.2.1

### Fixed

- **Block at Startup on macOS 27** ([#73](https://github.com/homielab/mountmate/issues/73)): Turning on "Also Block at Startup", or saving a custom mount point, failed on macOS 27 with "/etc/fstab: Operation not permitted", even after entering the administrator password. macOS 27 no longer lets the system password prompt that MountMate used change /etc/fstab. On macOS 27 and later, MountMate now asks for your administrator password itself and makes the change with `sudo`. Your password is only used for that change and is never stored. If macOS still refuses, MountMate tells you how to add the rule yourself in Terminal.

---

## 6.2

### Changed

- **Keyboard Shortcuts No Longer Need Accessibility Permission**: Global shortcuts now use system hot keys. MountMate no longer asks for Accessibility access, holding the keys runs the action once, and if another app already uses a shortcut, Settings tells you. A MountMate shortcut now takes priority over the same shortcut in other apps, so shortcuts must include ⌘ or ⌃. A saved shortcut without them is turned off, and Settings asks you to record a new one.
- **Safer Network Share Passwords**: SMB and AFP shares are now mounted through macOS's network file system framework, so passwords no longer appear in the system process list or in logs. Shares without a username still sign in with your Mac's saved credentials (or as guest).
- **More Room for Slow Disks**: Mount and unmount now wait up to 30 seconds (was 15) before giving up, so spinning-up hard drives have time to respond.
- **Manage More in Settings**: New lists for volumes kept mounted, pinned volumes and custom mount points, so you can remove entries for disks that are no longer connected.

### Fixed

- **Network Share Reconnects**: Keep-alive now waits longer between failed reconnect attempts instead of retrying every few seconds, which could lock accounts on servers with lockout policies and wasted battery.
- **Shares With the Same Name**: Two shares with the same name on different servers no longer share a mount folder. Mounting one no longer reports success when the other is mounted, and ejecting one no longer unmounts the other. Imported shares get unique names.
- **Server Matching**: A share on "nas" is no longer confused with one on "nas2" or "nas.backup.lan".
- **Ejecting Shares**: Ejecting a share could be undone by a reconnect running at the same moment. Ejecting a share that was renamed or mounted by Finder now works.
- **Network Changes**: Connecting or disconnecting a VPN no longer remounts every share. Shares are remounted only when the network they used goes away.
- **Keychain Passwords**: A failed save no longer deletes the saved password, a password that can't be read no longer mounts with an empty one, and clearing the password field now removes the saved password.
- **Internal Disks Shown as External**: If macOS was slow to answer, an internal disk could appear with an Eject button and be included in Unmount All and Unmount on Sleep. It now keeps its last known type.
- **Unmount on Sleep**: The Mac now waits (up to 20 seconds) for disks to unmount before going to sleep.
- **Stuck Spinners**: Several volumes can now show progress at the same time, and a spinner no longer disappears while an operation is still running or stays after a failed refresh.
- **Frozen Drive List**: A stuck USB or network volume can no longer stop the drive list from updating.
- **Custom Mount Points**: Saving or removing a custom mount point no longer freezes MountMate while the password prompt is open. Cancelling the prompt no longer shows an error. The editor no longer opens twice for pinned volumes.
- **Volumes Without a UUID**: Settings for a volume without a unique ID could be applied to a different volume that later used the same device name. Such volumes can no longer be blocked, pinned or ignored by mistake.
- **Saved Settings**: One unreadable entry no longer erases a whole saved list (for example all network shares). A backup is kept.
- **Block USB Auto-Mount**: Now also detects USB drives and SD cards formatted as APFS.
- **Blocking a Mounted Volume**: Blocking a volume while MountMate is running no longer unmounts it unexpectedly.
- **Encrypted Volumes**: "That password didn't work" now only appears when the password was actually wrong.
- **Mount Errors Show Sooner**: A disk that can't be mounted (for example an unsupported format) now reports the error right away instead of after a 15-second retry.
- **Launch at Login**: Now registers correctly, and Settings tells you when macOS needs your approval in Login Items.
- **Language Setting**: Choosing "Later" after changing the language now keeps the change. Traditional Chinese is detected correctly.
- **Network Share Settings**: Server addresses pasted with `smb://` are cleaned up, duplicates are detected, and deleting a share asks first and unmounts it (with "Remove Anyway" if the server can't be reached).
- **Ignoring Windows and Linux Partitions**: Partitions without a volume UUID (such as Microsoft Reserved or BitLocker) can be ignored reliably, and existing ignore settings for them are kept.
- **Translations**: Several messages that were only in English are now translated.

---

## 6.1

### Added

- **Block Disks at Startup**: A new option in Settings → General, "Also Block at Startup (Requires Admin Password)". When it's on, blocked disks are also written to `/etc/fstab` as `noauto` rules, so macOS never mounts them at startup, even before MountMate opens. Previously a blocked disk connected at boot was mounted by macOS and then unmounted by MountMate. You can still mount a blocked disk yourself from MountMate or Disk Utility. Rules are added while the disk is connected (one admin password prompt), removed when you unblock the disk, and all removed when you turn the option off. For safety, startup blocking is never applied to macOS system volumes or to volumes on the startup disk's APFS container, and it supports APFS, Mac OS Extended, ExFAT and FAT disks only. NTFS disks and disks that use third-party drivers stay blocked only while MountMate is running.

### Fixed

- **Mounting Blocked Volumes on Slow Disks**: Clicking Mount on a blocked volume could fail with "Volume on diskXsY failed to mount" when the disk was asleep and took more than a few seconds to spin up. MountMate now keeps its own mount request approved until the mount finishes.
- **Accessibility Prompt in Settings**: The "Accessibility Permission Required" alert no longer appears every time Settings opens. Settings now shows an inline status that updates by itself when access is granted, keyboard shortcuts start working right away without restarting MountMate, and there is a tip for the case where access looks enabled but doesn't work after an update.

---

## 6.0

### Changed

- **Faster, Smoother Menu**: The drive list only redraws when something actually changed, refreshes at high priority when you open the menu, and picks up newly plugged-in drives faster.
- **No More Freezes When Mounting Shares**: Mounting a network share no longer blocks the menu, even when the server is slow or unreachable. "Open in Finder" on a share is instant.
- **Faster Mount All / Unmount All**: Volumes are now mounted and unmounted in parallel, and the list updates as soon as they finish.
- **Lighter Network Share Checks**: Network share status is refreshed on mount events and when you open the menu, instead of after every disk refresh.
- **Lower Background Usage**: The Keep Alive timer no longer does any work when nothing is set to keep alive, and lets macOS group its wake-ups to save energy.

### Fixed

- **Saved Passwords for Encrypted Volumes**: Locked APFS volumes now unlock automatically with the password saved in Keychain. The password you type is always the one used, and a wrong or outdated password asks again instead of showing an unknown error.
- **Unlocking No Longer Freezes the Menu**: Unlocking an encrypted volume now runs in the background.
- **Mount All / Unmount All Failures Are Reported**: If a volume can't be mounted or unmounted (for example because it's in use), an alert now names it instead of failing silently.

---

## 5.20

### Added

- **Pin Volumes to Top**: Right-click any volume and choose "Pin to Top" to show it in a new "Pinned" section at the top of the list, in both normal view and "Show Only Volumes". Pins are remembered when the drive is reconnected.
- **Allow Other Apps to Mount Blocked Disks**: A new option in Settings → General. When it's on, blocking only stops a disk from mounting automatically when it's plugged in or at login. Apps such as backup tools (e.g. Carbon Copy Cloner) can still mount blocked disks when they need them, without quitting MountMate.

### Changed

- **Free Space on Volumes**: Volume rows now show free space as well as used and total, e.g. "120 GB used / 500 GB (380 GB free)". APFS volumes show the free space of their container, so you can see at a glance how much room is left, including in "Show Only Volumes".
- **Unmounting a Disk Image Ejects It** ([#72](https://github.com/homielab/mountmate/issues/72)): Unmounting the last volume of a disk image (DMG) now ejects the image too, like Finder does, so it no longer stays in the "Disk Images" list.

### Fixed

- **Critical: Data Loss on Network Shares** ([#68](https://github.com/homielab/mountmate/issues/68), [#71](https://github.com/homielab/mountmate/issues/71)): A failed mount attempt could delete the contents of a network share that was already mounted at the same path. This happened when two mounts for the same share ran at once (for example, mount at login, wake, or a network change with Keep Alive). MountMate no longer deletes anything inside a mount point: after a failed mount it only removes the folder it created, and only if that folder is empty and not mounted. Only one mount per share can run at a time now.
- **Ejecting a Sleeping Disk** ([#70](https://github.com/homielab/mountmate/issues/70)): Ejecting a disk that had spun down to sleep no longer shows a warning and leaves the disk unmounted but not ejected. MountMate now waits for the disk to wake and retries once.

---

## 5.19

### Added

- **Runtime Auto-Mount Blocking**: Blocked volumes are persisted in MountMate and rejected by Disk Arbitration while the app is running. This avoids modifying `/etc/fstab`, which is protected on recent macOS versions.
- **Startup Unmount Sweep**: When MountMate launches and finds a blocked volume already mounted because it was mounted before the app started, it unmounts it automatically, retrying briefly if the volume is still busy.
- **Keep Alive (Auto-Reconnect)**: MountMate can now keep mounts alive automatically. Network shares and volumes marked "Keep Mounted" are remounted when they drop unexpectedly, with retry attempts at a configurable interval and exponential backoff.
- **Network Change Handling**: MountMate watches the network path and remounts active shares through the new primary interface when Wi-Fi/Ethernet changes, then reconnects dropped shares as soon as connectivity recovers.
- **Mount on Login & Wake**: Keep-alive shares and volumes mount at login and reconnect promptly after the Mac wakes from sleep. Volumes unmounted by "Unmount All Disks on Sleep" come back on wake.
- **NFS & AFP Shares**: Network shares now support the NFS and AFP protocols in addition to SMB, including import of manually mounted NFS/AFP shares.
- **Keep Mounted for Volumes**: Right-click any local or external volume and choose "Keep Mounted (Auto-Reconnect)" to have MountMate remount it whenever it drops while the disk is connected.

### Changed

- **Manual Mounts of Blocked Volumes**: MountMate can still mount a blocked volume through its own controls. Automatic reconnects and mount requests not initiated by MountMate remain blocked while the app is running.
- **Keyboard Shortcut Permission Flow**: Keyboard shortcuts are disabled by default. Accessibility checks no longer prompt during launch; a warning appears only when shortcuts are enabled without Accessibility access.
- **Custom Keyboard Shortcuts**: Configure separate shortcuts for mounting and unmounting all volumes in Settings. The default unmount shortcut now includes Option to avoid Finder's `⌘⇧U` conflict.
- **Custom Mount Points and Blocked Volumes**: A custom mount point can no longer be assigned to a volume that is blocked from auto-mounting, since the two settings contradict each other.
- **Never Fights the User**: Shares and volumes unmounted explicitly through MountMate are not auto-remounted until you mount them again; automatic reconnect failures no longer pop error dialogs.

### Fixed

- **Ghost "Disk Images" Entries**: Bare OS-internal devices (e.g. cryptex RAM disks used for Siri/PKI assets on macOS 26) no longer appear as anonymous unmounted rows under "Disk Images".
- **Duplicate Boot Volume Row**: Sealed APFS system snapshot volumes (e.g. `disk5s1s1` mirroring `disk5s1`) are no longer listed as a second row with the same name, and no longer double-count used space in the parent disk header.
- **EFI in Bulk Actions**: EFI partitions are now categorized as system volumes, so "Mount All Volumes" no longer fails with the "EFI cannot be mounted directly" error and "Unmount All" no longer counts them.
- **Blocked Volume Startup Cleanup**: Volumes that are already unmounted are no longer retried or reported as failed during MountMate's startup cleanup.
- **Shell Process Diagnostics**: Large but fast `diskutil` plist responses are no longer mislabeled as slow processes. Shell output handling now avoids pipe-draining races and consolidates timeout termination into a single diagnostic.

---

## 5.17

### Added

- **Import Mounted Shares**: Existing SMB shares mounted through Finder can now be imported into Network Shares, either in bulk or by dragging them into Settings.
- **Automatic Share Discovery**: MountMate collects the server, share path, username, and current mount point when available, while avoiding duplicate entries.

### Improved

- **Localization Coverage**: Fixed and completed French, Russian, Ukrainian, Vietnamese, Simplified Chinese, and Traditional Chinese translations across Settings and error messages.

---

## 5.16

### Improved

- **Update Reliability**: Updated the Sparkle appcast and Homebrew cask configuration to use the official release endpoints and current macOS dependency syntax.

---

## 5.15

### Added

- **Custom Volume Mount Points**: Configure persistent, `fstab`-backed mount locations for local volumes.
- **Force Unmount**: Retry a failed unmount with a force option after user confirmation.
- **Mount Folder Picker**: Network share mount locations can now be selected with the standard macOS folder picker.

### Improved

- **Redesigned Interface**: Refined the menu bar, drive list, settings, icons, labels, colors, and controls for clearer drive management.
- **Faster Refreshes**: Disk metadata is now fetched concurrently to improve refresh performance.
- **Process Reliability**: Shell operations now have timeouts and more robust process termination.

---

## 5.14

### Improved

- **Automated Releases**: Added a GitHub Actions release workflow with safer signing and publishing configuration.

---

## 5.13

### Added

- **Russian Localization**: Added Russian language support.
- **Ukrainian Settings Localization**: Completed Ukrainian support in Settings and project configuration.

### Fixed

- **APFS Disk Detection**: Synthesized APFS devices are no longer incorrectly treated as root disks.

---

## 5.12

### Added

- **Show Only Volumes**: Added a display option that hides disk hierarchy and shows volumes directly.

### Improved

- **USB Auto-Mount Blocking**: Detection now follows devices to their whole disk, improving USB and SD card identification.
- **Manual Mount Approval**: Volumes blocked from automatic mounting can still be mounted later through an explicit user action.
- **Process Execution**: Replaced shell-based execution with direct process handling to prevent pipe deadlocks.

---

## 5.11

### Added

- **Whole-Disk Volumes**: Added support for drives whose filesystem is located directly on the whole disk rather than a partition.

---

## 5.10

### Improved

- **Mount Approval Matching**: Manual mount approvals can now identify volumes by UUID for more reliable behavior.

---

## 5.9

### Improved

- **Accessibility**: Added accessibility labels to the primary interface controls.

---

## 5.8

### Improved

- **RAID Detection**: Improved partition-based Apple RAID member detection and added regression tests.

---

## 5.7

### Added

- **RAID Set Management**: Added support for detecting and managing Apple RAID sets.
- **Eject Manual Shares**: Manually connected network shares can now be ejected together.

### Improved

- **SMB Parsing**: Consolidated mounted-share parsing for more consistent detection and matching.

---

## 5.6

### Added

- **Apple RAID Support**: Apple RAID devices are now detected and displayed.
- **Manual Network Shares**: SMB shares connected outside MountMate are now shown in the drive list.
- **Menu Bar Mount Count**: Added an option to display the number of mounted volumes in the menu bar.

### Improved

- **Network Share Matching**: Normalized server and share paths, including percent-encoded characters, for more reliable mounted-share detection.
- **Website**: Redesigned the project landing page and updated application artwork and metadata.

---

## 5.5

### Added

- **Network Share Controls**: Added unmount and Open in Finder actions for saved network shares.

### Improved

- **Mount Point Errors**: Permission failures now explain why a mount point could not be created or used.
- **Launch at Login**: The setting now follows the actual macOS service state and recovers cleanly after errors.

### Fixed

- **Credential Privacy**: SMB passwords are removed from mount error messages.
- **Volume Identification**: Corrected UUID extraction for disks and volumes.

---

## 5.4

### Improved

- **Open in Finder**: Mounted paths are now revealed and selected using the native Finder activation API.

---

## 5.3

### Added

- **Ukrainian Localization**: Added Ukrainian language support.
- **Conflicting Process Details**: Failed disk operations now identify applications that may be keeping a volume busy.

### Improved

- **Open in Finder**: Mounted volumes and network shares are selected directly in Finder.
- **App Icon**: Updated the application icon and source artwork.

---

## 5.2

### Added

- **Global Expand/Collapse**: Added a quick toggle in the header to collapse or expand all disk sections at once.
- **Collapsible Layout**: Disk images, external drives, and network shares can now be collapsed to hide nested volumes.
- **Guest Access**: Username is now optional for network shares, enabling Guest login.
- **Flexible Names**: Network share display names are optional and default to the share path if omitted.

### Improved

- **SMB Performance**: Optimized network mounts with `noowners` and `nosuid` flags, significantly improving transfer speeds and reducing NAS disk activity.

### Fixed

- **Energy Consumption**: Refactored network share status checking to use event-driven updates instead of polling, significantly reducing CPU usage and battery drain.

---

## 5.1

### Added

- **Keyboard Shortcuts**: Quickly mount and unmount volumes using global hotkeys.
  - `⌘⇧U` - Unmount all user volumes
  - `⌘⇧M` - Mount all unmounted volumes
  - Enable/disable in Settings → General → "Enable Keyboard Shortcuts"
  - Requires Accessibility permission (prompt guides you to System Settings)

### Improved

- **Dynamic Menu Bar Icon**: The menu bar icon now changes to indicate app state:
  - Shows a clock badge while mounting/unmounting drives
  - Shows a warning badge if an error occurs
  - Returns to normal when operations complete
- **Better Mount/Unmount Icons**: Changed mount/unmount button icons from arrows to plus/minus for clearer meaning.

Thanks @ilyagr for the pull requests!

---

## 5.0

### Added

- **Network Shares**: You can now configure SMB network shares to be automatically mounted at login.
  - Supports custom mount points (e.g., `~/mountmate`).
  - Securely stores passwords in the System Keychain.
  - Manage shares via the new "Network Shares" tab in Settings.
- **Force Eject**: Added the ability to force eject a disk if it is currently in use by other applications.
  - When an eject fails due to the disk being busy, an alert will offer a "Force Eject" option.
- **Encrypted Disks**: You can now choose to save passwords for encrypted external drives, so they unlock automatically next time.
