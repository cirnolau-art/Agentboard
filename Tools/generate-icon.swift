import AppKit

let output = CommandLine.arguments[1]
let fm = FileManager.default
try fm.createDirectory(atPath: output, withIntermediateDirectories: true)
for (name, size) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)
    let rect = NSRect(x: 46, y: 46, width: 932, height: 932)
    let background = NSBezierPath(roundedRect: rect, xRadius: 205, yRadius: 205)
    NSGradient(starting: NSColor(red: 0.13, green: 0.20, blue: 0.24, alpha: 1), ending: NSColor(red: 0.04, green: 0.07, blue: 0.10, alpha: 1))!.draw(in: background, angle: -70)
    let mint = NSColor(red: 0.50, green: 0.91, blue: 0.77, alpha: 1)
    for (offset, alpha) in [(0.0,0.45),(130.0,0.72),(260.0,1.0)] {
        let center: CGFloat = 365 + offset
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 512, y: center + 145)); p.line(to: NSPoint(x: 788, y: center)); p.line(to: NSPoint(x: 512, y: center - 145)); p.line(to: NSPoint(x: 236, y: center)); p.close()
        NSColor(red: 0.065, green: 0.105, blue: 0.14, alpha: 1).setStroke(); p.lineWidth = 38; p.lineJoinStyle = .round; p.stroke()
        mint.withAlphaComponent(alpha).setFill(); p.fill()
    }
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
}
