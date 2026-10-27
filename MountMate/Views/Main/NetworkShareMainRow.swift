//  Created by homielab.com

import SwiftUI

struct NetworkShareMainRow: View {
  let share: NetworkShare
  var isManual: Bool = false
  @ObservedObject var networkManager = NetworkMountManager.shared
  @ObservedObject private var keepAliveManager = KeepAliveManager.shared
  @State private var isWorking = false
  @State private var isHovering = false

  private var isMounted: Bool {
    isManual || networkManager.mountedShareIDs.contains(share.id)
  }

  private var isReconnecting: Bool {
    !isMounted && keepAliveManager.reconnectingShareIDs.contains(share.id)
  }

  private var usage: ShareUsage? {
    isMounted ? networkManager.usageByShareID[share.id] : nil
  }

  private var statusText: String {
    if let usage {
      let formatter = ByteCountFormatter()
      formatter.allowedUnits = [.useGB, .useMB, .useKB, .useTB]
      formatter.countStyle = .file
      return String(
        format: NSLocalizedString(
          "DiskUsageUsedFree", comment: "Disk usage format: used / total (free)"),
        formatter.string(fromByteCount: usage.usedBytes),
        formatter.string(fromByteCount: usage.totalBytes),
        formatter.string(fromByteCount: usage.freeBytes))
    }
    if isMounted { return NSLocalizedString("Mounted", comment: "Status") }
    if keepAliveManager.reconnectingShareIDs.contains(share.id) {
      return NSLocalizedString("Reconnecting…", comment: "Keep-alive reconnect status")
    }
    return NSLocalizedString("Not Mounted", comment: "Status")
  }

  /// Main action of the row: eject a mounted share, mount an unmounted one.
  private func toggleMount() {
    guard !isWorking else { return }
    isWorking = true
    if isMounted {
      NetworkMountManager.shared.unmount(share: share) { success, error in
        isWorking = false
        if !success, let error = error {
          DriveManager.shared.userActionError = AppAlert(
            title: NSLocalizedString("Unmount Failed", comment: "Alert title"),
            message: error, kind: .basic)
        }
      }
    } else {
      NetworkMountManager.shared.mount(share: share) { success, error in
        isWorking = false
        if success {
          NetworkMountManager.shared.openInFinderAfterMounting(share, trigger: .popover)
        }
        if !success, let error = error {
          DriveManager.shared.userActionError = AppAlert(
            title: NSLocalizedString("Mount Failed", comment: "Alert title"), message: error,
            kind: .basic)
        }
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 0) {
        HStack {
          ZStack {
            Image(systemName: "server.rack")
              .font(.body)
              .foregroundStyle(isMounted ? Color.accentColor : Color.secondary.opacity(0.6))
              .overlay(alignment: .bottomTrailing) {
                if usage == nil {
                  // Filled when mounted, hollow when not, so the state does not
                  // depend on colour. The status line below says it in words.
                  Group {
                    if isMounted {
                      Circle().fill(Color.green)
                    } else {
                      Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1)
                    }
                  }
                  .frame(width: 6, height: 6)
                  .offset(x: 2, y: 2)
                  .accessibilityHidden(true)
                }
              }

            if let usage {
              CircularProgressRing(
                progress: usage.percentage,
                color: CircularProgressRing.usageColor(for: usage.percentage),
                lineWidth: 3.0
              ).frame(width: 26, height: 26)
            }
          }
          .frame(width: 24, alignment: .center)
          .padding(.trailing, 8)

          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(share.name)
                .font(.body)
                .bold()
                .foregroundStyle(isMounted ? .primary : .secondary)

              if share.shareProtocol.isDeprecated {
                Text(
                  NSLocalizedString(
                    "Deprecated", comment: "Badge for deprecated share protocol")
                )
                .font(.caption2)
                .bold()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12))
                .clipShape(.rect(cornerRadius: 3))
              }
            }

            Text(statusText)
              .font(.caption)
              .foregroundStyle(.secondary)

            if isReconnecting {
              ReconnectStatusLine(
                nextRetry: { keepAliveManager.nextRetryDate(forShareID: share.id) },
                reconnectNow: { keepAliveManager.sweepNow(resetBackoff: true) })
            }
          }
          Spacer()
        }
        .accessibilityElement(children: .combine)
        .contentShape(Rectangle())
        .onTapGesture {
          if isMounted {
            let path = NetworkMountManager.shared.getMountPoint(for: share)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
          }
        }
        .rowKeyboardNavigation(primaryAction: toggleMount)
        .accessibilityAction(named: Text(isMounted ? "Eject" : "Mount")) { toggleMount() }
        .accessibilityActions {
          if isReconnecting {
            Button("Reconnect Now") { keepAliveManager.sweepNow(resetBackoff: true) }
          }
          if isMounted {
            let path = NetworkMountManager.shared.getMountPoint(for: share)
            Button("Open in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            Button("Copy Path") { MountPointActions.copyPath(path) }
            Button("Open in Terminal") { MountPointActions.openInTerminal(path) }
          }
        }

        Button(action: toggleMount) {
          Label(
            isMounted
              ? NSLocalizedString("Eject", comment: "Action")
              : NSLocalizedString("Mount", comment: "Action"),
            systemImage: isMounted ? "eject.fill" : "play.fill"
          )
          .font(.caption)
          .bold()
          .opacity(isWorking ? 0 : 1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isMounted ? .red : .blue)
        .disabled(isWorking)
        .overlay {
          if isWorking {
            ProgressView().controlSize(.small)
          }
        }
        .help(
          isMounted
            ? NSLocalizedString("Eject", comment: "Tooltip")
            : NSLocalizedString("Mount", comment: "Tooltip")
        )
        .padding(.leading, 8)
      }
      .padding(.vertical, 4)
      .padding(.horizontal, 4)
      .contextMenu {
        if isReconnecting {
          Button {
            keepAliveManager.sweepNow(resetBackoff: true)
          } label: {
            Label("Reconnect Now", systemImage: "arrow.clockwise")
          }
        }
        if isMounted {
          let path = NetworkMountManager.shared.getMountPoint(for: share)
          Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
          } label: {
            Label("Open in Finder", systemImage: "folder")
          }
          Button {
            MountPointActions.copyPath(path)
          } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
          }
          Button {
            MountPointActions.openInTerminal(path)
          } label: {
            Label("Open in Terminal", systemImage: "terminal")
          }
        }
      }
      .background(isHovering ? Color.primary.opacity(0.08) : Color.clear)
      .clipShape(.rect(cornerRadius: 6))
      .onHover { hovering in
        self.isHovering = hovering
      }
    }
  }
}
