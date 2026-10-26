//  Created by homielab.com

import AppKit
import Foundation

/// Mounts the volumes that "Unmount All Disks on Sleep" unmounted when the Mac
/// wakes up. Main thread only.
final class WakeRemountManager {
  static let shared = WakeRemountManager()

  /// Settings → General → Behavior; on unless the user turned it off.
  static let enabledKey = "remountOnWakeEnabled"
  static let planKey = "mountmate_wakeRemountPlan_v1"

  /// Seconds after wake to look for the disks (they come back a moment after
  /// the Mac). The last attempt ends the plan.
  private static let attemptDelays: [TimeInterval] = [3, 10]

  private let defaults: UserDefaults
  private var wakeToken: NSObjectProtocol?
  private var isRunning = false

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var isEnabled: Bool {
    defaults.object(forKey: Self.enabledKey) as? Bool ?? true
  }

  /// A plan left from before the app (re)started is stale: forget it.
  func start() {
    clearPlan()
    guard wakeToken == nil else { return }
    wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.handleWake()
    }
  }

  // MARK: - Plan

  private(set) var plan: WakeRemountPlan? {
    get {
      guard let data = defaults.data(forKey: Self.planKey) else { return nil }
      return try? JSONDecoder().decode(WakeRemountPlan.self, from: data)
    }
    set {
      if let newValue, !newValue.isEmpty, let data = try? JSONEncoder().encode(newValue) {
        defaults.set(data, forKey: Self.planKey)
      } else {
        defaults.removeObject(forKey: Self.planKey)
      }
    }
  }

  private func clearPlan() { plan = nil }

  /// Called before the unmount on sleep starts. Does nothing (and drops an
  /// old plan) when the setting is off.
  func begin(volumes: [Volume]) {
    plan = isEnabled ? WakeRemountPlan(volumes: volumes) : nil
  }

  /// The unmount on sleep finished: volumes that could not be unmounted are
  /// not part of the plan.
  func settle(failed: [Volume]) {
    plan = plan?.excluding(failed)
  }

  func sleepTimedOut() {
    plan = plan?.markingSleepTimedOut()
  }

  /// The user unmounted these volumes on purpose: never mount them again.
  func forget(_ volumes: [Volume]) {
    guard let current = plan else { return }
    plan = current.excluding(volumes)
  }

  // MARK: - Wake

  private func handleWake() {
    guard !isRunning, let current = plan, !current.isEmpty else {
      clearPlan()
      return
    }
    isRunning = true
    Log.drive.notice(
      "System woke from sleep. Remounting \(current.entries.count, privacy: .public) volume(s) unmounted before sleep."
    )
    attempt(index: 0, announceUnfinished: true)
  }

  private func attempt(index: Int, announceUnfinished: Bool) {
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.attemptDelays[index]) { [weak self] in
      DriveManager.shared.refreshDrives(qos: .userInitiated) {
        self?.remount(index: index, announceUnfinished: announceUnfinished)
      }
    }
  }

  private func remount(index: Int, announceUnfinished: Bool) {
    guard let current = plan, !current.isEmpty else {
      finish()
      return
    }
    let volumes = DriveManager.shared.bulkActionDisks.flatMap(\.allVolumes)
    let present = Set(volumes.compactMap(\.stableVolumeUUID))
    let mounted = Set(volumes.filter(\.isMounted).compactMap(\.stableVolumeUUID))

    if announceUnfinished {
      let names = current.unfinishedNames(stillMounted: mounted)
      if !names.isEmpty {
        NotificationManager.shared.sleepUnmountLeftoverMounted(names: names)
      }
    }

    let entries = current.volumesToMount(presentUUIDs: present, mountedUUIDs: mounted)
    let byUUID = Dictionary(
      volumes.compactMap { volume in volume.stableVolumeUUID.map { ($0, volume) } },
      uniquingKeysWith: { first, _ in first })
    for entry in entries {
      guard let volume = byUUID[entry.volumeUUID], !DriveManager.shared.isBusy(volume.id) else {
        continue
      }
      // Not a user action: a blocked volume stays blocked, and no alert
      // appears for a disk nobody is looking at.
      DriveManager.shared.mount(
        volume: volume, allowsErrorAlerts: false, isUserInitiated: false)
    }

    // Keep the entries that are not connected yet for the next attempt.
    plan = current.remaining(afterMounted: mounted.union(entries.map(\.volumeUUID)))
    if index + 1 < Self.attemptDelays.count, plan?.isEmpty == false {
      attempt(index: index + 1, announceUnfinished: false)
    } else {
      finish()
    }
  }

  private func finish() {
    clearPlan()
    isRunning = false
  }
}
