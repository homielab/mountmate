//  Created by homielab.com

import AppKit
import Combine
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
  private var cancellables = Set<AnyCancellable>()
  private var statusItem: NSStatusItem?
  private let popover = NSPopover()
  private var eventMonitor: Any?

  // MARK: - Application Lifecycle

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    setupStatusItem()
    setupStatusItemObservers()
    setupErrorObserver()
    setupSleepObserver()
    checkAndRequestFullDiskAccessIfNeeded()
    NetworkMountManager.shared.mountAllAutoShares()
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
    }
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

  private func setupSleepObserver() {
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(systemWillSleep),
      name: NSWorkspace.willSleepNotification,
      object: nil
    )
  }

  private func setupStatusItem() {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    self.statusItem = statusItem

    if let button = statusItem.button {
      button.target = self
      button.action = #selector(togglePopover(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    popover.behavior = .applicationDefined
    popover.animates = true
    popover.contentSize = NSSize(width: 350, height: 520)
    popover.contentViewController = NSHostingController(
      rootView: PopoverContent {
        MainView()
      }
      .environmentObject(DriveManager.shared)
    )

    updateStatusItemIcon()
    installPopoverEventMonitor()
  }

  private func setupStatusItemObservers() {
    DriveManager.shared.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in
        self?.updateStatusItemIcon()
      }
      .store(in: &cancellables)
  }

  private func installPopoverEventMonitor() {
    eventMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in
      guard let self, self.popover.isShown else { return }
      DispatchQueue.main.async {
        if !CustomMountPointEditorState.shared.isChoosingFolder, NSApp.modalWindow == nil {
          self.popover.performClose(nil)
        }
      }
    }
  }

  private func updateStatusItemIcon() {
    guard let button = statusItem?.button else { return }
    let iconName: String
    if DriveManager.shared.isUnmountingAll
      || DriveManager.shared.busyVolumeIdentifier != nil
      || DriveManager.shared.busyEjectingIdentifier != nil
    {
      iconName = "externaldrive.fill.badge.timemachine"
    } else if DriveManager.shared.userActionError != nil {
      iconName = "externaldrive.fill.trianglebadge.exclamationmark"
    } else {
      iconName = "externaldrive.fill"
    }

    button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "MountMate")
  }

  @objc private func togglePopover(_ sender: Any?) {
    guard let button = statusItem?.button else { return }
    if popover.isShown {
      if CustomMountPointEditorState.shared.isChoosingFolder { return }
      popover.performClose(sender)
      return
    }

    NSApp.activate(ignoringOtherApps: true)
    if let contentView = popover.contentViewController?.view {
      contentView.layoutSubtreeIfNeeded()
      let fittingSize = contentView.fittingSize
      popover.contentSize = NSSize(
        width: max(360, fittingSize.width),
        height: min(max(480, fittingSize.height), 720)
      )
    }
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
  }

  // MARK: - Actions

  @objc private func systemWillSleep(_ notification: Notification) {
    if UserDefaults.standard.bool(forKey: "ejectOnSleepEnabled") {
      print("System will sleep. Ejecting all user volumes.")
      DriveManager.shared.unmountAllDrives()
    }
  }

  // MARK: - Permissions

  private func checkAndRequestFullDiskAccessIfNeeded() {
    guard !SandboxChecker.isSandboxed else {
      print("App is sandboxed. Skipping Full Disk Access check.")
      return
    }

    let hasPromptedKey = "hasPromptedForFullDiskAccess"
    guard !UserDefaults.standard.bool(forKey: hasPromptedKey) else {
      return
    }

    print("Checking for Full Disk Access permission...")

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        _ = try FileManager.default.contentsOfDirectory(
          atPath: "/Library/Application Support/com.apple.TCC")
        print("Full Disk Access is already granted.")
      } catch {
        print("Full Disk Access not granted. Prompting user.")

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
      if let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
      {
        NSWorkspace.shared.open(url)
      }
    }
  }

  // MARK: - UI

  private func showAlert(_ appAlert: AppAlert) {
    let alert = NSAlert()
    alert.messageText = appAlert.title
    alert.informativeText = appAlert.message
    alert.alertStyle = .warning

    switch appAlert.kind {
    case .basic:
      alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK button"))

    case .lockedVolume(_):
      let textField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
      textField.placeholderString = NSLocalizedString(
        "Password", comment: "Password placeholder")

      
      let checkbox = NSButton(checkboxWithTitle: NSLocalizedString("Remember password in Keychain", comment: "Checkbox"), target: nil, action: nil)
      checkbox.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
      
      let stackView = NSStackView(views: [textField, checkbox])
      stackView.orientation = .vertical
      stackView.alignment = .leading
      stackView.spacing = 8
      stackView.frame = NSRect(x: 0, y: 0, width: 250, height: 56)
      
      alert.accessoryView = stackView
      alert.addButton(withTitle: NSLocalizedString("Unlock", comment: "Unlock button"))
      alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))

    case .forceEject:
      alert.addButton(withTitle: NSLocalizedString("Force Eject", comment: "Force Eject button"))
      alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
    }

    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()

    if response == .alertFirstButtonReturn {
      if case .lockedVolume(let lockedVolumeAlert) = appAlert.kind,
        let stackView = alert.accessoryView as? NSStackView,
        let textField = stackView.views.first(where: { $0 is NSSecureTextField }) as? NSSecureTextField,
        let checkbox = stackView.views.first(where: { $0 is NSButton }) as? NSButton
      {
        lockedVolumeAlert.onConfirm(textField.stringValue, checkbox.state == .on)
      } else if case .forceEject(let action) = appAlert.kind {
        action()
      }
    }

    DriveManager.shared.userActionError = nil
  }
}
