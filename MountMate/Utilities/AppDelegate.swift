//  Created by homielab.com

import AppKit
import Combine
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Application Lifecycle
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupErrorObserver()
        setupSleepObserver()
        requestFileAccessPermissionIfNeeded()
    }
    
    // MARK: - Observers
    
    private func setupErrorObserver() {
        DriveManager.shared.$operationError
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
    
    // MARK: - Actions
    
    @objc private func systemWillSleep(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "ejectOnSleepEnabled") {
            print("System will sleep. Ejecting all user volumes.")
            DriveManager.shared.unmountAllDrives()
        }
    }
    
    // MARK: - Permissions
    
    private func requestFileAccessPermissionIfNeeded() {
        guard !SandboxChecker.isSandboxed else {
            print("App is sandboxed. Skipping manual permission request.")
            return
        }
        
        print("App is not sandboxed. Checking for /Volumes access permission.")
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: "/Volumes")
                print("Successfully accessed /Volumes or already have permission.")
            } catch {
                print("Could not access /Volumes. The system should prompt for permission. Error: \(error.localizedDescription)")
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
            textField.placeholderString = NSLocalizedString("Password", comment: "Password placeholder")
            alert.accessoryView = textField
            alert.addButton(withTitle: NSLocalizedString("Unlock", comment: "Unlock button"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        }
        
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            if case .lockedVolume(let lockedVolumeAlert) = appAlert.kind,
               let textField = alert.accessoryView as? NSSecureTextField {
                lockedVolumeAlert.onConfirm(textField.stringValue)
            }
        }
        
        DriveManager.shared.operationError = nil
    }
}
