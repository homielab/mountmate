//  Created by homielab.com

import Foundation

/// Reads the free space of mounted external volumes every
/// `LowSpaceRules.pollInterval` while nothing else refreshes the list, so an
/// always-connected drive that fills up is announced without opening the
/// popover. Only `statfs` of those mount points: no `diskutil`, no network
/// shares. The timer runs only while notifications and the almost-full
/// warning are on and an external volume is mounted. Main thread only.
extension DriveManager {
  func observeLowSpacePollSettings() {
    // Both settings live in UserDefaults (the Notifications toggle writes it too).
    NotificationCenter.default.addObserver(
      self, selector: #selector(lowSpacePollSettingsDidChange),
      name: UserDefaults.didChangeNotification, object: nil)
  }

  @objc func lowSpacePollSettingsDidChange(_ notification: Notification) {
    scheduleLowSpacePoll()
  }

  /// Starts, moves or stops the poll timer for the current settings and
  /// disks; polls right away when it is overdue.
  func scheduleLowSpacePoll() {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.scheduleLowSpacePoll() }
      return
    }
    let decision = LowSpaceRules.pollDecision(
      notificationsEnabled: NotificationManager.shared.isEnabled,
      threshold: LowSpaceRules.threshold(), disks: physicalDisks ?? [],
      lastRead: lastUsageRead, now: Date())
    switch decision {
    case .off:
      lowSpacePollTimer?.invalidate()
      lowSpacePollTimer = nil
    case .wait(let date):
      if let timer = lowSpacePollTimer, timer.isValid, timer.fireDate == date { return }
      lowSpacePollTimer?.invalidate()
      let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
        self?.scheduleLowSpacePoll()
      }
      // Lets macOS batch the wake-up with others; minutes late is fine here.
      timer.tolerance = 60
      RunLoop.main.add(timer, forMode: .common)
      lowSpacePollTimer = timer
    case .pollNow:
      lowSpacePollTimer?.invalidate()
      lowSpacePollTimer = nil
      pollLowSpace()
    }
  }

  private func pollLowSpace() {
    guard !isPollingLowSpace else { return }
    let mountPoints = LowSpaceRules.pollCandidates(in: physicalDisks ?? []).compactMap(
      \.mountPoint)
    guard !mountPoints.isEmpty else { return }
    isPollingLowSpace = true
    Log.drive.debug("Polling free space of \(mountPoints.count) external volume(s).")
    DispatchQueue.global(qos: .utility).async { [weak self] in
      // Each read is bounded by FileSystemUsage's timeout; a hung volume is skipped.
      let outcomes = DiskListParser.readUsageConcurrently(of: mountPoints) {
        FileSystemUsage.read(atPath: $0)
      }
      DispatchQueue.main.async {
        guard let self else { return }
        self.isPollingLowSpace = false
        self.lastUsageRead = Date()
        NotificationManager.shared.lowSpacePolled(
          LowSpaceRules.applyingPolledUsage(outcomes, to: self.physicalDisks ?? []))
        self.scheduleLowSpacePoll()
      }
    }
  }
}
