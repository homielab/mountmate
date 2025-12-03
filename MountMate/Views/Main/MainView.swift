//  Created by homielab.com

import SwiftUI

struct MainView: View {
  @EnvironmentObject var driveManager: DriveManager
  @ObservedObject var persistence = PersistenceManager.shared

  @State private var initialLoadTimer = Timer.publish(every: 0.25, on: .main, in: .common)
    .autoconnect()

  private var internalDisks: [PhysicalDisk] {
    (driveManager.physicalDisks ?? []).filter { $0.type == .internalDisk && $0.hasVisibleContent }
  }
  private var externalDisks: [PhysicalDisk] {
    (driveManager.physicalDisks ?? []).filter { $0.type == .physical && $0.hasVisibleContent }
  }
  private var diskImages: [PhysicalDisk] {
    (driveManager.physicalDisks ?? []).filter { $0.type == .diskImage && $0.hasVisibleContent }
  }

  private var hasVisibleDisks: Bool {
    !internalDisks.isEmpty || !externalDisks.isEmpty || !diskImages.isEmpty
      || !persistence.networkShares.isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      HeaderActionsView()

      if let error = driveManager.refreshError {
        ErrorBannerView(message: error)
      }

      if driveManager.physicalDisks == nil {
        ProgressView()
          .frame(height: 150)
          .onReceive(initialLoadTimer) { _ in
            if driveManager.physicalDisks != nil {
              self.initialLoadTimer.upstream.connect().cancel()
            }
          }
      } else if !hasVisibleDisks {
        noDrivesView
      } else {
        DriveListView(
          internalDisks: internalDisks,
          externalDisks: externalDisks,
          diskImages: diskImages,
          networkShares: persistence.networkShares
        )
      }
    }
    .frame(width: 350)
    .padding(.bottom, 8)
    .onAppear {
      NSApp.activate(ignoringOtherApps: true)
      driveManager.refreshDrives()
    }
  }

  private var noDrivesView: some View {
    VStack(spacing: 8) {
      Image(systemName: "externaldrive.fill.badge.questionmark").font(.system(size: 40))
        .foregroundColor(.secondary)
      Text(NSLocalizedString("No Drives Found", comment: "Empty state title")).font(.headline)
      Text(
        NSLocalizedString(
          "Connect a USB drive, SD card, or mount a disk image to see it here.",
          comment: "Empty state description")
      )
      .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(
        .horizontal)
    }
    .padding(.vertical, 40)
  }

}

struct DriveListView: View {
  let internalDisks: [PhysicalDisk]
  let externalDisks: [PhysicalDisk]
  let diskImages: [PhysicalDisk]
  let networkShares: [NetworkShare]

  var body: some View {
    List {
      if !internalDisks.isEmpty {
        Section(header: Text("Internal Disks")) {
          ForEach(internalDisks) { disk in DiskAndVolumesView(disk: disk) }
        }
      }
      if !externalDisks.isEmpty {
        Section(header: Text("External Disks")) {
          ForEach(externalDisks) { disk in DiskAndVolumesView(disk: disk) }
        }
      }
      if !diskImages.isEmpty {
        Section(header: Text("Disk Images")) {
          ForEach(diskImages) { disk in DiskAndVolumesView(disk: disk) }
        }
      }
      if !networkShares.isEmpty {
        Section(header: Text("Network Shares")) {
          ForEach(networkShares) { share in NetworkShareMainRow(share: share) }
        }
      }
    }
    .listStyle(.sidebar)
    .frame(minHeight: 50)
  }
}

// MARK: - Hierarchical Helper & Row Views
struct DiskAndVolumesView: View {
  let disk: PhysicalDisk

  private var visibleContainers: [APFSContainer] {
    disk.containers.filter { !$0.volumes.isEmpty }
  }

  var body: some View {
    DiskHeaderRow(disk: disk)
    ForEach(disk.partitions) { partition in
      VolumeRowView(volume: partition).padding(.leading, 24)
    }
    ForEach(visibleContainers) { container in
      ContainerRowView(container: container)
      ForEach(container.volumes) { volume in
        VolumeRowView(volume: volume).padding(.leading, 48)
      }
    }
  }
}

struct DiskHeaderRow: View {
  let disk: PhysicalDisk
  @EnvironmentObject var manager: DriveManager
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 0) {
      HStack {
        ZStack {
          Image(systemName: "internaldrive.fill").font(.title2)
          if let error = disk.storageError {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).help(error)
          } else if let percentage = disk.usagePercentage {
            CircularProgressRing(progress: percentage, color: .purple, lineWidth: 3.5).frame(
              width: 32, height: 32)
          }
        }
        .frame(width: 40, height: 40)

        VStack(alignment: .leading, spacing: 2) {
          Text(disk.name ?? disk.connectionType).font(.headline)
          if let error = disk.storageError {
            Text(error).font(.caption).foregroundColor(.orange).lineLimit(1).truncationMode(.tail)
          } else if let total = disk.totalSize, let used = disk.usedSpace, let free = disk.freeSpace
          {
            Text("\(used) used / \(total) (\(free) free)").font(.caption).foregroundColor(
              .secondary)
          } else {
            Text(disk.connectionType).font(.caption).foregroundColor(.secondary)
          }
        }
      }
      .contentShape(Rectangle())
      .contextMenu {
        Button("Ignore This Disk") {
          let allVolumesToIgnore = disk.partitions + disk.containers.flatMap { $0.volumes }
          for volume in allVolumesToIgnore { PersistenceManager.shared.ignore(volume: volume) }
          manager.refreshDrives(qos: .userInitiated)
        }
        if disk.type != .internalDisk {
          Button("Eject") { manager.eject(disk: disk) }
        }
      }

      Spacer()

      if disk.type != .internalDisk {
        let isEjecting = manager.busyEjectingIdentifier == disk.id
        Button(action: { manager.eject(disk: disk) }) {
          Image(systemName: "eject.fill").opacity(isEjecting ? 0 : 1)
        }
        .buttonStyle(.bordered).tint(.purple).disabled(isEjecting)
        .overlay { if isEjecting { ProgressView().controlSize(.small) } }.help("Eject")
      }
    }
    .listRowSeparator(.hidden).padding(.vertical, 8).padding(.horizontal, 4)
    .background(isHovering ? Color.primary.opacity(0.1) : Color.clear).cornerRadius(6)
    .onHover { hovering in self.isHovering = hovering }
  }
}

struct ContainerRowView: View {
  let container: APFSContainer
  var body: some View {
    HStack {
      Image(systemName: "shippingbox.fill").font(.body).foregroundColor(.secondary)
        .frame(width: 24, alignment: .center).padding(.trailing, 4)
      Text("APFS Container • \(container.id)")
        .font(.subheadline).fontWeight(.semibold).foregroundColor(.secondary)
      Spacer()
    }
    .padding(.leading, 24)
    .padding(.vertical, 2)
  }
}

struct VolumeRowView: View {
  let volume: Volume
  @EnvironmentObject var manager: DriveManager
  @StateObject private var persistence = PersistenceManager.shared
  @State private var isHovering = false
  private var isLoading: Bool { manager.busyVolumeIdentifier == volume.id }

  private func usageColor(for percentage: Double) -> Color {
    if percentage > 0.9 { return .red } else if percentage > 0.75 { return .orange }
    return .accentColor
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 0) {
        HStack {
          ZStack {
            Image(systemName: "externaldrive")
              .font(.body)
              .foregroundColor(
                volume.isMounted ? .accentColor : .secondary.opacity(0.6))
            if let error = volume.storageError {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
                .help(error)
            } else if volume.isMounted, let percentage = volume.usagePercentage {
              CircularProgressRing(
                progress: percentage, color: usageColor(for: percentage),
                lineWidth: 3.0
              ).frame(width: 26, height: 26)
            }
          }
          .frame(width: 24, alignment: .center).padding(.trailing, 8)

          VStack(alignment: .leading, spacing: 2) {
            Text(volume.name).fontWeight(.semibold).foregroundColor(
              volume.isMounted ? .primary : .secondary)
            if volume.isMounted {
              if let total = volume.totalSize, let used = volume.usedSpace {
                Text("\(used) / \(total)").font(.caption).foregroundColor(
                  .secondary)
              } else if let fsType = volume.fileSystemType {
                Text(fsType).font(.caption).foregroundColor(.secondary)
              }
            } else {
              Text("Unmounted").font(.caption).foregroundColor(.secondary)
            }
          }
          Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
          if volume.isMounted, let mountPoint = volume.mountPoint {
            NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
          }
        }

        Button(action: {
          if volume.isMounted {
            manager.unmount(volume: volume)
          } else {
            manager.mount(volume: volume)
          }
        }) {
          Image(
            systemName: volume.isMounted ? "xmark.circle.fill" : "arrow.up.circle.fill"
          )
          .opacity(isLoading ? 0 : 1)
        }
        .buttonStyle(.bordered).tint(volume.isMounted ? .red : .blue).disabled(isLoading)
        .overlay { if isLoading { ProgressView().controlSize(.small) } }
        .help(
          volume.isMounted
            ? NSLocalizedString("Unmount", comment: "...")
            : NSLocalizedString("Mount", comment: "...")
        )
        .padding(.leading, 8)
      }
      .padding(.vertical, 4)
      .padding(.horizontal, 4)
      .background(isHovering ? Color.primary.opacity(0.1) : Color.clear)
      .cornerRadius(5)
      .onHover { hovering in
        self.isHovering = hovering
      }
      .contextMenu {
        if volume.isMounted {
          Button {
            manager.unmount(volume: volume)
          } label: {
            Label("Unmount", systemImage: "xmark.circle")
          }
          Button {
            if let path = volume.mountPoint {
              NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
          } label: {
            Label("Open in Finder", systemImage: "folder")
          }
          Divider()
          if volume.isProtected {
            Button {
              if let compositeId = volume.compositeId,
                let info = persistence.protectedVolumes.first(where: {
                  $0.id == compositeId
                })
              {
                persistence.unprotect(info: info)
                DriveManager.shared.refreshDrives(qos: .userInitiated)
              }
            } label: {
              Label("Unprotect from 'Unmount All'", systemImage: "lock.open.fill")
            }
          } else {
            Button {
              if !persistence.protect(volume: volume) {
                showPersistenceError(for: volume)
              } else {
                DriveManager.shared.refreshDrives(qos: .userInitiated)
              }
            } label: {
              Label("Protect from 'Unmount All'", systemImage: "lock.fill")
            }
          }
        } else {
          Button {
            manager.mount(volume: volume)
          } label: {
            Label("Mount", systemImage: "arrow.up.circle")
          }
          Divider()
        }

        Button {
          if !PersistenceManager.shared.block(volume: volume) {
            showPersistenceError(for: volume)
          }
        } label: {
          Label("Don't Auto-Mount This Volume", systemImage: "hand.raised")
        }
        Divider()
        Button(role: .destructive) {
          if !PersistenceManager.shared.ignore(volume: volume) {
            showPersistenceError(for: volume)
          } else {
            DriveManager.shared.refreshDrives(qos: .userInitiated)
          }
        } label: {
          Label("Ignore This Volume", systemImage: "eye.slash")
        }

      }

      if !volume.snapshots.isEmpty {
        DisclosureGroup {
          ForEach(volume.snapshots) { snapshot in
            SnapshotRowView(snapshot: snapshot)
          }
        } label: {
          Text(NSLocalizedString("Snapshots", comment: "Snapshots section label"))
            .font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
        }
        .padding(.leading, 32)
      }
    }
  }

  private func showPersistenceError(for volume: Volume) {
    let message = String(
      format: NSLocalizedString(
        "Could not save settings for “%@” because it does not have a unique identifier (UUID).",
        comment: "Persistence error message"), volume.name)
    DriveManager.shared.userActionError = AppAlert(
      title: NSLocalizedString("Action Failed", comment: "Alert title"),
      message: message,
      kind: .basic
    )
  }
}

struct SnapshotRowView: View {
  let snapshot: APFSSnapshot

  var body: some View {
    HStack {
      Image(systemName: "camera.fill")
        .foregroundColor(.secondary)
        .font(.caption)
      Text(snapshot.name)
        .font(.caption)
      Spacer()
    }
  }
}

struct NetworkShareMainRow: View {
  let share: NetworkShare
  @State private var isMounted = false
  @State private var isWorking = false
  @State private var isHovering = false

  // Timer to periodically check mount status
  let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 0) {
        HStack {
          ZStack {
            Image(systemName: "network")
              .font(.body)
              .foregroundColor(isMounted ? .accentColor : .secondary.opacity(0.6))
          }
          .frame(width: 24, alignment: .center).padding(.trailing, 8)

          VStack(alignment: .leading, spacing: 2) {
            Text(share.name).fontWeight(.semibold).foregroundColor(
              isMounted ? .primary : .secondary)
            Text(isMounted ? "Mounted" : "Not Mounted")
              .font(.caption).foregroundColor(.secondary)
          }
          Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
          if isMounted {
            let path = NetworkMountManager.shared.getMountPoint(for: share)
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
          }
        }

        Button(action: {
          isWorking = true
          if isMounted {
            NetworkMountManager.shared.unmount(share: share) { success, error in
              isWorking = false
              checkStatus()
              if !success, let error = error {
                DriveManager.shared.userActionError = AppAlert(
                  title: "Unmount Failed", message: error, kind: .basic)
              }
            }
          } else {
            NetworkMountManager.shared.mount(share: share) { success, error in
              isWorking = false
              checkStatus()
              if !success, let error = error {
                DriveManager.shared.userActionError = AppAlert(
                  title: "Mount Failed", message: error, kind: .basic)
              }
            }
          }
        }) {
          Image(
            systemName: isMounted ? "xmark.circle.fill" : "arrow.up.circle.fill"
          )
          .opacity(isWorking ? 0 : 1)
        }
        .buttonStyle(.bordered).tint(isMounted ? .red : .blue).disabled(isWorking)
        .overlay { if isWorking { ProgressView().controlSize(.small) } }
        .help(isMounted ? "Unmount" : "Mount")
        .padding(.leading, 8)
      }
      .padding(.vertical, 4)
      .padding(.horizontal, 4)
      .background(isHovering ? Color.primary.opacity(0.1) : Color.clear)
      .cornerRadius(5)
      .onHover { hovering in
        self.isHovering = hovering
      }
    }
    .onAppear { checkStatus() }
    .onReceive(timer) { _ in checkStatus() }
  }

  private func checkStatus() {
    isMounted = NetworkMountManager.shared.isMounted(share: share)
  }
}

struct HeaderActionsView: View {
  @EnvironmentObject var driveManager: DriveManager

  private var canUnmountAll: Bool {
    (driveManager.physicalDisks ?? []).flatMap {
      $0.partitions + $0.containers.flatMap { $0.volumes }
    }
    .contains { $0.isMounted && $0.category == .user && !$0.isProtected }
  }

  var body: some View {
    HStack {
      Text("MountMate").font(.headline)
      Spacer()

      // Unmount All Button
      Button(action: { driveManager.unmountAllDrives() }) {
        if driveManager.isUnmountingAll {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "eject.circle.fill")
        }
      }
      .buttonStyle(.plain).help(NSLocalizedString("Unmount All", comment: "Tooltip"))
      .disabled(!canUnmountAll || driveManager.isUnmountingAll)

      // Settings Button
      if #available(macOS 14.0, *) {
        SettingsLink {
          Image(systemName: "gearshape.fill")
        }
        .buttonStyle(.plain)
        .help("Settings")
        .simultaneousGesture(
          TapGesture().onEnded {
            focusSettingsWindow()
          })
      } else {
        Button(action: {
          NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
          NSApp.activate(ignoringOtherApps: true)
        }) {
          Image(systemName: "gearshape.fill")
        }
        .buttonStyle(.plain)
        .help("Settings")
      }

      // Refresh Button
      Button(action: { driveManager.refreshDrives(qos: .userInitiated) }) {
        if driveManager.isRefreshing {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "arrow.clockwise")
        }
      }
      .buttonStyle(.plain).help("Refresh Drives")
      .disabled(driveManager.isRefreshing)

      // Quit Button
      Button(action: { NSApplication.shared.terminate(nil) }) {
        Image(systemName: "power").foregroundColor(.red)
      }
      .buttonStyle(.plain).help(NSLocalizedString("Quit MountMate", comment: "Tooltip"))
    }
    .frame(width: 320)
    .padding()
  }

  private func focusSettingsWindow() {
    let settingsID = "com_apple_SwiftUI_Settings_window"

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      if let settingsWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == settingsID })
      {
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
      }
    }
  }
}
