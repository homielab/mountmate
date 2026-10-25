//  Created by homielab.com

import SwiftUI

// MARK: - Dynamic Menu Bar Icon

struct MenuBarIconView: View {
  @ObservedObject var driveManager: DriveManager
  @ObservedObject var networkManager = NetworkMountManager.shared
  @AppStorage("showCountInMenuBar") private var showCountInMenuBar = false

  /// Determines the appropriate icon based on current state
  var currentIcon: String {
    // Priority 1: Show busy state during operations
    if driveManager.isUnmountingAll
      || driveManager.busyVolumeIdentifier != nil
      || driveManager.busyEjectingIdentifier != nil
    {
      return "externaldrive.fill.badge.timemachine"
    }

    // Priority 2: Show error state if there's an error
    if driveManager.userActionError != nil {
      return "externaldrive.fill.trianglebadge.exclamationmark"
    }

    // Default: normal icon
    return "externaldrive.fill"
  }

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
    if driveManager.userActionError != nil {
      parts.append(NSLocalizedString("Accessibility Error", comment: "Accessibility value"))
    } else if currentIcon == "externaldrive.fill.badge.timemachine" {
      parts.append(NSLocalizedString("Accessibility Busy", comment: "Accessibility value"))
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
    let icon = currentIcon
    if showCountInMenuBar {
      HStack(spacing: 4) {
        Image(systemName: icon)
        Text("\(mountedCount)").font(.system(size: 13, weight: .medium, design: .rounded))
      }
    } else {
      Image(systemName: icon)
    }
  }
}
