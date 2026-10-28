import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let side = CGFloat(pixels)
        let bounds = NSRect(x: side * 0.06, y: side * 0.06, width: side * 0.88, height: side * 0.88)
        let path = NSBezierPath(roundedRect: bounds, xRadius: side * 0.20, yRadius: side * 0.20)
        NSGradient(starting: NSColor(calibratedRed: 1, green: 0.70, blue: 0.23, alpha: 1),
                   ending: NSColor(calibratedRed: 0.94, green: 0.35, blue: 0.12, alpha: 1))!
            .draw(in: path, angle: -90)
        let symbol = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: side * 0.48, weight: .medium))!
        let symbolSize = symbol.size
        let width = side * 0.60
        let height = width * symbolSize.height / symbolSize.width
        symbol.draw(in: NSRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height))
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
