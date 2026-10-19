//  Created by homielab.com

import Foundation
import ServiceManagement

class LaunchAtLoginManager: ObservableObject {
  @Published var isEnabled: Bool {
    didSet {
      guard !isApplyingSystemState, isEnabled != oldValue else { return }
      updateLoginItemStatus()
    }
  }

  /// The login item is registered but the user still has to allow it in
  /// System Settings → General → Login Items.
  @Published private(set) var requiresApproval = false

  private let service = SMAppService.mainApp
  /// Set while `isEnabled` mirrors the system state, so that does not
  /// register or unregister the login item.
  private var isApplyingSystemState = false

  init() {
    // Always read the actual system state, not UserDefaults.
    let status = service.status
    self.isEnabled = Self.isOn(status)
    self.requiresApproval = status == .requiresApproval
  }

  /// A login item waiting for approval counts as on: it is registered and
  /// starts at login once allowed.
  private static func isOn(_ status: SMAppService.Status) -> Bool {
    status == .enabled || status == .requiresApproval
  }

  /// Re-reads the system state, e.g. after the user returns from System
  /// Settings.
  func refreshStatus() {
    let status = service.status
    isApplyingSystemState = true
    isEnabled = Self.isOn(status)
    isApplyingSystemState = false
    requiresApproval = status == .requiresApproval
  }

  func openLoginItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  private func updateLoginItemStatus() {
    do {
      if isEnabled {
        try service.register()
      } else {
        try service.unregister()
      }
    } catch {
      print("Failed to update login item status: \(error)")
    }
    // Reflect the actual state: on failure this reverts the toggle, and a
    // successful registration may still need the user's approval.
    DispatchQueue.main.async {
      self.refreshStatus()
    }
  }
}
