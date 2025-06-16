//
//  Created by homielab
//

import SwiftUI

struct MainView: View {
    @StateObject private var driveManager = DriveManager()
    @Environment(\.openWindow) var openWindow

    private var groupedDrives: [String: [Drive]] {
        Dictionary(grouping: driveManager.drives, by: { $0.connectionType })
    }
    
    private var sortedGroupKeys: [String] {
        let preferredOrder = [
            NSLocalizedString("USB", comment: "..."),
            NSLocalizedString("Thunderbolt", comment: "..."),
            NSLocalizedString("Disk Image", comment: "...")
        ]
        
        return groupedDrives.keys.sorted {
            let firstIndex = preferredOrder.firstIndex(of: $0) ?? Int.max
            let secondIndex = preferredOrder.firstIndex(of: $1) ?? Int.max
            
            if firstIndex == secondIndex {
                return $0 < $1
            }
            
            return firstIndex < secondIndex
        }
    }
    
    private var canUnmountAll: Bool {
        return driveManager.drives.contains { $0.isMounted && $0.category == .user }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            if driveManager.drives.isEmpty {
                noDrivesView
            } else {
                driveListView
            }
        }
        .frame(width: 320)
        .padding(.bottom, 8)
        .onAppear(perform: driveManager.refreshDrives)
    }
    
    private var headerView: some View {
        HStack {
            Text("MountMate")
                .font(.headline)
            Spacer()

            Button(action: {
                driveManager.unmountAllDrives()
            }) {
                Image(systemName: "eject.circle.fill")
                    .opacity(driveManager.isUnmountingAll ? 0 : 1)
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Unmount All", comment: "Unmount All button tooltip"))
            // Disable if there's nothing to unmount OR if it's already in progress
            .disabled(!canUnmountAll || driveManager.isUnmountingAll)
            .overlay {
                if driveManager.isUnmountingAll {
                    ProgressView().controlSize(.small)
                }
            }
            
            Button {
                openWindow(id: "settings-window")
            } label: {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(.plain)
            .help("Settings")
            
            Button(action: {
                driveManager.refreshDrives()
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh Drives")
            
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Image(systemName: "power")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Quit MountMate", comment: "Quit button tooltip"))
        }
        .padding()
    }
    
    private var driveListView: some View {
        List {
            ForEach(sortedGroupKeys, id: \.self) { key in
                Section(header: Text(key)) {
                    if let drives = groupedDrives[key] {
                        ForEach(drives) { drive in
                            DriveRowView(drive: drive, manager: driveManager)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(maxHeight: 300)
    }
    
    private var noDrivesView: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.fill.badge.questionmark")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            
            Text(NSLocalizedString("No Drives Found", comment: "Empty state title"))
                .font(.headline)
            
            Text(NSLocalizedString("Connect a USB drive, SD card, or mount a disk image to see it here.", comment: "Empty state description"))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(height: 150)
    }
    
}


struct DriveRowView: View {
    let drive: Drive
    @ObservedObject var manager: DriveManager
    
    private var isLoading: Bool {
        return manager.busyDriveIdentifier == drive.deviceIdentifier
    }
    
    var body: some View {
        HStack(spacing: 0) {
            
            HStack {
                Image(systemName: "externaldrive")
                    .font(.title2)
                    .foregroundColor(drive.isMounted ? .accentColor : .secondary)
                    .frame(width: 30, alignment: .center)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(drive.name)
                        .fontWeight(.bold)
                    
                    if drive.isMounted {
                        if let percentage = drive.usagePercentage {
                            ProgressView(value: percentage)
                                .progressViewStyle(.linear)
                        }
                        
                        HStack {
                            if let free = drive.freeSpace, let total = drive.totalSize {
                                Text("\(free) \(NSLocalizedString("free of", comment: "e.g., 100GB free of 500GB")) \(total)")
                            }
                            Spacer()
                            if let fsType = drive.fileSystemType {
                                Text(fsType)
                                    .padding(.horizontal, 5)
                                    .background(Color.secondary.opacity(0.2))
                                    .cornerRadius(4)
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        
                    } else {
                        Text("Unmounted")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer() // Pushes the button to the right
            }
            .contentShape(Rectangle()) // Makes the entire area of this HStack tappable
            .onTapGesture {
                if drive.isMounted, let mountPoint = drive.mountPoint {
                    NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
                }
            }
            
            // The Mount/Unmount button is now a sibling to the clickable area,
            // so their gestures do not conflict.
            Button(action: {
                if drive.isMounted {
                    manager.unmount(drive: drive)
                } else {
                    manager.mount(drive: drive)
                }
            }) {
                Text(drive.isMounted ? NSLocalizedString("Unmount", comment: "Unmount button") : NSLocalizedString("Mount", comment: "Mount button"))
                    .opacity(isLoading ? 0 : 1)
            }
            .buttonStyle(.bordered)
            .tint(drive.isMounted ? .red : .blue)
            .disabled(isLoading)
            .overlay {
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            // Add a little padding to separate it from the edge
            .padding(.leading, 8)
        }
    }
}
