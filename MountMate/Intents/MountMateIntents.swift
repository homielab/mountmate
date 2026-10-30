//  Created by homielab.com

import AppIntents
import Foundation

/// Runs the menu's bulk actions for Shortcuts. Everything runs in the app on
/// the main actor; no popover opens and no alert shows (the intent reports).
@MainActor
enum IntentActions {
  /// Refreshes the drive list first: right after Shortcuts launches the app
  /// nothing has been read yet.
  static func refreshedDriveManager() async -> DriveManager {
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
      manager.mountAllVolumes(reportFailures: false, trigger: .shortcuts) {
        continuation.resume(returning: $0)
      }
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

  /// The disks that could not be ejected, with the reason.
  static func ejectAll() async -> [BulkVolumeActions.DiskEjectFailure] {
    let manager = await refreshedDriveManager()
    return await withCheckedContinuation { continuation in
      manager.ejectAllDisks(reportFailures: false) { continuation.resume(returning: $0) }
    }
  }

  /// `nil` when the share is mounted, else the error (possibly empty).
  static func mount(share: NetworkShare) async -> String? {
    await withCheckedContinuation { continuation in
      NetworkMountManager.shared.mount(share: share) { success, error in
        if success {
          NetworkMountManager.shared.openInFinderAfterMounting(share, trigger: .shortcuts)
        }
        continuation.resume(returning: success ? nil : (error ?? ""))
      }
    }
  }

  /// `nil` when the share is unmounted, else the error (possibly empty).
  static func unmount(share: NetworkShare) async -> String? {
    await withCheckedContinuation { continuation in
      NetworkMountManager.shared.unmount(share: share) { success, error in
        continuation.resume(returning: success ? nil : (error ?? ""))
      }
    }
  }

  /// Reads the mount table first: right after Shortcuts launches the app the
  /// mounted shares are not known yet.
  static func refreshedNetworkManager() async -> NetworkMountManager {
    let manager = NetworkMountManager.shared
    await withCheckedContinuation { continuation in
      manager.refreshMountStatus(readUsage: false) { continuation.resume() }
    }
    return manager
  }

  /// The saved shares that could not be mounted.
  static func mountAllShares() async -> [NetworkMountManager.ShareMountFailure] {
    let manager = await refreshedNetworkManager()
    return await withCheckedContinuation { continuation in
      manager.mountAllShares(trigger: .shortcuts) { continuation.resume(returning: $0) }
    }
  }

  /// The saved shares that could not be unmounted.
  static func unmountAllShares() async -> [NetworkMountManager.ShareUnmountFailure] {
    let manager = await refreshedNetworkManager()
    return await withCheckedContinuation { continuation in
      manager.unmountAllShares { continuation.resume(returning: $0) }
    }
  }

  /// Decides what to do for a volume (UUID, else name) after refreshing the
  /// drive list.
  static func volumePlan(
    _ reference: VolumeIntentPlanner.Reference, mount: Bool
  ) async -> VolumeIntentPlanner.Plan {
    let manager = await refreshedDriveManager()
    let volumes = VolumeIntentPlanner.candidates(
      in: manager.physicalDisks ?? [], unverifiedDiskIDs: manager.unverifiedDiskIDs)
    return VolumeIntentPlanner.plan(reference, in: volumes, mount: mount)
  }

  /// `nil` when the volume is mounted, else the error (possibly empty).
  static func mount(volume: Volume) async -> String? {
    await withCheckedContinuation { continuation in
      DriveManager.shared.mount(volume: volume, allowsErrorAlerts: false, trigger: .shortcuts) {
        result in
        continuation.resume(returning: Self.failureMessage(result))
      }
    }
  }

  /// `nil` when the volume is unmounted, else the error (possibly empty).
  static func unmount(volume: Volume) async -> String? {
    await withCheckedContinuation { continuation in
      DriveManager.shared.unmount(volume: volume, allowsErrorAlerts: false) { result in
        continuation.resume(returning: Self.failureMessage(result))
      }
    }
  }

  /// Decides which disk to eject for a volume (UUID, else name) after
  /// refreshing the drive list.
  static func ejectPlan(
    _ reference: VolumeIntentPlanner.Reference
  ) async -> VolumeIntentPlanner.EjectPlan {
    let manager = await refreshedDriveManager()
    return VolumeIntentPlanner.ejectPlan(
      reference, in: manager.physicalDisks ?? [], unverifiedDiskIDs: manager.unverifiedDiskIDs)
  }

  /// `nil` when the disk is ejected, else the error (possibly empty). Never
  /// forced.
  static func eject(disk: PhysicalDisk) async -> String? {
    await withCheckedContinuation { continuation in
      DriveManager.shared.eject(disk: disk, allowsErrorAlerts: false) { result in
        continuation.resume(returning: Self.failureMessage(result))
      }
    }
  }

  /// Where `volume` is mounted in the drive list read after its mount (the
  /// mount refreshes it), or `""` when the list reports no mount point.
  static func mountPoint(of volume: Volume) -> String {
    let manager = DriveManager.shared
    let volumes = VolumeIntentPlanner.candidates(
      in: manager.physicalDisks ?? [], unverifiedDiskIDs: manager.unverifiedDiskIDs)
    return VolumeIntentPlanner.mountPoint(of: volume, in: volumes) ?? volume.mountPoint ?? ""
  }

  /// The mounted user volumes of external disks, in menu order, after
  /// refreshing the drive list.
  static func mountedVolumes() async -> [Volume] {
    let manager = await refreshedDriveManager()
    return VolumeIntentPlanner.mountedVolumes(
      in: manager.physicalDisks ?? [], unverifiedDiskIDs: manager.unverifiedDiskIDs)
  }

  /// Whether the volume is mounted, after refreshing the drive list.
  static func isMounted(
    _ reference: VolumeIntentPlanner.Reference
  ) async -> VolumeIntentPlanner.MountedAnswer {
    let manager = await refreshedDriveManager()
    let volumes = VolumeIntentPlanner.candidates(
      in: manager.physicalDisks ?? [], unverifiedDiskIDs: manager.unverifiedDiskIDs)
    return VolumeIntentPlanner.isMounted(reference, in: volumes)
  }

  /// Where `share` is mounted, read from the mount table after its mount.
  static func mountPoint(of share: NetworkShare) async -> String {
    await refreshedNetworkManager().getMountPoint(for: share)
  }

  /// The saved shares with their mount state, after reading the mount table.
  static func networkShares() async -> [NetworkShareEntity] {
    let manager = await refreshedNetworkManager()
    return NetworkShareEntity.entities(
      for: NetworkShareQuery.savedShares(), mountPoints: manager.mountPointsByShareID)
  }

  private static func failureMessage(_ result: Result<Void, Error>) -> String? {
    if case .failure(let error) = result { return error.localizedDescription }
    return nil
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
      throw IntentFailure(
        message: IntentMessages.ejectFailure(
          names: failed.map(\.name), reasons: failed.map(\.reason)))
    }
    return .result(dialog: IntentDialog(stringLiteral: IntentMessages.disksEjected()))
  }
}

struct MountAllSharesIntent: AppIntent {
  static var title: LocalizedStringResource = "Mount All Network Shares"
  static var description = IntentDescription(
    "Mounts every network share saved in MountMate that is not mounted yet.")

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let failures = await IntentActions.mountAllShares()
    guard failures.isEmpty else {
      throw IntentFailure(
        message: IntentMessages.bulkShareFailure(
          names: failures.map(\.name), mount: true,
          reasons: SavedShareBulkRules.mountFailureReasons(failures)))
    }
    return .result(dialog: IntentDialog(stringLiteral: IntentMessages.sharesMounted()))
  }
}

struct UnmountAllSharesIntent: AppIntent {
  static var title: LocalizedStringResource = "Unmount All Network Shares"
  static var description = IntentDescription(
    "Unmounts every mounted network share saved in MountMate.")

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let failures = await IntentActions.unmountAllShares()
    guard failures.isEmpty else {
      throw IntentFailure(
        message: IntentMessages.bulkShareFailure(
          names: failures.map(\.target.name), mount: false,
          reasons: failures.map(\.failure.message)))
    }
    return .result(dialog: IntentDialog(stringLiteral: IntentMessages.sharesUnmounted()))
  }
}

struct MountShareIntent: AppIntent {
  static var title: LocalizedStringResource = "Mount Network Share"
  static var description = IntentDescription(
    "Mounts a network share saved in MountMate and returns its mount point.")

  @Parameter(title: "Network Share")
  var share: NetworkShareEntity

  /// Returns the mount point as text, so it goes straight into Run Shell
  /// Script (rsync) or a path field.
  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    guard let saved = NetworkShareQuery.savedShares().first(where: { $0.id == share.id }) else {
      throw IntentFailure(message: IntentMessages.shareNotFound())
    }
    if let error = await IntentActions.mount(share: saved) {
      throw IntentFailure(message: IntentMessages.shareFailure(name: saved.name, reason: error))
    }
    return .result(
      value: await IntentActions.mountPoint(of: saved),
      dialog: IntentDialog(stringLiteral: IntentMessages.shareMounted(name: saved.name)))
  }
}

struct UnmountShareIntent: AppIntent {
  static var title: LocalizedStringResource = "Unmount Network Share"
  static var description = IntentDescription("Unmounts a network share saved in MountMate.")

  @Parameter(title: "Network Share")
  var share: NetworkShareEntity

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard let saved = NetworkShareQuery.savedShares().first(where: { $0.id == share.id }) else {
      throw IntentFailure(message: IntentMessages.shareNotFound())
    }
    if let error = await IntentActions.unmount(share: saved) {
      throw IntentFailure(
        message: IntentMessages.shareUnmountFailure(name: saved.name, reason: error))
    }
    return .result(
      dialog: IntentDialog(stringLiteral: IntentMessages.shareUnmounted(name: saved.name)))
  }
}

struct MountVolumeIntent: AppIntent {
  static var title: LocalizedStringResource = "Mount Volume"
  static var description = IntentDescription(
    "Mounts one external volume by its name and returns its mount point.")

  @Parameter(title: "Volume")
  var volume: VolumeEntity

  /// Returns the mount point as text (see `MountShareIntent`).
  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    switch await IntentActions.volumePlan(volume.reference, mount: true) {
    case .failure(let message):
      throw IntentFailure(message: message)
    case .alreadyDone(let found):
      return .result(
        value: IntentActions.mountPoint(of: found),
        dialog: IntentDialog(stringLiteral: IntentMessages.shareMounted(name: found.name)))
    case .run(let found):
      if let error = await IntentActions.mount(volume: found) {
        throw IntentFailure(
          message: IntentMessages.shareFailure(name: found.name, reason: error))
      }
      return .result(
        value: IntentActions.mountPoint(of: found),
        dialog: IntentDialog(stringLiteral: IntentMessages.shareMounted(name: found.name)))
    }
  }
}

struct UnmountVolumeIntent: AppIntent {
  static var title: LocalizedStringResource = "Unmount Volume"
  static var description = IntentDescription(
    "Unmounts one external volume by its name. A protected volume is refused.")

  @Parameter(title: "Volume")
  var volume: VolumeEntity

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    switch await IntentActions.volumePlan(volume.reference, mount: false) {
    case .failure(let message):
      throw IntentFailure(message: message)
    case .alreadyDone(let found):
      return .result(
        dialog: IntentDialog(stringLiteral: IntentMessages.shareUnmounted(name: found.name)))
    case .run(let found):
      if let error = await IntentActions.unmount(volume: found) {
        throw IntentFailure(
          message: IntentMessages.shareUnmountFailure(name: found.name, reason: error))
      }
      return .result(
        dialog: IntentDialog(stringLiteral: IntentMessages.shareUnmounted(name: found.name)))
    }
  }
}

struct EjectVolumeIntent: AppIntent {
  static var title: LocalizedStringResource = "Eject Volume"
  static var description = IntentDescription(
    "Ejects the external disk that holds one volume, chosen by its name. A disk with a protected volume is refused."
  )

  @Parameter(title: "Volume")
  var volume: VolumeEntity

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    switch await IntentActions.ejectPlan(volume.reference) {
    case .failure(let message):
      throw IntentFailure(message: message)
    case .run(let disk):
      let name = volume.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if let error = await IntentActions.eject(disk: disk) {
        throw IntentFailure(message: IntentMessages.volumeEjectFailure(name: name, reason: error))
      }
      return .result(dialog: IntentDialog(stringLiteral: IntentMessages.volumeEjected(name: name)))
    }
  }
}

struct GetMountedVolumesIntent: AppIntent {
  static var title: LocalizedStringResource = "Get Mounted Volumes"
  static var description = IntentDescription(
    "Returns the external volumes that are mounted now, in the order of the MountMate menu.")

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<[VolumeEntity]> {
    .result(value: await IntentActions.mountedVolumes().map(VolumeEntity.init(volume:)))
  }
}

struct GetNetworkSharesIntent: AppIntent {
  static var title: LocalizedStringResource = "Get Network Shares"
  static var description = IntentDescription(
    "Returns the network shares saved in MountMate, each with whether it is mounted and its mount point."
  )

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<[NetworkShareEntity]> {
    .result(value: await IntentActions.networkShares())
  }
}

struct IsVolumeMountedIntent: AppIntent {
  static var title: LocalizedStringResource = "Is Volume Mounted"
  static var description = IntentDescription(
    "Tells whether an external volume is mounted now. A volume that is not connected is not mounted."
  )

  @Parameter(title: "Volume")
  var volume: VolumeEntity

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
    switch await IntentActions.isMounted(volume.reference) {
    case .failure(let message):
      throw IntentFailure(message: message)
    case .answer(let mounted):
      return .result(value: mounted)
    }
  }
}

/// At most 10 App Shortcuts per app: the actions that only read state (Get
/// Mounted Volumes, Get Network Shares, Is Volume Mounted) have no phrase and
/// are found in the Shortcuts app's action list.
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
    AppShortcut(
      intent: UnmountShareIntent(),
      phrases: ["Unmount a network share with \(.applicationName)"],
      shortTitle: "Unmount Network Share", systemImageName: "network.slash")
    AppShortcut(
      intent: MountAllSharesIntent(),
      phrases: ["Mount all network shares with \(.applicationName)"],
      shortTitle: "Mount All Network Shares", systemImageName: "network")
    AppShortcut(
      intent: UnmountAllSharesIntent(),
      phrases: ["Unmount all network shares with \(.applicationName)"],
      shortTitle: "Unmount All Network Shares", systemImageName: "network.slash")
    AppShortcut(
      intent: MountVolumeIntent(),
      phrases: ["Mount a volume with \(.applicationName)"],
      shortTitle: "Mount Volume", systemImageName: "externaldrive.badge.plus")
    AppShortcut(
      intent: UnmountVolumeIntent(),
      phrases: ["Unmount a volume with \(.applicationName)"],
      shortTitle: "Unmount Volume", systemImageName: "eject")
    AppShortcut(
      intent: EjectVolumeIntent(),
      phrases: ["Eject a volume with \(.applicationName)"],
      shortTitle: "Eject Volume", systemImageName: "eject.fill")
  }
}
