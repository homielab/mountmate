//  Created by homielab.com

import SwiftUI

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
