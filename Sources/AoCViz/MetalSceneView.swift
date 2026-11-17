import AoCKit
import AoCRender
import MetalKit
import SwiftUI

/// Hosts the renderer's `MTKView`. Drag to orbit, shift- or right-drag to pan,
/// scroll or pinch to zoom, double-click to reset the camera.
struct MetalSceneView: NSViewRepresentable {
    let renderer: Renderer

    func makeNSView(context _: Context) -> InteractiveMTKView {
        let view = InteractiveMTKView(frame: .zero, device: renderer.gpu.device)
        renderer.configure(view)
        view.renderer = renderer
        return view
    }

    func updateNSView(_: InteractiveMTKView, context _: Context) {}
}

final class InteractiveMTKView: MTKView {
    weak var renderer: Renderer?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDragged(with event: NSEvent) {
        if event.modifierFlags.contains(.shift) {
            renderer?.camera.pan(dx: Float(event.deltaX), dy: Float(event.deltaY))
        } else {
            renderer?.camera.orbit(dx: Float(event.deltaX), dy: Float(event.deltaY))
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        renderer?.camera.pan(dx: Float(event.deltaX), dy: Float(event.deltaY))
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = Float(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8)
        renderer?.camera.zoom(exp(-delta * 0.01))
    }

    override func magnify(with event: NSEvent) {
        renderer?.camera.zoom(1 / (1 + Float(event.magnification)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { renderer?.resetCamera() }
    }
}
