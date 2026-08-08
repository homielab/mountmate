//  Created by homielab.com

import SwiftUI

struct SettingsView: View {
  var body: some View {
    TabView {
      GeneralSettingsView()
        .tabItem { Label("General", systemImage: "gear") }

      ManagementSettingsView()
        .tabItem { Label("Management", systemImage: "slider.horizontal.3") }

      NetworkSharesSettingsView()
        .tabItem { Label("Network Shares", systemImage: "server.rack") }
    }
    .frame(
      minWidth: 460, idealWidth: 480, maxWidth: 520, minHeight: 540, idealHeight: 640,
      maxHeight: 800)
  }
}
