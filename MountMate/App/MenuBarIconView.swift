//  Created by homielab.com

import SwiftUI

// MARK: - Menu Bar Icon State

/// What the menu bar icon shows. Priority: error, busy, reconnecting, idle.
enum MenuBarIconState: Equatable {
  case idle
  case busy
  case reconnecting
  case error

  init(
    isUnmountingAll: Bool, busyVolume: Bool, busyEject: Bool, error: Bool, reconnecting: Bool
  ) {
    if error {
      self = .error
    } else if isUnmountingAll || busyVolume || busyEject {
      self = .busy
    } else if reconnecting {
      self = .reconnecting
    } else {
      self = .idle
    }
  }

  var symbolName: String {
    switch self {
    case .idle: return "externaldrive.fill"
    case .busy: return "externaldrive.fill.badge.timemachine"
    case .reconnecting: return "externaldrive.fill.badge.wifi"
    case .error: return "externaldrive.fill.trianglebadge.exclamationmark"
    }
  }

  /// Localizable key spoken by VoiceOver; nil when idle.
  var accessibilityKey: String? {
    switch self {
    case .idle: return nil
    case .busy: return "Accessibility Busy"
    case .reconnecting: return "Accessibility Reconnecting"
    case .error: return "Accessibility Error"
    }
  }
}

// MARK: - Dynamic Menu Bar Icon

struct MenuBarIconView: View {
  @ObservedObject var driveManager: DriveManager
  @ObservedObject var networkManager = NetworkMountManager.shared
  @ObservedObject var keepAlive = KeepAliveManager.shared
  @ObservedObject var updater: UpdaterController
  @AppStorage("showCountInMenuBar") private var showCountInMenuBar = false

  /// The state shown by the icon, from the manager flags.
  var iconState: MenuBarIconState {
    MenuBarIconState(
      isUnmountingAll: driveManager.isUnmountingAll,
      busyVolume: driveManager.busyVolumeIdentifier != nil,
      busyEject: driveManager.busyEjectingIdentifier != nil,
      error: driveManager.userActionError != nil,
      reconnecting: !keepAlive.reconnectingShareIDs.isEmpty
        || !keepAlive.reconnectingVolumeIDs.isEmpty)
  }

  var currentIcon: String { iconState.symbolName }

  var mountedCount: Int {
    let physicalCount = (driveManager.physicalDisks ?? [])
      .flatMap { $0.partitions + $0.containers.flatMap { $0.volumes } }
      .filter { $0.isMounted && $0.category == .user && !$0.isProtected }.count

    let networkCount = networkManager.mountedShareIDs.count
    let manualNetworkCount = networkManager.manuallyConnectedShares.count
    return physicalCount + networkCount + manualNetworkCount
  }

  /// Spoken by VoiceOver: the icon and the count are one element, so the count is a value, not a label.
  var accessibilityStatus: String {
    var parts = [PluralizedString.format("menubar.mounted.count", mountedCount)]
    if let key = iconState.accessibilityKey {
      parts.append(NSLocalizedString(key, comment: "Accessibility value"))
    }
    if updater.reminder.hasPendingUpdate {
      parts.append(
        NSLocalizedString("Accessibility Update Available", comment: "Accessibility value"))
    }
    return parts.joined(separator: ", ")
  }

  var body: some View {
    iconContent
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text("MountMate"))
      .accessibilityValue(Text(accessibilityStatus))
  }

  @ViewBuilder
  private var iconContent: some View {
    if showCountInMenuBar {
      HStack(spacing: 4) {
        iconImage
        Text("\(mountedCount)").font(.system(size: 13, weight: .medium, design: .rounded))
      }
    } else {
      iconImage
    }
  }

  /// The state symbol, with a dot while an update is waiting for the user.
  private var iconImage: Image {
    let icon = currentIcon
    if updater.reminder.hasPendingUpdate, let badged = BadgedMenuBarIcon.image(symbolName: icon) {
      return Image(nsImage: badged)
    }
    return Image(systemName: icon)
  }
}
