//  Created by homielab.com

import AppIntents
import Foundation

/// Runs the menu's bulk actions for Shortcuts. Everything runs in the app on
/// the main actor; no popover opens and no alert shows (the intent reports).
@MainActor
enum IntentActions {
  /// Refreshes the drive list first: right after Shortcuts launches the app
  /// nothing has been read yet.
  private static func refreshedDriveManager() async -> DriveManager {
    let manager = DriveManager.shared
    await withCheckedContinuation { continuation in
      manager.refreshDrives(qos: .userInitiated) { continuation.resume() }
    }
    return manager
  }

  /// Names of the volumes that could not be mounted.
  static func mountAll() async -> [String] {
    let manager = await refreshedDriveManager()
    return await withCheckedContinuation { continuation in
      manager.mountAllVolumes(reportFailures: false) { continuation.resume(returning: $0) }
    }
  }

  /// Names of the volumes that could not be unmounted.
  static func unmountAll() async -> [String] {
    let manager = await refreshedDriveManager()
    return await withCheckedContinuation { continuation in
      manager.unmountAllDrives(
        reportFailures: false, finished: { continuation.resume(returning: $0) })
    }
  }

  /// Names of the disks that could not be ejected.
  static func ejectAll() async -> [String] {
    let manager = await refreshedDriveManager()
    return await withCheckedContinuation { continuation in
      manager.ejectAllDisks(reportFailures: false) { continuation.resume(returning: $0) }
    }
  }

  /// `nil` when the share is mounted, else the error (possibly empty).
  static func mount(share: NetworkShare) async -> String? {
    await withCheckedContinuation { continuation in
      NetworkMountManager.shared.mount(share: share) { success, error in
        continuation.resume(returning: success ? nil : (error ?? ""))
      }
    }
  }
}

struct MountAllIntent: AppIntent {
  static var title: LocalizedStringResource = "Mount All Volumes"
  static var description = IntentDescription(
    "Mounts every external volume that is not mounted yet.")

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let failed = await IntentActions.mountAll()
    guard failed.isEmpty else {
      throw IntentFailure(message: IntentMessages.volumeFailure(names: failed, mount: true))
    }
    return .result(dialog: IntentDialog(stringLiteral: IntentMessages.volumesMounted()))
  }
}

struct UnmountAllIntent: AppIntent {
  static var title: LocalizedStringResource = "Unmount All Volumes"
  static var description = IntentDescription(
    "Unmounts every mounted external volume except protected ones.")

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let failed = await IntentActions.unmountAll()
    guard failed.isEmpty else {
      throw IntentFailure(message: IntentMessages.volumeFailure(names: failed, mount: false))
    }
    return .result(dialog: IntentDialog(stringLiteral: IntentMessages.volumesUnmounted()))
  }
}

struct EjectAllIntent: AppIntent {
  static var title: LocalizedStringResource = "Eject All External Disks"
  static var description = IntentDescription(
    "Unmounts and ejects every external disk so it can be unplugged. Disks with a protected volume stay."
  )

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let failed = await IntentActions.ejectAll()
    guard failed.isEmpty else {
      throw IntentFailure(message: IntentMessages.ejectFailure(names: failed))
    }
    return .result(dialog: IntentDialog(stringLiteral: IntentMessages.disksEjected()))
  }
}

struct MountShareIntent: AppIntent {
  static var title: LocalizedStringResource = "Mount Network Share"
  static var description = IntentDescription("Mounts a network share saved in MountMate.")

  @Parameter(title: "Network Share")
  var share: NetworkShareEntity

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard let saved = NetworkShareQuery.savedShares().first(where: { $0.id == share.id }) else {
      throw IntentFailure(message: IntentMessages.shareNotFound())
    }
    if let error = await IntentActions.mount(share: saved) {
      throw IntentFailure(message: IntentMessages.shareFailure(name: saved.name, reason: error))
    }
    return .result(
      dialog: IntentDialog(stringLiteral: IntentMessages.shareMounted(name: saved.name)))
  }
}

struct MountMateShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: MountAllIntent(),
      phrases: [
        "Mount all volumes with \(.applicationName)",
        "Mount all drives with \(.applicationName)",
      ],
      shortTitle: "Mount All Volumes", systemImageName: "externaldrive.badge.plus")
    AppShortcut(
      intent: UnmountAllIntent(),
      phrases: [
        "Unmount all volumes with \(.applicationName)",
        "Unmount all drives with \(.applicationName)",
      ],
      shortTitle: "Unmount All Volumes", systemImageName: "eject")
    AppShortcut(
      intent: EjectAllIntent(),
      phrases: [
        "Eject all external disks with \(.applicationName)",
        "Eject all drives with \(.applicationName)",
      ],
      shortTitle: "Eject All External Disks", systemImageName: "eject.circle")
    AppShortcut(
      intent: MountShareIntent(),
      phrases: ["Mount a network share with \(.applicationName)"],
      shortTitle: "Mount Network Share", systemImageName: "network")
  }
}
