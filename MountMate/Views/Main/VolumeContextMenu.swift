//  Created by homielab.com

import SwiftUI

/// The right-click menu of a volume row. What to show comes from
/// `VolumeMenuRules`; the items only run the actions.
struct VolumeContextMenu: View {
  let volume: Volume
  let state: VolumeRowState
  /// Opens or closes the inline custom mount point editor of this row.
  let toggleCustomMountPointEditor: () -> Void

  // Used for actions only.
  private var manager: DriveManager { DriveManager.shared }
  private var persistence: PersistenceManager { PersistenceManager.shared }
  private var rules: VolumeMenuRules { VolumeMenuRules(volume: volume, state: state) }

  var body: some View {
    let rules = rules
    if rules.showsReconnectNow {
      Button {
        KeepAliveManager.shared.sweepNow(resetBackoff: true)
      } label: {
        Label("Reconnect Now", systemImage: "arrow.clockwise")
      }
    }
    if rules.showsMountedActions {
      Button {
        manager.unmount(volume: volume)
      } label: {
        Label("Unmount", systemImage: "minus.circle")
      }
      .disabled(rules.disablesVolumeOperations)
      Button {
        if let path = volume.mountPoint {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
      } label: {
        Label("Open in Finder", systemImage: "folder")
      }
      if rules.showsPathActions, let path = volume.mountPoint {
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
      if rules.showsVerifyVolume {
        Button {
          manager.verifyVolume(volume)
        } label: {
          Label(
            rules.isVerifying
              ? NSLocalizedString(
                "Verifying…", comment: "Volume context menu: verification in progress")
              : NSLocalizedString(
                "Verify Volume", comment: "Volume context menu: verify volume action"),
            systemImage: "checkmark.shield")
        }
        .disabled(rules.isVerifying || rules.disablesVolumeOperations)
      }
      if rules.showsRename {
        Button {
          manager.promptRenameVolume(volume)
        } label: {
          Label(
            NSLocalizedString(
              "Rename Volume…", comment: "Volume context menu: rename volume action"),
            systemImage: "pencil")
        }
        .disabled(rules.isVerifying || rules.disablesVolumeOperations)
      }
      Divider()
      protectItem(rules.protectAction)
    }
    if rules.showsMountActions {
      Button {
        manager.mount(volume: volume, trigger: .popover)
      } label: {
        Label("Mount", systemImage: "plus.circle")
      }
      .disabled(rules.disablesVolumeOperations)
      Button {
        manager.mount(volume: volume, readOnly: true, trigger: .popover)
      } label: {
        Label("Mount Read-Only", systemImage: "lock.circle")
      }
      .disabled(rules.disablesVolumeOperations)
    }

    Divider()
    if rules.isPinned {
      Button {
        persistence.setPinned(false, volume: volume)
      } label: {
        Label("Unpin", systemImage: "pin.slash")
      }
    } else {
      Button {
        if !persistence.setPinned(true, volume: volume) {
          showPersistenceError()
        }
      } label: {
        Label("Pin to Top", systemImage: "pin")
      }
    }
    if rules.isKeepAlive {
      Button {
        if !persistence.setKeepAlive(false, volume: volume) {
          showPersistenceError()
        }
      } label: {
        Label("Disable Keep Mounted", systemImage: "arrow.triangle.2.circlepath")
      }
    } else {
      Button {
        if !persistence.setKeepAlive(true, volume: volume) {
          showPersistenceError()
        }
      } label: {
        Label("Keep Mounted (Auto-Reconnect)", systemImage: "arrow.triangle.2.circlepath")
      }
    }

    if rules.showsIdleUnmount {
      idleUnmountMenu(rules)
    }

    Button {
      if !persistence.block(volume: volume) {
        showPersistenceError()
      }
    } label: {
      Label("Don't Auto-Mount This Volume", systemImage: "hand.raised")
    }
    if rules.showsForgetSavedPassword {
      Button {
        manager.unlocker.forgetSavedPassword(for: volume)
      } label: {
        Label(
          NSLocalizedString(
            "Forget Saved Password", comment: "Volume context menu: delete the saved APFS password"),
          systemImage: "key.slash")
      }
    }
    Button {
      toggleCustomMountPointEditor()
    } label: {
      Label(
        NSLocalizedString(
          "Custom Mount Point Menu",
          comment: "Volume context menu custom mount point action"),
        systemImage: "folder.badge.gearshape")
    }
    Divider()
    Button(role: .destructive) {
      if !persistence.ignore(volume: volume) {
        showPersistenceError()
      } else {
        manager.refreshDrives(qos: .userInitiated)
      }
    } label: {
      Label("Ignore This Volume", systemImage: "eye.slash")
    }
  }

  @ViewBuilder
  private func protectItem(_ action: VolumeMenuRules.ProtectAction?) -> some View {
    switch action {
    case .unprotect:
      Button {
        if let compositeId = volume.compositeId,
          let info = persistence.protectedVolumes.first(where: { $0.id == compositeId })
        {
          persistence.unprotect(info: info)
          manager.refreshDrives(qos: .userInitiated)
        }
      } label: {
        Label("Unprotect from 'Unmount All'", systemImage: "lock.open.fill")
      }
    case .protect:
      Button {
        if !persistence.protect(volume: volume) {
          showPersistenceError()
        } else {
          manager.refreshDrives(qos: .userInitiated)
        }
      } label: {
        Label("Protect from 'Unmount All'", systemImage: "lock.fill")
      }
    case nil:
      EmptyView()
    }
  }

  /// "Unmount When Idle" submenu: Off or a number of minutes, the current
  /// choice checked. Unavailable while the volume is kept mounted or protected.
  private func idleUnmountMenu(_ rules: VolumeMenuRules) -> some View {
    Menu {
      ForEach(PersistenceManager.idleUnmountChoices, id: \.self) { minutes in
        Button {
          if !persistence.setIdleUnmountMinutes(minutes, volume: volume) {
            showPersistenceError()
          }
        } label: {
          let title = VolumeMenuRules.idleUnmountChoiceTitle(minutes)
          if rules.isCurrentIdleChoice(minutes) {
            Label(title, systemImage: "checkmark")
          } else {
            Text(title)
          }
        }
      }
    } label: {
      Label(idleUnmountTitle(rules), systemImage: "moon.zzz")
    }
    .disabled(rules.idleUnmountDisabled)
  }

  private func idleUnmountTitle(_ rules: VolumeMenuRules) -> String {
    if rules.isKeepAlive {
      return NSLocalizedString(
        "Unmount When Idle (Off While Kept Mounted)",
        comment: "Volume context menu: idle unmount unavailable for keep-alive volumes")
    }
    if rules.isProtected {
      return NSLocalizedString(
        "Unmount When Idle (Off While Protected)",
        comment: "Volume context menu: idle unmount unavailable for protected volumes")
    }
    return NSLocalizedString(
      "Unmount When Idle", comment: "Volume context menu: idle unmount submenu")
  }

  private func showPersistenceError() {
    let message = String(
      format: NSLocalizedString(
        "Could not save settings for “%@” because it does not have a unique identifier (UUID).",
        comment: "Persistence error message"), volume.name)
    manager.userActionError = AppAlert(
      title: NSLocalizedString("Action Failed", comment: "Alert title"),
      message: message,
      kind: .basic
    )
  }
}
