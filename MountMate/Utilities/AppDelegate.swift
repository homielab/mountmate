//  Created by homielab.com

import AppKit
import Combine
import IOKit.pwr_mgt

// IOKit's message constants are function-like C macros
// (iokit_common_msg(...)) that Swift does not import.
private let kIOMessageCanSystemSleepValue: UInt32 = 0xE000_0270
private let kIOMessageSystemWillSleepValue: UInt32 = 0xE000_0280

class AppDelegate: NSObject, NSApplicationDelegate {
  private var cancellables = Set<AnyCancellable>()
  private static let forgetCheckboxID = NSUserInterfaceItemIdentifier("forgetSavedPassword")
  private var emptyFieldObserver: NSObjectProtocol?

  // IOKit system power registration (see setupSleepObserver).
  private var powerRootPort: io_connect_t = 0
  private var powerNotifyPort: IONotificationPortRef?
  private var powerNotifier: io_object_t = 0
  /// Longest the app delays sleep while unmounting. macOS waits at most 30s
  /// for an answer to kIOMessageSystemWillSleep before sleeping anyway.
  private static let sleepUnmountTimeout: TimeInterval = 20

  // MARK: - Application Lifecycle

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    setupErrorObserver()
    setupSleepObserver()
    checkAndRequestFullDiskAccessIfNeeded()
    NotificationManager.shared.start()
    // Starts the keep-alive scheduler (reconnect sweeps, network and wake
    // monitoring) and the login mount for network shares.
    KeepAliveManager.shared.sweepNow()
    IdleUnmountManager.shared.start()
    WakeRemountManager.shared.start()
    NetworkMountManager.shared.mountAllAutoShares()
  }

  // MARK: - Observers

  private func setupErrorObserver() {
    DriveManager.shared.$userActionError
      .receive(on: DispatchQueue.main)
      .compactMap { $0 }
      .sink { [weak self] appAlert in
        self?.showAlert(appAlert)
      }
      .store(in: &cancellables)
  }

  func applicationWillTerminate(_ notification: Notification) {
    if powerNotifier != 0 {
      IODeregisterForSystemPower(&powerNotifier)
      powerNotifier = 0
    }
    if let port = powerNotifyPort {
      IONotificationPortSetDispatchQueue(port, nil)
      IONotificationPortDestroy(port)
      powerNotifyPort = nil
    }
    if powerRootPort != 0 {
      IOServiceClose(powerRootPort)
      powerRootPort = 0
    }
  }

  /// Registers for IOKit system power notifications. Unlike
  /// NSWorkspace.willSleepNotification, kIOMessageSystemWillSleep lets the
  /// app hold off sleep until IOAllowPowerChange is called, so the
  /// "Unmount All Disks on Sleep" unmounts can finish before the disks lose
  /// power.
  private func setupSleepObserver() {
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    let callback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in
      guard let refcon else { return }
      let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
      delegate.handlePowerMessage(messageType, notificationID: Int(bitPattern: messageArgument))
    }
    var notifyPort: IONotificationPortRef?
    let rootPort = IORegisterForSystemPower(refcon, &notifyPort, callback, &powerNotifier)
    guard rootPort != 0, let notifyPort else {
      // Fall back to the old notification: it cannot delay sleep, but the
      // unmounts still start.
      Log.app.error("IORegisterForSystemPower failed; using NSWorkspace sleep notification.")
      NSWorkspace.shared.notificationCenter.addObserver(
        self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification,
        object: nil)
      return
    }
    powerRootPort = rootPort
    powerNotifyPort = notifyPort
    // Deliver on the main queue: DriveManager state is main-thread only.
    IONotificationPortSetDispatchQueue(notifyPort, DispatchQueue.main)
  }

  // MARK: - Actions

  /// Fallback used only when IOKit power registration failed.
  @objc private func systemWillSleep(_ notification: Notification) {
    guard UserDefaults.standard.bool(forKey: "ejectOnSleepEnabled") else { return }
    Log.app.notice("System will sleep. Ejecting all user volumes.")
    WakeRemountManager.shared.begin(volumes: DriveManager.shared.unmountAllCandidates)
    DriveManager.shared.unmountAllDrives(
      suppressReconnect: false, reportFailures: false,
      unmountResult: { WakeRemountManager.shared.settle(failed: $0) })
  }

  /// Main thread. Every kIOMessageCanSystemSleep / kIOMessageSystemWillSleep
  /// must be answered with exactly one IOAllowPowerChange.
  private func handlePowerMessage(_ messageType: UInt32, notificationID: Int) {
    switch messageType {
    case kIOMessageCanSystemSleepValue:
      // Idle sleep request: never veto it.
      IOAllowPowerChange(powerRootPort, notificationID)

    case kIOMessageSystemWillSleepValue:
      guard UserDefaults.standard.bool(forKey: "ejectOnSleepEnabled") else {
        IOAllowPowerChange(powerRootPort, notificationID)
        return
      }
      Log.app.notice("System will sleep. Ejecting all user volumes.")
      let rootPort = powerRootPort
      // Both the completion and the cap below call this on the main thread;
      // the flag makes the second call a no-op.
      var hasAllowed = false
      let allowSleep: () -> Void = {
        guard !hasAllowed else { return }
        hasAllowed = true
        IOAllowPowerChange(rootPort, notificationID)
      }
      // Cap the delay: a hung unmount must not keep the Mac awake.
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.sleepUnmountTimeout) {
        if !hasAllowed {
          Log.app.error("Unmount on sleep still running; allowing sleep anyway.")
          WakeRemountManager.shared.sleepTimedOut()
          NotificationManager.shared.sleepUnmountTimedOut()
        }
        allowSleep()
      }
      // The unmount is not a user decision — keep-alive targets reconnect on
      // wake, so pass suppressReconnect: false.
      WakeRemountManager.shared.begin(volumes: DriveManager.shared.unmountAllCandidates)
      DriveManager.shared.unmountAllDrives(
        suppressReconnect: false, reportFailures: false, completion: allowSleep,
        unmountResult: { WakeRemountManager.shared.settle(failed: $0) })

    default:
      break
    }
  }

  // MARK: - Permissions

  private func checkAndRequestFullDiskAccessIfNeeded() {
    guard !SandboxChecker.isSandboxed else {
      Log.app.info("App is sandboxed. Skipping Full Disk Access check.")
      return
    }

    let hasPromptedKey = "hasPromptedForFullDiskAccess"
    guard !UserDefaults.standard.bool(forKey: hasPromptedKey) else {
      return
    }

    Log.app.info("Checking for Full Disk Access permission")

    DispatchQueue.global(qos: .userInitiated).async {
      if FullDiskAccessChecker.currentlyGranted() {
        Log.app.info("Full Disk Access is already granted.")
      } else {
        Log.app.notice("Full Disk Access not granted. Prompting user.")

        DispatchQueue.main.async {
          self.showFullDiskAccessAlert()
          UserDefaults.standard.set(true, forKey: hasPromptedKey)
        }
      }
    }
  }

  private func showFullDiskAccessAlert() {
    let alert = NSAlert()
    alert.messageText = NSLocalizedString("Full Disk Access Recommended", comment: "Alert title")
    alert.informativeText = NSLocalizedString(
      "To ensure MountMate can see all disk types and prevent errors, please grant Full Disk Access.\n\nClick 'Open System Settings' to be taken to the correct panel.",
      comment: "Alert message")
    alert.alertStyle = .informational
    alert.addButton(withTitle: NSLocalizedString("Open System Settings", comment: "Button title"))
    alert.addButton(withTitle: NSLocalizedString("Later", comment: "Button title"))

    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()

    if response == .alertFirstButtonReturn {
      FullDiskAccessChecker.openSystemSettings()
    }
  }

  // MARK: - UI

  private func showAlert(_ appAlert: AppAlert) {
    let alert = NSAlert()
    alert.messageText = appAlert.title
    alert.informativeText = appAlert.message
    alert.alertStyle = appAlert.style == .informational ? .informational : .warning

    switch appAlert.kind {
    case .basic:
      alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK button"))

    case .lockedVolume(let lockedAlert):
      let textField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
      textField.placeholderString = NSLocalizedString(
        "Password", comment: "Password placeholder")

      let checkbox = NSButton(
        checkboxWithTitle: NSLocalizedString("Remember password in Keychain", comment: "Checkbox"),
        target: nil, action: nil)
      checkbox.frame = NSRect(x: 0, y: 0, width: 200, height: 24)

      var views: [NSView] = [textField, checkbox]
      if lockedAlert.offersForgetSavedPassword {
        let forget = NSButton(
          checkboxWithTitle: NSLocalizedString(
            "Forget the saved password", comment: "Checkbox: the saved password was rejected"),
          target: nil, action: nil)
        forget.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        forget.state = .on
        forget.identifier = Self.forgetCheckboxID
        views.append(forget)
      }
      let stackView = NSStackView(views: views)
      stackView.orientation = .vertical
      stackView.alignment = .leading
      stackView.spacing = 8
      stackView.frame = NSRect(
        x: 0, y: 0, width: 250, height: lockedAlert.offersForgetSavedPassword ? 88 : 56)

      alert.accessoryView = stackView
      let unlockButton = alert.addButton(
        withTitle: NSLocalizedString("Unlock", comment: "Unlock button"))
      alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
      // Focus the password field; Unlock stays off while it is empty.
      alert.window.initialFirstResponder = textField
      unlockButton.isEnabled = false
      emptyFieldObserver = NotificationCenter.default.addObserver(
        forName: NSControl.textDidChangeNotification, object: textField, queue: .main
      ) { [weak unlockButton, weak textField] _ in
        unlockButton?.isEnabled = !(textField?.stringValue.isEmpty ?? true)
      }

    case .forceEject:
      alert.addButton(withTitle: NSLocalizedString("Force Eject", comment: "Force Eject button"))
      alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))

    case .forceUnmount:
      alert.addButton(
        withTitle: NSLocalizedString("Force Unmount", comment: "Force Unmount button"))
      alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
    }

    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    if let observer = emptyFieldObserver {
      NotificationCenter.default.removeObserver(observer)
      emptyFieldObserver = nil
    }

    if response == .alertFirstButtonReturn {
      if case .lockedVolume(let lockedVolumeAlert) = appAlert.kind,
        let stackView = alert.accessoryView as? NSStackView,
        let textField = stackView.views.first(where: { $0 is NSSecureTextField })
          as? NSSecureTextField,
        let checkbox = stackView.views.first(where: { $0 is NSButton }) as? NSButton
      {
        let forget = stackView.views.first { $0.identifier == Self.forgetCheckboxID } as? NSButton
        lockedVolumeAlert.onConfirm(
          textField.stringValue, checkbox.state == .on, forget?.state == .on)
      } else if case .forceEject(let action) = appAlert.kind {
        action()
      } else if case .forceUnmount(let action) = appAlert.kind {
        action()
      }
    }

    DriveManager.shared.userActionError = nil
  }
}
