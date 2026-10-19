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

enum HotkeyAction: Hashable, CaseIterable {
  case unmountAll
  case mountAll

  /// Carbon hot key ID (EventHotKeyID.id).
  fileprivate var hotKeyID: UInt32 {
    switch self {
    case .unmountAll: return 1
    case .mountAll: return 2
    }
  }

  fileprivate init?(hotKeyID: UInt32) {
    guard let action = Self.allCases.first(where: { $0.hotKeyID == hotKeyID }) else {
      return nil
    }
    self = action
  }
}

extension HotkeyShortcut {
  /// Carbon hot keys take the keystroke away from every other app, so a
  /// shortcut must include ⌘ or ⌃. Without them (e.g. ⌥E or ⇧A) it would
  /// block typing characters such as "é" or "A" everywhere.
  var isSafeAsGlobalHotKey: Bool {
    !modifiers.isDisjoint(with: [.command, .control])
  }

  /// The modifiers in Carbon's format, for `RegisterEventHotKey`.
  var carbonModifiers: UInt32 {
    var flags: UInt32 = 0
    if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
    if modifiers.contains(.option) { flags |= UInt32(optionKey) }
    if modifiers.contains(.control) { flags |= UInt32(controlKey) }
    if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
    return flags
  }
}

// MARK: - Hotkey Manager

/// Manages global keyboard shortcuts for mounting and unmounting volumes.
///
/// Uses Carbon hot keys (`RegisterEventHotKey`): they need no Accessibility
/// permission, and the system delivers a registered combination only to
/// MountMate, so it no longer also reaches the frontmost app.
class HotkeyManager: ObservableObject {
  static let shared = HotkeyManager()

  /// Signature of MountMate's hot keys ("MMHK").
  fileprivate static let hotKeySignature: OSType = 0x4D4D_484B

  @Published private(set) var unmountShortcut: HotkeyShortcut
  @Published private(set) var mountShortcut: HotkeyShortcut
  @Published var isListening = false
  /// Actions whose shortcut could not be registered while listening,
  /// usually because another app already uses the combination.
  @Published private(set) var unavailableShortcuts: Set<HotkeyAction> = []

  private var hotKeyRefs: [HotkeyAction: EventHotKeyRef] = [:]
  private var eventHandlerRef: EventHandlerRef?
  /// Hot keys currently held down. Used to ignore auto-repeat, so holding a
  /// shortcut runs its action once.
  private var pressedActions: Set<HotkeyAction> = []
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
    if let eventHandlerRef {
      RemoveEventHandler(eventHandlerRef)
    }
  }

  // MARK: - Setup

  private func setupObserver() {
    // Also fires right away with the current value.
    UserDefaults.standard.publisher(for: \.hotkeysEnabled)
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] enabled in
        if enabled {
          self?.startListening()
        } else {
          self?.stopListening()
        }
      }
      .store(in: &cancellables)
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

  // MARK: - Listening

  /// Registers both shortcuts. Main thread only.
  func startListening() {
    guard !isListening else { return }
    installEventHandlerIfNeeded()

    var failed: Set<HotkeyAction> = []
    for action in HotkeyAction.allCases {
      let combination = self.shortcut(for: action)
      // Shortcuts saved by older versions may lack ⌘/⌃. Settings asks the
      // user to record a new one; never register them.
      guard combination.isSafeAsGlobalHotKey else {
        print(
          "⚠️ HotkeyManager: Not registering \(combination.displayString); it needs ⌘ or ⌃.")
        continue
      }
      var ref: EventHotKeyRef?
      // Exclusive, so a combination another app already registered fails
      // here (and is reported in Settings) instead of silently not firing.
      let status = RegisterEventHotKey(
        UInt32(combination.keyCode),
        combination.carbonModifiers,
        EventHotKeyID(signature: Self.hotKeySignature, id: action.hotKeyID),
        GetApplicationEventTarget(),
        OptionBits(kEventHotKeyExclusive),
        &ref)
      if status == noErr, let ref {
        hotKeyRefs[action] = ref
      } else {
        failed.insert(action)
        print(
          "⚠️ HotkeyManager: Could not register \(combination.displayString) (status \(status)); it may be used by another app."
        )
      }
    }

    unavailableShortcuts = failed
    isListening = true
    #if DEBUG
      print(
        "HotkeyManager: Started listening (Unmount: \(unmountShortcut.displayString), Mount: \(mountShortcut.displayString))"
      )
    #endif
  }

  /// Unregisters both shortcuts. Main thread only.
  func stopListening() {
    for ref in hotKeyRefs.values {
      UnregisterEventHotKey(ref)
    }
    hotKeyRefs.removeAll()
    pressedActions.removeAll()
    unavailableShortcuts = []
    isListening = false
    #if DEBUG
      print("HotkeyManager: Stopped listening for global hotkeys")
    #endif
  }

  private func installEventHandlerIfNeeded() {
    guard eventHandlerRef == nil else { return }
    var eventTypes = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    let status = InstallEventHandler(
      GetApplicationEventTarget(), hotKeyEventHandler, 2, &eventTypes, nil,
      &eventHandlerRef)
    if status != noErr {
      print("⚠️ HotkeyManager: Could not install the hot key handler (status \(status)).")
    }
  }

  // MARK: - Event Handling

  /// Called on the main thread for MountMate's hot key events.
  fileprivate func handleHotKey(_ action: HotkeyAction, pressed: Bool) {
    guard pressed else {
      pressedActions.remove(action)
      return
    }
    // Still held: an auto-repeat of the same press.
    guard pressedActions.insert(action).inserted else { return }

    switch action {
    case .unmountAll:
      #if DEBUG
        print("HotkeyManager: Triggered Unmount All (\(unmountShortcut.displayString))")
      #endif
      DriveManager.shared.unmountAllDrives()
    case .mountAll:
      #if DEBUG
        print("HotkeyManager: Triggered Mount All (\(mountShortcut.displayString))")
      #endif
      DriveManager.shared.mountAllVolumes()
    }
  }
}

/// Carbon event handler for hot key presses and releases. A C function
/// pointer, so it cannot capture context; it forwards to the shared manager.
private let hotKeyEventHandler: EventHandlerUPP = { _, event, _ in
  guard let event else { return OSStatus(eventNotHandledErr) }

  var hotKeyID = EventHotKeyID()
  let status = GetEventParameter(
    event,
    EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotKeyID)
  guard status == noErr, hotKeyID.signature == HotkeyManager.hotKeySignature,
    let action = HotkeyAction(hotKeyID: hotKeyID.id)
  else { return OSStatus(eventNotHandledErr) }

  let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
  HotkeyManager.shared.handleHotKey(action, pressed: pressed)
  return noErr
}

// MARK: - UserDefaults Extension

extension UserDefaults {
  @objc dynamic var hotkeysEnabled: Bool {
    bool(forKey: "hotkeysEnabled")
  }
}
