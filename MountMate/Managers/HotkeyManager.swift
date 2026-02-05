//  Created by homielab.com

import AppKit
import Carbon
import Combine
import Foundation

/// Manages global keyboard shortcuts for mounting and unmounting volumes.
/// Uses NSEvent's global monitor to listen for key events system-wide.
/// Note: Requires Accessibility permissions in System Preferences > Privacy & Security > Accessibility
class HotkeyManager: ObservableObject {
  static let shared = HotkeyManager()

  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var cancellables = Set<AnyCancellable>()

  @Published var isListening = false

  private init() {
    setupObserver()
  }

  deinit {
    stopListening()
  }

  // MARK: - Setup

  private func setupObserver() {
    // Observe changes to the hotkey enabled setting
    UserDefaults.standard.publisher(for: \.hotkeysEnabled)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] enabled in
        if enabled {
          self?.startListening()
        } else {
          self?.stopListening()
        }
      }
      .store(in: &cancellables)

    // Start listening if already enabled
    if UserDefaults.standard.bool(forKey: "hotkeysEnabled") {
      startListening()
    }
  }

  // MARK: - Accessibility Check

  /// Check if the app has accessibility permissions
  static func checkAccessibilityPermissions() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  // MARK: - Listening

  func startListening() {
    guard globalMonitor == nil else { return }

    // Check accessibility permissions and prompt if needed
    let trusted = HotkeyManager.checkAccessibilityPermissions()
    
    #if DEBUG
      print("HotkeyManager: Accessibility permissions granted: \(trusted)")
    #endif

    // Add global monitor for when other apps are focused
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      self?.handleKeyEvent(event)
    }

    // Add local monitor for when our app is focused
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if self?.handleKeyEvent(event) == true {
        return nil  // Consume the event
      }
      return event  // Pass through
    }

    isListening = true
    #if DEBUG
      print("HotkeyManager: Started listening for global hotkeys")
    #endif
  }

  func stopListening() {
    if let monitor = globalMonitor {
      NSEvent.removeMonitor(monitor)
      globalMonitor = nil
    }
    
    if let monitor = localMonitor {
      NSEvent.removeMonitor(monitor)
      localMonitor = nil
    }

    isListening = false
    #if DEBUG
      print("HotkeyManager: Stopped listening for global hotkeys")
    #endif
  }

  // MARK: - Event Handling

  @discardableResult
  private func handleKeyEvent(_ event: NSEvent) -> Bool {
    // Check for Cmd+Shift modifier (and exclude other modifiers like Ctrl, Option)
    let requiredFlags: NSEvent.ModifierFlags = [.command, .shift]
    let excludedFlags: NSEvent.ModifierFlags = [.control, .option]
    
    // Must have command and shift
    guard event.modifierFlags.contains(requiredFlags) else { return false }
    
    // Must not have control or option
    guard event.modifierFlags.intersection(excludedFlags).isEmpty else { return false }

    // Get the key character (handling nil keyCharacters)
    guard let characters = event.charactersIgnoringModifiers?.lowercased() else { return false }

    switch characters {
    case "u":
      // Cmd+Shift+U: Unmount all volumes
      #if DEBUG
        print("HotkeyManager: Triggered Unmount All (⌘⇧U)")
      #endif
      DispatchQueue.main.async {
        DriveManager.shared.unmountAllDrives()
      }
      return true

    case "m":
      // Cmd+Shift+M: Mount all volumes
      #if DEBUG
        print("HotkeyManager: Triggered Mount All (⌘⇧M)")
      #endif
      DispatchQueue.main.async {
        DriveManager.shared.mountAllVolumes()
      }
      return true

    default:
      return false
    }
  }
}

// MARK: - UserDefaults Extension

extension UserDefaults {
  @objc dynamic var hotkeysEnabled: Bool {
    return bool(forKey: "hotkeysEnabled")
  }
}
