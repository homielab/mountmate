# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Added

- **Shortcuts that pass results on**: Mount Volume and Mount Network Share now return the mount point ("/Volumes/Backup"), so a shortcut can mount a NAS, run rsync on that folder and unmount it without guessing the path. New actions Get Mounted Volumes (the mounted external volumes, in menu order), Get Network Shares (every saved share, with whether it is mounted and where) and Is Volume Mounted (true or false; an unplugged drive is not mounted) let a shortcut check what is mounted before it acts.
- **Read-only network shares**: the network share sheet has a "Mount Read-Only" switch (off by default), so a NAS backup share can be opened and copied from but nothing on it can be changed or deleted by mistake. It applies from the next mount, including at login and Keep Alive reconnects, the share shows a "Read-only" badge in the menu and in Settings, and Export/Import Shares keeps the setting. Shares saved before stay writable.
- **Keyboard shortcuts for network shares**: Settings → General → Keyboard Shortcuts has Mount All Network Shares and Unmount All Network Shares (no keys until you record them), so a NAS can be mounted or unmounted from the keyboard like your disks. A small message says what happened ("Mounted 2 network shares", "No network shares to unmount"), shares that fail get the usual alert (with Force Unmount when it may help), and a key already used by another MountMate action is refused.
- **Export and import network shares**: Settings → Network Shares has a menu (⇅) with "Export Shares…" and "Import Shares from File…", so moving to a new Mac no longer means typing every NAS share again. The JSON file keeps each share's name, protocol, server, path, username, login and Keep Alive switches and custom mount point, but never a password. Importing skips shares that are already saved or not valid (unknown protocol, missing server, mount point in use) and says "Imported 5 shares. Skipped 2".
- **Network shares in Copy Diagnostics**: the report now counts your saved network shares by protocol (SMB, NFS, AFP) and says how many are mounted, use Keep Alive, mount at login and are almost full, so a bug report about a share that does not reconnect carries what is needed. Share names, servers, paths and usernames are never included.
- **Almost-full warning for network shares**: a mounted network share at or above your almost-full limit (for example a NAS with 100 GB free of 2 TB at 95%) now gets the same orange ring and "Almost full" badge as a local volume, with "Almost full: 95% used, 100 GB free" in its tooltip and VoiceOver. With Notifications on you get one notification, and another only after the share drops 5 points below the limit and fills up again. It follows the same on/off switch and limit in Settings → General → Behavior; a share that reports no size gets no warning.
- **Disk pulled out without ejecting** (Settings → General → Behavior, shown with Notifications on, off by default): when a USB drive or memory card is unplugged while one of its volumes is still mounted, a notification says “Backup” was disconnected without being ejected, so you can check that your copies finished. Volumes that were unmounted or ejected first (also from Finder), disk images, internal disks, Time Machine volumes and disks that vanish around sleep and wake are not reported.
- **Unmount All Disks When the Screen Locks** (Settings → General → Behavior, off by default): every removable disk is unmounted as soon as the screen locks, so a drive with private files is not left open while you are away. Protected volumes, volumes kept mounted by Keep Alive and volumes in use stay mounted, nothing is forced and no alert appears. With Mount Again on Wake on, the disks come back when you unlock, also after the Mac slept while locked.
- **Keyboard shortcut feedback**: after Unmount All, Mount All or Eject All External Disks runs from its global keyboard shortcut, a small message at the top of the screen says what happened ("Unmounted 3 volumes", "Nothing to mount", "Ejected 1 disk, 1 failed"), so a press is never silent while the menu is closed. The buttons in the menu are unchanged and failures still get their alert.
- **Mount All / Unmount All for saved network shares**: the "Saved Network Shares" header has a Mount All button (when a saved share is not mounted) and an Unmount All button (when one is mounted) that act on every saved share at once, and the Shortcuts app gets Mount All Network Shares and Unmount All Network Shares. One alert, or the shortcut's error, lists each share that failed with its reason; Unmount All offers Force Unmount when that may help.
- **Open in Finder after mounting** (Settings → General → Behavior, off by default): a volume or network share you mount from the popover, with Mount All or with a Shortcuts action opens in a Finder window once it is ready. Automatic mounts (plugging in, login, Keep Alive, Mount Again on Wake), failed mounts and blocked disks never open a window.
- **Rename Volume…**: right-click a mounted, writable external volume (not protected, not a disk image) and choose "Rename Volume…" to give it a new name. The name is checked as you type (not empty, no "/" or ":", at most 11 characters on FAT/exFAT), the row updates once diskutil is done, and a translated alert explains failures such as a busy volume or a file system macOS cannot rename (NTFS). Mount points and fstab entries are left alone.
- **Verify Volume**: right-click a mounted external volume and choose "Verify Volume" to verify its file system data structures with `diskutil verifyVolume` in the background (never repairs). A "Verifying…" status and spinner appear while the check runs, and an alert reports whether the volume is OK or has problems, with a recommendation to use First Aid in Disk Utility if repairs are needed.
- **Browse Network**: the network share sheet has a "Browse Network…" button next to the server address that lists the servers announcing SMB or NFS on the local network (Bonjour); picking one fills the address and the protocol. A server that goes offline drops out of the list while it is open, and reopening the list starts fresh. If nothing is found or the local-network permission is denied, a clear message says so and typing the address by hand works as before. No password is involved.
- **Almost-full warning**: a mounted volume that is 90% full or more (Settings → General → Behavior: on or off, and 80%, 90% or 95%) gets an orange "Almost full" badge and ring, and its tooltip and VoiceOver say "Almost full: 94% used, 12 GB free". With Notifications on you get one notification per volume each time it is mounted; Copy Diagnostics counts the volumes (no names). Disk images, system and read-only volumes are skipped, and nothing is unmounted or deleted.
- **SMART warning**: a drive whose SMART health status is "Failing" now shows a red warning triangle next to its name (VoiceOver and the tooltip say "SMART status: failing — back up this disk"). With Notifications on you get one notification per failing disk, not one per refresh, and Copy Diagnostics counts the failing disks (no names). Drives that report Verified, Not Supported or nothing show nothing, and nothing is unmounted or ejected for you.
- **Eject Volume in Shortcuts**: pick a volume or type its name (case ignored) and the Shortcuts action ejects the external disk that holds it, so you can unplug just that drive. Internal disks are never found, a disk with a protected volume is refused, nothing is forced, and a failure is shown as the shortcut's error.
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

- **Almost-full notice for drives that stay plugged in**: with Notifications and the almost-full warning on, MountMate checks the free space of mounted external volumes every 15 minutes, so a backup drive that fills up overnight gets its notification within 15 minutes instead of only when you open the menu. It only reads the space macOS already knows (no `diskutil` run), skips internal disks, disk images and network shares, and stops checking when no external volume is mounted or the setting is off.
- **Faster disk list with a hung drive**: when several exFAT or NTFS drives stop answering, plugging or unplugging a disk now waits about 2 seconds in total instead of 2 seconds per drive before the list updates; their space is read at the same time.
- **Website search results and link previews** now describe what MountMate does (network shares, Keep Alive, Homebrew), and the screenshots have descriptive text for screen readers that tells the light and dark versions apart.
- Internal: two translations no screen used any more were removed from all 7 languages, and a test now fails when a Shortcuts phrase, intent title or description is missing from the translation files (Siri would not recognize such a phrase).
- **Faster list after plugging in a disk**: the disk list now refreshes at a higher priority when a disk is mounted, appears or vanishes, at launch and after waking, so macOS no longer delays it like background work when the Mac is busy or on battery. Unmount refreshes run at a normal priority; the refresh itself is unchanged.
- Internal: the decision to allow or refuse a disk mount (disk images, mounts MountMate asked for, Block USB Auto-Mount for USB drives and SD cards, the blocked volumes list, Allow Requested Mounts) is now a separate, unit-tested `MountApprovalDecision` covering every combination. No change in behavior.
- Internal: the step that lets the Mac sleep after Unmount All Disks on Sleep is now a separate, unit-tested `SleepAllowGate` (sleep is allowed exactly once, when the unmount finishes or after 20 seconds, whichever comes first). No change in behavior.
- Internal: the number next to the menu bar icon (also read by VoiceOver) is now counted by a separate, unit-tested `MountedCount` (mounted, unprotected user volumes plus mounted saved shares and manually connected shares). No change in behavior.
- Internal: the rule that decides when the mount point folder of a failed network mount is removed is now a separate, unit-tested function (refactor, no behaviour change; the guard from #71 that keeps a live share's files safe is unchanged).
- Internal: unit tests for the volume list row state (default state for a volume without settings, and the custom mount point editor opening only on the pinned or the disk row of a volume, never both) and for resetting the custom mount point editor. No change in behavior.
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
- Docs: the website no longer advertises AFP as a supported protocol (existing AFP shares keep working with a deprecation notice) and now lists Rename Volume, Verify Volume, Browse Network, Open in Finder after mounting and Force Unmount for shares.

### Fixed

- **Keep Alive reconnects shares that stopped responding**: a share still listed as mounted after the NAS restarted, the Wi-Fi or VPN changed, used to stay "mounted", hang Finder and never come back. Keep Alive now checks that each mounted share answers (giving it up to 10 seconds) and unmounts and mounts again one that does not; with Notifications on, a share that still cannot reconnect gets the usual "Cannot Reconnect" message. In Low Power Mode Keep Alive checks half as often, and Copy Diagnostics counts the stale mounts it found.
- **Network share address and password**: two shares on different ports of one server (`nas:445/data` and `nas:4450/data`) are no longer refused as "already saved", and a mounted share is no longer taken for the one on another port. The server field now refuses addresses that cannot work ("my nas", "nas:abc", "nas:99999") with a translated message, and keeps an IPv6 link-local zone (`fe80::1%en0`). The Password field is off until a username is entered, since a password without one was saved but never used; renaming a share also updates its Keychain item's name.
- **Browse Network fills in a real address**: picking a server such as "My NAS" or "John's MacBook Pro" used to put that name, spaces and all, into the Server field, so the share was "unreachable" or refused as an invalid configuration. MountMate now looks up the host name the server announces ("Johns-MacBook-Pro.local", with the port when it is not the usual one) and shows it under the name in the list; if the lookup fails it uses the name as macOS would turn it into a host name ("my-nas.local").
- **Disks with the same volume UUID**: two SD cards flashed from one image (Raspberry Pi, Ventoy) or a clone no longer share one row, busy spinner or low-space state. Their Protect, Ignore and Keep Alive settings are not saved for them, so one card never inherits the other's. Disks with a unique UUID keep their settings.
- **Unmount Volume in Shortcuts on a disk image**: the action now waits until the image is detached, reports a failed detach as an error and shows no alert.
- **No more endless "Almost full" warnings on small partitions**: volumes under 1 GB (Ventoy's VTOYEFI, a Raspberry Pi bootfs) are full by design and no longer get the orange ring or a notification. Right-click any volume and choose "Don't Warn About Free Space on This Volume" to silence it; the same menu turns it back on.
- **Menu fits small screens**: with many drives and shares the list now scrolls inside the menu instead of running off a 13-inch screen.

- **Mount All skips system partitions**: Preboot, Recovery, VM, Update and other APFS helper volumes, Apple_Boot, Microsoft Reserved, Windows Recovery and Linux swap partitions now count as system volumes like EFI, so they no longer show as normal rows, and Mount All and the Mount All Volumes shortcut stop failing with "Could not mount" on drives that hold macOS, Windows or Linux.
- **Eject respects Protect**: the Eject button on a disk is greyed out when one of its volumes is protected, and Eject refuses a disk whose volume is still being mounted, unmounted or unlocked, the same as Eject All and Shortcuts.
- **Shortcuts that stopped working after an update**: a saved shortcut without ⌘ or ⌃ is no longer silently ignored. MountMate says once per launch that it is off and where to record a new one; the saved keys stay in Settings.
- **Unmount All and Eject All keep busy volumes in Mount Again on Wake**: a volume that could not be unmounted or ejected (in use) is still mounted again after the next wake; only the ones that really left are forgotten. Pressing the Unmount All shortcut again while it is running no longer shows a wrong "Nothing to unmount".
- **Imported shares no longer take a drive’s mount folder**: Import Shares from File, Import Mounted and dropping a mounted share now skip a share whose mount folder is already used by a volume’s custom mount point or another share, and say which one (“Media” not added: Already used by volume “Media Disk”.), instead of failing later with a “not empty” error.
- **Custom mount points are refused for NTFS volumes**: an NTFS volume (also one mounted by Paragon or Tuxera) or a disk of another third-party driver no longer gets a custom mount point, because its `/etc/fstab` rule turned on Apple's experimental NTFS writing, which can damage the disk, or took the disk away from your driver. The menu item is off with the reason, and Save explains it. Rules an older version already wrote are listed in Settings → Management under "Unsafe Custom Mount Rules" with a Remove Rule button; MountMate never changes them on its own.
- A custom mount point or network share folder already saved for another volume or share is now refused at Save, naming the volume or share that uses it, instead of the later mount failing with a "not empty" error.
- **Read-only network shares**: a read-only share no longer gets the orange "Almost full" ring, notification or Copy Diagnostics count, since nothing can be freed on it. The "Read-only" badge now shows how the share is actually mounted (also for shares mounted read-only in Finder), and Import Mounted keeps a read-only mount read-only. Chinese texts no longer have a stray space after "。".
- **Time Machine disks recognized more reliably**: HFS+ backup disks (with a Backups.backupdb folder) and disks chosen as a backup destination in Time Machine settings now count as Time Machine disks, so unmounting on sleep, screen lock or idle leaves them mounted and they are not reported as disconnected without ejecting. A slow disk is checked for at most a second.
- **Slow hubs and hard disks after wake**: Mount Again on Wake now looks for the disks a third time, about 45 seconds after wake, so a hub or hard disk that takes long to spin up is mounted again too. Disks that are still missing or fail to mount after that are no longer skipped silently: with Notifications on you get one "Disks Were Not Mounted Again" notification naming them.
- **Shortcuts with two volumes of the same name**: with two drives both named "Untitled", Mount Volume, Unmount Volume and Eject Volume always failed with "More than one volume is named" and the picker showed only one. The picker now lists each volume with its size and device (and mount point), and a shortcut acts on the volume you picked even when another has the same name. Shortcuts made before keep working by name; when the name is shared, the error now asks you to choose the volume again.
- **No more account lockouts after a password change**: when a NAS or Windows-domain server rejects a share's saved password (wrong password, expired password, locked or restricted account), Keep Alive and the retries at login stop reconnecting that share instead of signing in with the old password every few minutes until the account is locked. The share shows "Password Rejected" in Settings → Network Shares, you get one "Password Rejected" notification (with Notifications on) instead of "Cannot Reconnect", and Copy Diagnostics counts such shares. Editing the share (for example to enter the new password) or mounting it yourself makes Keep Alive try again.
- **Ejected disk mounted again after wake**: a disk you eject from the menu (Eject or Force Eject) is no longer mounted again by Mount Again on Wake or after unlocking the screen if you plug it back in before then. A failed eject keeps the disk in the plan.
- A "Mount at login" share that was still waiting to retry when Keep Alive was turned on is retried again once Keep Alive is turned off, instead of never mounting.
- **Mount at login with Keep Alive off**: a network share set to mount at login that fails because the Mac started before Wi-Fi was connected, or before a NAS that lost power with it had finished booting, is now tried again after 15 seconds, 30 seconds, 1 minute, 2 minutes and 2 minutes, and each time the network comes up, up to 5 times in all or until it mounts. A share you unmount in MountMate meanwhile is left alone; with Keep Alive on, its reconnects work as before.
- **Login mount gave up silently**: with Keep Alive off and Notifications on, a network share that still fails to mount at login after its last try now shows one "Could Not Mount at Login" notification with the share name and the reason (for example a wrong password or a server that is off), instead of only writing to the log.
- **Keep Alive after wake or a network drop**: when the Mac wakes or the network comes back while Keep Alive is still waiting on a server that was offline, the reconnect now runs as soon as that check ends instead of waiting for the next retry, so NAS shares come back without remounting them by hand.
- The address under each share in Settings → Network Shares is now the one MountMate really connects to, the same as the Preview in the share sheet: NFS shares show `nas:/volume1/media`, IPv6 servers get brackets (`smb://[fd00::2]/share`) and spaces in paths are encoded. Hover it to see the full address.
- Importing shares from a hand-written file whose server is a full address (`smb://admin@nas.local/Public`, `\\nas\Public`) now splits it into server, share path and username instead of saving a share that never mounts.

- **Renaming exFAT drives**: exFAT volumes now accept names up to 15 characters (such as "Photos Backup") instead of being cut off at 11; FAT32 stays at 11.
- **Duplicate keyboard shortcuts**: recording a shortcut that another MountMate action already uses is refused with “Already used by Unmount All Volumes” (or the action’s name) instead of being saved, so no shortcut is left dead and Settings no longer blames another app. Duplicates saved by older versions are shown the same way.
- **Free space on disks with several APFS volumes**: volumes that share one APFS container now show the container's free space and fill level, as Finder does, so "Almost full" warns when the disk is really filling up instead of judging each volume alone.

- **Keyboard shortcut feedback colours**: the message after a keyboard shortcut now shows an orange icon when something failed ("Ejected 1 disk, 1 failed") and a grey one when there was nothing to do; green is kept for success only.
- **Volume Almost Full** is shown again when a volume fills up again after you freed space (it drops at least 5 points below the warning level first), not only after it is unmounted and mounted again. A volume hovering around the level still gets one notification.
- **Network share sizes with an unreachable server**: a share whose server does not answer no longer makes every opening of the menu or Settings ask all your shares for their size again (up to 2 seconds each time); sizes are refreshed at most once a minute, and a share you just mounted still gets its size right away.
- **Share preview shows the real address**: the "Preview" line in Add/Edit Share now shows exactly what MountMate connects to: IPv6 hosts in brackets, the port, encoded spaces, and for NFS the `server:/export` target (with `-o port=N`) instead of a made-up `nfs://` URL.
- **Remount and Force Unmount while a volume is busy**: Remount (after changing or removing a custom mount point) and Force Unmount no longer start while a mount or unmount is still running on the same volume, which made two diskutil commands race, hid the spinner too early and showed a wrong error. They are skipped like a second Mount or Unmount; a new mount point then takes effect the next time the volume mounts.
- **Network share onto a folder with files**: a share is no longer mounted onto a folder that already holds files (for example a custom mount point set to ~/Documents), which hid those files until the share was unmounted. The mount is refused with a message asking for an empty folder; an empty folder or one with only .DS_Store is used as before.
- **Network share mount point checked at Save**: a custom mount point that resolves to the root folder (`/`, `//`, `~/../..`) or a path or display name with control characters such as a line break is refused in the share sheet with a clear message, instead of failing later with a NetFS error when mounting. `~` and `..` are resolved first, so `~/x/..` (your home folder) is accepted.
- **Protected volumes and Unmount When Idle**: a volume marked Protected is no longer unmounted for being idle, like Unmount All and the sleep unmount already skip it. Its "Unmount When Idle" submenu is greyed out as "(Off While Protected)"; the chosen delay is kept and applies again once you unprotect the volume.
- **Recording a keyboard shortcut without the mouse**: in Settings → Keyboard Shortcuts, Space or Return on a focused shortcut button, or VoiceOver's press, now starts recording, and VoiceOver names each button by its action ("Shortcut for “Mount All Volumes”") followed by the current shortcut, instead of three identical "Keyboard Shortcut" buttons.
- **Pasting a share address with spaces**: an address copied from Finder's Connect to Server such as `smb://nas/My%20Share` now saves the share path as `My Share` and mounts, instead of failing because the path was encoded twice (`My%2520Share`). A share path typed in its own field is kept as typed.
- **Editing a saved share into a copy of another**: changing the server or share path of a saved network share to one another saved share already uses is now refused with "This share is already saved as …", so two saved shares can no longer mount the same folder (mounting one showed both as mounted, unmounting one unmounted both). Edits that keep the address stay allowed.
- **Mount Again on Wake after a quick sleep or a failed first attempt**: sleeping and waking the Mac again within 13 seconds (for example closing and reopening the lid, or after a Power Nap dark wake) no longer discards the new wake plan or lets the earlier wake overwrite it, and a volume whose mount fails at the 3-second check stays in the plan and is tried again at 10 seconds.
- **Pasting `//nas/Public` or `\\nas\Public` into the server address**: an address copied from `mount` output (`//admin@nas:445/Public`) or a Windows UNC path is now split into the server, share path and username like an `smb://` URL, instead of leaving the server empty and Save disabled.
- **Custom mount point**: a path that means the root folder, such as `//`, `/.` or `/x/..`, is now refused with "Cannot Be Root", and `..` and `.` in a valid path are resolved before it is checked and used.
- **Importing a mounted share keeps its port**: an SMB or AFP share connected on another port (`smb://user@nas:8445/share`) is now imported as server `nas:8445` (`[fd00::2]:8445` for an IPv6 address) instead of `nas`, so it mounts again on the same port.
- **Network share names are trimmed**: spaces around a share's display name are removed when you save it, and a name of only spaces falls back to the share path's last part (like an empty name), so a share can no longer get an invisible mount folder such as `~/mountmate/   `.
- **Adding shares found on the network no longer skips distinct shares**: an NFS export whose path differs only in case from a saved one (`/export/Data` and `/export/data`), or an SMB and an NFS share on the same server and path, are now added as separate shares instead of being treated as duplicates. SMB and AFP share names still match case-insensitively, and a server written with a port (`nas:445`) matches the same server without one.
- **Expand and collapse a disk with the keyboard or VoiceOver**: a disk's header row now takes keyboard focus and Return or Space (macOS 14+) shows or hides its volumes; VoiceOver reads it as a button with the value "Expanded" or "Collapsed" and toggles it with its default action. Before, only a mouse click or Expand All worked.
- **NFS export paths are case-sensitive**: two NFS shares whose export paths differ only in case (`/export/Data` and `/export/data`) are no longer rejected as duplicates, and each mounted export is shown on the share with the exact same path. SMB and AFP share names are still compared without case.
- **NFS shares with a port or IPv6 server**: an NFS share whose server is an IPv6 address (`fd00::2`, `[fd00::2]`) or has a port (`nas:2049`, `[fd00::2]:2049`) now mounts; before, the address went to `mount_nfs` as typed and the mount always failed.
- **Copy Diagnostics hides share mount points**: paths of mounted network shares (the default `~/mountmate/<share name>` folder and any custom mount point you set) are replaced with `<share>` or `<mountpoint>`, so the report no longer shows share names.
- **VoiceOver skips decorative icons**: the error banner, the error screen and "Loading Disks..." are each read as one element, without "exclamation mark triangle" or a separate "in progress" first, and the icons in the empty states and the network share sheets are no longer read aloud.
- **Network share texts name every protocol**: the Network Shares settings (Import Mounted tooltip, login note, empty-import message, empty-list hint) said "SMB" only, although SMB, NFS and AFP shares are accepted. They now say "SMB, NFS or AFP" in all seven languages.
- **Encrypted volumes with a saved password reconnect on their own**: Keep Alive, Mount Again on Wake, Mount All and the Mount Volume shortcut now unlock a locked APFS volume with its password saved in the Keychain instead of staying on "Reconnecting…" or "Cannot Reconnect". They never show a password prompt; if the saved password is rejected, MountMate stops trying it until you unlock the volume yourself.
- **Share addresses with a user or port**: an SMB or AFP address such as `smb://admin@nas:445/Public` in the Server field now mounts: the user fills the Username field when it is empty (a password in the address is dropped), the port is used for the connection, and IPv6 addresses (`fe80::1` or `[fe80::1]:445`) work too. Before, such a share always failed with "Invalid share configuration". Opening and saving a share saved this way fixes it.
- **Pasted share URLs**: pasting a full address such as `smb://nas.local/Public` into the Server field of the network share sheet now saves the host `nas.local` and the share path `Public` (used when the Share field is empty) instead of the host "nas.local/Public", which could not mount. Leading and trailing slashes in the share path (`/Public/`) are dropped too. Shares saved before are not changed.
- **Faster retry after a slow disk list**: when listing disks fails after plugging in a drive or waking the Mac (for example a one-off `diskutil` timeout), the retry 5 seconds later now runs at the same priority as the original refresh instead of as low-priority background work, so the new drive appears without an extra delay, also on battery.
- **Keep Alive skips an outdated drive list**: when MountMate could not refresh the disk list, or could not confirm a disk's details, Keep Alive now waits for fresh data instead of trying to remount drives that may be gone and reporting "Cannot Reconnect" for them.
- **Back-to-back confirmations stay on screen**: when a second keyboard shortcut or Unmount When Idle shows its message while the previous one is fading out, the new message now stays for its full few seconds instead of disappearing with the old one.
- **Translated busy and time-out errors**: "Another operation on this volume is running", "Timed out waiting for the mount to finish" and "This disk is already being ejected", shown by Shortcuts actions and Keep Alive, now appear in your language instead of always in English.
- **VoiceOver names the share on Open in Finder**: the Open in Finder button of each saved network share in Settings now says which share it opens ("Open in Finder “NAS”") in all seven languages, instead of the same "Open in Finder" on every row.
- **Traditional Chinese name in the language picker**: the picker's source label for Traditional Chinese is now written in Traditional script (中文（繁體）) instead of mixing in the Simplified 繁体.
- **Permission prompts in your language**: the macOS prompts asking for access to removable volumes and to the local network are now shown in French, Russian, Ukrainian, Vietnamese and Chinese (Simplified and Traditional) instead of always in English.
- **Mount All and Unmount All skip busy volumes**: a volume that is already being mounted, unmounted or unlocked is left out of Mount All, Unmount All (button, shortcut and unmount on sleep), so two operations no longer collide with a spurious "busy" error or end the other's spinner early. Unmount All now shows a spinner on each row it works on.
- **Changing a custom mount point** no longer leaves the volume unmounted with a spinner that never stops: the volume is mounted again at the new location once the change is saved.
- **Eject All External Disks**: a disk that fails to eject (for example a hard drive still spinning up) is now tried a second time after 2 seconds, like a single Eject, and the alert and the Shortcuts error say why for each disk (busy, in use by an app, timed out) instead of only listing names. When Force Eject may help, the alert offers it.
- **Ejecting a disk twice**: choosing Eject again (from the right-click menu, which is now greyed out while the disk ejects) or running Eject All External Disks a second time no longer starts a second eject of the same disk. Before, if the eject then failed, Keep Alive could stay off for the still-mounted volumes and the spinner stopped too early. Eject All also skips a disk while one of its volumes is mounting or unmounting.
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

- **Automatic unmounts spare backups and disk images**: Unmount All Disks on Sleep, Unmount All Disks When the Screen Locks and Unmount When Idle no longer unmount Time Machine disks (so the next backup still runs) or disk images such as an installer you have open. Unmount All from the menu or its shortcut still unmounts them.
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
