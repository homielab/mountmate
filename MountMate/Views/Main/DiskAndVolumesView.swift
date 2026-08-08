//  Created by homielab.com

import SwiftUI

struct DiskAndVolumesView: View {
  let disk: PhysicalDisk
  @ObservedObject var customMountPointEditor: CustomMountPointEditorState
  @State private var isExpanded = true
  @EnvironmentObject var manager: DriveManager
  @AppStorage("showOnlyVolumes") private var showOnlyVolumes = false

  private var visibleContainers: [APFSContainer] {
    disk.containers.filter { !$0.volumes.isEmpty }
  }

  var body: some View {
    Group {
      if !showOnlyVolumes {
        DiskHeaderRow(disk: disk, isExpanded: $isExpanded)
      }
      if isExpanded || showOnlyVolumes {
        ForEach(disk.partitions) { partition in
          VolumeRowView(
            volume: partition,
            customMountPointEditor: customMountPointEditor
          )
          .padding(.leading, showOnlyVolumes ? 0 : 24)
        }
        ForEach(visibleContainers) { container in
          if !showOnlyVolumes {
            ContainerRowView(container: container)
          }
          ForEach(container.volumes) { volume in
            VolumeRowView(
              volume: volume,
              customMountPointEditor: customMountPointEditor
            )
            .padding(.leading, showOnlyVolumes ? 0 : 48)
          }
        }
      }
    }
    .onReceive(manager.driveExpansionSubject) { expanded in
      withAnimation {
        self.isExpanded = expanded
      }
    }
  }
}
