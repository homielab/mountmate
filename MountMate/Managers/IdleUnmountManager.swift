//  Created by homielab.com

import Combine
import Foundation
import IOKit

/// Decides when a volume with "Unmount When Idle" has gone unused long
/// enough. Pure logic with the clock passed in, so it can be tested without
/// disks or timers.
///
/// Activity is measured per physical disk: the read and write operation
/// counters of its block storage driver (the numbers `iostat` shows). Any
/// read or write on the disk, by any volume or process, counts as use.
/// Reading the counters never touches the disk itself.
struct IdleUnmountTracker: Sendable {
  /// Completed read/write operations of a whole disk since it attached.
  struct Activity: Equatable, Sendable {
    let reads: UInt64
    let writes: UInt64
  }

  /// A mounted volume with an idle timeout.
  struct Candidate: Equatable, Sendable {
    /// `Volume.id`.
    let volumeID: String
    /// BSD name of the physical whole disk, e.g. "disk4".
    let diskID: String
    /// Seconds without disk activity before the volume is unmounted.
    let limit: TimeInterval
  }

  private struct State {
    var diskID: String
    var activity: Activity?
    var lastActive: Date
  }

  private var states: [String: State] = [:]
  private var lastCheck: Date?

  /// How often to look at a volume whose limit is `minutes`: half the
  /// limit, at least 30 seconds and at most 5 minutes.
  static func checkInterval(forMinutes minutes: Int) -> TimeInterval {
    min(300, max(30, TimeInterval(minutes) * 60 / 2))
  }

  /// Records the current counters and returns the volume IDs whose disk has
  /// been inactive for at least their limit. Volumes no longer passed in
  /// are forgotten, so a volume mounted again starts a fresh idle period.
  ///
  /// - Parameter maxGap: A longer gap since the previous check (the Mac
  ///   slept, the app was stalled) counts as activity: the counters cannot
  ///   tell whether the disk was used meanwhile, and a just-woken Mac should
  ///   not unmount drives right away.
  mutating func evaluate(
    _ candidates: [Candidate], activity: [String: Activity], now: Date, maxGap: TimeInterval
  ) -> [String] {
    let resumedAfterGap = lastCheck.map { now.timeIntervalSince($0) > maxGap } ?? false
    lastCheck = now
    var idle: [String] = []
    var seen = Set<String>()
    for candidate in candidates {
      seen.insert(candidate.volumeID)
      let current = activity[candidate.diskID]
      guard var state = states[candidate.volumeID], state.diskID == candidate.diskID,
        !resumedAfterGap, let current, state.activity == current
      else {
        // New, moved to another disk, after a gap, unreadable counters (never
        // unmount blind) or the disk was used: a new idle period starts now.
        states[candidate.volumeID] = State(
          diskID: candidate.diskID, activity: current, lastActive: now)
        continue
      }
      if now.timeIntervalSince(state.lastActive) >= candidate.limit {
        idle.append(candidate.volumeID)
        // Starts over whether or not the unmount succeeds; a volume still in
        // use is tried again only after another full idle period.
        state.lastActive = now
        states[candidate.volumeID] = state
      }
    }
    states = states.filter { seen.contains($0.key) }
    return idle
  }

  /// Forgets everything (the feature was turned off for every volume).
  mutating func reset() {
    states = [:]
    lastCheck = nil
  }
}

/// Unmounts external volumes that have not been used for the number of
/// minutes the user chose for them ("Unmount When Idle" in the volume's
/// context menu). The unmount is never forced: a volume with open files
/// stays mounted and is tried again after another idle period, without an
/// alert.
///
/// Only volumes on external physical disks qualify. Internal and system
/// disks, disk images, network shares and volumes marked "Keep Mounted" are
/// never unmounted for being idle.
final class IdleUnmountManager {
  static let shared = IdleUnmountManager()

  /// Main thread only.
  private var tracker = IdleUnmountTracker()
  private var timer: Timer?
  private var timerInterval: TimeInterval = 0
  private var cancellables = Set<AnyCancellable>()
  private let activityQueue = DispatchQueue(
    label: "com.homielab.mountmate.idleunmount", qos: .utility)

  private init() {}

  /// Starts watching the setting; the timer only runs while at least one
  /// volume has a timeout. Call once, on the main thread.
  func start() {
    guard cancellables.isEmpty else { return }
    PersistenceManager.shared.$idleUnmountVolumes
      .receive(on: DispatchQueue.main)
      .sink { [weak self] entries in self?.reschedule(for: entries) }
      .store(in: &cancellables)
  }

  private func reschedule(for entries: [IdleUnmountVolume]) {
    let interval = entries.filter { $0.minutes > 0 }
      .map { IdleUnmountTracker.checkInterval(forMinutes: $0.minutes) }.min()
    guard let interval else {
      timer?.invalidate()
      timer = nil
      timerInterval = 0
      tracker.reset()
      return
    }
    guard timer == nil || interval != timerInterval else { return }
    timer?.invalidate()
    timerInterval = interval
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.check() }
    timer.tolerance = interval / 10
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    check()
  }

  /// Volumes that may be unmounted for being idle, with their limits.
  /// Protected volumes are skipped; their saved setting applies again once
  /// they are unprotected. Time Machine volumes are never unmounted, so the
  /// next backup finds its disk.
  static func candidates(
    disks: [PhysicalDisk], unverifiedDiskIDs: Set<String>, settings: [IdleUnmountVolume],
    keepAliveIDs: Set<String>, busyVolumeIDs: Set<String>
  ) -> [IdleUnmountTracker.Candidate] {
    let minutesByID = Dictionary(
      settings.filter { $0.minutes > 0 }.map { ($0.id, $0.minutes) },
      uniquingKeysWith: { first, _ in first })
    var result: [IdleUnmountTracker.Candidate] = []
    for disk in disks where disk.type == .physical && !unverifiedDiskIDs.contains(disk.id) {
      for volume in disk.allVolumes {
        guard volume.isMounted, volume.category == .user, !volume.isProtected,
          !volume.isTimeMachine,
          let mountPoint = volume.mountPoint, mountPoint != "/",
          !mountPoint.hasPrefix("/System/"),
          let compositeId = volume.compositeId, let minutes = minutesByID[compositeId],
          !keepAliveIDs.contains(compositeId), !busyVolumeIDs.contains(volume.id)
        else { continue }
        result.append(
          .init(volumeID: volume.id, diskID: disk.id, limit: TimeInterval(minutes) * 60))
      }
    }
    return result
  }

  private func check() {
    let drives = DriveManager.shared
    let persistence = PersistenceManager.shared
    // After a failed refresh the list may show disks that are gone or
    // changed: wait for fresh data instead of acting on it.
    let disks = drives.isShowingStaleDisks ? [] : drives.physicalDisks ?? []
    let candidates = Self.candidates(
      disks: disks, unverifiedDiskIDs: drives.unverifiedDiskIDs,
      settings: persistence.idleUnmountVolumes,
      keepAliveIDs: Set(persistence.keepAliveVolumes.map(\.id)),
      busyVolumeIDs: drives.busyVolumeIDs)
    let maxGap = timerInterval * 2 + 30
    guard !candidates.isEmpty else {
      _ = tracker.evaluate([], activity: [:], now: Date(), maxGap: maxGap)
      return
    }
    let diskIDs = Set(candidates.map(\.diskID))
    activityQueue.async { [weak self] in
      var activity: [String: IdleUnmountTracker.Activity] = [:]
      for diskID in diskIDs {
        activity[diskID] = Self.diskActivity(forWholeDisk: diskID)
      }
      DispatchQueue.main.async {
        guard let self else { return }
        let idle = self.tracker.evaluate(
          candidates, activity: activity, now: Date(), maxGap: maxGap)
        for candidate in candidates where idle.contains(candidate.volumeID) {
          self.unmount(volumeID: candidate.volumeID, idleMinutes: Int(candidate.limit / 60))
        }
      }
    }
  }

  private func unmount(volumeID: String, idleMinutes: Int) {
    guard
      let volume = (DriveManager.shared.physicalDisks ?? []).flatMap(\.allVolumes)
        .first(where: { $0.id == volumeID && $0.isMounted })
    else { return }
    DriveManager.shared.unmountIdleVolume(volume) { succeeded in
      guard succeeded else { return }
      let message = PluralizedString.format("idle.unmounted", volume.name, idleMinutes)
      // With notifications on, the notice stays in Notification Center for a
      // user who was away; otherwise show the short-lived HUD as before.
      guard !NotificationManager.shared.idleUnmounted(message: message, volumeID: volumeID)
      else { return }
      FeedbackHUD.show(message, systemImage: "moon.zzz.fill")
    }
  }

  /// Read/write operation counters of a whole disk's block storage driver,
  /// or nil when they cannot be read.
  static func diskActivity(forWholeDisk bsdName: String) -> IdleUnmountTracker.Activity? {
    guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
    let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard media != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(media) }
    guard
      let statistics = IORegistryEntrySearchCFProperty(
        media, kIOServicePlane, "Statistics" as CFString, kCFAllocatorDefault,
        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        as? [String: Any]
    else { return nil }
    return activity(fromStatistics: statistics)
  }

  /// The operation counters of an IOBlockStorageDriver "Statistics"
  /// dictionary.
  static func activity(fromStatistics statistics: [String: Any]) -> IdleUnmountTracker.Activity? {
    guard let reads = (statistics["Operations (Read)"] as? NSNumber)?.uint64Value,
      let writes = (statistics["Operations (Write)"] as? NSNumber)?.uint64Value
    else { return nil }
    return .init(reads: reads, writes: writes)
  }
}
