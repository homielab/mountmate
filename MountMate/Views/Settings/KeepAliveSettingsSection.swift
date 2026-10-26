//  Created by homielab.com

import SwiftUI

struct KeepAliveSettingsSection: View {
  @ObservedObject private var keepAliveManager = KeepAliveManager.shared

  static func retryIntervalLabel(_ interval: Double) -> String {
    switch interval {
    case ..<60:
      return PluralizedString.format("retry.seconds", Int(interval))
    default:
      return PluralizedString.format("retry.minutes", Int(interval / 60))
    }
  }

  var body: some View {
    Section {
      Toggle(isOn: $keepAliveManager.isEnabled) {
        Label("Keep Mounts Alive", systemImage: "arrow.triangle.2.circlepath")
      }

      if keepAliveManager.isEnabled {
        Picker(selection: $keepAliveManager.retryInterval) {
          ForEach(KeepAliveManager.allowedRetryIntervals, id: \.self) { interval in
            Text(Self.retryIntervalLabel(interval)).tag(interval)
          }
        } label: {
          Label("Retry Interval", systemImage: "clock.arrow.circlepath")
        }
        .pickerStyle(.menu)

        Toggle(isOn: $keepAliveManager.remountOnNetworkChange) {
          Label("Remount on Network Change", systemImage: "wifi")
        }
        Toggle(isOn: $keepAliveManager.remountOnWake) {
          Label("Reconnect After Sleep", systemImage: "sun.max")
        }
      }
    } header: {
      Label("Keep Alive", systemImage: "bolt.horizontal.circle")
    } footer: {
      Text(
        NSLocalizedString(
          "Keep Alive Footer",
          comment:
            "Keep Alive settings explanation: automatically remounts network shares marked Keep Mounted and volumes marked Keep Mounted when they drop, after network changes, on wake, and at login."
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}
