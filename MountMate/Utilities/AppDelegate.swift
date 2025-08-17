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
        
        switch appAlert.kind {
        case .basic:
            alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK button"))
            
        case .lockedVolume(let lockedVolumeAlert):
            let textField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            textField.placeholderString = NSLocalizedString("Password", comment: "Password field placeholder")
            alert.accessoryView = textField
            
            alert.addButton(withTitle: NSLocalizedString("Unlock", comment: "Unlock button"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        }
        
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            if case .lockedVolume(let lockedVolumeAlert) = appAlert.kind {
                if let textField = alert.accessoryView as? NSSecureTextField {
                    lockedVolumeAlert.onConfirm(textField.stringValue)
                }
            }
        }
        
        DriveManager.shared.operationError = nil
    }
}
