// Draws the app icon (the menu bar shield on a green rounded square) into an .iconset folder.
// Used by build.sh:  swift make-icon.swift <out.iconset>  then  iconutil -c icns <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // macOS icon grid: the tile is 824/1024 of the canvas, with a ~185/1024 corner radius.
    let tile = NSRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let path = NSBezierPath(roundedRect: tile, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)

    // soft drop shadow under the tile
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = s * 20 / 1024
    shadow.shadowOffset = NSSize(width: 0, height: -s * 8 / 1024)
    shadow.set()
    NSColor(calibratedRed: 0.13, green: 0.62, blue: 0.30, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // green gradient, lighter at the top
    NSGradient(starting: NSColor(calibratedRed: 0.30, green: 0.82, blue: 0.42, alpha: 1),
               ending: NSColor(calibratedRed: 0.10, green: 0.58, blue: 0.27, alpha: 1))!
        .draw(in: path, angle: -90)

    // the same symbol as the menu bar's "connected" state: white shield, green lock
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.48, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [
            NSColor(calibratedRed: 0.10, green: 0.58, blue: 0.27, alpha: 1), .white]))
    if let sym = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let sz = sym.size
        let r = NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height)
        sym.draw(in: r)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
