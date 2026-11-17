// Tiles PNG frames into one labelled contact sheet. Run via scripts/viz/tool.sh contact-sheet ...
//
//   contact-sheet <out.png> [--cols N] <frame.png>...
//
// Each tile is labelled with its file name (minus "frame-" and ".png"), so a sheet made by
// scripts/viz/frames.sh shows the timeline position of every frame. Works without a WindowServer.
import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("contact-sheet: \(message)\n".utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { fail("usage: contact-sheet <out.png> [--cols N] <frame.png>...") }
let out = args.removeFirst()
var columns: Int?
if let flag = args.firstIndex(of: "--cols"), flag + 1 < args.count {
    columns = Int(args[flag + 1])
    args.removeSubrange(flag...(flag + 1))
}
guard !args.isEmpty else { fail("no input frames") }

let frames: [(label: String, image: CGImage)] = args.map { path in
    guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fail("cannot read \(path)")
    }
    var label = URL(filePath: path).deletingPathExtension().lastPathComponent
    if label.hasPrefix("frame-") { label.removeFirst("frame-".count) }
    return (label, image)
}

let cols = max(1, columns ?? (frames.count <= 4 ? 2 : 3))
let rows = (frames.count + cols - 1) / cols
let width = frames[0].image.width
let height = frames[0].image.height
let gap = 4

guard
    let context = CGContext(
        data: nil, width: cols * width + (cols - 1) * gap, height: rows * height + (rows - 1) * gap,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fail("cannot allocate the sheet") }
context.setFillColor(CGColor(gray: 0.35, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))

NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
let fontSize = CGFloat(max(12, height / 22))
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
    .foregroundColor: NSColor.white,
    .backgroundColor: NSColor(white: 0, alpha: 0.6),
]
for (index, frame) in frames.enumerated() {
    let x = (index % cols) * (width + gap)
    let y = (rows - 1 - index / cols) * (height + gap)  // CoreGraphics origin is bottom-left
    context.draw(frame.image, in: CGRect(x: x, y: y, width: width, height: height))
    (" \(frame.label) " as NSString).draw(
        at: CGPoint(x: CGFloat(x) + 6, y: CGFloat(y + height) - fontSize * 1.5), withAttributes: attributes)
}

guard let sheet = context.makeImage(),
    let png = NSBitmapImageRep(cgImage: sheet).representation(using: .png, properties: [:])
else { fail("cannot encode the sheet") }
do {
    try png.write(to: URL(filePath: out))
} catch {
    fail("cannot write \(out): \(error)")
}
print("\(out): \(frames.count) frame(s), \(cols) column(s), \(sheet.width)x\(sheet.height)")
