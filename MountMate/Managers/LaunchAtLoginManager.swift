//  Created by homielab.com

import Foundation
import ServiceManagement

class LaunchAtLoginManager: ObservableObject {
  @Published var isEnabled: Bool {
    didSet {
      guard isEnabled != oldValue else { return }
      updateLoginItemStatus()
    }
  }

  private let service: SMAppService

  init() {
    self.service = SMAppService()

    // Always read the actual system state, not UserDefaults
    if #available(macOS 13.0, *) {
      let status = SMAppService().status
      self.isEnabled = (status == .enabled)
    } else {
      self.isEnabled = UserDefaults.standard.bool(forKey: "launchAtLoginEnabled")
    }
  }

  private func updateLoginItemStatus() {
    guard #available(macOS 13.0, *) else { return }
    do {
      if isEnabled {
        try service.register()
      } else {
        try service.unregister()
      }
    } catch {
      print("Failed to update login item status: \(error)")
      // Revert to actual system state on failure
      DispatchQueue.main.async {
        let actualStatus = self.service.status
        self.isEnabled = (actualStatus == .enabled)
      }
    }
  }
}
