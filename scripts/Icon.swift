import AppKit
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (size, suffix) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")] {
    let n = CGFloat(size)
    let image = NSImage(size: NSSize(width: n, height: n))
    image.lockFocus()
    let bg = NSBezierPath(roundedRect: NSRect(x: n*0.06, y: n*0.06, width: n*0.88, height: n*0.88), xRadius: n*0.20, yRadius: n*0.20)
    NSGradient(starting: NSColor(red: 0.07, green: 0.68, blue: 0.63, alpha: 1), ending: NSColor(red: 0.04, green: 0.36, blue: 0.42, alpha: 1))!.draw(in: bg, angle: -65)
    let p = NSBezierPath(roundedRect: NSRect(x: n*0.27, y: n*0.22, width: n*0.46, height: n*0.55), xRadius: n*0.055, yRadius: n*0.055)
    p.lineWidth = n*0.04
    NSColor.white.setStroke(); p.stroke()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: n*0.39, y: n*0.72, width: n*0.22, height: n*0.09), xRadius: n*0.025, yRadius: n*0.025).fill()
    let lines = NSBezierPath()
    for y: CGFloat in [0.59, 0.47, 0.35] { lines.move(to: NSPoint(x: n*0.37, y: n*y)); lines.line(to: NSPoint(x: n*0.63, y: n*y)) }
    lines.lineWidth = n*0.035; lines.lineCapStyle = .round; lines.stroke()
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(suffix).png"))
}
