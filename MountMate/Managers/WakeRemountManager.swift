//  Created by homielab.com

import AppKit
import Foundation

/// Mounts the volumes that "Unmount All Disks on Sleep" or "Unmount All Disks
/// When the Screen Locks" unmounted when the Mac wakes up or the screen
/// unlocks. Main thread only.
final class WakeRemountManager {
  /// Runs `work` after the given delay.
  typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void
  /// Refreshes the drive list and delivers the current volumes.
  typealias VolumeRefresher = (_ completion: @escaping ([Volume]) -> Void) -> Void
  /// Mounts `volume` for wake and reports whether the mount succeeded.
  typealias Mounter = (_ volume: Volume, _ completion: @escaping (Bool) -> Void) -> Void

  static let shared = WakeRemountManager()

  /// Settings → General → Behavior; on unless the user turned it off.
  static let enabledKey = "remountOnWakeEnabled"
  static let planKey = "mountmate_wakeRemountPlan_v1"

  /// Seconds after wake to look for the disks (they come back a moment after
  /// the Mac). The last attempt ends the plan.
  static let attemptDelays: [TimeInterval] = [3, 10]

  static let mainQueueScheduler: Scheduler = { delay, work in
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  static let liveVolumeRefresher: VolumeRefresher = { completion in
    DriveManager.shared.refreshDrives(qos: .userInitiated) {
      completion(DriveManager.shared.bulkActionDisks.flatMap(\.allVolumes))
    }
  }

  static let liveMounter: Mounter = { volume, completion in
    // Not a user action: a blocked volume stays blocked, and no alert
    // appears for a disk nobody is looking at.
    DriveManager.shared.mount(
      volume: volume, allowsErrorAlerts: false, isUserInitiated: false, trigger: .wake
    ) { result in
      if case .success = result {
        completion(true)
      } else {
        completion(false)
      }
    }
  }

  private let defaults: UserDefaults
  private let schedule: Scheduler
  private let refreshVolumes: VolumeRefresher
  private let isBusy: (String) -> Bool
  private let mount: Mounter
  private let notifyLeftover: ([String]) -> Void
  private var wakeToken: NSObjectProtocol?
  private(set) var isRunning = false
  /// True while the plan must wait for the screen to unlock: a wake then
  /// keeps the plan and mounts nothing. Set by the app delegate.
  var waitsForUnlock: () -> Bool = { false }
  private(set) var generation = 0

  init(
    defaults: UserDefaults = .standard,
    schedule: @escaping Scheduler = WakeRemountManager.mainQueueScheduler,
    refreshVolumes: @escaping VolumeRefresher = WakeRemountManager.liveVolumeRefresher,
    isBusy: @escaping (String) -> Bool = { DriveManager.shared.isBusy($0) },
    mount: @escaping Mounter = WakeRemountManager.liveMounter,
    notifyLeftover: @escaping ([String]) -> Void = {
      NotificationManager.shared.sleepUnmountLeftoverMounted(names: $0)
    }
  ) {
    self.defaults = defaults
    self.schedule = schedule
    self.refreshVolumes = refreshVolumes
    self.isBusy = isBusy
    self.mount = mount
    self.notifyLeftover = notifyLeftover
  }

  var isEnabled: Bool {
    defaults.object(forKey: Self.enabledKey) as? Bool ?? true
  }

  /// A plan left from before the app (re)started is stale: forget it.
  func start() {
    generation &+= 1
    isRunning = false
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
      do {
        return try JSONDecoder().decode(WakeRemountPlan.self, from: data)
      } catch {
        Log.persistence.error(
          "Could not read the saved Mount Again on Wake plan, dropping it: \(error.localizedDescription, privacy: .public)"
        )
        defaults.removeObject(forKey: Self.planKey)
        return nil
      }
    }
    set {
      guard let newValue, !newValue.isEmpty else {
        defaults.removeObject(forKey: Self.planKey)
        return
      }
      do {
        defaults.set(try JSONEncoder().encode(newValue), forKey: Self.planKey)
      } catch {
        Log.persistence.error(
          "Could not save the Mount Again on Wake plan: \(error.localizedDescription, privacy: .public)"
        )
        defaults.removeObject(forKey: Self.planKey)
      }
    }
  }

  private func clearPlan() { plan = nil }

  /// Called before the unmount on sleep or lock starts. Does nothing (and
  /// drops an old plan) when the setting is off.
  /// - Parameter merging: add the volumes to the current plan instead of
  ///   replacing it (the plan kept from a screen lock).
  func begin(volumes: [Volume], merging: Bool = false) {
    generation &+= 1
    isRunning = false
    guard isEnabled else {
      plan = nil
      return
    }
    let new = WakeRemountPlan(volumes: volumes)
    plan = merging ? (plan?.adding(new) ?? new) : new
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

  func handleWake() {
    guard !waitsForUnlock() else {
      Log.drive.notice("System woke from sleep with the screen locked. Remount waits for unlock.")
      return
    }
    run(reason: "System woke from sleep")
  }

  /// The screen unlocked: mounts what the lock (and a sleep while locked)
  /// unmounted.
  func handleUnlock() {
    run(reason: "Screen unlocked")
  }

  private func run(reason: String) {
    guard !isRunning else { return }
    guard let current = plan, !current.isEmpty else {
      clearPlan()
      return
    }
    isRunning = true
    generation &+= 1
    let currentGeneration = generation
    Log.drive.notice(
      "\(reason, privacy: .public). Remounting \(current.entries.count, privacy: .public) volume(s) unmounted before."
    )
    attempt(index: 0, generation: currentGeneration, announceUnfinished: true)
  }

  private func attempt(index: Int, generation: Int, announceUnfinished: Bool) {
    schedule(Self.attemptDelays[index]) { [weak self] in
      guard let self, self.isRunning, self.generation == generation else { return }
      self.refreshVolumes { [weak self] volumes in
        guard let self, self.isRunning, self.generation == generation else { return }
        self.remount(
          index: index, generation: generation, volumes: volumes,
          announceUnfinished: announceUnfinished)
      }
    }
  }

  private func remount(
    index: Int, generation: Int, volumes: [Volume], announceUnfinished: Bool
  ) {
    guard let current = plan, !current.isEmpty else {
      finish()
      return
    }
    let present = Set(volumes.compactMap(\.stableVolumeUUID))
    let mounted = Set(volumes.filter(\.isMounted).compactMap(\.stableVolumeUUID))

    if announceUnfinished {
      let names = current.unfinishedNames(stillMounted: mounted)
      if !names.isEmpty {
        notifyLeftover(names)
      }
    }

    let entries = current.volumesToMount(presentUUIDs: present, mountedUUIDs: mounted)
    // Drop only the volumes that are already mounted; volumes being mounted
    // below stay in the plan until their mount succeeds, so a failed mount is
    // retried on the next attempt.
    plan = current.remaining(afterMounted: mounted)
    let byUUID = Dictionary(
      volumes.compactMap { volume in volume.stableVolumeUUID.map { ($0, volume) } },
      uniquingKeysWith: { first, _ in first })
    for entry in entries {
      guard let volume = byUUID[entry.volumeUUID], !isBusy(volume.id) else {
        continue
      }
      mount(volume) { [weak self] succeeded in
        guard let self, self.isRunning, self.generation == generation, succeeded else { return }
        self.plan = self.plan?.remaining(afterMounted: [entry.volumeUUID])
        if self.plan == nil {
          self.finish()
        }
      }
    }

    guard isRunning, self.generation == generation else { return }
    if index + 1 < Self.attemptDelays.count, plan?.isEmpty == false {
      attempt(index: index + 1, generation: generation, announceUnfinished: false)
    } else {
      finish()
    }
  }

  private func finish() {
    clearPlan()
    isRunning = false
  }
}
