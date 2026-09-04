# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

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
- **Custom Mount Points and Blocked Volumes**: A custom mount point can no longer be assigned to a volume that is blocked from auto-mounting, since the two settings contradict each other.
- **Never Fights the User**: Shares and volumes unmounted explicitly through MountMate are not auto-remounted until you mount them again; automatic reconnect failures no longer pop error dialogs.

### Fixed

- **Ghost "Disk Images" Entries**: Bare OS-internal devices (e.g. cryptex RAM disks used for Siri/PKI assets on macOS 26) no longer appear as anonymous unmounted rows under "Disk Images".
- **Duplicate Boot Volume Row**: Sealed APFS system snapshot volumes (e.g. `disk5s1s1` mirroring `disk5s1`) are no longer listed as a second row with the same name, and no longer double-count used space in the parent disk header.
- **EFI in Bulk Actions**: EFI partitions are now categorized as system volumes, so "Mount All Volumes" no longer fails with the "EFI cannot be mounted directly" error and "Unmount All" no longer counts them.

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
