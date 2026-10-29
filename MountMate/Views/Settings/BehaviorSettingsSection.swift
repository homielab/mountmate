//  Created by homielab.com

import SwiftUI

struct BehaviorSettingsSection: View {
  @EnvironmentObject var launchManager: LaunchAtLoginManager
  @EnvironmentObject var diskMounter: DiskMounter
  @ObservedObject private var persistence = PersistenceManager.shared
  @ObservedObject private var notificationManager = NotificationManager.shared

  @AppStorage("ejectOnSleepEnabled") private var ejectOnSleepEnabled = false
  @AppStorage(ScreenLockRules.enabledKey) private var unmountOnLockEnabled = false
  @AppStorage(WakeRemountManager.enabledKey) private var remountOnWakeEnabled = true
  @AppStorage(LowSpaceRules.enabledKey) private var lowSpaceEnabled = true
  @AppStorage(UnexpectedRemovalTracker.enabledKey) private var unexpectedRemovalEnabled = false
  @AppStorage(OpenAfterMountRules.enabledKey) private var openFinderAfterMount = false
  @AppStorage(LowSpaceRules.thresholdKey) private var lowSpacePercent = LowSpaceRules.defaultPercent

  /// One line under "Also Block at Startup" saying what is in effect, so the
  /// user can see the result after the password prompt closes.
  @ViewBuilder private var startupBlockStatus: some View {
    if persistence.isUpdatingStartupRules {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Updating startup rules…")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    } else if persistence.blockAtStartup {
      if persistence.startupRuleCount > 0 {
        Label(
          PluralizedString.format("startup.blocked.count", persistence.startupRuleCount),
          systemImage: "checkmark.circle.fill"
        )
        .font(.caption)
        .foregroundStyle(.green)
      } else {
        Text(
          "No disk has a startup rule yet. Blocked disks get one the next time they're connected."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  var body: some View {
    Section {
      Toggle(isOn: $launchManager.isEnabled) {
        Label("Start MountMate at Login", systemImage: "arrow.right.circle")
      }
      if launchManager.requiresApproval {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
          Text("Allow MountMate in Login Items to start it at login.")
            .font(.caption)
          Spacer()
          Button("Open Login Items") { launchManager.openLoginItemsSettings() }
            .controlSize(.small)
        }
      }
      if let loginError = launchManager.lastError {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
          Text(
            String(
              format: NSLocalizedString("Login Item Error", comment: "Login item failure"),
              loginError)
          )
          .font(.caption)
          Spacer()
          Button("Open Login Items") { launchManager.openLoginItemsSettings() }
            .controlSize(.small)
        }
      }
      Toggle(isOn: $diskMounter.blockUSBAutoMount) {
        Label("Block USB Auto-Mount", systemImage: "hand.raised.slash")
      }
      Toggle(isOn: $diskMounter.allowRequestedMounts) {
        Label("Allow Other Apps to Mount Blocked Disks", systemImage: "app.badge.checkmark")
      }
      .help(
        "Blocked disks are only stopped from mounting automatically when plugged in or at login. Apps such as backup tools can still mount them when needed."
      )
      Toggle(
        isOn: Binding(
          get: { persistence.blockAtStartup },
          set: { persistence.setBlockAtStartup($0) })
      ) {
        Label("Also Block at Startup (Requires Admin Password)", systemImage: "power")
      }
      .help(
        "Adds a system rule (/etc/fstab) for each blocked disk so macOS never mounts it at startup, even before MountMate opens. You can still mount it yourself. Rules are added while the disk is connected."
      )
      startupBlockStatus
      Toggle(isOn: $openFinderAfterMount) {
        Label("Open in Finder after mounting", systemImage: "macwindow")
      }
      .help(
        "Opens a Finder window when a volume or share you mount from the menu, with Mount All or with a Shortcuts action is ready. Disks mounted automatically, by Keep Alive or after wake do not open a window."
      )
      Toggle(isOn: $ejectOnSleepEnabled) {
        Label("Unmount All Disks on Sleep", systemImage: "moon.zzz")
      }
      Toggle(isOn: $unmountOnLockEnabled) {
        Label("Unmount All Disks When the Screen Locks", systemImage: "lock")
      }
      .help(
        "Unmounts every removable disk when the screen locks, so no drive stays open while you are away. Protected volumes, volumes kept mounted by Keep Alive and volumes in use stay mounted. Nothing is forced."
      )
      if ejectOnSleepEnabled || unmountOnLockEnabled {
        Toggle(isOn: $remountOnWakeEnabled) {
          Label("Mount Again on Wake", systemImage: "sunrise")
        }
        .help(
          "Mounts the disks that were unmounted before sleep or when the screen locked again when the Mac wakes up or you unlock it. Disks you unmounted yourself, disks that are not connected and blocked disks stay unmounted."
        )
      }
      Toggle(isOn: $notificationManager.isEnabled) {
        Label("Notifications", systemImage: "bell.badge")
      }
      .help(
        "Notifies you when Keep Alive cannot reconnect a mount and when it is back, when a blocked disk could not be unmounted, when unmounting before sleep took too long, and when a volume is unmounted because it was idle."
      )
      if notificationManager.isEnabled {
        Toggle(isOn: $unexpectedRemovalEnabled) {
          Label(
            "Notify when a disk is disconnected without ejecting",
            systemImage: "externaldrive.badge.xmark")
        }
        .help(
          "Tells you when a USB drive or memory card is pulled out while one of its volumes is still mounted, so you can check that copies finished. Disk images, internal disks and Time Machine volumes are not watched."
        )
      }
      Toggle(isOn: $lowSpaceEnabled) {
        Label(
          "Warn when a volume is almost full", systemImage: "externaldrive.badge.exclamationmark")
      }
      .help(
        "Marks a mounted volume that is nearly full, and with Notifications on tells you once each time it is mounted. Nothing is unmounted or deleted."
      )
      if lowSpaceEnabled {
        Picker(selection: $lowSpacePercent) {
          ForEach(LowSpaceRules.percentChoices, id: \.self) { percent in
            Text(verbatim: "\(percent)%").tag(percent)
          }
        } label: {
          Label("Almost full from", systemImage: "gauge.with.dots.needle.67percent")
        }
      }
      if notificationManager.isEnabled, notificationManager.isDeniedBySystem {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
          Text("Notifications for MountMate are turned off in System Settings.")
            .font(.caption)
          Spacer()
          Button("Open Notification Settings") {
            notificationManager.openSystemNotificationSettings()
          }
          .controlSize(.small)
        }
      }
    } header: {
      Label("Behavior", systemImage: "gearshape")
    }
  }
}
