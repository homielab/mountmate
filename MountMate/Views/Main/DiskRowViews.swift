//  Created by homielab.com

import SwiftUI

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
                    PersistenceManager.shared.ignore(disk: disk)
                    DriveManager.shared.refreshDrives(qos: .userInitiated)
                }
                if disk.type != .internalDisk {
                    Button(NSLocalizedString("Eject", comment: "Context menu action")) { manager.eject(disk: disk) }
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
    @StateObject private var persistence = PersistenceManager.shared

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
                        CircularProgressRing(progress: percentage, color: usageColor(for: percentage), lineWidth: 3.0).frame(width: 26, height: 26)
                    }
                }
                .frame(width: 24, alignment: .center).padding(.trailing, 8)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.name).fontWeight(.semibold).foregroundColor(volume.isMounted ? .primary : .secondary)
                    if volume.isMounted {
                        if let total = volume.totalSize, let used = volume.usedSpace {
                            Text("\(used) / \(total)").font(.caption).foregroundColor(.secondary)
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
                           if let info = persistence.protectedVolumes.first(where: { $0.volumeUUID == volume.id && $0.diskUUID == volume.diskUUID }) {
                               persistence.unprotect(info: info)
                               DriveManager.shared.refreshDrives(qos: .userInitiated)
                           }
                       } label: {
                           Label("Unprotect from 'Unmount All'", systemImage: "lock.open.fill")
                       }
                   } else {
                       Button {
                           persistence.protect(volume: volume)
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
                Image(systemName: volume.isMounted ? "xmark.circle.fill" : "arrow.up.circle.fill").opacity(isLoading ? 0 : 1)
            }
            .buttonStyle(.bordered).tint(volume.isMounted ? .red : .blue).disabled(isLoading)
            .overlay { if isLoading { ProgressView().controlSize(.small) } }
            .help(volume.isMounted ? NSLocalizedString("Unmount", comment: "...") : NSLocalizedString("Mount", comment: "..."))
            .padding(.leading, 8)
        }
        .padding(.vertical, 4)
    }
}
