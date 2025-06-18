//  Created by homielab.com

import Foundation
import ServiceManagement

class LaunchAtLoginManager: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "launchAtLoginEnabled")
            updateLoginItemStatus()
        }
    }
    
    private let service: SMAppService
    
    init() {
        self.service = SMAppService()
        if UserDefaults.standard.object(forKey: "launchAtLoginEnabled") == nil {
            self.isEnabled = true
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
            DispatchQueue.main.async { self.isEnabled.toggle() }
        }
    }
}