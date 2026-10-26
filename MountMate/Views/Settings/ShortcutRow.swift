//  Created by homielab.com

import SwiftUI

/// One recordable global shortcut with its conflict and availability warnings.
struct ShortcutRow: View {
  let description: LocalizedStringKey
  let action: HotkeyAction
  /// The action being recorded across all rows; hides the warnings while recording.
  @Binding var recordingShortcut: HotkeyAction?
  let hotkeysEnabled: Bool
  let onConflict: (String) -> Void

  @ObservedObject private var hotkeyManager = HotkeyManager.shared

  var body: some View {
    VStack(alignment: .trailing, spacing: 4) {
      HStack(spacing: 8) {
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        KeyboardShortcutRecorder(
          shortcut: Binding(
            get: { hotkeyManager.shortcut(for: action) },
            set: { if let shortcut = $0 { updateShortcut(shortcut, for: action) } }
          ),
          isRecording: Binding(
            get: { recordingShortcut == action },
            set: { setRecording($0, for: action) }
          )
        )
        .frame(width: 150, height: 26)
        if action == .ejectAll, hotkeyManager.shortcut(for: action) != nil {
          Button {
            hotkeyManager.clearShortcut(for: action)
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help(NSLocalizedString("Clear Shortcut", comment: "Tooltip"))
          .accessibilityLabel(Text("Clear Shortcut"))
        }
      }
      if recordingShortcut == nil {
        if let assigned = hotkeyManager.shortcut(for: action), !assigned.isSafeAsGlobalHotKey {
          // Saved by an older version; not registered (see HotkeyManager).
          shortcutWarning("This shortcut needs ⌘ or ⌃. Click it to record a new one.")
        } else if hotkeyManager.unavailableShortcuts.contains(action) {
          // Registration fails when another app already uses the combination.
          shortcutWarning("This shortcut is used by another app. Choose a different one.")
        }
      }
    }
  }

  private func shortcutWarning(_ message: LocalizedStringKey) -> some View {
    HStack(spacing: 4) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(message)
    }
    .font(.caption)
  }

  private func setRecording(_ recording: Bool, for action: HotkeyAction) {
    recordingShortcut = recording ? action : nil
    if recording {
      hotkeyManager.stopListening()
    } else if hotkeysEnabled {
      hotkeyManager.startListening()
    }
  }

  private func updateShortcut(_ shortcut: HotkeyShortcut, for action: HotkeyAction) {
    let isTaken = HotkeyAction.allCases.contains {
      $0 != action && hotkeyManager.shortcut(for: $0) == shortcut
    }
    guard !isTaken else {
      onConflict(
        NSLocalizedString(
          "This shortcut is already assigned to the other action.",
          comment: "Duplicate keyboard shortcut warning"))
      recordingShortcut = nil
      return
    }

    hotkeyManager.setShortcut(shortcut, for: action)
    recordingShortcut = nil
  }
}
