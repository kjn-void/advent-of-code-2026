import AppKit
import SwiftUI

/// The app icon, drawn in code: a SwiftPM executable has no bundle and no asset catalog, so the app
/// renders this at launch and hands it to the Dock (`NSApp.applicationIconImage`).
///
/// A voxel Christmas tree with ornaments and a gold AoC star, on an isometric tile floor, inside the
/// standard macOS icon shape (an 824-point rounded square on a 1024-point canvas).
enum AppIcon {
    static let canvas: CGFloat = 1024

    @MainActor static func render(size: CGFloat = canvas) -> CGImage? {
        let renderer = ImageRenderer(content: AppIconView().frame(width: canvas, height: canvas))
        renderer.scale = size / canvas
        return renderer.cgImage
    }

    @MainActor static func image() -> NSImage? {
        render().map { NSImage(cgImage: $0, size: NSSize(width: canvas, height: canvas)) }
    }
}

private struct AppIconView: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.width / AppIcon.canvas
            context.scaleBy(x: scale, y: scale)
            Self.draw(in: &context)
        }
    }

    // MARK: Drawing

    private static let body = CGRect(x: 100, y: 100, width: 824, height: 824)

    private static func draw(in context: inout GraphicsContext) {
        let shape = Path(roundedRect: body, cornerRadius: 185, style: .continuous)

        // Drop shadow under the icon body.
        var shadow = context
        shadow.addFilter(.shadow(color: .black.opacity(0.45), radius: 18, y: 12))
        shadow.fill(shape, with: .color(.black))

        context.fill(
            shape,
            with: .linearGradient(
                Gradient(colors: [rgb(0.13, 0.17, 0.36), rgb(0.04, 0.05, 0.13)]),
                startPoint: CGPoint(x: 512, y: 100), endPoint: CGPoint(x: 512, y: 924)))

        var inside = context
        inside.clip(to: shape)
        drawSnow(in: &inside)
        // Warm glow behind the tree.
        inside.fill(
            Path(ellipseIn: CGRect(x: 182, y: 170, width: 660, height: 660)),
            with: .radialGradient(
                Gradient(colors: [rgb(1.0, 0.80, 0.35).opacity(0.28), .clear]),
                center: CGPoint(x: 512, y: 440), startRadius: 0, endRadius: 340))
        drawFloor(in: &inside)
        for voxel in treeVoxels().sorted(by: { $0.depth < $1.depth }) {
            drawCube(voxel, in: &inside)
        }
        drawStar(in: &inside)

        // Thin highlight along the rim, like the system icons.
        context.stroke(
            Path(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerRadius: 184, style: .continuous),
            with: .linearGradient(
                Gradient(colors: [.white.opacity(0.22), .white.opacity(0.02)]),
                startPoint: CGPoint(x: 512, y: 100), endPoint: CGPoint(x: 512, y: 924)),
            lineWidth: 3)
    }

    // Isometric projection: x runs right-down, y left-down, z up. One cube is 2a wide.
    private static let a: CGFloat = 46
    private static let b: CGFloat = 23
    private static let c: CGFloat = 52
    private static let origin = CGPoint(x: 512, y: 640)

    private static func project(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + (x - y) * a, y: origin.y + (x + y) * b - z * c)
    }

    private static func polygon(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    private struct Voxel {
        var x: CGFloat
        var y: CGFloat
        var z: CGFloat
        var top: Color
        var left: Color
        var right: Color
        var depth: CGFloat { x + y + z }
    }

    private static func cube(_ x: Int, _ y: Int, _ z: Int, base: (Double, Double, Double)) -> Voxel {
        let (r, g, bl) = base
        return Voxel(
            x: CGFloat(x), y: CGFloat(y), z: CGFloat(z),
            top: rgb(min(r * 1.25 + 0.06, 1), min(g * 1.25 + 0.06, 1), min(bl * 1.25 + 0.06, 1)),
            left: rgb(r * 0.85, g * 0.85, bl * 0.85), right: rgb(r * 0.55, g * 0.55, bl * 0.6))
    }

    /// A stepped tree: trunk, tiers that narrow upwards, a two-cube spire, ornaments in some outer cubes.
    private static func treeVoxels() -> [Voxel] {
        let green = (0.16, 0.62, 0.34)
        let ornaments = [(0.95, 0.22, 0.20), (1.0, 0.78, 0.22), (0.25, 0.78, 1.0), (1.0, 0.30, 0.75)]
        var voxels = [cube(0, 0, 0, base: (0.45, 0.28, 0.16))]
        let tiers: [(z: Int, radius: Int)] = [(1, 2), (2, 2), (3, 1), (4, 1), (5, 0), (6, 0)]
        for tier in tiers {
            for x in -tier.radius...tier.radius {
                for y in -tier.radius...tier.radius {
                    // Round the big tiers off at the corners.
                    if tier.radius == 2, abs(x) == 2, abs(y) == 2 { continue }
                    let edge = max(abs(x), abs(y)) == tier.radius && tier.radius > 0
                    let pick = (x * 7 + y * 13 + tier.z * 5 + 40) % 9
                    let color = edge && (x > 0 || y > 0) && pick < 3 ? ornaments[(pick + tier.z) % 4] : green
                    voxels.append(cube(x, y, tier.z, base: color))
                }
            }
        }
        return voxels
    }

    private static func drawCube(_ v: Voxel, in context: inout GraphicsContext) {
        let (x, y, z) = (v.x - 0.5, v.y - 0.5, v.z)
        let top = polygon([
            project(x, y, z + 1), project(x + 1, y, z + 1), project(x + 1, y + 1, z + 1), project(x, y + 1, z + 1),
        ])
        let right = polygon([
            project(x + 1, y, z), project(x + 1, y + 1, z), project(x + 1, y + 1, z + 1), project(x + 1, y, z + 1),
        ])
        let left = polygon([
            project(x, y + 1, z), project(x + 1, y + 1, z), project(x + 1, y + 1, z + 1), project(x, y + 1, z + 1),
        ])
        context.fill(top, with: .color(v.top))
        context.fill(right, with: .color(v.right))
        context.fill(left, with: .color(v.left))
        let edge = GraphicsContext.Shading.color(.black.opacity(0.22))
        for face in [top, right, left] { context.stroke(face, with: edge, lineWidth: 1.5) }
    }

    /// A 7 x 7 slab of floor tiles with a glowing trail across it (the guard's patrol).
    private static func drawFloor(in context: inout GraphicsContext) {
        let n: CGFloat = 3.5
        let depth: CGFloat = 0.35
        context.fill(
            polygon([project(n, -n, 0), project(n, n, 0), project(n, n, -depth), project(n, -n, -depth)]),
            with: .color(rgb(0.07, 0.08, 0.16)))
        context.fill(
            polygon([project(-n, n, 0), project(n, n, 0), project(n, n, -depth), project(-n, n, -depth)]),
            with: .color(rgb(0.10, 0.11, 0.21)))
        for i in -3...3 {
            for j in -3...3 {
                let (x, y) = (CGFloat(i) - 0.5, CGFloat(j) - 0.5)
                let tile = polygon([
                    project(x + 0.06, y + 0.06, 0), project(x + 0.94, y + 0.06, 0),
                    project(x + 0.94, y + 0.94, 0), project(x + 0.06, y + 0.94, 0),
                ])
                let even = (i + j).isMultiple(of: 2)
                context.fill(tile, with: .color(even ? rgb(0.17, 0.19, 0.31) : rgb(0.14, 0.16, 0.27)))
            }
        }
        // Trail: in along the front-left edge, turning right at the corner.
        var trail = Path()
        trail.addLines([project(-3, 2.6, 0), project(2.6, 2.6, 0), project(2.6, -3, 0)])
        var glow = context
        glow.addFilter(.blur(radius: 6))
        glow.stroke(trail, with: .color(rgb(1.0, 0.85, 0.35).opacity(0.8)), lineWidth: 14)
        context.stroke(
            trail, with: .color(rgb(1.0, 0.92, 0.55)),
            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
    }

    private static func drawStar(in context: inout GraphicsContext) {
        let center = CGPoint(x: project(0, 0, 7).x, y: project(0, 0, 7).y - 40)
        var star = Path()
        for k in 0..<10 {
            let radius: CGFloat = k.isMultiple(of: 2) ? 92 : 38
            let angle = -CGFloat.pi / 2 + CGFloat(k) * .pi / 5
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if k == 0 { star.move(to: point) } else { star.addLine(to: point) }
        }
        star.closeSubpath()

        var glow = context
        glow.addFilter(.blur(radius: 26))
        glow.fill(star, with: .color(rgb(1.0, 0.80, 0.25).opacity(0.9)))
        context.fill(
            star,
            with: .linearGradient(
                Gradient(colors: [rgb(1.0, 0.95, 0.60), rgb(1.0, 0.72, 0.12)]),
                startPoint: CGPoint(x: center.x, y: center.y - 92), endPoint: CGPoint(x: center.x, y: center.y + 60)))
        context.stroke(star, with: .color(rgb(0.75, 0.45, 0.05)), lineWidth: 3)
    }

    private static func drawSnow(in context: inout GraphicsContext) {
        var seed: UInt64 = 2026
        for _ in 0..<70 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let x = 100 + CGFloat(seed >> 40 & 0x3ff) / 1023 * 824
            let y = 100 + CGFloat(seed >> 20 & 0x3ff) / 1023 * 824
            let r = 2 + CGFloat(seed >> 8 & 0x7) * 0.7
            context.fill(
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                with: .color(.white.opacity(0.10 + Double(seed >> 4 & 0xf) / 15 * 0.35)))
        }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(.sRGB, red: r, green: g, blue: b)
    }
}
