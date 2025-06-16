//
//  Created by homielab
//

import Foundation
import ServiceManagement

class LaunchAtLoginManager: ObservableObject {
    
    @Published var isEnabled: Bool {
        didSet {
            updateLoginItemStatus()
        }
    }
    
    private let service: SMAppService
    
    init() {
        // Initialize the service instance once.
        self.service = SMAppService()
        
        // Initialize the property based on the OS version and correct service call.
        if #available(macOS 13.0, *) {
            self.isEnabled = service.status == .enabled
        } else {
            self.isEnabled = false
        }
    }
    
    private func updateLoginItemStatus() {
        // Only attempt to register/unregister if on macOS 13+.
        if #available(macOS 13.0, *) {
            do {
                if isEnabled {
                    try service.register()
                    print("Successfully registered for launch at login.")
                } else {
                    try service.unregister()
                    print("Successfully unregistered from launch at login.")
                }
            } catch {
                print("Failed to update login item status: \(error)")
                // Revert the toggle's state if the operation fails
                DispatchQueue.main.async {
                    self.isEnabled.toggle()
                }
            }
        }
    }
}
