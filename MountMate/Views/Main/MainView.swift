//  Created by homielab.com

import AppKit
import SwiftUI

final class CustomMountPointEditorState: ObservableObject {
  static let shared = CustomMountPointEditorState()

  @Published var expandedVolumeID: String?
  @Published var mountPointPath = ""
  @Published var inlineError: String?
  @Published var pendingSavePath: String?
  @Published var selectedFolderURL: URL?
  @Published var showCreateDirectoryAlert = false
  @Published var showNonEmptyDirectoryAlert = false
  @Published var isChoosingFolder = false
  weak var hostWindow: NSWindow?

  func sync(from persistedPath: String?) {
    mountPointPath = persistedPath ?? ""
    inlineError = nil
    pendingSavePath = nil
    selectedFolderURL = nil
    showCreateDirectoryAlert = false
    showNonEmptyDirectoryAlert = false
    isChoosingFolder = false
  }

  func collapse() {
    expandedVolumeID = nil
    inlineError = nil
    pendingSavePath = nil
    selectedFolderURL = nil
    showCreateDirectoryAlert = false
    showNonEmptyDirectoryAlert = false
    isChoosingFolder = false
  }
}

struct HostingWindowReader: NSViewRepresentable {
  let onResolve: (NSWindow?) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      onResolve(view.window)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async {
      onResolve(nsView.window)
    }
  }
}

struct MainView: View {
  @EnvironmentObject var driveManager: DriveManager
  @ObservedObject var persistence = PersistenceManager.shared

  @State private var initialLoadTimer = Timer.publish(every: 0.25, on: .main, in: .common)
    .autoconnect()
  @ObservedObject private var customMountPointEditor = CustomMountPointEditorState.shared

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
          networkShares: persistence.networkShares,
          customMountPointEditor: customMountPointEditor
        )
      }
    }
    .frame(width: 350)
    .padding(.bottom, 8)
    .background(
      HostingWindowReader { window in
        customMountPointEditor.hostWindow = window
      }
    )
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
  @ObservedObject var customMountPointEditor: CustomMountPointEditorState

  var body: some View {
    List {
      if !internalDisks.isEmpty {
        Section(header: Text("Internal Disks")) {
          ForEach(internalDisks) { disk in
            DiskAndVolumesView(
              disk: disk,
              customMountPointEditor: customMountPointEditor)
          }
        }
      }
      if !externalDisks.isEmpty {
        Section(header: Text("External Disks")) {
          ForEach(externalDisks) { disk in
            DiskAndVolumesView(
              disk: disk,
              customMountPointEditor: customMountPointEditor)
          }
        }
      }
      if !diskImages.isEmpty {
        Section(header: Text("Disk Images")) {
          ForEach(diskImages) { disk in
            DiskAndVolumesView(
              disk: disk,
              customMountPointEditor: customMountPointEditor)
          }
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
  @ObservedObject var customMountPointEditor: CustomMountPointEditorState
  @State private var isExpanded = true
  @EnvironmentObject var manager: DriveManager // Make sure manager is available

  private var visibleContainers: [APFSContainer] {
    disk.containers.filter { !$0.volumes.isEmpty }
  }

  var body: some View {
    Group {
      DiskHeaderRow(disk: disk, isExpanded: $isExpanded)
      if isExpanded {
        ForEach(disk.partitions) { partition in
          VolumeRowView(
            volume: partition,
            customMountPointEditor: customMountPointEditor)
            .padding(.leading, 24)
        }
        ForEach(visibleContainers) { container in
          ContainerRowView(container: container)
          ForEach(container.volumes) { volume in
            VolumeRowView(
              volume: volume,
              customMountPointEditor: customMountPointEditor)
              .padding(.leading, 48)
          }
        }
      }
    }
    // Listen for global toggle events
    .onReceive(manager.driveExpansionSubject) { expanded in
       withAnimation {
         self.isExpanded = expanded
       }
    }
  }
}

struct DiskHeaderRow: View {
  let disk: PhysicalDisk
  @Binding var isExpanded: Bool
  @EnvironmentObject var manager: DriveManager
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 0) {
      // Toggle Chevron & Icon
      HStack(spacing: 4) {
        Image(systemName: "chevron.right")
          .font(.caption2)
          .foregroundColor(.secondary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .animation(.easeInOut(duration: 0.2), value: isExpanded)
          .frame(width: 12)
        
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
      .onTapGesture {
        withAnimation(.easeInOut(duration: 0.2)) {
          isExpanded.toggle()
        }
      }
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
  @ObservedObject var customMountPointEditor: CustomMountPointEditorState
  @EnvironmentObject var manager: DriveManager
  @StateObject private var persistence = PersistenceManager.shared
  @State private var isHovering = false
  private var isLoading: Bool { manager.busyVolumeIdentifier == volume.id }
  private var customMountPoint: String? { persistence.customMountPoint(for: volume)?.mountPoint }
  private var isCustomMountPointExpanded: Bool { customMountPointEditor.expandedVolumeID == volume.id }

  private func usageColor(for percentage: Double) -> Color {
    if percentage > 0.9 { return .red } else if percentage > 0.75 { return .orange }
    return .accentColor
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 0) {
        Button(action: {
          syncEditorStateFromPersistence()
          withAnimation(.easeInOut(duration: 0.18)) {
            customMountPointEditor.expandedVolumeID = isCustomMountPointExpanded ? nil : volume.id
          }
        }) {
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
            .rotationEffect(.degrees(isCustomMountPointExpanded ? 90 : 0))
            .frame(width: 12, height: 12)
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 28, height: 28, alignment: .center)
        .contentShape(Rectangle())
        .disabled(isLoading)
        .help(
          NSLocalizedString(
            "Custom Mount Point Menu",
            comment: "Volume context menu custom mount point action"))
        .padding(.trailing, 8)

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
            if let customMountPoint {
              Text(
                String(
                  format: NSLocalizedString(
                    "Custom Mount Point Summary",
                    comment: "Volume row custom mount point summary"),
                  customMountPoint))
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .help(customMountPoint)
            }
          }
          Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
          if volume.isMounted, let mountPoint = volume.mountPoint {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: mountPoint)])
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
            systemName: volume.isMounted ? "minus.circle.fill" : "plus.circle.fill"
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
      .onAppear {
        if isCustomMountPointExpanded {
          syncEditorStateFromPersistence()
        }
      }
      .contextMenu {
        if volume.isMounted {
          Button {
            manager.unmount(volume: volume)
          } label: {
            Label("Unmount", systemImage: "minus.circle")
          }
          Button {
            if let path = volume.mountPoint {
              NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
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
            Label("Mount", systemImage: "plus.circle")
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
        Button {
          syncEditorStateFromPersistence()
          customMountPointEditor.expandedVolumeID = isCustomMountPointExpanded ? nil : volume.id
        } label: {
          Label(
            NSLocalizedString(
              "Custom Mount Point Menu",
              comment: "Volume context menu custom mount point action"),
            systemImage: "folder.badge.gearshape")
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

      if isCustomMountPointExpanded {
        InlineCustomMountPointEditor(
          volume: volume,
          editorState: customMountPointEditor,
          onClose: {
            customMountPointEditor.collapse()
          })
          .padding(.leading, 32)
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

  private func syncEditorStateFromPersistence() {
    customMountPointEditor.sync(from: customMountPoint)
  }
}

struct InlineCustomMountPointEditor: View {
  let volume: Volume
  @EnvironmentObject private var driveManager: DriveManager
  @ObservedObject private var persistence = PersistenceManager.shared
  @ObservedObject var editorState: CustomMountPointEditorState
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField(
        NSLocalizedString("Folder Path", comment: "Custom mount point path field"),
        text: $editorState.mountPointPath,
        prompt: Text(
          NSLocalizedString(
            "Custom Mount Point Path Prompt",
            comment: "Custom mount point path placeholder")))
        .textFieldStyle(.roundedBorder)
        .foregroundStyle(.white)

      HStack(spacing: 8) {
        Button(NSLocalizedString("Choose Folder", comment: "Choose folder button")) {
          chooseFolder()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.white)

        Button(NSLocalizedString("Default Path", comment: "Default path button")) {
          editorState.mountPointPath = ""
          editorState.inlineError = nil
          editorState.pendingSavePath = nil
          editorState.selectedFolderURL = nil
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.white)

        Spacer()
      }

      Text(
        NSLocalizedString(
          "Custom Mount Point System Helper",
          comment: "Custom mount point helper text"))
        .font(.caption)
        .foregroundStyle(.white.opacity(0.92))
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)

      if let inlineError = editorState.inlineError {
        Text(inlineError)
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Button(NSLocalizedString("Cancel", comment: "Cancel button")) {
          onClose()
        }
        .foregroundStyle(.white)
        Spacer()
        Button(NSLocalizedString("Save", comment: "Save button")) {
          save()
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.white.opacity(0.08))
    )
    .alert(
      NSLocalizedString("Create Folder Title", comment: "Create folder alert title"),
      isPresented: $editorState.showCreateDirectoryAlert)
    {
      Button(NSLocalizedString("Create", comment: "Create button")) {
        createPendingDirectoryAndSave()
      }
      Button(NSLocalizedString("Cancel", comment: "Cancel button"), role: .cancel) {}
    } message: {
      Text(
        NSLocalizedString(
          "Create Folder Message",
          comment: "Create folder alert message"))
    }
    .alert(
      NSLocalizedString("Folder Not Empty Title", comment: "Non-empty folder alert title"),
      isPresented: $editorState.showNonEmptyDirectoryAlert)
    {
      Button(NSLocalizedString("Use Folder", comment: "Use folder button")) {
        commitPendingSave()
      }
      Button(NSLocalizedString("Cancel", comment: "Cancel button"), role: .cancel) {}
    } message: {
      Text(
        NSLocalizedString(
          "Folder Not Empty Message",
          comment: "Non-empty folder alert message"))
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = NSLocalizedString("Choose", comment: "Choose button")
    editorState.isChoosingFolder = true

    let currentPath = driveManager.normalizedMountPointPath(editorState.mountPointPath)
    if !currentPath.isEmpty {
      panel.directoryURL = URL(fileURLWithPath: currentPath)
    }

    panel.begin { response in
      defer {
        editorState.isChoosingFolder = false
        NSApp.activate(ignoringOtherApps: true)
      }
      guard response == .OK else { return }
        editorState.mountPointPath = panel.url?.path ?? editorState.mountPointPath
        editorState.selectedFolderURL = panel.url
        editorState.inlineError = nil
      }
    }

  private func save() {
    editorState.inlineError = nil

    let normalizedPath = driveManager.normalizedMountPointPath(editorState.mountPointPath)
    editorState.mountPointPath = normalizedPath

    guard !normalizedPath.isEmpty else {
      if let error = persistence.removeCustomMountPoint(for: volume) {
        editorState.inlineError = error
        return
      }
      if volume.isMounted {
        driveManager.remount(volume: volume)
      }
      onClose()
      return
    }

    if let validationError = driveManager.customMountPointValidationError(
      for: normalizedPath, excluding: volume)
    {
      editorState.inlineError = validationError
      return
    }

    do {
      let directoryState = try driveManager.inspectDirectory(at: normalizedPath)
      editorState.pendingSavePath = normalizedPath
      if editorState.selectedFolderURL?.path != normalizedPath {
        editorState.selectedFolderURL = nil
      }

      if !directoryState.exists {
        editorState.showCreateDirectoryAlert = true
        return
      }

      guard directoryState.isDirectory else {
        editorState.inlineError = NSLocalizedString(
          "Custom Mount Point Must Be Folder",
          comment: "Custom mount point validation")
        return
      }

      if !directoryState.isEmpty {
        editorState.showNonEmptyDirectoryAlert = true
        return
      }

      commitPendingSave()
    } catch {
      editorState.inlineError = String(
        format: NSLocalizedString(
          "Custom Mount Point Inspect Error",
          comment: "Custom mount point validation"), error.localizedDescription)
    }
  }

  private func createPendingDirectoryAndSave() {
    guard let path = editorState.pendingSavePath else { return }

    do {
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
      commitPendingSave()
    } catch {
      editorState.inlineError = String(
        format: NSLocalizedString(
          "Custom Mount Point Create Error",
          comment: "Custom mount point validation"), error.localizedDescription)
    }
  }

  private func commitPendingSave() {
    guard let path = editorState.pendingSavePath else { return }
    let selectedFolderURL =
      editorState.selectedFolderURL?.path == path ? editorState.selectedFolderURL : nil
    if let error = persistence.applyCustomMountPoint(path, selectedURL: selectedFolderURL, for: volume)
    {
      editorState.inlineError = error
      return
    }
    if volume.isMounted {
      driveManager.remount(volume: volume)
    }
    onClose()
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
  @ObservedObject var networkManager = NetworkMountManager.shared
  @State private var isWorking = false
  @State private var isHovering = false

  private var isMounted: Bool {
    networkManager.mountedShareIDs.contains(share.id)
  }

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
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
          }
        }

        Button(action: {
          isWorking = true
          if isMounted {
            NetworkMountManager.shared.unmount(share: share) { success, error in
              isWorking = false
              // Status update handled by manager
              if !success, let error = error {
                DriveManager.shared.userActionError = AppAlert(
                  title: "Unmount Failed", message: error, kind: .basic)
              }
            }
          } else {
            NetworkMountManager.shared.mount(share: share) { success, error in
              isWorking = false
              // Status update handled by manager
              if !success, let error = error {
                DriveManager.shared.userActionError = AppAlert(
                  title: "Mount Failed", message: error, kind: .basic)
              }
            }
          }
        }) {
          Image(
            systemName: isMounted ? "minus.circle.fill" : "plus.circle.fill"
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
      
      // Global Expand/Collapse Button
      Button(action: toggleExpansion) {
        Image(systemName: allCollapsed ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
      }
      .buttonStyle(.plain)
      .help(allCollapsed ? "Expand All" : "Collapse All")

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

  @State private var allCollapsed = false

  private func toggleExpansion() {
    allCollapsed.toggle()
    driveManager.driveExpansionSubject.send(!allCollapsed)
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
