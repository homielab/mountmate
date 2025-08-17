//  Created by homielab.com

import SwiftUI

struct HeaderActionsView: View {
    @ObservedObject var driveManager: DriveManager
    var onShowSettings: () -> Void
    var onRefresh: () -> Void

    private var canUnmountAll: Bool {
        driveManager.physicalDisks.flatMap { $0.volumes }.contains { $0.isMounted && $0.category == .user }
    }

    var body: some View {
        HStack {
            Text("MountMate").font(.headline)
            Spacer()

            Button(action: { driveManager.unmountAllDrives() }) {
                Image(systemName: "eject.circle.fill").opacity(driveManager.isUnmountingAll ? 0 : 1)
            }
            .buttonStyle(.plain).help(NSLocalizedString("Unmount All", comment: "Unmount All button tooltip"))
            .disabled(!canUnmountAll || driveManager.isUnmountingAll)
            .overlay { if driveManager.isUnmountingAll { ProgressView().controlSize(.small) } }

            Button(action: onShowSettings) { Image(systemName: "gearshape.fill") }
                .buttonStyle(.plain).help("Settings")

            Button(action: onRefresh) {
                if driveManager.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain).help("Refresh Drives")
            .disabled(driveManager.isRefreshing)

            Button(action: { NSApplication.shared.terminate(nil) }) { Image(systemName: "power").foregroundColor(.red) }
                .buttonStyle(.plain).help(NSLocalizedString("Quit MountMate", comment: "Quit button tooltip"))
        }
        .padding()
    }
}

struct MainView: View {
    @StateObject private var driveManager = DriveManager.shared
    @Environment(\.openWindow) var openWindow
    
    private var internalDisks: [PhysicalDisk] {
        driveManager.physicalDisks.filter { $0.type == .internalDisk }
    }

    private var externalDisks: [PhysicalDisk] {
        driveManager.physicalDisks.filter { $0.type == .physical }
    }

    private var diskImages: [PhysicalDisk] {
        driveManager.physicalDisks.filter { $0.type == .diskImage }
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderActionsView(
                driveManager: driveManager,
                onShowSettings: openAndFocusSettingsWindow,
                onRefresh: { driveManager.refreshDrives() }
            )

            if driveManager.physicalDisks.isEmpty {
                noDrivesView
            } else {
                driveListView
            }
        }
        .frame(width: 370)
        .padding(.bottom, 8)
    }

    private func openAndFocusSettingsWindow() {
        let settingsWindowTitle = NSLocalizedString("MountMate Settings", comment: "")
        if let window = NSApp.windows.first(where: { $0.title == settingsWindowTitle }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openWindow(id: "settings-window")
        }
    }

    private var driveListView: some View {
        List {
            if !internalDisks.isEmpty {
                Section(header: Text(NSLocalizedString("Internal Disks", comment: "Section header"))) {
                    ForEach(internalDisks) { disk in
                        DiskHeaderRow(disk: disk, manager: driveManager)
                        ForEach(disk.volumes) { volume in
                            VolumeRowView(volume: volume, manager: driveManager).padding(.leading, 24)
                        }
                    }
                }
            }
            
            if !externalDisks.isEmpty {
                Section(header: Text(NSLocalizedString("External Disks", comment: "Section header"))) {
                    ForEach(externalDisks) { disk in
                        DiskHeaderRow(disk: disk, manager: driveManager)
                        
                        ForEach(disk.volumes) { volume in
                            VolumeRowView(volume: volume, manager: driveManager)
                                .padding(.leading, 24)
                        }
                    }
                }
            }
            if !diskImages.isEmpty {
                Section(header: Text(NSLocalizedString("Disk Images", comment: "Section header"))) {
                    ForEach(diskImages) { disk in
                        DiskHeaderRow(disk: disk, manager: driveManager)
                        
                        ForEach(disk.volumes) { volume in
                            VolumeRowView(volume: volume, manager: driveManager)
                                .padding(.leading, 24)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(maxHeight: 400)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
    }

    private var noDrivesView: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.fill.badge.questionmark").font(.system(size: 40)).foregroundColor(.secondary)
            Text(NSLocalizedString("No Drives Found", comment: "Empty state title")).font(.headline)
            Text(NSLocalizedString("Connect a USB drive, SD card, or mount a disk image to see it here.", comment: "Empty state description"))
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal)
        }
        .frame(height: 150)
    }
}

struct DiskHeaderRow: View {
    let disk: PhysicalDisk
    @ObservedObject var manager: DriveManager

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                ZStack {
                    Image(systemName: "internaldrive.fill").font(.title2)
                    if let percentage = disk.usagePercentage {
                        CircularProgressRing(progress: percentage, color: .purple, lineWidth: 3.5).frame(width: 32, height: 32)
                    }
                }
                .frame(width: 40, height: 40)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.name ?? disk.connectionType).font(.headline)
                    if let total = disk.totalSize, let used = disk.usedSpace, let free = disk.freeSpace {
                        Text("\(used) used / \(total) (\(free) free)")
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        Text(disk.connectionType).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button(NSLocalizedString("Ignore This Disk", comment: "Context menu action")) {
                    PersistenceManager.shared.ignore(volumes: disk.volumes)
                    DriveManager.shared.refreshDrives(qos: .userInitiated)
                }
                Button(NSLocalizedString("Eject", comment: "Context menu action")) {
                    manager.eject(disk: disk)
                }
            }

            Spacer()

            if disk.type != .internalDisk {
                let isEjecting = manager.busyEjectingIdentifier == disk.id
                Button(action: { manager.eject(disk: disk) }) {
                    Image(systemName: "eject.fill").opacity(isEjecting ? 0 : 1)
                }
                .buttonStyle(.bordered).tint(.purple).disabled(isEjecting)
                .overlay { if isEjecting { ProgressView().controlSize(.small) } }
                .help(NSLocalizedString("Eject", comment: "Eject button tooltip"))
            }
        }
        .padding(.vertical, 8)
    }
}

struct VolumeRowView: View {
    let volume: Volume
    @ObservedObject var manager: DriveManager

    private var isLoading: Bool { manager.busyVolumeIdentifier == volume.id }

    private func usageColor(for percentage: Double) -> Color {
        if percentage > 0.9 { return .red }
        else if percentage > 0.75 { return .orange }
        return .accentColor
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                ZStack {
                    Image(systemName: "externaldrive")
                        .font(.body)
                        .foregroundColor(volume.isMounted ? .accentColor : .secondary.opacity(0.6))

                    if volume.isMounted, let percentage = volume.usagePercentage {
                        CircularProgressRing(progress: percentage, color: usageColor(for: percentage), lineWidth: 3.0)
                            .frame(width: 26, height: 26)
                    }
                }
                .frame(width: 24, alignment: .center)
                .padding(.trailing, 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.name)
                        .fontWeight(.semibold)
                        .foregroundColor(volume.isMounted ? .primary : .secondary)

                    if volume.isMounted {
                       if let total = volume.totalSize, let used = volume.usedSpace {
                           Text("\(used) / \(total)")
                               .font(.caption).foregroundColor(.secondary)
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
            .contextMenu {
                if volume.isMounted {
                    Button { manager.unmount(volume: volume) } label: { Label("Unmount", systemImage: "xmark.circle") }
                    Button {
                        if let path = volume.mountPoint { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    } label: {
                        Label("Open in Finder", systemImage: "folder")
                    }
                    Divider()
                    if volume.isProtected {
                        Button {
                            PersistenceManager.shared.unprotectVolume(id: volume.id)
                            DriveManager.shared.refreshDrives(qos: .userInitiated)
                        } label: {
                            Label("Unprotect from 'Unmount All'", systemImage: "lock.open.fill")
                        }
                    } else {
                        Button {
                            PersistenceManager.shared.protect(volume: volume)
                            DriveManager.shared.refreshDrives(qos: .userInitiated)
                        } label: {
                            Label("Protect from 'Unmount All'", systemImage: "lock.fill")
                        }
                    }
                } else {
                    Button { manager.mount(volume: volume) } label: { Label("Mount", systemImage: "arrow.up.circle") }
                    Divider()
                }
                
                Button(role: .destructive) {
                    PersistenceManager.shared.ignore(volume: volume)
                    DriveManager.shared.refreshDrives(qos: .userInitiated)
                } label: {
                    Label("Ignore This Volume", systemImage: "eye.slash")
                }
                
            }

            Button(action: {
                if volume.isMounted { manager.unmount(volume: volume) }
                else { manager.mount(volume: volume) }
            }) {
                Image(systemName: volume.isMounted ? "xmark.circle.fill" : "arrow.up.circle.fill")
                    .opacity(isLoading ? 0 : 1)
            }
            .buttonStyle(.bordered)
            .tint(volume.isMounted ? .red : .blue)
            .disabled(isLoading)
            .overlay { if isLoading { ProgressView().controlSize(.small) } }
            .help(volume.isMounted ? NSLocalizedString("Unmount", comment: "Unmount button tooltip") : NSLocalizedString("Mount", comment: "Mount button tooltip"))
            .padding(.leading, 8)
        }
        .padding(.vertical, 4)
    }
}
