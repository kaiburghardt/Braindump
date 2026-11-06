// Draws the Braindump icon: a happy pink brain with a face on a violet background,
// with two sticky notes (one checked off) and a few sparkles popping out at the top.
// Usage: make_icon <out.png>
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func sparkle(center c: CGPoint, radius r: CGFloat) -> CGPath {
    let k = r * 0.16
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.addCurve(to: CGPoint(x: c.x + r, y: c.y), control1: CGPoint(x: c.x + k, y: c.y + k), control2: CGPoint(x: c.x + k, y: c.y + k))
    p.addCurve(to: CGPoint(x: c.x, y: c.y - r), control1: CGPoint(x: c.x + k, y: c.y - k), control2: CGPoint(x: c.x + k, y: c.y - k))
    p.addCurve(to: CGPoint(x: c.x - r, y: c.y), control1: CGPoint(x: c.x - k, y: c.y - k), control2: CGPoint(x: c.x - k, y: c.y - k))
    p.addCurve(to: CGPoint(x: c.x, y: c.y + r), control1: CGPoint(x: c.x - k, y: c.y + k), control2: CGPoint(x: c.x - k, y: c.y + k))
    p.closeSubpath()
    return p
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// MARK: - Icon body (macOS grid: 824 pt body in a 1024 pt canvas)

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 26, color: rgb(0x000000, 0.30))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(0x5B3FD9))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
ctx.drawLinearGradient(
    gradient([rgb(0x8A6BFF), rgb(0x5B3FD9), rgb(0x3E25A8)], [0, 0.55, 1]),
    start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: []
)
// soft glow behind the brain
ctx.drawRadialGradient(
    gradient([rgb(0xC9B6FF, 0.45), rgb(0xC9B6FF, 0)]),
    startCenter: CGPoint(x: 512, y: 480), startRadius: 0,
    endCenter: CGPoint(x: 512, y: 480), endRadius: 420, options: []
)
ctx.restoreGState()

// move the motif down a bit so it sits optically centered with the notes on top
ctx.saveGState()
ctx.translateBy(x: 0, y: -28)

// MARK: - Brain geometry

let cx: CGFloat = 512, cy: CGFloat = 445

// Two hemispheres, each an ellipse plus lobe circles along the edge; their union
// gives the bumpy silhouette with the notch at the top center.
struct Lobe { var c: CGPoint; var r: CGFloat }
var leftLobes: [Lobe] = []
let hemiDX: CGFloat = 108
for (deg, r) in [(76, 90), (116, 92), (156, 90), (196, 86), (236, 80), (274, 76)] as [(CGFloat, CGFloat)] {
    let t = deg * .pi / 180
    let ry: CGFloat = sin(t) > 0 ? 148 : 122
    leftLobes.append(Lobe(c: CGPoint(x: cx - hemiDX + 134 * cos(t), y: cy + ry * sin(t)), r: r))
}
let rightLobes = leftLobes.map { Lobe(c: CGPoint(x: 2 * cx - $0.c.x, y: $0.c.y), r: $0.r) }
let bottomLobe = Lobe(c: CGPoint(x: cx, y: cy - 126), r: 78)
// order around the outline (clockwise from the notch at the top)
let ring: [Lobe] = rightLobes + [bottomLobe] + leftLobes.reversed()

let brainPath: CGPath = {
    var p: CGPath = CGPath(ellipseIn: CGRect(x: cx - hemiDX - 160, y: cy - 150, width: 320, height: 320), transform: nil)
    p = p.union(CGPath(ellipseIn: CGRect(x: cx + hemiDX - 160, y: cy - 150, width: 320, height: 320), transform: nil))
    for l in ring {
        p = p.union(CGPath(ellipseIn: CGRect(x: l.c.x - l.r, y: l.c.y - l.r, width: 2 * l.r, height: 2 * l.r), transform: nil))
    }
    return p
}()

// notches between neighbouring lobes (outer intersection of the circles)
func notch(_ a: Lobe, _ b: Lobe) -> CGPoint? {
    let dx = b.c.x - a.c.x, dy = b.c.y - a.c.y
    let d = (dx * dx + dy * dy).squareRoot()
    guard d < a.r + b.r, d > abs(a.r - b.r) else { return nil }
    let along = (a.r * a.r - b.r * b.r + d * d) / (2 * d)
    let h = (a.r * a.r - along * along).squareRoot()
    let m = CGPoint(x: a.c.x + along * dx / d, y: a.c.y + along * dy / d)
    let p1 = CGPoint(x: m.x + h * dy / d, y: m.y - h * dx / d)
    let p2 = CGPoint(x: m.x - h * dy / d, y: m.y + h * dx / d)
    func dist(_ p: CGPoint) -> CGFloat { hypot(p.x - cx, p.y - cy) }
    return dist(p1) > dist(p2) ? p1 : p2
}

let outline = rgb(0xA8285F)
let outlineWidth: CGFloat = 15

// MARK: - Sticky notes sticking out of the top (drawn behind the brain)

enum NoteMark { case check, lines }

func stickyNote(center: CGPoint, size: CGFloat, angle: CGFloat, color: CGColor, mark: NoteMark) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle)
    let r = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
    let p = CGPath(roundedRect: r, cornerWidth: size * 0.1, cornerHeight: size * 0.1, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: rgb(0x1E0B5C, 0.40))
    ctx.addPath(p)
    ctx.setFillColor(color)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    switch mark {
    case .check:
        ctx.setStrokeColor(rgb(0x5B3FD9))
        ctx.setLineWidth(size * 0.12)
        ctx.move(to: CGPoint(x: -size * 0.22, y: size * 0.10))
        ctx.addLine(to: CGPoint(x: -size * 0.05, y: -size * 0.06))
        ctx.addLine(to: CGPoint(x: size * 0.25, y: size * 0.26))
        ctx.strokePath()
    case .lines:
        ctx.setStrokeColor(rgb(0x000000, 0.22))
        ctx.setLineWidth(size * 0.085)
        for (y, w) in [(0.24, 0.52), (0.04, 0.38)] as [(CGFloat, CGFloat)] {
            ctx.move(to: CGPoint(x: -size * 0.26, y: size * y))
            ctx.addLine(to: CGPoint(x: -size * 0.26 + size * w, y: size * y))
            ctx.strokePath()
        }
    }
    ctx.restoreGState()
}

stickyNote(center: CGPoint(x: 352, y: 728), size: 160, angle: -0.26, color: rgb(0x7FE3C6), mark: .lines)
stickyNote(center: CGPoint(x: 690, y: 748), size: 176, angle: 0.24, color: rgb(0xFFD84D), mark: .check)

// drop shadow + outline
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 34, color: rgb(0x1E0B5C, 0.45))
ctx.addPath(brainPath)
ctx.setLineWidth(outlineWidth * 2)
ctx.setLineJoin(.round)
ctx.setStrokeColor(outline)
ctx.setFillColor(outline)
ctx.drawPath(using: .fillStroke)
ctx.restoreGState()

// fill
ctx.saveGState()
ctx.addPath(brainPath)
ctx.clip()
ctx.drawLinearGradient(
    gradient([rgb(0xFFBFDA), rgb(0xFF92C0), rgb(0xF472AA)], [0, 0.5, 1]),
    start: CGPoint(x: cx, y: cy + 240), end: CGPoint(x: cx, y: cy - 240), options: []
)

// inner shadow at the bottom (light from above)
let hole = CGMutablePath()
hole.addRect(body.insetBy(dx: -200, dy: -200))
hole.addPath(brainPath)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 22), blur: 26, color: rgb(0xC8387C, 0.6))
ctx.addPath(hole)
ctx.setFillColor(rgb(0x000000))
ctx.fillPath(using: .evenOdd)
ctx.restoreGState()

// highlight edge at the top
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 12, color: rgb(0xFFFFFF, 0.55))
ctx.addPath(hole)
ctx.fillPath(using: .evenOdd)
ctx.restoreGState()

ctx.setLineCap(.round)
ctx.setLineJoin(.round)

func smooth(_ p: [CGPoint]) -> CGPath {
    // Catmull-Rom → Bézier through the points
    let path = CGMutablePath()
    path.move(to: p[0])
    for i in 0..<(p.count - 1) {
        let p0 = i > 0 ? p[i - 1] : p[i]
        let p1 = p[i], p2 = p[i + 1]
        let p3 = i + 2 < p.count ? p[i + 2] : p[i + 1]
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        path.addCurve(to: p2, control1: c1, control2: c2)
    }
    return path
}

// folds: short curled strokes from the notches at the edge inwards
let gyrus = rgb(0xD5468A)
ctx.setStrokeColor(gyrus)
ctx.setLineWidth(15)
var notches: [CGPoint] = []
for i in 0..<ring.count {
    notches.append(notch(ring[i], ring[(i + 1) % ring.count]) ?? .zero)
}
// (length, curl direction) per notch in ring order; 0 = no fold
let folds: [(len: CGFloat, side: CGFloat)] = [
    (74, -1), (88, 1), (80, -1), (58, 1), (0, 1), (0, 1),
    (0, 1), (0, 1), (60, -1), (84, 1), (86, -1), (70, 1), (0, 1),
]
for (i, n) in notches.enumerated() where folds[i].len > 0 {
    let target = CGPoint(x: n.x < cx ? cx - 70 : cx + 70, y: cy + 30)
    let vx = target.x - n.x, vy = target.y - n.y
    let len = hypot(vx, vy)
    let d = CGPoint(x: vx / len, y: vy / len)
    let nrm = CGPoint(x: -d.y * folds[i].side, y: d.x * folds[i].side)
    let L = folds[i].len
    func at(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
        CGPoint(x: n.x + d.x * a + nrm.x * b, y: n.y + d.y * a + nrm.y * b)
    }
    ctx.addPath(smooth([at(-20, 0), at(L * 0.45, L * 0.14), at(L, L * 0.04), at(L * 1.08, -L * 0.32)]))
    ctx.strokePath()
}

// center fissure between the hemispheres
let top = notches[ring.count - 1]
ctx.addPath(smooth([
    CGPoint(x: top.x, y: top.y + 20), top,
    CGPoint(x: cx - 12, y: cy + 150), CGPoint(x: cx + 10, y: cy + 108), CGPoint(x: cx, y: cy + 72),
]))
ctx.strokePath()

// glossy highlights
ctx.setStrokeColor(rgb(0xFFFFFF, 0.8))
ctx.setLineWidth(17)
for l in [leftLobes[1], leftLobes[0], rightLobes[0]] {
    ctx.addArc(center: l.c, radius: l.r - 30, startAngle: 0.78 * .pi, endAngle: 0.62 * .pi, clockwise: true)
    ctx.strokePath()
}

ctx.restoreGState()

// MARK: - Face

let faceY = cy - 40
let eyeDX: CGFloat = 92
let ink = rgb(0x3A0F38)

// blush
for s: CGFloat in [-1, 1] {
    ctx.addEllipse(in: CGRect(x: cx + s * 168 - 42, y: faceY - 78 - 24, width: 84, height: 48))
    ctx.setFillColor(rgb(0xFF4F8B, 0.55))
    ctx.fillPath()
}

// eyes
for s: CGFloat in [-1, 1] {
    let e = CGPoint(x: cx + s * eyeDX, y: faceY)
    ctx.addEllipse(in: CGRect(x: e.x - 34, y: e.y - 44, width: 68, height: 88))
    ctx.setFillColor(ink)
    ctx.fillPath()
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.addEllipse(in: CGRect(x: e.x - 2, y: e.y + 6, width: 26, height: 26))
    ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: e.x - 20, y: e.y - 26, width: 12, height: 12))
    ctx.fillPath()
}

// open smile with tongue
let mouthY = faceY - 72
let mouth = CGMutablePath()
mouth.move(to: CGPoint(x: cx - 46, y: mouthY))
mouth.addQuadCurve(to: CGPoint(x: cx + 46, y: mouthY), control: CGPoint(x: cx, y: mouthY + 8))
mouth.addCurve(to: CGPoint(x: cx - 46, y: mouthY),
               control1: CGPoint(x: cx + 44, y: mouthY - 64), control2: CGPoint(x: cx - 44, y: mouthY - 64))
mouth.closeSubpath()
ctx.addPath(mouth)
ctx.setFillColor(ink)
ctx.fillPath()
ctx.saveGState()
ctx.addPath(mouth)
ctx.clip()
ctx.addEllipse(in: CGRect(x: cx - 30, y: mouthY - 66, width: 60, height: 44))
ctx.setFillColor(rgb(0xFF6F9F))
ctx.fillPath()
ctx.restoreGState()

// MARK: - Sparkles

ctx.setFillColor(rgb(0xFFF3B0))
ctx.addPath(sparkle(center: CGPoint(x: 512, y: 812), radius: 58))
ctx.fillPath()
ctx.addPath(sparkle(center: CGPoint(x: 222, y: 640), radius: 30))
ctx.fillPath()
ctx.addPath(sparkle(center: CGPoint(x: 826, y: 600), radius: 24))
ctx.fillPath()

ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outPath))
