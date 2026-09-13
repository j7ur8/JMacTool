import AppKit
import Foundation

// Renders the JMacTool app icon into a macOS .iconset directory:
//   swift build-app-icon.swift <iconset-dir>
// The motif is a display frame around a bold "A" (the English input source
// Input Change switches to), on a dark rounded-rect canvas.

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("Usage: swift build-app-icon.swift <iconset-dir>\n", stderr)
    exit(1)
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let icons: [(size: CGFloat, filename: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

func makeIconRep(size: CGFloat) -> NSBitmapImageRep? {
    // Render into an explicit bitmap so each PNG has exactly `size` pixels,
    // independent of the display's backing scale factor.
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return nil
    }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    let background = NSBezierPath(
        roundedRect: canvas.insetBy(dx: size * 0.08, dy: size * 0.08),
        xRadius: size * 0.22,
        yRadius: size * 0.22
    )
    NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.21, blue: 0.30, alpha: 1.0),
        NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.12, alpha: 1.0)
    ])?.draw(in: background, angle: -90)
    background.addClip()

    // Display frame around the letter.
    let screenRect = NSRect(
        x: size * 0.19,
        y: size * 0.40,
        width: size * 0.62,
        height: size * 0.42
    )
    let screen = NSBezierPath(roundedRect: screenRect, xRadius: size * 0.05, yRadius: size * 0.05)
    NSColor(calibratedRed: 0.92, green: 0.96, blue: 1.0, alpha: 1.0).setStroke()
    screen.lineWidth = max(1.5, size * 0.022)
    screen.stroke()

    // Stand.
    let standPath = NSBezierPath()
    standPath.move(to: NSPoint(x: size * 0.42, y: screenRect.minY))
    standPath.line(to: NSPoint(x: size * 0.38, y: size * 0.28))
    standPath.line(to: NSPoint(x: size * 0.62, y: size * 0.28))
    standPath.line(to: NSPoint(x: size * 0.58, y: screenRect.minY))
    standPath.close()
    NSColor(calibratedRed: 0.92, green: 0.96, blue: 1.0, alpha: 1.0).setFill()
    standPath.fill()
    let base = NSBezierPath(
        roundedRect: NSRect(x: size * 0.32, y: size * 0.245, width: size * 0.36, height: size * 0.035),
        xRadius: size * 0.0175,
        yRadius: size * 0.0175
    )
    base.fill()

    // The letter ties the icon to Input Change (switch to English layout).
    let font = NSFont.systemFont(ofSize: size * 0.30, weight: .bold)
    let text = "A" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white
    ]
    let textSize = text.size(withAttributes: attributes)
    text.draw(
        in: NSRect(
            x: (size - textSize.width) / 2.0,
            y: screenRect.midY - textSize.height / 2.0 - size * 0.005,
            width: textSize.width,
            height: textSize.height
        ),
        withAttributes: attributes
    )

    // Status dot, echoing the menu item indicator.
    let dotDiameter = size * 0.055
    let dot = NSBezierPath(
        roundedRect: NSRect(
            x: screenRect.maxX - dotDiameter * 2.2,
            y: screenRect.minY + dotDiameter * 1.1,
            width: dotDiameter,
            height: dotDiameter
        ),
        xRadius: dotDiameter / 2.0,
        yRadius: dotDiameter / 2.0
    )
    NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1.0).setFill()
    dot.fill()

    return rep
}

for icon in icons {
    guard let rep = makeIconRep(size: icon.size),
          let pngData = rep.representation(using: .png, properties: [:]) else {
        fputs("Failed to render app icon.\n", stderr)
        exit(1)
    }

    try pngData.write(to: outputDirectory.appendingPathComponent(icon.filename))
}
