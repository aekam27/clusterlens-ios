import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "ClusterLens/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
let side = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: side,
    pixelsHigh: side,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { fatalError("Could not create icon bitmap") }

bitmap.size = NSSize(width: side, height: side)
NSGraphicsContext.saveGraphicsState()
let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.current = graphics

let bounds = NSRect(x: 0, y: 0, width: side, height: side)
NSGradient(colors: [
    NSColor(red: 0.035, green: 0.10, blue: 0.08, alpha: 1),
    NSColor(red: 0.08, green: 0.42, blue: 0.27, alpha: 1)
])!.draw(in: bounds, angle: 48)

NSColor.white.withAlphaComponent(0.055).setFill()
NSBezierPath(ovalIn: NSRect(x: 470, y: 420, width: 760, height: 760)).fill()

let shadow = NSBezierPath(roundedRect: NSRect(x: 205, y: 173, width: 614, height: 678), xRadius: 122, yRadius: 122)
NSColor.black.withAlphaComponent(0.22).setFill()
shadow.fill()

let bodyRect = NSRect(x: 205, y: 204, width: 614, height: 650)
let body = NSBezierPath(roundedRect: bodyRect, xRadius: 120, yRadius: 120)
NSColor(red: 0.91, green: 0.96, blue: 0.93, alpha: 1).setFill()
body.fill()

NSColor(red: 0.10, green: 0.30, blue: 0.23, alpha: 0.23).setStroke()
for y in [420.0, 625.0] {
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 205, y: y))
    line.curve(
        to: NSPoint(x: 819, y: y),
        controlPoint1: NSPoint(x: 330, y: y - 92),
        controlPoint2: NSPoint(x: 690, y: y - 92)
    )
    line.lineWidth = 16
    line.stroke()
}

let codeRect = NSRect(x: 278, y: 390, width: 468, height: 210)
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 144, weight: .bold),
    .foregroundColor: NSColor(red: 0.035, green: 0.25, blue: 0.17, alpha: 1),
    .paragraphStyle: paragraph,
    .kern: -10
]
("{ }" as NSString).draw(in: codeRect, withAttributes: attributes)

NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode PNG") }
try data.write(to: URL(fileURLWithPath: output))
