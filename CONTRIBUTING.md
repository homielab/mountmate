# Contributing to MountMate

Thanks for helping. Bug reports and pull requests are welcome; for a larger change, please open an issue first so we can agree on the approach.

## Reporting a bug

Use the bug report form. It asks for the MountMate and macOS versions, the `Error code: <n> (<NAME>)` line from the error dialog and a log. See "Sending Logs" in the [README](README.md) for the command.

## Build and test

MountMate is an Xcode project (no Swift package manifest), macOS 13 or later.

```bash
# Unit tests (ad-hoc signing, same command as CI)
xcodebuild test -project MountMate.xcodeproj -scheme MountMate \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO

# Code style (configuration in .swift-format); CI runs it with --strict
swift format lint --strict -r MountMate MountMateTests
```

Add tests for new logic in `MountMateTests/`. Code that talks to `diskutil`, the Keychain or `/etc/fstab` takes its input through a closure or protocol so it can be tested without touching the system; never point a test at the real `/etc/fstab`. Code that hops to the main queue after a callback takes the scheduler as a parameter too (see `NotificationManager`'s `performOnMain`), so tests run the hops right away instead of waiting a fixed number of main-queue turns; don't add sleeps.

## Code guidelines

- Settings → General is one view per section in `MountMate/Views/Settings/` (`DisplaySettingsSection`, `PermissionsSettingsSection`, `BehaviorSettingsSection`, `KeepAliveSettingsSection`, `ShortcutsLanguageSettingsSection`, `LogsSettingsSection`, `AboutSettingsSection`); `GeneralSettingsView` only assembles them. Add a setting to the section it belongs to, with its state in that section, and keep shared pieces (such as `ShortcutRow`) in their own file.
- Log with `Log.<category>`, not `print()`. Never log passwords; share names, paths and error details use `privacy: .private`.
- Value types passed between queues are `Sendable`; keep the build free of concurrency warnings.
- Add a dependency only with a clear reason; Sparkle is the only one today.

## Localization

Every user-facing string exists in all 7 languages under `MountMate/Resources/<lang>.lproj/Localizable.strings` (en, fr, ru, uk, vi, zh-Hans, zh-Hant). Plural forms go in `Localizable.stringsdict` of each language. Permission prompts (the `NS…UsageDescription` keys of `MountMate/Info.plist`) are translated in `InfoPlist.strings` of each language; change the English text in both files. Shortcuts phrases (`phrases:` in `MountMate/Intents/MountMateIntents.swift`) are keys of `AppShortcuts.strings`, with `\(.applicationName)` written as `${applicationName}`; intent titles, short titles, descriptions, parameter titles and entity `@Property` titles (any file in `MountMate/Intents/`) are keys of `Localizable.strings`. macOS allows at most ten App Shortcuts (phrases) per app and MountMate uses all ten, so a new action has no phrase unless it replaces one; it still shows in the Shortcuts action list. `LocalizationKeyParityTests` fails when a language is missing a key, a placeholder differs, an English key is used by no Swift file, or a Shortcuts phrase or intent string has no key.

## Commits and pull requests

- Use [Conventional Commits](https://www.conventionalcommits.org): `type(scope): summary`, imperative, lower-case, no trailing period (for example `fix(network): keep shares after wake`).
- Keep a pull request focused on one change.
- Add a line for user-visible changes under `## [Unreleased]` in `CHANGELOG.md` (`### Added`, `Changed` or `Fixed`), written for users of the app.
- CI runs the unit tests and the style check on every pull request.

## Releases

Maintainers release by pushing a version tag; the release workflow first runs the same unit tests and style check as CI, and only if they pass builds, signs, notarizes and publishes. Please do not bump versions, create tags or edit `docs/appcast.xml` or `Casks/mountmate.rb` in a pull request.
