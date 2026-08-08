//  Created by homielab.com

import SwiftUI

struct DriveListView: View {
  let internalDisks: [PhysicalDisk]
  let externalDisks: [PhysicalDisk]
  let diskImages: [PhysicalDisk]
  let networkShares: [NetworkShare]
  let manualShares: [NetworkShare]
  @ObservedObject var customMountPointEditor: CustomMountPointEditorState

  var body: some View {
    List {
      if !internalDisks.isEmpty {
        Section(header: Label("Internal Disks", systemImage: "internaldrive")) {
          ForEach(internalDisks) { disk in
            DiskAndVolumesView(
              disk: disk,
              customMountPointEditor: customMountPointEditor)
          }
        }
      }
      if !externalDisks.isEmpty {
        Section(header: Label("External Disks", systemImage: "externaldrive.fill")) {
          ForEach(externalDisks) { disk in
            DiskAndVolumesView(
              disk: disk,
              customMountPointEditor: customMountPointEditor)
          }
        }
      }
      if !diskImages.isEmpty {
        Section(header: Label("Disk Images", systemImage: "opticaldisc")) {
          ForEach(diskImages) { disk in
            DiskAndVolumesView(
              disk: disk,
              customMountPointEditor: customMountPointEditor)
          }
        }
      }
      if !networkShares.isEmpty {
        Section(header: Label("Saved Network Shares", systemImage: "server.rack")) {
          ForEach(networkShares) { share in NetworkShareMainRow(share: share) }
        }
      }
      if !manualShares.isEmpty {
        Section(header: ManualSharesSectionHeader()) {
          ForEach(manualShares) { share in NetworkShareMainRow(share: share, isManual: true) }
        }
      }
    }
    .listStyle(.sidebar)
    .frame(minHeight: 50)
  }
}
