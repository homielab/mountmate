//  Created by homielab.com

import AppKit
import Combine
import UserNotifications

/// Decides when a background event is worth a notification, so a target
/// that stays down produces one notice per outage instead of one per retry.
///
/// A failure is announced once, when a target has failed
/// `failuresBeforeNotice` attempts in a row (one failed attempt right after
/// wake, before the network is back, stays quiet). A success is announced
/// only for a target whose failure was announced, and starts a new outage.
/// Not thread-safe: use from one queue (the main queue in the app).
struct BackgroundEventThrottle: Sendable {
  let failuresBeforeNotice: Int

  private var failureCounts: [String: Int] = [:]
  private var announcedFailures: Set<String> = []

  init(failuresBeforeNotice: Int = 2) {
    self.failuresBeforeNotice = max(1, failuresBeforeNotice)
  }

  /// Records a failed attempt; true when this failure should be announced.
  mutating func recordFailure(_ key: String) -> Bool {
    guard !announcedFailures.contains(key) else { return false }
    let count = (failureCounts[key] ?? 0) + 1
    failureCounts[key] = count
    guard count >= failuresBeforeNotice else { return false }
    announcedFailures.insert(key)
    return true
  }

  /// Records a success; true when the target recovers from an announced
  /// failure.
  mutating func recordSuccess(_ key: String) -> Bool {
    failureCounts.removeValue(forKey: key)
    return announcedFailures.remove(key) != nil
  }

  /// Drops a target's history without announcing anything (the user
  /// unmounted it, or keep-alive was turned off).
  mutating func forget(_ key: String) {
    failureCounts.removeValue(forKey: key)
    announcedFailures.remove(key)
  }

  mutating func reset() {
    failureCounts.removeAll()
    announcedFailures.removeAll()
  }

  /// Whether a failure is currently announced for the target. For tests.
  func hasAnnouncedFailure(_ key: String) -> Bool {
    announcedFailures.contains(key)
  }
}

/// Remembers which disks already got a "SMART failing" notice, so a disk
/// that stays failing is announced once per run, not on every refresh.
/// Not thread-safe: main queue only.
struct SMARTAlertTracker: Sendable {
  private var announced: Set<String> = []

  /// The disks of `disks` that report `.failing` and were not announced
  /// yet; they count as announced afterwards. A disk that is gone or no
  /// longer failing is forgotten, so macOS reusing its identifier for the
  /// next drive (or the same drive failing again) is announced again.
  mutating func newlyFailing(in disks: [PhysicalDisk]) -> [PhysicalDisk] {
    announced.formIntersection(disks.filter { $0.smartStatus == .failing }.map(\.id))
    return disks.filter { $0.smartStatus == .failing && announced.insert($0.id).inserted }
  }
}

/// What a click on a MountMate notification (or one of its buttons) does.
enum NotificationAction: Equatable {
  case reconnectNow
  case openPopover
  case none

  /// Category of the "Cannot Reconnect" notification, which has the
  /// "Reconnect Now" button.
  static let keepAliveFailedCategory = "keepAliveFailed"
  static let reconnectActionID = "reconnectNow"

  /// Clicking the notification body opens the popover; the button retries;
  /// dismissing does nothing.
  static func resolve(actionIdentifier: String) -> NotificationAction {
    switch actionIdentifier {
    case UNNotificationDefaultActionIdentifier: return .openPopover
    case reconnectActionID: return .reconnectNow
    default: return .none
    }
  }

  /// The categories to register with the notification center.
  static func makeCategories() -> Set<UNNotificationCategory> {
    let reconnect = UNNotificationAction(
      identifier: reconnectActionID,
      title: NSLocalizedString("Reconnect Now", comment: "Notification button"),
      options: [])
    return [
      UNNotificationCategory(
        identifier: keepAliveFailedCategory, actions: [reconnect], intentIdentifiers: [],
        options: [])
    ]
  }
}

/// The part of `UNUserNotificationCenter` MountMate uses, so tests can stand
/// in for the system.
protocol NotificationCentering: AnyObject {
  func setDelegate(_ delegate: UNUserNotificationCenterDelegate)
  func setCategories(_ categories: Set<UNNotificationCategory>)
  func requestAuthorization(completion: @escaping (_ granted: Bool, _ error: Error?) -> Void)
  func authorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void)
  func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void)
}

/// The real notification center. Looked up on each use, so creating one
/// outside an app bundle (unit tests) is harmless.
final class SystemNotificationCenter: NotificationCentering {
  private var center: UNUserNotificationCenter { .current() }

  func setDelegate(_ delegate: UNUserNotificationCenterDelegate) {
    center.delegate = delegate
  }

  func setCategories(_ categories: Set<UNNotificationCategory>) {
    center.setNotificationCategories(categories)
  }

  func requestAuthorization(completion: @escaping (Bool, Error?) -> Void) {
    center.requestAuthorization(options: [.alert, .sound], completionHandler: completion)
  }

  func authorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
    center.getNotificationSettings { completion($0.authorizationStatus) }
  }

  func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
    center.add(request, withCompletionHandler: completion)
  }
}

/// Optional macOS notifications for events that happen in the background:
/// keep-alive reconnect failures and recoveries, blocked volumes that could
/// not be unmounted, unmount-on-sleep running out of time, idle unmounts,
/// failing disks, almost full volumes and disks pulled out without ejecting.
///
/// Off by default. Permission is requested only when the user turns the
/// setting on. Main thread only.
final class NotificationManager: NSObject, ObservableObject {
  static let shared = NotificationManager()

  static let enabledKey = "notificationsEnabled"

  /// The user's "Notifications" setting.
  @Published var isEnabled: Bool {
    didSet {
      guard oldValue != isEnabled else { return }
      defaults.set(isEnabled, forKey: Self.enabledKey)
      if isEnabled {
        requestAuthorization()
      } else {
        keepAliveThrottle.reset()
        removalTracker.reset()
      }
    }
  }

  /// Whether macOS lets MountMate show notifications: false after the user
  /// declined the prompt or turned them off in System Settings.
  @Published private(set) var isDeniedBySystem = false

  private var isAuthorized = false
  private var keepAliveThrottle = BackgroundEventThrottle()
  private var smartTracker = SMARTAlertTracker()
  private var lowSpaceTracker = LowSpaceAlertTracker()
  private var removalTracker = UnexpectedRemovalTracker()
  private var cancellables = Set<AnyCancellable>()

  private let center: NotificationCentering
  private let defaults: UserDefaults
  private let activationNotifications: NotificationCenter
  private let workspaceNotifications: NotificationCenter
  private let performOnMain: (@escaping () -> Void) -> Void
  private let mountedPaths: () -> Set<String>?
  private let now: () -> Date

  /// What the notification buttons do; replaced in tests.
  var reconnectNow: () -> Void = { KeepAliveManager.shared.sweepNow(resetBackoff: true) }
  var openPopover: () -> Void = { MenuBarPopover.open() }

  /// - Parameters:
  ///   - activationNotifications: where `didBecomeActiveNotification` is
  ///     observed to re-read the permission.
  ///   - workspaceNotifications: where unmount requests, sleep and wake are
  ///     observed for the pulled-out disk warning.
  ///   - mountedPaths: the mount points in the kernel mount table, or nil
  ///     when it cannot be read.
  ///   - performOnMain: how the notification center's callbacks get back to
  ///     the main thread. Tests run them right away, so they don't depend on
  ///     how many main-queue hops a permission check takes.
  init(
    center: NotificationCentering = SystemNotificationCenter(),
    defaults: UserDefaults = .standard,
    activationNotifications: NotificationCenter = .default,
    workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
    performOnMain: @escaping (@escaping () -> Void) -> Void = {
      DispatchQueue.main.async(execute: $0)
    },
    mountedPaths: @escaping () -> Set<String>? = {
      MountTable.entries().map { Set($0.map(\.mountPoint)) }
    },
    now: @escaping () -> Date = Date.init
  ) {
    self.center = center
    self.defaults = defaults
    self.activationNotifications = activationNotifications
    self.workspaceNotifications = workspaceNotifications
    self.performOnMain = performOnMain
    self.mountedPaths = mountedPaths
    self.now = now
    isEnabled = defaults.bool(forKey: Self.enabledKey)
    super.init()
  }

  /// Called once at launch: becomes the notification center's delegate and
  /// reads the current permission.
  func start() {
    center.setDelegate(self)
    center.setCategories(NotificationAction.makeCategories())
    if isEnabled { refreshAuthorizationStatus() }
    // Permission can change in System Settings while MountMate runs.
    activationNotifications.publisher(for: NSApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in
        guard let self, self.isEnabled else { return }
        self.refreshAuthorizationStatus()
      }
      .store(in: &cancellables)
    observeRemovalEvents()
  }

  /// An unmount the user or an app asked for (Finder, `diskutil`, MountMate)
  /// posts `willUnmount`; a disk pulled out does not. Sleep and wake pause
  /// the pulled-out disk warning.
  private func observeRemovalEvents() {
    workspaceNotifications.publisher(for: NSWorkspace.willUnmountNotification)
      .sink { [weak self] notification in
        guard let self,
          let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
        else { return }
        self.removalTracker.recordRequestedUnmount(mountPoint: url.path, at: self.now())
      }
      .store(in: &cancellables)
    workspaceNotifications.publisher(for: NSWorkspace.willSleepNotification)
      .sink { [weak self] _ in self?.removalTracker.systemWillSleep() }
      .store(in: &cancellables)
    workspaceNotifications.publisher(for: NSWorkspace.didWakeNotification)
      .sink { [weak self] _ in
        guard let self else { return }
        self.removalTracker.systemDidWake(at: self.now())
      }
      .store(in: &cancellables)
  }

  /// True when a notification would be shown right now.
  var canDeliver: Bool { isEnabled && isAuthorized }

  func openSystemNotificationSettings() {
    let identifier = Bundle.main.bundleIdentifier ?? "com.homielab.mountmate"
    let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    let url =
      URL(string: "\(pane)?id=\(identifier)")
      ?? URL(fileURLWithPath: "/System/Library/PreferencePanes/Notifications.prefPane")
    NSWorkspace.shared.open(url)
  }

  // MARK: - Events

  /// A keep-alive attempt for a share or volume finished.
  func keepAliveResult(targetID: String, name: String, success: Bool) {
    guard isEnabled else { return }
    if success {
      guard keepAliveThrottle.recordSuccess(targetID) else { return }
      post(
        id: "keepAlive.\(targetID)",
        title: NSLocalizedString("Reconnected", comment: "Notification title"),
        body: String(
          format: NSLocalizedString(
            "“%@” is mounted again.", comment: "Notification: keep-alive reconnected a mount"),
          name))
    } else {
      guard keepAliveThrottle.recordFailure(targetID) else { return }
      post(
        id: "keepAlive.\(targetID)",
        category: NotificationAction.keepAliveFailedCategory,
        title: NSLocalizedString("Cannot Reconnect", comment: "Notification title"),
        body: String(
          format: NSLocalizedString(
            "MountMate couldn't reconnect “%@”. It will keep trying.",
            comment: "Notification: keep-alive reconnect failed"),
          name))
    }
  }

  /// The user unmounted a keep-alive target, or it left keep-alive: forget
  /// its outage without announcing a recovery.
  func keepAliveForget(targetID: String) {
    keepAliveThrottle.forget(targetID)
  }

  func keepAliveReset() {
    keepAliveThrottle.reset()
  }

  /// A blocked volume mounted before MountMate started could not be
  /// unmounted.
  func blockedVolumeStillMounted(name: String, volumeUUID: String) {
    post(
      id: "blocked.\(volumeUUID)",
      title: NSLocalizedString("Blocked Disk Still Mounted", comment: "Notification title"),
      body: String(
        format: NSLocalizedString(
          "MountMate couldn't unmount the blocked volume “%@”, probably because it is in use.",
          comment: "Notification: blocked volume could not be unmounted at startup"),
        name))
  }

  /// "Unmount All Disks on Sleep" had not finished when sleep was allowed.
  func sleepUnmountTimedOut() {
    post(
      id: "sleepUnmount",
      title: NSLocalizedString("Unmount Before Sleep Unfinished", comment: "Notification title"),
      body: NSLocalizedString(
        "Some disks were still unmounting when the Mac went to sleep. Check that they are unmounted before disconnecting them.",
        comment: "Notification: unmount on sleep timed out"))
  }

  /// After wake: volumes that "Unmount All Disks on Sleep" had no time to
  /// unmount are still mounted.
  func sleepUnmountLeftoverMounted(names: [String]) {
    post(
      id: "sleepUnmountLeftover",
      title: NSLocalizedString(
        "Disks Were Not Unmounted Before Sleep", comment: "Notification title"),
      body: String(
        format: NSLocalizedString(
          "MountMate could not unmount these disks before the Mac went to sleep: %@.",
          comment: "Notification after wake; list of volume names"),
        names.joined(separator: ", ")))
  }

  /// A volume was unmounted by "Unmount When Idle". Returns false when no
  /// notification is shown, so the caller can fall back to its own feedback.
  @discardableResult
  func idleUnmounted(message: String, volumeID: String) -> Bool {
    guard canDeliver else { return false }
    post(
      id: "idle.\(volumeID)",
      title: NSLocalizedString("Unmount When Idle", comment: "Notification title"),
      body: message)
    return true
  }

  /// A refresh finished. Announces each disk that reports a failing SMART
  /// status, each volume that is almost full and each volume pulled out
  /// without ejecting, once. With notifications off nothing is remembered,
  /// so turning them on announces a disk that is still failing.
  /// - Parameters:
  ///   - ejectingDiskIDs, busyVolumeIDs: MountMate's own ejects and unmounts
  ///     in flight; their volumes vanishing is expected.
  func disksRefreshed(
    _ disks: [PhysicalDisk], unverifiedDiskIDs: Set<String> = [],
    ejectingDiskIDs: Set<String> = [], busyVolumeIDs: Set<String> = []
  ) {
    guard isEnabled else { return }
    announceRemovals(
      in: disks, unverifiedDiskIDs: unverifiedDiskIDs, ejectingDiskIDs: ejectingDiskIDs,
      busyVolumeIDs: busyVolumeIDs)
    for disk in smartTracker.newlyFailing(in: disks) {
      post(
        id: "smart.\(disk.id)",
        title: NSLocalizedString("Disk Is Failing", comment: "Notification title"),
        body: String(
          format: NSLocalizedString(
            "“%@” reports a failing SMART status. Back up its data now.",
            comment: "Notification: a disk's SMART status is failing"),
          disk.name ?? disk.connectionType))
    }
    // Nothing is remembered while the warning is off, like with SMART.
    guard let threshold = LowSpaceRules.threshold(defaults: defaults) else { return }
    announceLowSpace(in: disks, threshold: threshold)
  }

  private func announceLowSpace(in disks: [PhysicalDisk], threshold: Double) {
    for (volume, warning) in lowSpaceTracker.newWarnings(in: disks, threshold: threshold) {
      post(
        id: "lowSpace.\(volume.id)",
        title: NSLocalizedString("Volume Almost Full", comment: "Notification title"),
        body: String(
          format: NSLocalizedString(
            "“%1$@” is %2$d%% full. Free up space before copies and backups start failing.",
            comment: "Notification: a volume is almost full"),
          volume.name, warning.percentUsed))
    }
  }

  /// Nothing is remembered while the warning is off: turning it on starts
  /// from the next refresh.
  private func announceRemovals(
    in disks: [PhysicalDisk], unverifiedDiskIDs: Set<String>, ejectingDiskIDs: Set<String>,
    busyVolumeIDs: Set<String>
  ) {
    guard UnexpectedRemovalTracker.isEnabled(defaults: defaults) else {
      removalTracker.reset()
      return
    }
    let removals = removalTracker.removals(
      in: disks, unverifiedDiskIDs: unverifiedDiskIDs, ejectingDiskIDs: ejectingDiskIDs,
      busyVolumeIDs: busyVolumeIDs, mountedPaths: mountedPaths(), now: now())
    for removal in removals {
      Log.drive.notice(
        "Volume \(removal.name, privacy: .private) disappeared without being ejected.")
      post(
        id: "removed.\(removal.volumeID)",
        title: NSLocalizedString("Disconnected Without Ejecting", comment: "Notification title"),
        body: String(
          format: NSLocalizedString(
            "“%@” was disconnected without being ejected. Check your files.",
            comment: "Notification: a disk was pulled out while its volume was mounted"),
          removal.name))
    }
  }

  // MARK: - Delivery

  /// Shows a notification when the setting is on and macOS allows it. A new
  /// notification with the same id replaces the previous one.
  private func post(id: String, category: String? = nil, title: String, body: String) {
    guard isEnabled else { return }
    let content = UNMutableNotificationContent()
    if let category { content.categoryIdentifier = category }
    content.title = title
    content.body = body
    let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
    center.add(request) { error in
      if let error {
        Log.app.error(
          "Could not show notification: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// Runs what the user chose on a notification. Main thread.
  func handleResponse(actionIdentifier: String) {
    switch NotificationAction.resolve(actionIdentifier: actionIdentifier) {
    case .reconnectNow: reconnectNow()
    case .openPopover: openPopover()
    case .none: break
    }
  }

  private func requestAuthorization() {
    center.requestAuthorization { [weak self] granted, error in
      if let error {
        Log.app.error(
          "Notification permission request failed: \(error.localizedDescription, privacy: .public)")
      }
      self?.performOnMain {
        self?.isAuthorized = granted
        self?.isDeniedBySystem = !granted
      }
    }
  }

  private func refreshAuthorizationStatus() {
    center.authorizationStatus { [weak self] status in
      self?.performOnMain {
        guard let self else { return }
        switch status {
        case .notDetermined:
          // Turned on in an earlier version of the settings or the prompt
          // never answered: ask again.
          self.requestAuthorization()
        case .denied:
          self.isAuthorized = false
          self.isDeniedBySystem = true
        default:
          self.isAuthorized = true
          self.isDeniedBySystem = false
        }
      }
    }
  }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
  /// Show banners even while MountMate's menu or settings are open.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let action = response.actionIdentifier
    DispatchQueue.main.async {
      self.handleResponse(actionIdentifier: action)
      completionHandler()
    }
  }
}
