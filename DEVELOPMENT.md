# Developing MountMate

Build, architecture notes and releases. Conventions for pull requests: [CONTRIBUTING.md](CONTRIBUTING.md).

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

The disk list is built by `DiskListParser` (`MountMate/Managers/DiskListParser.swift`), which runs no process itself: statfs and the Disk Arbitration fallback are passed in. Volumes that need statfs (mounted, without `CapacityInUse`) are collected in a first pass and read in parallel, so several hung disks cost one 2 s timeout, not one each. `DiskListParserTests` run it against a recorded `diskutil list -plist` in `MountMateTests/Fixtures/`; add a fixture there when a new disk layout needs covering.

`/etc/fstab` code is split in three: `FstabRules` (`MountMate/Managers/FstabRules.swift`) builds, finds and removes MountMate's lines and validates every field, as pure functions without file access; `FstabVolumeLookup` asks `diskutil` for the file system and startup-block eligibility of a volume; `FstabWriter` reads `/etc/fstab` and writes it through the administrator prompt. Test rule changes in `FstabRulesTests` and `BlockedFstabRuleTests`; the privileged command is tested against a temporary file, never the real `/etc/fstab`.

Network shares are read from the kernel mount table by `MountTable` (`MountMate/Utilities/MountTable.swift`, `getfsstat` with `MNT_NOWAIT`: no process, never waits on a server). `MountedNetworkShare` (`MountMate/Models/`) is one SMB/NFS/AFP/WebDAV entry and knows which saved share it is; `NetworkMountManager.importedShare(from:)` turns a share connected in Finder into an importable `NetworkShare`, and the NetFS error texts live in `MountMate/Utilities/NetFSErrorMessages.swift`. Tests: `MountTableTests` and `NetworkShareParsingTests`.

CI runs both on every pull request and push to `main`; the style check is strict. See [CONTRIBUTING.md](CONTRIBUTING.md) for conventions.

## Releasing

Push a version tag (`git tag v6.4 && git push origin v6.4`, or `scripts/create-draft-release.sh`): the release workflow sets the version and build number, builds, signs and notarizes the app and DMG, updates `docs/appcast.xml` and the Homebrew cask on `main`, and publishes the GitHub release with the version's `CHANGELOG.md` section. Write that section for users: `scripts/2-build.sh` turns it into HTML (`scripts/changelog-to-html.sh`) and embeds it in the new appcast item, so Sparkle's update window shows it. The appcast keeps the newest three versions.

To check the zip and appcast locally without a DMG, signing or notarization (`docs/appcast.xml` stays unchanged; output in `Dist/Final/`):

```bash
# Dist/Release/MountMate.app = any local Release build; use a throwaway EdDSA key file
SPARKLE_PRIVATE_KEY=/path/to/test_key scripts/2-build.sh --dry-run
```

`scripts/0-run-all.sh` runs the whole build locally (needs `.env.local` with the signing identity, notary profile and Sparkle key) and publishes nothing.
