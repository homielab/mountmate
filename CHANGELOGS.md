# Changelog

All notable changes to this project will be documented in this file.

## 5.0

### Added

- **Network Shares**: You can now configure SMB network shares to be automatically mounted at login.
  - Supports custom mount points (e.g., `~/mountmate`).
  - Securely stores passwords in the System Keychain.
  - Manage shares via the new "Network Shares" tab in Settings.
- **Force Eject**: Added the ability to force eject a disk if it is currently in use by other applications.
  - When an eject fails due to the disk being busy, an alert will offer a "Force Eject" option.
- **Encrypted Disks**: You can now choose to save passwords for encrypted external drives, so they unlock automatically next time.
