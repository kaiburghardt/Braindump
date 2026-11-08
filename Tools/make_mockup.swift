// Puts a window capture of Braindump on a MacBook screen for the README.
// Usage: make_mockup <window.png> <out.png> [dark|light] [output width in px, default 1800]
//
// The capture comes from `screencapture -l <windowID> -o` (no shadow, transparent corners),
// at any scale. It's placed as a 1080 pt wide window (the default window size) on a
// 1280 × 832 pt screen – a 13" MacBook at a larger text size – so the window fills most of it.
// Everything around it is drawn here: wallpaper, menu bar, notch and the device. No Apple artwork.
// `dark` gives a dark wallpaper, white menu bar text and a space black device; `light` a pale
// wallpaper and a silver device. The background stays transparent.
import AppKit
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: make_mockup <window.png> <out.png> [dark|light] [width]")
    exit(1)
}
let dark = args.count > 3 ? args[3] != "light" : true
let outWidth = args.count > 4 ? (Double(args[4]) ?? 1800) : 1800

guard let windowImage = NSImage(contentsOfFile: args[1])?
    .cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    print("can't read \(args[1])")
    exit(1)
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func nsColor(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(cgColor: rgb(hex, alpha))!
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// Rounded rect with separate radii for the top and bottom corners (y grows upwards).
func roundedRect(_ r: CGRect, top: CGFloat, bottom: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + bottom, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - bottom, y: r.minY))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + bottom), radius: bottom)
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - top))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - top, y: r.maxY), radius: top)
    p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY))
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - top), radius: top)
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + bottom))
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + bottom, y: r.minY), radius: bottom)
    p.closeSubpath()
    return p
}

// MARK: - Layout (points, y grows upwards)

let screenSize = CGSize(width: 1280, height: 832)
let windowWidth: CGFloat = 1080
let windowSize = CGSize(
    width: windowWidth,
    height: windowWidth * CGFloat(windowImage.height) / CGFloat(windowImage.width)
)
let menuBarHeight: CGFloat = 30
let bezel = (side: CGFloat(19), top: CGFloat(19), bottom: CGFloat(23))
let rim: CGFloat = 3  // aluminium edge around the black bezel
let lidSize = CGSize(
    width: screenSize.width + 2 * (bezel.side + rim),
    height: screenSize.height + bezel.top + bezel.bottom + 2 * rim
)
let baseSize = CGSize(width: lidSize.width * 1.13, height: 19)
let margin = (side: CGFloat(14), top: CGFloat(10), bottom: CGFloat(24))

let canvasSize = CGSize(
    width: baseSize.width + 2 * margin.side,
    height: margin.bottom + baseSize.height + lidSize.height + margin.top
)
let midX = canvasSize.width / 2
let baseRect = CGRect(x: midX - baseSize.width / 2, y: margin.bottom, width: baseSize.width, height: baseSize.height)
let lidRect = CGRect(x: midX - lidSize.width / 2, y: baseRect.maxY - 1, width: lidSize.width, height: lidSize.height)
let screenRect = CGRect(
    x: lidRect.minX + rim + bezel.side, y: lidRect.minY + rim + bezel.bottom,
    width: screenSize.width, height: screenSize.height
)

// MARK: - Context

let scale = outWidth / canvasSize.width
let pixelWidth = Int(outWidth.rounded())
let pixelHeight = Int((canvasSize.height * scale).rounded())
let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(
    data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
ctx.interpolationQuality = .high
ctx.scaleBy(x: scale, y: scale)
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

/// Shadow offsets and blur ignore the CTM, so they're scaled by hand.
func setShadow(dy: CGFloat, blur: CGFloat, color: CGColor) {
    ctx.setShadow(offset: CGSize(width: 0, height: dy * scale), blur: blur * scale, color: color)
}

// MARK: - Shadow under the device

ctx.saveGState()
ctx.translateBy(x: midX, y: baseRect.minY + 3)
ctx.scaleBy(x: 1, y: 0.035)
ctx.drawRadialGradient(
    gradient([rgb(0x000000, dark ? 0.55 : 0.32), rgb(0x000000, 0)]),
    startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: baseSize.width * 0.53, options: []
)
ctx.restoreGState()

// MARK: - Lid

let lidPath = roundedRect(lidRect, top: 30, bottom: 8)
ctx.saveGState()
ctx.addPath(lidPath)
ctx.clip()
ctx.drawLinearGradient(
    dark
        ? gradient([rgb(0x56575B), rgb(0x3A3B3E), rgb(0x2E2F31)], [0, 0.1, 1])
        : gradient([rgb(0xE9EAEC), rgb(0xCFD0D3), rgb(0xBDBEC2)], [0, 0.1, 1]),
    start: CGPoint(x: midX, y: lidRect.maxY), end: CGPoint(x: midX, y: lidRect.minY), options: []
)
ctx.restoreGState()

let bezelRect = lidRect.insetBy(dx: rim, dy: rim)
ctx.addPath(roundedRect(bezelRect, top: 27, bottom: 5))
ctx.setFillColor(rgb(0x050506))
ctx.fillPath()

// MARK: - Screen

let screenPath = roundedRect(screenRect, top: 11, bottom: 0)
ctx.saveGState()
ctx.addPath(screenPath)
ctx.clip()

// Wallpaper: soft colour blobs on a flat ground, in the icon's violet and pink.
let s = screenRect
ctx.setFillColor(dark ? rgb(0x110C2B) : rgb(0xF4EFFF))
ctx.fill(s)
let blobs: [(x: CGFloat, y: CGFloat, r: CGFloat, color: UInt32, alpha: CGFloat)] = dark
    ? [
        (0.12, 0.20, 0.62, 0x5B3FD9, 0.95),
        (0.92, 0.88, 0.55, 0xD9498F, 0.75),
        (0.80, 0.05, 0.50, 0x2C5BE8, 0.65),
        (0.38, 1.00, 0.45, 0x8A6BFF, 0.55),
        (0.55, 0.45, 0.35, 0x3E25A8, 0.45),
    ]
    : [
        (0.10, 0.18, 0.62, 0xC4B2FF, 0.95),
        (0.92, 0.88, 0.55, 0xFFBFDA, 0.85),
        (0.82, 0.05, 0.50, 0xB9D4FF, 0.80),
        (0.38, 1.00, 0.45, 0xFFDDBF, 0.70),
        (0.55, 0.45, 0.35, 0xE3D8FF, 0.60),
    ]
for blob in blobs {
    let center = CGPoint(x: s.minX + blob.x * s.width, y: s.minY + blob.y * s.height)
    ctx.drawRadialGradient(
        gradient([rgb(blob.color, blob.alpha), rgb(blob.color, blob.alpha * 0.45), rgb(blob.color, 0)], [0, 0.5, 1]),
        startCenter: center, startRadius: 0, endCenter: center, endRadius: blob.r * s.width, options: []
    )
}

// Menu bar (transparent, like macOS 26): app menus on the left, status items and clock on the right.
let ink = dark ? nsColor(0xFFFFFF, 0.92) : nsColor(0x000000, 0.82)
let menuMidY = s.maxY - menuBarHeight / 2
func drawText(_ text: String, x: CGFloat, weight: NSFont.Weight, alignRight: Bool = false) -> CGFloat {
    let str = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: weight),
        .foregroundColor: ink,
    ])
    let size = str.size()
    let originX = alignRight ? x - size.width : x
    str.draw(at: CGPoint(x: originX, y: menuMidY - size.height / 2))
    return size.width
}
var x = s.minX + 18
for (i, item) in ["Braindump", "File", "Edit", "View", "Note", "Window", "Help"].enumerated() {
    x += drawText(item, x: x, weight: i == 0 ? .bold : .medium) + 19
}
var right = s.maxX - 16
right -= drawText("Sun 8 Nov  9:41", x: right, weight: .medium, alignRight: true) + 17
for symbol in ["switch.2", "magnifyingglass", "wifi", "battery.100percent"] {
    let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
    guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
    else { continue }
    let size = image.size
    image.draw(in: CGRect(x: right - size.width, y: menuMidY - size.height / 2, width: size.width, height: size.height))
    right -= size.width + 17
}

// The window, centred below the menu bar, with a macOS-like shadow.
let windowRect = CGRect(
    x: s.midX - windowSize.width / 2,
    y: s.minY + (s.height - menuBarHeight - windowSize.height) / 2,
    width: windowSize.width, height: windowSize.height
)
ctx.saveGState()
setShadow(dy: -18, blur: 55, color: rgb(0x000000, dark ? 0.6 : 0.3))
ctx.draw(windowImage, in: windowRect)
ctx.restoreGState()
ctx.saveGState()
setShadow(dy: -1, blur: 3, color: rgb(0x000000, dark ? 0.5 : 0.18))
ctx.draw(windowImage, in: windowRect)
ctx.restoreGState()

ctx.restoreGState()  // screen clip

// Notch with the camera.
let notchSize = CGSize(width: 160, height: menuBarHeight)
let notchRect = CGRect(x: midX - notchSize.width / 2, y: s.maxY - notchSize.height, width: notchSize.width, height: notchSize.height + bezel.top)
ctx.addPath(roundedRect(notchRect, top: 0, bottom: 10))
ctx.setFillColor(rgb(0x050506))
ctx.fillPath()
let camera = CGPoint(x: midX, y: s.maxY - notchSize.height / 2 + 1)
ctx.setFillColor(rgb(0x1B1D24))
ctx.fillEllipse(in: CGRect(x: camera.x - 3.2, y: camera.y - 3.2, width: 6.4, height: 6.4))
ctx.setFillColor(rgb(0x2C3A5C, 0.9))
ctx.fillEllipse(in: CGRect(x: camera.x - 1.4, y: camera.y - 1.4, width: 2.8, height: 2.8))

// MARK: - Base

let b = baseRect
let taper = b.height * 2.6
let basePath = CGMutablePath()
basePath.move(to: CGPoint(x: b.minX, y: b.maxY))
basePath.addLine(to: CGPoint(x: b.maxX, y: b.maxY))
basePath.addCurve(
    to: CGPoint(x: b.maxX - taper, y: b.minY),
    control1: CGPoint(x: b.maxX, y: b.minY + b.height * 0.35),
    control2: CGPoint(x: b.maxX - taper * 0.35, y: b.minY)
)
basePath.addLine(to: CGPoint(x: b.minX + taper, y: b.minY))
basePath.addCurve(
    to: CGPoint(x: b.minX, y: b.maxY),
    control1: CGPoint(x: b.minX + taper * 0.35, y: b.minY),
    control2: CGPoint(x: b.minX, y: b.minY + b.height * 0.35)
)
basePath.closeSubpath()

ctx.saveGState()
ctx.addPath(basePath)
ctx.clip()
ctx.drawLinearGradient(
    dark
        ? gradient([rgb(0x6A6B70), rgb(0x46474B), rgb(0x333437), rgb(0x1E1F21)], [0, 0.12, 0.6, 1])
        : gradient([rgb(0xF4F4F6), rgb(0xDADBDE), rgb(0xBFC0C4), rgb(0x8F9095)], [0, 0.12, 0.6, 1]),
    start: CGPoint(x: midX, y: b.maxY), end: CGPoint(x: midX, y: b.minY), options: []
)
// Darker ends, where the rounded corners turn away.
ctx.drawLinearGradient(
    gradient([rgb(0x000000, dark ? 0.35 : 0.18), rgb(0x000000, 0), rgb(0x000000, 0), rgb(0x000000, dark ? 0.35 : 0.18)], [0, 0.06, 0.94, 1]),
    start: CGPoint(x: b.minX, y: b.midY), end: CGPoint(x: b.maxX, y: b.midY), options: []
)
// The groove for opening the lid.
let groove = CGMutablePath()
let grooveWidth: CGFloat = 190, grooveDepth: CGFloat = 7
groove.move(to: CGPoint(x: midX - grooveWidth / 2, y: b.maxY + 0.5))
groove.addCurve(
    to: CGPoint(x: midX - grooveWidth / 2 + 16, y: b.maxY - grooveDepth),
    control1: CGPoint(x: midX - grooveWidth / 2 + 8, y: b.maxY),
    control2: CGPoint(x: midX - grooveWidth / 2 + 6, y: b.maxY - grooveDepth)
)
groove.addLine(to: CGPoint(x: midX + grooveWidth / 2 - 16, y: b.maxY - grooveDepth))
groove.addCurve(
    to: CGPoint(x: midX + grooveWidth / 2, y: b.maxY + 0.5),
    control1: CGPoint(x: midX + grooveWidth / 2 - 6, y: b.maxY - grooveDepth),
    control2: CGPoint(x: midX + grooveWidth / 2 - 8, y: b.maxY)
)
groove.closeSubpath()
ctx.addPath(groove)
ctx.clip()
ctx.drawLinearGradient(
    dark
        ? gradient([rgb(0x141516), rgb(0x2C2D30)])
        : gradient([rgb(0x9C9DA2), rgb(0xC9CACE)]),
    start: CGPoint(x: midX, y: b.maxY), end: CGPoint(x: midX, y: b.maxY - grooveDepth), options: []
)
ctx.restoreGState()

// Hinge line between lid and base.
ctx.setFillColor(rgb(0x000000, dark ? 0.6 : 0.3))
ctx.fill(CGRect(x: b.minX + 2, y: b.maxY - 0.6, width: b.width - 4, height: 0.9))

// MARK: - Write

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: args[2])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    print("can't write \(args[2])")
    exit(1)
}
print("✓ \(args[2]) (\(pixelWidth) × \(pixelHeight))")
