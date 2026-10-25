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

  /// Label for a key code. Special keys keep their symbols; character keys follow
  /// the current keyboard layout (AZERTY, Dvorak, Cyrillic…), falling back to the
  /// US layout when the system cannot translate the key.
  static func keyLabel(
    for keyCode: UInt16, layout: KeyboardLayoutProviding = SystemKeyboardLayout.shared
  ) -> String {
    if let special = specialKeyLabels[Int(keyCode)] { return special }
    if let character = layout.character(for: keyCode) { return character.uppercased() }
    return usKeyLabels[Int(keyCode)] ?? "Key \(keyCode)"
  }

  private static let specialKeyLabels: [Int: String] = [
    kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
    kVK_ForwardDelete: "⌦", kVK_Escape: "Esc", kVK_LeftArrow: "←", kVK_RightArrow: "→",
    kVK_DownArrow: "↓", kVK_UpArrow: "↑", kVK_Home: "↖", kVK_End: "↘",
    kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
  ]

  /// US layout labels, used when the current layout cannot be read.
  static let usKeyLabels: [Int: String] = [
    kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
    kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
    kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
    kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
    kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
    kVK_ANSI_Z: "Z",
    kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
    kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
    kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-", kVK_ANSI_RightBracket: "]",
    kVK_ANSI_LeftBracket: "[", kVK_ANSI_Quote: "'", kVK_ANSI_Semicolon: ";",
    kVK_ANSI_Backslash: "\\", kVK_ANSI_Comma: ",", kVK_ANSI_Slash: "/",
    kVK_ANSI_Period: ".", kVK_ANSI_Grave: "`",
  ]
}

// MARK: - Keyboard layout

/// Translates a virtual key code to the character the current layout prints on it.
protocol KeyboardLayoutProviding {
  func character(for keyCode: UInt16) -> String?
}

extension Notification.Name {
  /// Posted on the main queue after the selected keyboard input source changed.
  static let keyboardLayoutDidChange = Notification.Name("MountMateKeyboardLayoutDidChange")
}

/// Reads the selected keyboard layout through Text Input Sources and `UCKeyTranslate`.
final class SystemKeyboardLayout: KeyboardLayoutProviding {
  static let shared = SystemKeyboardLayout()

  private let lock = NSLock()
  private var layoutData: Data?
  private var loaded = false
  private var observer: NSObjectProtocol?

  private init() {
    observer = DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
      object: nil, queue: .main
    ) { [weak self] _ in
      self?.invalidate()
      Log.hotkey.debug("Keyboard input source changed; shortcut labels refreshed")
      NotificationCenter.default.post(name: .keyboardLayoutDidChange, object: nil)
    }
  }

  deinit {
    if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
  }

  private func invalidate() {
    lock.lock()
    loaded = false
    layoutData = nil
    lock.unlock()
  }

  private func currentLayoutData() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    if loaded { return layoutData }
    loaded = true
    // The selected layout, or the layout behind the selected input method (Pinyin, Kana…).
    let source =
      TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
    if let source, let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
      layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    }
    if layoutData == nil {
      Log.hotkey.debug("No Unicode key layout data; falling back to the US labels")
    }
    return layoutData
  }

  func character(for keyCode: UInt16) -> String? {
    guard let data = currentLayoutData() else { return nil }
    return Self.translate(keyCode: keyCode, layoutData: data)
  }

  /// Character printed by `keyCode` without modifiers; nil for dead keys and non-printing results.
  static func translate(keyCode: UInt16, layoutData: Data) -> String? {
    layoutData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> String? in
      guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
      else { return nil }
      var deadKeyState: UInt32 = 0
      var chars = [UniChar](repeating: 0, count: 4)
      var length = 0
      let status = UCKeyTranslate(
        layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
      guard status == noErr, length > 0 else { return nil }
      let string = String(utf16CodeUnits: chars, count: length)
      guard let scalar = string.unicodeScalars.first,
        !CharacterSet.controlCharacters.contains(scalar),
        !CharacterSet.whitespacesAndNewlines.contains(scalar)
      else { return nil }
      return string
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
        Log.hotkey.error(
          "Not registering \(combination.displayString, privacy: .public); it needs ⌘ or ⌃.")
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
        Log.hotkey.error(
          "Could not register \(combination.displayString, privacy: .public) (status \(status, privacy: .public)); it may be used by another app."
        )
      }
    }

    unavailableShortcuts = failed
    isListening = true
    #if DEBUG
      Log.hotkey.info(
        "Started listening (Unmount: \(self.unmountShortcut.displayString, privacy: .public), Mount: \(self.mountShortcut.displayString, privacy: .public))"
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
      Log.hotkey.info("Stopped listening for global hotkeys")
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
      Log.hotkey.error(
        "Could not install the hot key handler (status \(status, privacy: .public)).")
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
        Log.hotkey.notice(
          "Triggered Unmount All (\(self.unmountShortcut.displayString, privacy: .public))")
      #endif
      DriveManager.shared.unmountAllDrives()
    case .mountAll:
      #if DEBUG
        Log.hotkey.notice(
          "Triggered Mount All (\(self.mountShortcut.displayString, privacy: .public))")
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
