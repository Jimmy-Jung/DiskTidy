import AppKit

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: swift generate-icon.swift <output.png>\n".utf8))
    exit(1)
}
let outputPath = CommandLine.arguments[1]

let size: CGFloat = 1024
let canvas = NSImage(size: NSSize(width: size, height: size))
canvas.lockFocus()

let bgRect = NSRect(x: 0, y: 0, width: size, height: size)
let cornerRadius = size * 0.2237
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)
NSColor(calibratedRed: 0.20, green: 0.47, blue: 0.95, alpha: 1.0).setFill()
bgPath.fill()

if let symbol = NSImage(systemSymbolName: "internaldrive.fill", accessibilityDescription: nil) {
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    let configured = symbol.withSymbolConfiguration(config) ?? symbol
    let imgSize = configured.size
    let origin = NSPoint(x: (size - imgSize.width) / 2, y: (size - imgSize.height) / 2)
    configured.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
}

canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("PNG conversion failed\n".utf8))
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
