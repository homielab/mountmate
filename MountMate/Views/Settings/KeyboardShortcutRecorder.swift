//  Created by homielab.com

import AppKit
import Carbon
import SwiftUI

struct KeyboardShortcutRecorder: NSViewRepresentable {
  @Binding var shortcut: HotkeyShortcut?
  @Binding var isRecording: Bool
  /// VoiceOver label, naming the action the shortcut runs.
  let accessibilityName: String

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeNSView(context: Context) -> ShortcutRecorderButton {
    let button = ShortcutRecorderButton()
    button.shortcut = shortcut
    button.isRecording = isRecording
    button.recorderLabel = accessibilityName

    let coordinator = context.coordinator
    button.onShortcut = { newShortcut in
      coordinator.parent.shortcut = newShortcut
      coordinator.parent.isRecording = false
    }
    button.onRecordingChanged = { recording in
      coordinator.parent.isRecording = recording
    }
    return button
  }

  func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
    context.coordinator.parent = self
    nsView.shortcut = shortcut
    nsView.isRecording = isRecording
    nsView.recorderLabel = accessibilityName
  }

  final class Coordinator {
    var parent: KeyboardShortcutRecorder

    init(_ parent: KeyboardShortcutRecorder) {
      self.parent = parent
    }
  }
}

final class ShortcutRecorderButton: NSButton {
  var shortcut: HotkeyShortcut? {
    didSet { updateTitle() }
  }
  var isRecording = false {
    didSet { updateTitle() }
  }
  var recorderLabel = "" {
    didSet { updateTitle() }
  }
  var onShortcut: ((HotkeyShortcut) -> Void)?
  var onRecordingChanged: ((Bool) -> Void)?

  private var layoutObserver: NSObjectProtocol?

  override var acceptsFirstResponder: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configure()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }

  override func mouseDown(with event: NSEvent) {
    startRecording()
  }

  /// VoiceOver's press (VO-Space) starts recording like a click.
  override func accessibilityPerformPress() -> Bool {
    startRecording()
    return true
  }

  /// Also the button's action, so Space on the focused button records.
  @objc private func startRecording() {
    onRecordingChanged?(true)
    window?.makeFirstResponder(self)
    updateTitle()
  }

  override func keyDown(with event: NSEvent) {
    guard isRecording else {
      if Self.startKeyCodes.contains(Int(event.keyCode)) {
        startRecording()
      } else {
        super.keyDown(with: event)
      }
      return
    }

    if event.keyCode == UInt16(kVK_Escape) {
      onRecordingChanged?(false)
      return
    }

    let modifiers = event.modifierFlags.intersection(HotkeyShortcut.modifierMask)
    let shortcut = HotkeyShortcut(keyCode: event.keyCode, modifiers: modifiers)
    // Global shortcuts must include ⌘ or ⌃ (see `isSafeAsGlobalHotKey`).
    guard shortcut.isSafeAsGlobalHotKey else {
      NSSound.beep()
      return
    }
    guard !shortcut.isReservedBySystem else {
      NSSound.beep()
      FeedbackHUD.show(
        HotkeyManager.reservedShortcutMessage(shortcut), systemImage: "keyboard", tint: .warning)
      return
    }

    onShortcut?(shortcut)
    onRecordingChanged?(false)
  }

  /// While recording, ⌘-combinations come here before keyDown; handle them
  /// so ⌘Q or ⌘W are recorded (or refused) instead of quitting or closing.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard isRecording, window?.firstResponder === self else {
      return super.performKeyEquivalent(with: event)
    }
    keyDown(with: event)
    return true
  }

  override func resignFirstResponder() -> Bool {
    if isRecording {
      onRecordingChanged?(false)
    }
    return super.resignFirstResponder()
  }

  private func configure() {
    bezelStyle = .rounded
    isBordered = true
    focusRingType = .default
    setButtonType(.momentaryPushIn)
    target = self
    action = #selector(startRecording)
    updateTitle()
    layoutObserver = NotificationCenter.default.addObserver(
      forName: .keyboardLayoutDidChange, object: nil, queue: .main
    ) { [weak self] _ in self?.updateTitle() }
  }

  deinit {
    if let layoutObserver { NotificationCenter.default.removeObserver(layoutObserver) }
  }

  /// Space, Return and keypad Enter start recording on the focused button.
  private static let startKeyCodes: Set<Int> = [kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter]

  private func updateTitle() {
    title =
      isRecording
      ? NSLocalizedString("Press Shortcut…", comment: "Keyboard shortcut recorder prompt")
      : (shortcut?.displayString
        ?? NSLocalizedString("Not Set", comment: "Keyboard shortcut recorder: no shortcut assigned"))
    toolTip = title
    setAccessibilityLabel(AccessibilityLabels.shortcutRecorder(name: recorderLabel))
    setAccessibilityValue(title)
  }
}
