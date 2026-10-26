//  Created by homielab.com

import SwiftUI

enum DiagnosticsCopyState: Equatable {
  case idle, collecting, copied, failed
}

struct LogsSettingsSection: View {
  @State private var diagnosticsState: DiagnosticsCopyState = .idle

  var body: some View {
    Section {
      LabeledContent {
        HStack(spacing: 8) {
          switch diagnosticsState {
          case .idle:
            EmptyView()
          case .collecting:
            ProgressView().controlSize(.small)
            Text("Collecting…")
          case .copied:
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green)
              .accessibilityHidden(true)
            Text("Copied")
          case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
              .accessibilityHidden(true)
            Text("Could not read the log")
          }
          Button("Copy Diagnostics") { copyDiagnostics() }
            .controlSize(.small)
            .disabled(diagnosticsState == .collecting)
        }
        .font(.caption)
      } label: {
        Label("Diagnostics", systemImage: "stethoscope")
      }
      .help(
        "Copies MountMate's version, macOS version, your on/off settings and the last hour of its log. Paste it into a bug report. It has no passwords, paths or disk and share names."
      )
    } header: {
      Label("Logs", systemImage: "doc.text.magnifyingglass")
    }
  }

  private func copyDiagnostics() {
    diagnosticsState = .collecting
    let failing = (DriveManager.shared.physicalDisks ?? []).filter { $0.smartStatus == .failing }
    Task {
      let copied = await DiagnosticsReport.copyToPasteboard(failingDiskCount: failing.count)
      diagnosticsState = copied ? .copied : .failed
    }
  }
}
