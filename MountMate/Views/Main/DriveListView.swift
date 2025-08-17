//  Created by homielab.com

import SwiftUI

struct DriveListView: View {
    @ObservedObject var driveManager: DriveManager

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
                            VolumeRowView(volume: volume, manager: driveManager).padding(.leading, 24)
                        }
                    }
                }
            }
            
            if !diskImages.isEmpty {
                Section(header: Text(NSLocalizedString("Disk Images", comment: "Section header"))) {
                    ForEach(diskImages) { disk in
                        DiskHeaderRow(disk: disk, manager: driveManager)
                        ForEach(disk.volumes) { volume in
                            VolumeRowView(volume: volume, manager: driveManager).padding(.leading, 24)
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
}
