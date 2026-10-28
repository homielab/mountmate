# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Added

- **Mount All / Unmount All for saved network shares**: the "Saved Network Shares" header has a Mount All button (when a saved share is not mounted) and an Unmount All button (when one is mounted) that act on every saved share at once, and the Shortcuts app gets Mount All Network Shares and Unmount All Network Shares. One alert, or the shortcut's error, lists each share that failed with its reason; Unmount All offers Force Unmount when that may help.
- **Open in Finder after mounting** (Settings → General → Behavior, off by default): a volume or network share you mount from the popover, with Mount All or with a Shortcuts action opens in a Finder window once it is ready. Automatic mounts (plugging in, login, Keep Alive, Mount Again on Wake), failed mounts and blocked disks never open a window.
- **Rename Volume…**: right-click a mounted, writable external volume (not protected, not a disk image) and choose "Rename Volume…" to give it a new name. The name is checked as you type (not empty, no "/" or ":", at most 11 characters on FAT/exFAT), the row updates once diskutil is done, and a translated alert explains failures such as a busy volume or a file system macOS cannot rename (NTFS). Mount points and fstab entries are left alone.
- **Verify Volume**: right-click a mounted external volume and choose "Verify Volume" to verify its file system data structures with `diskutil verifyVolume` in the background (never repairs). A "Verifying…" status and spinner appear while the check runs, and an alert reports whether the volume is OK or has problems, with a recommendation to use First Aid in Disk Utility if repairs are needed.
- **Browse Network**: the network share sheet has a "Browse Network…" button next to the server address that lists the servers announcing SMB or NFS on the local network (Bonjour); picking one fills the address and the protocol. A server that goes offline drops out of the list while it is open, and reopening the list starts fresh. If nothing is found or the local-network permission is denied, a clear message says so and typing the address by hand works as before. No password is involved.
- **Almost-full warning**: a mounted volume that is 90% full or more (Settings → General → Behavior: on or off, and 80%, 90% or 95%) gets an orange "Almost full" badge and ring, and its tooltip and VoiceOver say "Almost full: 94% used, 12 GB free". With Notifications on you get one notification per volume each time it is mounted; Copy Diagnostics counts the volumes (no names). Disk images, system and read-only volumes are skipped, and nothing is unmounted or deleted.
- **SMART warning**: a drive whose SMART health status is "Failing" now shows a red warning triangle next to its name (VoiceOver and the tooltip say "SMART status: failing — back up this disk"). With Notifications on you get one notification per failing disk, not one per refresh, and Copy Diagnostics counts the failing disks (no names). Drives that report Verified, Not Supported or nothing show nothing, and nothing is unmounted or ejected for you.
- **More Shortcuts actions**: Unmount Network Share, Mount Volume and Unmount Volume join the Shortcuts app, so a shortcut can act on one saved share or one volume (pick it or type its name, case ignored) instead of all of them. A name that matches no volume is reported as the shortcut's error, a protected volume is not unmounted, and nothing is forced or ejected.
- **Eject All External Disks**: a button in the popover header (next to Unmount All), an optional keyboard shortcut (Settings → General → Keyboard Shortcuts, none by default) and a Shortcuts action unmount and eject every external disk at once so you can unplug them. Internal disks, disk images and disks with a protected volume are left alone, nothing is forced, and one alert names any disk that could not be ejected.
- **Notification actions**: the "Cannot Reconnect" notification now has a "Reconnect Now" button that retries right away, and clicking any MountMate notification opens the MountMate popover.
- **Reconnect Now**: a share or volume that Keep Alive is waiting to reconnect now shows "Retrying in N seconds" under "Reconnecting…", with a "Reconnect Now" button (also in the right-click menu) that retries right away instead of waiting out the backoff. The countdown only updates while the popover is open.
- **Reconnecting icon**: while Keep Alive is reconnecting a share or volume, the menu bar icon shows a Wi-Fi badge (VoiceOver says "Reconnecting") and returns to normal once everything is connected.

- **Copy Diagnostics**: Settings → General → Logs has a "Copy Diagnostics" button that puts the MountMate and macOS versions, your on/off settings and the last hour of MountMate's log on the clipboard, ready to paste into a bug report. Passwords, paths, and disk and share names are left out.
- **Mount Again on Wake**: with "Unmount All Disks on Sleep" on, a new switch (Settings → General → Behavior, on by default) mounts the unmounted disks again when the Mac wakes up. Disks you unmounted yourself, disks that are not connected and blocked disks stay unmounted. If a disk could not be unmounted before sleep in time, a notification (when notifications are on) names it after wake.
- **Shortcuts**: the Shortcuts app now has three MountMate actions: Mount All Volumes, Unmount All Volumes and Mount Network Share (choose one of your saved shares). Use them in automations, for example mounting a NAS when you arrive home or unmounting everything before bed. A volume or share that cannot be mounted or unmounted is reported as the shortcut's error instead of an alert, and no popover opens.
- **Mount Read-Only**: right-click a volume that is not mounted and choose "Mount Read-Only" to mount it without write access (useful for backup drives, NTFS drives and damaged drives). Volumes mounted read-only show a "Read-only" badge in their row. Unmount works as usual; a normal Mount, Keep Alive and auto-mount are unchanged.
- **Notifications** (Settings → General, off by default): MountMate can notify you when Keep Alive cannot reconnect a share or volume and when it is back, when a blocked disk mounted before MountMate started could not be unmounted, and when "Unmount All Disks on Sleep" had not finished before the Mac slept. A mount that stays down gives one notification, not one per retry. With notifications on, the "Unmount When Idle" notice also goes to Notification Center instead of the short on-screen message. macOS asks for permission only when you turn the setting on.
- **Unmount When Idle**: Right-click a volume on an external drive and choose "Unmount When Idle" to unmount it automatically after 1, 5, 15, 30 or 60 minutes without reads or writes on the drive. The unmount is never forced: a volume that is still in use stays mounted and is tried again later. Volumes kept mounted, internal disks, disk images and network shares are never affected. Manage the list under Settings → Management.
- **Forget Saved Password**: Encrypted APFS volumes with a password saved in the Keychain get a "Forget Saved Password" item in their right-click menu.

- **Copy Path and Open in Terminal**: The right-click menu of a mounted volume or network share now has "Copy Path" (puts the mount path on the clipboard) and "Open in Terminal" (opens a Terminal window in that folder). They are not shown for volumes that are not mounted.
- **Quiet update reminders**: An update found by an automatic check no longer opens a window on top of other apps. The menu bar icon gets a small dot (VoiceOver says "Update available") and the popover shows "MountMate X.Y is available" with a "View…" button that opens the update window. "Check for Updates..." still shows the window right away.
- **Updates**: Settings → About & Updates has an "Automatically check for updates" switch, automatic checks are on from the first launch (no more question at the second launch), and the popover header has a "Check for Updates..." button.

### Changed

- **Keep Alive lets a NAS sleep**: its periodic checks of network shares no longer ask each server for its capacity, so they no longer keep a NAS from spinning down. The capacity ring is read when you open the popover or Settings (at most once a minute) and when a share mounts.
- **AFP deprecation**: new network shares now only offer SMB and NFS because Apple has removed AFP client support in modern macOS versions. Existing saved AFP shares continue to be editable, removable and mountable, show a "Deprecated" badge (announced by VoiceOver), and any mount failure explains that AFP is deprecated rather than suggesting SMB settings.
- **README**: Quick Start and screenshots now come first, the feature list is 12 one-line items, and the full descriptions moved to a "Feature Details" section (README-vi.md follows).
- Internal: saving or removing a network share's Keychain password moved out of `EditNetworkShareSheet` into `NetworkSharePasswordSync`, and the share validation into `NetworkShareValidation`, unit-tested with a fake password store (new share, unchanged, changed or cleared password, switching to NFS, Keychain errors); the sheet shrinks from 374 to under 300 lines. No change in behavior.
- Internal: the pure decisions of a network-share mount moved out of `NetworkShareMounter` into `NetworkMountPlan` (may the attempt start, the preflight checks, how a result maps to the message and clean-up, the NetFS connection URL, user placement and options, the NFS arguments and failure classification, finding a share's own mount in the mount table), unit-tested for every branch; the file shrinks from 623 to under 400 lines. No change in behavior.
- Internal: the startup sweep that unmounts blocked volumes moved out of `DiskMounter` into `BlockedVolumeSweep` (reading the mounted device from `diskutil info`, skipping empty and "Not Mounted" mount points, up to three attempts with the retry delay injected, the notification after the last failure), unit-tested with an in-memory runner — no real sleeps or diskutil runs in tests. No change in behavior.
- Internal: mounting, unmounting and remounting one volume moved out of `DriveManager` into `DriveManager+Mount`, and the decision to retry a failed mount into `MountRetryRules` (unit-tested for every branch); the disk-change notification handling has its own file too. No change in behavior.
- Keep Alive's network-change handling is split out of `KeepAliveManager`: `NetworkChangeMonitor` wraps the system path monitor and `NetworkChangeRules` holds the remount decisions (Wi-Fi → Ethernet, a lost interface, VPN tunnels ignored), now unit-tested with an injected monitor. The behaviour is unchanged.
- The volume right-click menu is split out of `VolumeRowView` into `VolumeContextMenu`, with the show/hide conditions in `VolumeMenuRules` (unit-tested). The menu itself is unchanged.
- **Force Eject** now stops when the force unmount fails and shows that error (for example the process holding the disk), instead of ejecting anyway and showing the eject error. If the unmount works, it ejects as before.
- Internal: the rules that decide which mounts of blocked volumes are allowed (one-time approvals that expire after 60 seconds, matching by device name or volume/disk UUID, the 15 second auto-mount window) moved into `MountApprovalLedger` with unit tests. No change in behavior.
- Internal: unit tests for the administrator-password flow (`PrivilegedShell`), the startup-block volume lookup (`FstabVolumeLookup`, with `diskutil` plist fixtures), the login-item state mapping and the statfs in-flight guard; the commands they run are unchanged. No change in behavior.
- Internal: the "Block at Startup" logic (keeping the rules in /etc/fstab in step with the blocked list) moved out of `PersistenceManager` into `StartupBlockCoordinator`, and custom mount point updates into their own file; `PersistenceManager` can now use a separate `UserDefaults` and a fake /etc/fstab, so unit tests cover the reconcile, retry and "declined" behavior without a password prompt. The commands that write /etc/fstab are unchanged.
- Internal: mounting a network share moved out of `NetworkMountManager` into `NetworkShareMounter`, with unit tests for the stalled-mount rule, the connection URL and how a mount result becomes a message. No change in behavior.
- Internal: unlocking encrypted APFS volumes (saved password, password prompt, saving and forgetting the Keychain item) moved out of `DriveManager` into `EncryptedVolumeUnlocker`, with unit tests for the decision to ask for the password again or show an error. The password still reaches `diskutil` only through stdin. No change in behavior.
- **Keep Alive** now waits for a volume's remount to really finish instead of checking after 3 seconds, so a slow USB drive that needs up to 30 seconds to spin up is no longer counted as a failed reconnect (no backoff, no false "could not reconnect" notification).
- **Accessibility**: with "Reduce motion" on, the usage rings and the disk expand arrow no longer animate. Volume and share rows can be focused with Tab (Up/Down move between rows; Return or Space mounts or unmounts on macOS 14+), and VoiceOver offers Mount/Unmount, Open in Finder, Copy Path and Open in Terminal as actions on each row.
- **Full Disk Access** now shows in Settings → General → Permissions as "Granted" or "Not Granted", with an "Open System Settings" button when it is missing. It updates when you come back from System Settings, so declining the one-time prompt no longer hides the problem.
- Network share status is now read straight from the system mount table instead of running `/sbin/mount` and parsing its text on every refresh, so Keep Alive checks start no process and mount folders whose names contain " on " or parentheses can no longer confuse it. A share connected in Finder whose server or share name cannot be read now shows "Unknown Server" / "Shared Folder" in your language, and NFS shares on an IPv6 server are imported with the right server and path.
- A busy network share no longer gets a pointless second mount attempt after a network change: if the unmount fails and the share is still mounted, MountMate keeps it and logs why. Mount All and the error alerts now agree on what a locked encrypted volume looks like.
- The update window now shows what is new in the offered version (its notes from this changelog), and the update feed keeps the last three versions instead of only the newest one.
- Release scripts: `scripts/3-release.sh` is removed (the release workflow tags and publishes), `scripts/0-run-all.sh` only builds locally, and `scripts/2-build.sh --dry-run` builds the zip and update feed without a DMG, signing or notarization.
- The `/etc/fstab` code is split out of the settings store into `FstabRules` (pure text rules), `FstabVolumeLookup` and `FstabWriter`, with new unit tests for custom mount point rules (escaped paths, conflicts, replacing and removing an entry). The behaviour and the administrator command are unchanged.
- `brew uninstall --zap mountmate` now also removes the app's cache, HTTP storage and saved window state, not only its preferences file.
- README and README-vi now describe the same features and match the app: the default shortcuts (Unmount All `⌘⌥⇧U`, Mount All `⌘⇧M`), the admin password asked only for `/etc/fstab` (Block at Startup, custom mount points), Sparkle as the update mechanism, and the newer features; README-vi also gains the network share errors and development sections.
- VoiceOver now reads the icon-only buttons (Expand/Collapse All, Unmount All, Settings, Refresh, Quit, Eject) by name and reports when they are busy, and the menu bar icon is announced as "MountMate" with the number of mounted volumes (and whether an action is running or failed).
- MountMate now writes its diagnostics to the macOS unified log (subsystem `com.homielab.mountmate`) instead of standard output, so they can be viewed in Console.app or collected with `log show` when reporting a problem (see "Sending Logs" in the README). Passwords are never logged and names, paths and error details are private.
- Keyboard shortcut labels in Settings now follow the current keyboard layout (for example AZERTY, Dvorak or Cyrillic), so the key shown is the key you press, and they update when you switch the input source. Special keys keep their symbols.
- Passwords MountMate saves in the Keychain are now labeled "MountMate – <volume or share name>" with the kind "APFS volume" or "Network share", so they are easy to find in Keychain Access. Passwords saved by earlier versions keep working and get the label the next time they are saved.
- The sample `diskutil` output used during development (`testDisks.plist`) is no longer shipped inside the app; it is now a test fixture, and the disk-list parsing it exercises has its own unit tests.
- The localization test now also checks that every language keeps the same format placeholders (`%@`, `%d`, `%1$@`…) as English; three unused strings were removed from all languages.
- Added a CI workflow that runs the unit tests and a swift-format check on every pull request and push to main; the Xcode scheme is now shared so the same test command works anywhere.
- Release builds now generate the update feed with the same Sparkle version the app ships with (2.10.0), so update signatures and feed format always match the built-in updater.
- Docs: the website and README now show `brew install mountmate` (with a copy button on the site), the macOS 13 requirement and first-launch notes; the Homebrew cask points to mountmate.homielab.com.
- Website: added `robots.txt`, `sitemap.xml` and SoftwareApplication structured data so search engines describe MountMate correctly, a line listing the seven interface languages, and an Encrypted volumes feature card.
- Docs: added a CONTRIBUTING guide, GitHub issue forms (bug reports ask for the version and the error code) and a pull request template; both READMEs now list the display options (menu bar count, internal disks, only volumes) and Ignore, Protect and Pin, and the Vietnamese README has a Quick Start.

### Fixed

- **Renamed volumes keep their new name everywhere**: after Rename Volume… or a rename in Finder, Settings → Management (Protected, Blocked, Keep Alive, Unmount When Idle, Ignored) and the "blocked disk still mounted" notification show the current name instead of the one the volume had when you saved the setting.
- **Eject All Manually Connected Shares**: the shares are now ejected at the same time, so one share on a server that does not answer no longer keeps the others (and the spinner) waiting. The alert says why each share could not be ejected (busy, timed out, no longer mounted) and offers Force Unmount when that may help.
- **Busy volumes**: while a volume is mounting, unmounting or being verified, its right-click menu no longer offers Mount, Mount Read-Only, Unmount, Verify or Rename, and a second mount or unmount started meanwhile (for example by Keep Alive or a shortcut) is skipped instead of running a second `diskutil` and clearing the spinner early.
- **Keep Alive backoff for volumes**: automatic reconnect attempts (Keep Alive sweep, Mount Again on Wake) no longer reset a volume's retry backoff, so a broken or unplugged volume is retried less and less often and shows "Retrying in N s" instead of being retried every 30 seconds forever. Mounting it yourself still starts over.
- **VoiceOver reads what a button acts on**: the Eject button of a disk row, the Mount/Eject button of a network share row and the Mount/Unmount, Edit and Delete buttons of a share in Settings now announce "Eject “Backup”" instead of just "Eject" or "Edit Share", in all seven languages, so rows no longer sound identical when several drives or shares are listed.
- **Mount All**: each volume now shows its spinner while it mounts, a second Mount All is ignored until the first one is done, a freshly plugged-in volume that fails to mount is retried once like a single mount, and the one-time approval for a "Block auto-mount" volume is withdrawn as soon as the mount ends instead of lingering for a minute.
- **Network shares: Force Unmount**: ejecting a share from the popover that is busy, whose server went away or whose unmount timed out now offers a confirmed "Force Unmount" (`umount -f`) instead of a raw `umount` message, and unmount errors are translated in all seven languages.
- **Read-only after changing the mount point**: a volume mounted read-only (for example a backup or a damaged disk) stays read-only when you set, change or remove its custom mount point. It used to be mounted again with write access.
- **Language change**: choosing another language in Settings → General now asks again to restart MountMate (Restart Now / Later), and says so if it cannot restart itself. The prompt had stopped appearing, so nothing seemed to happen after picking a language.
- **SMART warning notification**: with Notifications on, a failing drive plugged in after another failing drive was unplugged (macOS reuses names like disk4) is now announced too, and a drive that recovers and fails again is announced again.
- **Keep Alive after a failed unmount or eject**: when Unmount, Eject, Force Unmount/Eject, Unmount All or Eject All fails (for example "Resource busy"), the volume is no longer left excluded from Keep Alive, so it is remounted if the drive is disconnected later. Successful unmounts and a volume you had already unmounted before are unchanged.
- **Translations**: "Could not eject: %@" was declared twice in every language file; the duplicate is gone and a new test fails when a language file declares a key twice.
- **Unit tests**: `NotificationManagerTests` no longer fails at random in a full test run (the permission check that asks again takes two main-queue hops, the test waited for one); the manager now takes its main-thread scheduler and app-activation notification center as parameters.
- VoiceOver no longer reads the decorative icons in snapshot and container rows.
- Mounting, unmounting or reconnecting (Keep Alive) a network share no longer re-reads all disks, so the menu updates with less background work.

- A failure to save a setting, to keep the Mount Again on Wake plan or to build Copy Diagnostics is now written to the log, and if MountMate cannot restart itself after a language change, it says so and asks you to open it again.

- The drive and share lists refresh when the Mac wakes from sleep, so they no longer show disks or shares that changed while it slept.

- A drive whose APFS container spans several physical disks (for example a Fusion drive) is listed once instead of under each disk, and its used space is no longer counted twice.
- The drive list now updates within a second when a disk is plugged in or removed even if it never mounts (blocked or not formatted), without reopening the popover.
- If "Start MountMate at Login" cannot be changed, Settings shows the reason with an "Open Login Items" button instead of the switch silently flipping back.
- **Encrypted volumes**: unlocking now stops after three wrong passwords with a message about what to check (Caps Lock, keyboard layout, Disk Utility) instead of asking forever. The password field has focus when the prompt opens and Unlock stays disabled until you type something. If a saved Keychain password is rejected and the one you type works, it replaces the saved one when "Remember" is ticked, or you can choose "Forget the saved password" (ticked by default); it is never deleted silently or after a timeout.

- **Custom mount point**: saving a folder on a network share that no longer answers no longer freezes MountMate; the check runs in the background and stops after 2 seconds with a message.
- **VoiceOver**: each volume, disk and network share row is now read as one item, and the usage ring ("42% used"), the warning triangle (with the error text) and the "Reconnecting…" spinner have spoken labels. The dot on a network share is filled when mounted and hollow when not, instead of relying on colour.
- When reading the disk list fails (for example a slow or unresponsive disk), MountMate keeps showing the last known disks with the error banner instead of an empty list, and a slow network share check can no longer overwrite a newer one with outdated mount status.
- Share passwords are now hidden in every kind of share URL shown in error messages (also `//user:password@server/share`), "Mount All" no longer skips a volume just because it is named "EFI", and the remaining English-only network share errors and the "Could not eject" alert are translated.
- Counts and durations in the interface (blocked disks, imported shares, retry intervals, the idle-unmount notice) now use proper plural forms, including the three forms Russian and Ukrainian need ("1 диск", "2 диска", "5 дисков") and "Every 1 minute" instead of "Every 1 minutes". Failed mount, unmount and eject alerts are now complete translated sentences instead of a sentence with a translated verb inserted, which read wrongly in French, Russian, Ukrainian and Vietnamese.
- Refreshing the drive list no longer starts a `diskutil info` process for every disk each time: information about disks that are still attached unchanged is reused for 30 seconds, so refreshes use less CPU and wake sleeping hard drives less often. Newly attached or reformatted disks are still read immediately.
- Clearer messages when an SMB or AFP share fails to mount: MountMate now tells apart a wrong password, an expired or restricted account, a share the account may not use, an unsupported sign-in method or SMB version and a refused connection, hints how to enter a Windows domain login (`DOMAIN\user` or `user@domain`), and shows the original error code (for example `Error code: 80 (EAUTH)`). The code is also written to the log.
- "Remember password in Keychain" for an encrypted APFS volume now saves the password only after it unlocks the volume, so a mistyped password is no longer stored; if saving fails, MountMate tells you instead of failing silently.
- Hardened the Disk Arbitration mount-approval callback against unexpected disk description data: an unexpected description or UUID type no longer risks a crash (mounts proceed and the volume is simply not blocked).
- Custom mount points whose path contains control characters (like line breaks) are rejected with a clear message instead of being written into the root-managed /etc/fstab, where a break could forge extra rule lines; every rule field (path, volume UUID, file-system type, identifiers) is now validated before anything is staged.
- The privileged shell reads the staged copy of /etc/fstab exactly once, checks those bytes against their SHA-256 digest and writes the same bytes, so swapping the file in the temporary directory either aborts the update or has no effect; there is no gap between the check and the write anymore. The current /etc/fstab is compared by digest, without a second staged file.

---

## 6.3

### Added

- **Space Used on Network Shares** ([#76](https://github.com/homielab/mountmate/issues/76)): Mounted SMB, AFP and NFS shares now show how much space is used and free, with the same usage ring as local drives. If the server is slow or doesn't report its space, the share just shows "Mounted" as before.
- **Hide EFI Partitions**: A new option in Settings → General → Display hides EFI system partitions from the disk list.

---

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
