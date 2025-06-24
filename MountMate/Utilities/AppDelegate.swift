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
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        DriveManager.shared.operationError = nil
    }
}