//  Created by homielab.com

import AppKit
import Carbon
import Combine
import Foundation

// MARK: - Shortcut Model

struct HotkeyShortcut: Equatable {
  let keyCode: UInt16
  let modifiers: NSEvent.ModifierFlags

  static let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

  // Command-Shift-U belongs to Finder's Go > Utilities command. Option keeps
  // MountMate's default distinct while remaining easy to press.
  static let defaultUnmount = HotkeyShortcut(
    keyCode: UInt16(kVK_ANSI_U), modifiers: [.command, .option, .shift])
  static let defaultMount = HotkeyShortcut(
    keyCode: UInt16(kVK_ANSI_M), modifiers: [.command, .shift])

  init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
    self.keyCode = keyCode
    self.modifiers = modifiers.intersection(Self.modifierMask)
  }

  var displayString: String {
    let modifierString = [
      (NSEvent.ModifierFlags.command, "⌘"),
      (NSEvent.ModifierFlags.option, "⌥"),
      (NSEvent.ModifierFlags.control, "⌃"),
      (NSEvent.ModifierFlags.shift, "⇧"),
    ]
    .compactMap { modifiers.contains($0.0) ? $0.1 : nil }
    .joined()

    return modifierString + Self.keyLabel(for: keyCode)
  }

  static func keyLabel(for keyCode: UInt16) -> String {
    switch keyCode {
    case UInt16(kVK_Return): return "↩"
    case UInt16(kVK_Tab): return "⇥"
    case UInt16(kVK_Space): return "Space"
    case UInt16(kVK_Delete): return "⌫"
    case UInt16(kVK_ForwardDelete): return "⌦"
    case UInt16(kVK_Escape): return "Esc"
    case UInt16(kVK_LeftArrow): return "←"
    case UInt16(kVK_RightArrow): return "→"
    case UInt16(kVK_DownArrow): return "↓"
    case UInt16(kVK_UpArrow): return "↑"
    case UInt16(kVK_Home): return "↖"
    case UInt16(kVK_End): return "↘"
    case UInt16(kVK_PageUp): return "⇞"
    case UInt16(kVK_PageDown): return "⇟"
    case UInt16(kVK_F1): return "F1"
    case UInt16(kVK_F2): return "F2"
    case UInt16(kVK_F3): return "F3"
    case UInt16(kVK_F4): return "F4"
    case UInt16(kVK_F5): return "F5"
    case UInt16(kVK_F6): return "F6"
    case UInt16(kVK_F7): return "F7"
    case UInt16(kVK_F8): return "F8"
    case UInt16(kVK_F9): return "F9"
    case UInt16(kVK_F10): return "F10"
    case UInt16(kVK_F11): return "F11"
    case UInt16(kVK_F12): return "F12"
    default:
      return keyCode == UInt16(kVK_ANSI_A)
        ? "A"
        : keyCode == UInt16(kVK_ANSI_S)
          ? "S"
          : keyCode == UInt16(kVK_ANSI_D)
            ? "D"
            : keyCode == UInt16(kVK_ANSI_F)
              ? "F"
              : keyCode == UInt16(kVK_ANSI_H)
                ? "H"
                : keyCode == UInt16(kVK_ANSI_G)
                  ? "G"
                  : keyCode == UInt16(kVK_ANSI_Z)
                    ? "Z"
                    : keyCode == UInt16(kVK_ANSI_X)
                      ? "X"
                      : keyCode == UInt16(kVK_ANSI_C)
                        ? "C"
                        : keyCode == UInt16(kVK_ANSI_V)
                          ? "V"
                          : keyCode == UInt16(kVK_ANSI_B)
                            ? "B"
                            : keyCode == UInt16(kVK_ANSI_Q)
                              ? "Q"
                              : keyCode == UInt16(kVK_ANSI_W)
                                ? "W"
                                : keyCode == UInt16(kVK_ANSI_E)
                                  ? "E"
                                  : keyCode == UInt16(kVK_ANSI_R)
                                    ? "R"
                                    : keyCode == UInt16(kVK_ANSI_Y)
                                      ? "Y"
                                      : keyCode == UInt16(kVK_ANSI_T)
                                        ? "T"
                                        : keyCode == UInt16(kVK_ANSI_1)
                                          ? "1"
                                          : keyCode == UInt16(kVK_ANSI_2)
                                            ? "2"
                                            : keyCode == UInt16(kVK_ANSI_3)
                                              ? "3"
                                              : keyCode == UInt16(kVK_ANSI_4)
                                                ? "4"
                                                : keyCode == UInt16(kVK_ANSI_6)
                                                  ? "6"
                                                  : keyCode == UInt16(kVK_ANSI_5)
                                                    ? "5"
                                                    : keyCode == UInt16(kVK_ANSI_Equal)
                                                      ? "="
                                                      : keyCode == UInt16(kVK_ANSI_9)
                                                        ? "9"
                                                        : keyCode == UInt16(kVK_ANSI_7)
                                                          ? "7"
                                                          : keyCode == UInt16(kVK_ANSI_Minus)
                                                            ? "-"
                                                            : keyCode == UInt16(kVK_ANSI_8)
                                                              ? "8"
                                                              : keyCode == UInt16(kVK_ANSI_0)
                                                                ? "0"
                                                                : keyCode
                                                                  == UInt16(kVK_ANSI_RightBracket)
                                                                  ? "]"
                                                                  : keyCode == UInt16(kVK_ANSI_O)
                                                                    ? "O"
                                                                    : keyCode == UInt16(kVK_ANSI_U)
                                                                      ? "U"
                                                                      : keyCode
                                                                        == UInt16(
                                                                          kVK_ANSI_LeftBracket)
                                                                        ? "["
                                                                        : keyCode
                                                                          == UInt16(kVK_ANSI_I)
                                                                          ? "I"
                                                                          : keyCode
                                                                            == UInt16(kVK_ANSI_P)
                                                                            ? "P"
                                                                            : keyCode
                                                                              == UInt16(kVK_ANSI_L)
                                                                              ? "L"
                                                                              : keyCode
                                                                                == UInt16(
                                                                                  kVK_ANSI_J)
                                                                                ? "J"
                                                                                : keyCode
                                                                                  == UInt16(
                                                                                    kVK_ANSI_Quote)
                                                                                  ? "'"
                                                                                  : keyCode
                                                                                    == UInt16(
                                                                                      kVK_ANSI_K)
                                                                                    ? "K"
                                                                                    : keyCode
                                                                                      == UInt16(
                                                                                        kVK_ANSI_Semicolon
                                                                                      )
                                                                                      ? ";"
                                                                                      : keyCode
                                                                                        == UInt16(
                                                                                          kVK_ANSI_Backslash
                                                                                        )
                                                                                        ? "\\"
                                                                                        : keyCode
                                                                                          == UInt16(
                                                                                            kVK_ANSI_Comma
                                                                                          )
                                                                                          ? ","
                                                                                          : keyCode
                                                                                            == UInt16(
                                                                                              kVK_ANSI_Slash
                                                                                            )
                                                                                            ? "/"
                                                                                            : keyCode
                                                                                              == UInt16(
                                                                                                kVK_ANSI_N
                                                                                              )
                                                                                              ? "N"
                                                                                              : keyCode
                                                                                                == UInt16(
                                                                                                  kVK_ANSI_M
                                                                                                )
                                                                                                ? "M"
                                                                                                : keyCode
                                                                                                  == UInt16(
                                                                                                    kVK_ANSI_Period
                                                                                                  )
                                                                                                  ? "."
                                                                                                  : "Key \(keyCode)"
    }
  }
}

enum HotkeyAction: Equatable {
  case unmountAll
  case mountAll
}

// MARK: - Hotkey Manager

/// Manages global keyboard shortcuts for mounting and unmounting volumes.
/// Uses NSEvent's global monitor to listen for key events system-wide.
/// Note: Requires Accessibility permissions in System Preferences > Privacy & Security > Accessibility
class HotkeyManager: ObservableObject {
  static let shared = HotkeyManager()

  @Published private(set) var unmountShortcut: HotkeyShortcut
  @Published private(set) var mountShortcut: HotkeyShortcut
  @Published var isListening = false

  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var cancellables = Set<AnyCancellable>()

  private init() {
    unmountShortcut = Self.loadShortcut(
      keyCodeKey: "hotkeyUnmountKeyCode",
      modifiersKey: "hotkeyUnmountModifiers",
      fallback: .defaultUnmount)
    mountShortcut = Self.loadShortcut(
      keyCodeKey: "hotkeyMountKeyCode",
      modifiersKey: "hotkeyMountModifiers",
      fallback: .defaultMount)
    setupObserver()
  }

  deinit {
    stopListening()
  }

  // MARK: - Setup

  private func setupObserver() {
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

    // Retry after the user returns from System Settings where they may have
    // granted Accessibility access.
    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard UserDefaults.standard.bool(forKey: "hotkeysEnabled") else { return }
        self?.startListening()
      }
      .store(in: &cancellables)

    if UserDefaults.standard.bool(forKey: "hotkeysEnabled") {
      startListening()
    }
  }

  private static func loadShortcut(
    keyCodeKey: String, modifiersKey: String, fallback: HotkeyShortcut
  ) -> HotkeyShortcut {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: keyCodeKey) != nil,
      defaults.object(forKey: modifiersKey) != nil
    else { return fallback }

    let keyCode = UInt16(clamping: defaults.integer(forKey: keyCodeKey))
    let modifiers = NSEvent.ModifierFlags(
      rawValue: UInt(defaults.integer(forKey: modifiersKey)))
    return HotkeyShortcut(keyCode: keyCode, modifiers: modifiers)
  }

  // MARK: - Shortcut Configuration

  func shortcut(for action: HotkeyAction) -> HotkeyShortcut {
    switch action {
    case .unmountAll: return unmountShortcut
    case .mountAll: return mountShortcut
    }
  }

  func setShortcut(_ shortcut: HotkeyShortcut, for action: HotkeyAction) {
    let normalizedShortcut = HotkeyShortcut(
      keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
    let defaults = UserDefaults.standard

    switch action {
    case .unmountAll:
      unmountShortcut = normalizedShortcut
      defaults.set(Int(normalizedShortcut.keyCode), forKey: "hotkeyUnmountKeyCode")
      defaults.set(Int(normalizedShortcut.modifiers.rawValue), forKey: "hotkeyUnmountModifiers")
    case .mountAll:
      mountShortcut = normalizedShortcut
      defaults.set(Int(normalizedShortcut.keyCode), forKey: "hotkeyMountKeyCode")
      defaults.set(Int(normalizedShortcut.modifiers.rawValue), forKey: "hotkeyMountModifiers")
    }

    guard UserDefaults.standard.bool(forKey: "hotkeysEnabled") else { return }
    stopListening()
    startListening()
  }

  // MARK: - Accessibility Check

  /// Check if the app has accessibility permissions without displaying a prompt.
  static func checkAccessibilityPermissions() -> Bool {
    AXIsProcessTrustedWithOptions(nil)
  }

  // MARK: - Listening

  func startListening() {
    guard globalMonitor == nil else { return }

    // Startup checks must remain silent. The settings UI handles the explicit
    // user prompt when shortcuts are enabled without Accessibility access.
    guard HotkeyManager.checkAccessibilityPermissions() else {
      isListening = false
      #if DEBUG
        print("HotkeyManager: Accessibility permissions are not granted")
      #endif
      return
    }

    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      self?.handleKeyEvent(event)
    }

    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if self?.handleKeyEvent(event) == true {
        return nil  // Consume the event
      }
      return event  // Pass through
    }

    isListening = true
    #if DEBUG
      print(
        "HotkeyManager: Started listening (Unmount: \(unmountShortcut.displayString), Mount: \(mountShortcut.displayString))"
      )
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
    if matches(event, shortcut: unmountShortcut) {
      #if DEBUG
        print("HotkeyManager: Triggered Unmount All (\(unmountShortcut.displayString))")
      #endif
      DispatchQueue.main.async {
        DriveManager.shared.unmountAllDrives()
      }
      return true
    }

    if matches(event, shortcut: mountShortcut) {
      #if DEBUG
        print("HotkeyManager: Triggered Mount All (\(mountShortcut.displayString))")
      #endif
      DispatchQueue.main.async {
        DriveManager.shared.mountAllVolumes()
      }
      return true
    }

    return false
  }

  private func matches(_ event: NSEvent, shortcut: HotkeyShortcut) -> Bool {
    guard event.keyCode == shortcut.keyCode else { return false }
    let modifiers = event.modifierFlags.intersection(HotkeyShortcut.modifierMask)
    return modifiers == shortcut.modifiers
  }
}

// MARK: - UserDefaults Extension

extension UserDefaults {
  @objc dynamic var hotkeysEnabled: Bool {
    bool(forKey: "hotkeysEnabled")
  }
}
