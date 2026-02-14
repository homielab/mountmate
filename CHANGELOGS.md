# Changelog

All notable changes to this project will be documented in this file.

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
