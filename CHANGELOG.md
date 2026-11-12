# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- Optionally unmount network shares too when your Mac sleeps or locks, and mount them again on wake.
- **NFS shares no longer freeze Finder when the NAS goes away**: new shares give up on an unreachable server instead of waiting forever. Turn it on for older shares in their settings.
- **Clearer "in use" alerts**: when a drive can't be ejected, the alert names what is using it in plain words, such as "Spotlight indexing" or "Quick Look" instead of "mds", and shows its icon.
- **Copy Diagnostics** now also lists how many disks are connected by type and file system, the Keep Alive interval and the low-space warning threshold.

## [6.5] - 2026-11-03

### Fixed

- **Shortcuts no longer act on the wrong drive**: a Mount, Unmount or Eject Volume action that picked a drive which is not plugged in now fails with "not connected" instead of acting on another drive with the same name (such as "Untitled"). Shortcuts that hold only a name match by name as before.
- **Browse Network with local-network access denied** now says the permission is missing instead of "no servers found".
- **Import Shares from another Mac**: custom mount points in your home folder are exported as `~/…` (no user name in the file) and imported for the current user; a mount point under another user's home or in a missing folder is reset to the default, and the import message counts those shares.
- **Rename Volume** checks the name against the mounted file system, so a FAT32 or exFAT drive on a GPT disk now gets the 11 (FAT, letters without accents only) or 15 (exFAT) character limit as you type instead of a misleading diskutil error.
- **Verify Volume** only says "Problems were found" when diskutil reports damage. NTFS, a busy or unplugged volume now get "Could Not Verify Volume" with the reason (diskutil's raw output is in Copy Diagnostics). A running check can be stopped with "Cancel Verify" in the context menu, and quitting MountMate stops it too.
- **Safer /etc/fstab edits**: an fstab with Windows line endings (CRLF) is read line by line again instead of gaining blank lines and being rewritten in full, and MountMate keeps the previous file as `/etc/fstab.mountmate.bak` before every change (also shown in Copy Diagnostics).
- **Time Machine backups**: Unmount, Eject, Unmount All and Eject All External Disks ask first ("Unmount Anyway" or "Skip") when Time Machine is backing up to one of the volumes.
- **Open in Terminal** shows an alert when Terminal cannot be opened instead of doing nothing.
- **Encrypted volumes and a locked Keychain**: when the Keychain is locked or denies access to a saved APFS password, the password prompt now says so (with the Keychain error) instead of asking again with no reason, and a password deleted in Keychain Access no longer shows as saved.
- **Keyboard shortcut recorder**: system combinations (⌘C, ⌘V, ⌘Q, ⌘W, ⌘Tab, ⌘Space, ⌘⇧4, ⌃Space, ⌘⌥Esc…) are refused with a "reserved by macOS" message, and pressing ⌘Q or ⌘W while recording no longer quits MountMate or closes Settings.
- **Key names in shortcuts** (Space, Esc, Help, keypad keys) are now translated.

## [6.4] - 2026-10-31

### Added

- Shortcuts can now mount a drive or share and pass its folder on to the next step, and check what is mounted before they act.
- New Shortcuts actions: Eject Volume, Unmount Volume, Mount Volume, Unmount Network Share, Mount All Network Shares and Unmount All Network Shares.
- Mount a network share read-only, so nothing on it can be changed or deleted by mistake.
- Keyboard shortcuts for Mount All and Unmount All Network Shares, with a small message that says what happened.
- Export your network shares to a file and import them on another Mac. Passwords are never included.
- Network shares get the same "Almost full" warning as local drives.
- Get a notification when a drive is pulled out without ejecting, in Settings → General → Behavior.
- Unmount all disks when the screen locks, and open a volume in Finder right after mounting it, both optional.
- Rename Volume and Verify Volume in the right-click menu of a mounted drive.
- Browse Network lists the servers on your network, so you don't have to type an address.
- A drive that is failing its health check shows a red warning, with a notification.
- Almost-full warning for drives, with a limit you choose.
- Eject All External Disks, in the menu, as a keyboard shortcut and in Shortcuts.
- Reconnect Now and a countdown when Keep Alive is waiting to retry, plus a small badge on the menu bar icon while it reconnects.
- Unmount When Idle: a drive unmounts by itself after a few minutes without use.
- Mount Read-Only, Copy Path, Open in Terminal and Forget Saved Password in the right-click menu.
- Notifications when a share or drive can't reconnect and when it is back.
- Mount Again on Wake brings your disks back when the Mac wakes up.
- Copy Diagnostics puts what you need for a bug report on the clipboard, without passwords or names.
- Update reminders no longer pop up over other apps: the menu bar icon shows a small dot instead.

### Changed

- Network shares no longer keep a NAS from sleeping.
- The disk list updates faster after you plug in a drive and when a drive stops responding.
- New network shares offer SMB and NFS only, because macOS no longer supports AFP. Saved AFP shares keep working.
- Passwords MountMate saves are easier to find in Keychain Access.

### Fixed

- Shortcuts no longer act on the wrong drive when two drives have the same name.
- Browse Network, Import Shares and pasted server addresses work more reliably, including addresses with a user name or port.
- Rename Volume and Verify Volume give clearer results, and a running check can be cancelled.
- Time Machine backups are protected: MountMate asks before unmounting a drive that is being backed up, and automatic unmounts skip it.
- Keep Alive reconnects shares that stopped responding after a NAS restart or a network change, and no longer retries so often that it locks your account.
- Mount Again on Wake finds slow hubs and hard disks, and no longer remounts a disk you ejected yourself.
- Free space is right for disks with several volumes and for cloned drives.
- Small partitions that are full by design no longer trigger "Almost full".
- A card in a MacBook's card slot now counts as an external disk.
- Custom mount points are checked before saving, so a wrong folder can't hide your files.
- The menu scrolls on small screens, and VoiceOver reads rows, buttons and warnings more clearly.
- Unlocking an encrypted drive stops after three wrong passwords, and a locked Keychain now says so.
- Error messages for network shares explain what went wrong, such as a wrong or expired password.
- Security improvements.
- Squashed many more small bugs that liked to hide in the menu.

## [6.3] - 2026-10-23

### Added

- Mounted network shares show how much space is used and free, with the same ring as local drives.
- Hide EFI Partitions in Settings → General → Display.

## [6.2.2] - 2026-10-20

### Changed

- After you enter your administrator password, a short message confirms what was done.

## [6.2.1] - 2026-10-20

### Fixed

- Automatic unmounts no longer touch Time Machine disks or disk images.
- Block at Startup and custom mount points work again on macOS 27.

## [6.2] - 2026-10-19

### Changed

- Keyboard shortcuts no longer need Accessibility permission.
- Network share passwords are better protected.
- Slow disks get more time to mount and unmount.
- Settings has new lists for volumes you keep mounted, pinned volumes and custom mount points.

### Fixed

- Keep Alive waits longer between reconnect attempts, so it doesn't lock accounts or waste battery.
- Shares with the same name on different servers no longer get mixed up when you mount or eject them.
- Connecting a VPN no longer remounts every share.
- The Mac waits for disks to unmount before it goes to sleep.
- A stuck drive no longer freezes the list, and spinners no longer get stuck.
- Saving a custom mount point no longer freezes MountMate while the password prompt is open.
- One unreadable setting no longer erases a whole saved list.
- Launch at Login and the language setting work correctly, and Settings tells you when macOS needs your approval.
- Deleting a share asks first and unmounts it.
- Block USB Auto-Mount now also covers APFS drives and SD cards.
- Several messages that were only in English are now translated.
- Fixed many more small bugs.

## [6.1] - 2026-10-19

### Added

- Also Block at Startup keeps blocked disks from mounting when the Mac starts. It asks for your administrator password.

### Fixed

- Mounting a blocked volume works when the disk was asleep.
- The Accessibility alert no longer appears every time Settings opens.

## [6.0] - 2026-10-11

### Changed

- The menu is faster and smoother, and picks up newly plugged-in drives sooner.
- Mounting a network share no longer freezes the menu, even when the server is slow.
- Mount All and Unmount All are faster.
- MountMate uses less energy in the background.

### Fixed

- Encrypted volumes unlock automatically with the password saved in Keychain, without freezing the menu.
- Mount All and Unmount All now tell you which volume failed instead of failing silently.

## [5.20] - 2026-10-11

### Added

- Pin to Top puts your favorite volumes in their own section at the top of the list.
- Allow Other Apps to Mount Blocked Disks, so backup tools can still use them.

### Changed

- Volumes show free space as well as used and total.
- Unmounting a disk image also ejects it, like Finder.

### Fixed

- A failed mount could delete files on a network share. This no longer happens.
- Ejecting a disk that was asleep no longer leaves it unmounted but not ejected.

## [5.19] - 2026-09-04

### Added

- Keep Alive reconnects network shares and volumes when they drop, and after the Mac wakes or the network changes.
- Disks you block stay unmounted, even if they were mounted before MountMate started.
- Network shares can now use NFS and AFP as well as SMB.
- Keep Mounted for any volume in the right-click menu.
- Separate keyboard shortcuts for mounting and unmounting all volumes.

### Changed

- Keyboard shortcuts are off until you turn them on.
- Shares and volumes you unmount yourself are not remounted until you mount them again.

### Fixed

- Internal system disks no longer show up under Disk Images.
- The boot volume no longer appears twice, and its space is no longer counted twice.
- Mount All Volumes no longer fails on EFI partitions.

## [5.17] - 2026-08-21

### Added

- Import shares you mounted in Finder into Network Shares, all at once or by dragging them in.

### Changed

- Better French, Russian, Ukrainian, Vietnamese and Chinese translations.

## [5.16] - 2026-08-09

### Fixed

- More reliable updates and Homebrew installs.

## [5.15] - 2026-08-09

### Added

- Custom mount points for local volumes.
- Force Unmount after a failed unmount, with your confirmation.
- Pick the mount folder of a network share with the standard macOS folder picker.

### Changed

- A refreshed look for the menu bar, drive list and Settings.
- The drive list refreshes faster.

## [5.13] - 2026-08-08

### Added

- Russian language, and full Ukrainian support in Settings.

### Fixed

- Some APFS disks were treated as the main disk by mistake.

## [5.12] - 2026-08-08

### Added

- Show Only Volumes hides the disk layout and lists volumes directly.

### Changed

- USB drives and SD cards are recognized more reliably for Block USB Auto-Mount.
- A blocked volume can still be mounted by hand later.

## [5.11] - 2026-07-26

### Added

- Drives that keep their files directly on the whole disk now work.

## [5.10] - 2026-07-26

### Changed

- Volumes you allowed to mount are recognized more reliably.

## [5.9] - 2026-07-26

### Changed

- Better VoiceOver support for the main controls.

## [5.8] - 2026-07-26

### Fixed

- Apple RAID members are recognized more reliably.

## [5.7] - 2026-07-14

### Added

- Detect and manage Apple RAID sets.
- Eject all manually connected network shares at once.

## [5.6] - 2026-07-12

### Added

- Apple RAID devices are shown in the list.
- Network shares you connected outside MountMate show up in the list.
- Show the number of mounted volumes in the menu bar.

### Changed

- Mounted shares are matched more reliably.
- A redesigned MountMate website.

## [5.5] - 2026-03-26

### Added

- Unmount and Open in Finder for saved network shares.

### Changed

- Permission errors explain why a mount folder couldn't be used.
- Launch at Login follows the real macOS setting.

### Fixed

- Share passwords no longer appear in error messages.

## [5.4] - 2026-03-22

### Changed

- Open in Finder selects the mounted folder directly.

## [5.3] - 2026-03-22

### Added

- Ukrainian language.
- When a disk can't be ejected, MountMate names the apps that may be using it.

### Changed

- Open in Finder selects the volume or share directly.
- A new app icon.

## [5.2] - 2026-02-14

### Added

- Collapse or expand all disk sections at once.
- Disk images, external drives and network shares can be collapsed.
- Network shares can use Guest login, and the display name is optional.

### Changed

- Network shares transfer faster and keep a NAS disk quieter.

### Fixed

- Lower CPU use and battery drain from network share checks.

## [5.1] - 2026-02-05

### Added

- Keyboard shortcuts: ⌘⇧U unmounts all volumes and ⌘⇧M mounts them again. Turn them on in Settings → General.

### Changed

- The menu bar icon shows when MountMate is mounting or hit an error.
- Clearer mount and unmount icons.

## [5.0] - 2025-12-04

### Added

- Network shares that mount at login, with a custom mount folder and passwords kept in Keychain. Manage them in the new Network Shares tab.
- Force Eject when a disk is busy.
- Save the password of an encrypted external drive so it unlocks by itself next time.
