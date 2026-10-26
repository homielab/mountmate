//  Created by homielab.com

import AppKit

/// Menu bar symbol with a small dot in its top-right corner, used while an
/// update is waiting. Drawn as a template image so it follows the menu bar's
/// light/dark appearance like the plain symbol.
enum BadgedMenuBarIcon {
  private static var cache: [String: NSImage] = [:]

  static func image(symbolName: String) -> NSImage? {
    if let cached = cache[symbolName] { return cached }
    let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    guard
      let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    else { return nil }

    let dotDiameter: CGFloat = 6
    let gap: CGFloat = 1.5
    let size = NSSize(width: symbol.size.width + dotDiameter / 2, height: symbol.size.height)
    let image = NSImage(size: size, flipped: false) { rect in
      symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
      let dot = NSRect(
        x: rect.maxX - dotDiameter, y: rect.maxY - dotDiameter,
        width: dotDiameter, height: dotDiameter)
      // Cut a ring around the dot so it stays readable on top of the symbol.
      NSGraphicsContext.current?.compositingOperation = .clear
      NSBezierPath(ovalIn: dot.insetBy(dx: -gap, dy: -gap)).fill()
      NSGraphicsContext.current?.compositingOperation = .sourceOver
      NSColor.black.setFill()
      NSBezierPath(ovalIn: dot).fill()
      return true
    }
    image.isTemplate = true
    cache[symbolName] = image
    return image
  }
}
