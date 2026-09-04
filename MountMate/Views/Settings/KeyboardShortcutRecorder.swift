//  Created by homielab.com

import AppKit
import Carbon
import SwiftUI

struct KeyboardShortcutRecorder: NSViewRepresentable {
  @Binding var shortcut: HotkeyShortcut
  @Binding var isRecording: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeNSView(context: Context) -> ShortcutRecorderButton {
    let button = ShortcutRecorderButton()
    button.shortcut = shortcut
    button.isRecording = isRecording

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
  }

  final class Coordinator {
    var parent: KeyboardShortcutRecorder

    init(_ parent: KeyboardShortcutRecorder) {
      self.parent = parent
    }
  }
}

final class ShortcutRecorderButton: NSButton {
  var shortcut = HotkeyShortcut.defaultUnmount {
    didSet { updateTitle() }
  }
  var isRecording = false {
    didSet { updateTitle() }
  }
  var onShortcut: ((HotkeyShortcut) -> Void)?
  var onRecordingChanged: ((Bool) -> Void)?

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
    onRecordingChanged?(true)
    window?.makeFirstResponder(self)
    updateTitle()
  }

  override func keyDown(with event: NSEvent) {
    guard isRecording else {
      super.keyDown(with: event)
      return
    }

    if event.keyCode == UInt16(kVK_Escape) {
      onRecordingChanged?(false)
      return
    }

    let modifiers = event.modifierFlags.intersection(HotkeyShortcut.modifierMask)
    guard !modifiers.isEmpty else {
      NSSound.beep()
      return
    }

    onShortcut?(HotkeyShortcut(keyCode: event.keyCode, modifiers: modifiers))
    onRecordingChanged?(false)
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
    updateTitle()
  }

  private func updateTitle() {
    title =
      isRecording
      ? NSLocalizedString("Press Shortcut…", comment: "Keyboard shortcut recorder prompt")
      : shortcut.displayString
    toolTip = title
    setAccessibilityLabel(
      NSLocalizedString("Keyboard Shortcut", comment: "Keyboard shortcut recorder label"))
  }
}
