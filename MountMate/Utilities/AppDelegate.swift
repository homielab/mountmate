//  Created by homielab.com

import AppKit
import Combine
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        DriveManager.shared.$operationError
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { appAlert in self.showAlert(appAlert) }
            .store(in: &cancellables)
            
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
    }
    
    @objc private func systemWillSleep(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "ejectOnSleepEnabled") {
            print("System will sleep. Ejecting all user volumes.")
            DriveManager.shared.unmountAllDrives()
        }
    }
    
    private func showAlert(_ appAlert: AppAlert) {
        let alert = NSAlert()
        alert.messageText = appAlert.title
        alert.informativeText = appAlert.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK button"))

        // TODO: Use Auto Layout
        let secureTextField = NSSecureTextField(frame: NSRect(origin: .zero, size: CGSize(width: 225, height: 20)))
        secureTextField.translatesAutoresizingMaskIntoConstraints = false
        // TODO: Localize.
        secureTextField.placeholderString = "Password"
        secureTextField.contentType = .password
        
        if case .lockedVolume = appAlert.kind {
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))

            alert.accessoryView = secureTextField
        }

        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        DriveManager.shared.operationError = nil

        guard response == .alertFirstButtonReturn else {
            return
        }

        if case let .lockedVolume(alert) = appAlert.kind {
            alert.action(secureTextField.stringValue)
        }
    }
}
