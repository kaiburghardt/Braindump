// Used by ui_test.sh: compares two window captures in the editor area (left part, below the
// toolbar, right of the note icons) and prints "0" or "<pixels> px in x …, y …".
//   imgdiff a.png b.png [fraction of the width to compare, default 0.68]
import CoreGraphics
import Foundation
import ImageIO

func load(_ path: String) -> (data: [UInt8], width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width, height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (data, width, height)
}

let args = CommandLine.arguments
guard args.count >= 3, let a = load(args[1]), let b = load(args[2]), a.width == b.width, a.height == b.height else {
    print("cannot compare")
    exit(2)
}
let fraction = args.count > 3 ? Double(args[3]) ?? 0.68 : 0.68
// Icons are left out: the same symbol image drawn twice can differ slightly in its edges.
let minX = 70, maxX = Int(Double(a.width) * fraction), minY = 110
var count = 0, x0 = Int.max, y0 = Int.max, x1 = 0, y1 = 0
for y in minY..<(a.height - 10) {
    for x in minX..<maxX {
        let i = (y * a.width + x) * 4
        if (0..<3).contains(where: { abs(Int(a.data[i + $0]) - Int(b.data[i + $0])) > 40 }) {
            count += 1
            x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
        }
    }
}
print(count == 0 ? "0" : "\(count) px in x \(x0)…\(x1), y \(y0)…\(y1)")
