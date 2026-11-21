import AoCKit
import AoCShared
import Foundation
import MetalKit
import simd

/// Draws a `VisualizationScene` into an `MTKView`: lets the scene encode its compute work,
/// then renders its instance buffer as lit boxes, all in one command buffer per frame.
@MainActor
public final class Renderer: NSObject, MTKViewDelegate {
    public let gpu: GPU
    public var camera = OrbitCamera()
    /// Timeline driven by the UI; the renderer advances it while playing.
    public var playback = Playback()
    /// Called with errors thrown by the scene's `update` (rendering continues).
    public var onError: ((any Error) -> Void)?

    public var scene: (any VisualizationScene)? {
        didSet {
            if let scene { camera.frame(scene.bounds, view: scene.preferredView) }
            snapCamera = true
            startTime = CACurrentMediaTime()
            lastFrame = startTime
        }
    }

    private let pipeline: any MTLRenderPipelineState
    private let depthState: any MTLDepthStencilState
    private var startTime = CACurrentMediaTime()
    private var lastFrame = CACurrentMediaTime()
    /// Jump straight to the scene's camera focus on the next frame instead of gliding.
    private var snapCamera = true
    private static let sampleCount = 4

    public init(gpu: GPU) throws {
        self.gpu = gpu
        let library = try gpu.library(named: "AoCRender", in: .module)

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Boxes"
        descriptor.vertexFunction = library.makeFunction(name: "box_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "box_fragment")
        descriptor.rasterSampleCount = Self.sampleCount
        descriptor.depthAttachmentPixelFormat = .depth32Float
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm_srgb
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .sourceAlpha
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try gpu.device.makeRenderPipelineState(descriptor: descriptor)

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        depthState = gpu.device.makeDepthStencilState(descriptor: depth)!
        super.init()
    }

    /// Applies the renderer's required formats to `view`.
    public func configure(_ view: MTKView) {
        view.device = gpu.device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = Self.sampleCount
        view.clearColor = Self.clearColor
        view.preferredFramesPerSecond = 60
        view.delegate = self
    }

    public func resetCamera() {
        if let scene { camera.frame(scene.bounds, view: scene.preferredView) }
        snapCamera = true
    }

    public func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

    public func draw(in view: MTKView) {
        guard let commandBuffer = gpu.queue.makeCommandBuffer() else { return }
        commandBuffer.label = "Frame"

        let now = CACurrentMediaTime()
        let elapsed = min(now - lastFrame, 0.1)
        playback.advance(by: elapsed)
        lastFrame = now

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else {
            commandBuffer.commit()
            return
        }
        // Glide towards the scene's focus (time constant ~0.2 s); jump there right after a scene
        // change or camera reset.
        let follow: Float = snapCamera ? 1 : 1 - exp(-Float(elapsed) * 5)
        snapCamera = false
        encodeFrame(
            commandBuffer, pass: pass, size: view.drawableSize, time: Float(now - startTime), follow: follow)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Renders one frame offscreen at the current playback position, e.g. for `--snapshot`.
    public func snapshot(width: Int, height: Int) throws -> CGImage {
        func texture(_ format: MTLPixelFormat, samples: Int, usage: MTLTextureUsage) throws -> any MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.textureType = samples > 1 ? .type2DMultisample : .type2D
            descriptor.sampleCount = samples
            descriptor.usage = usage
            descriptor.storageMode = samples > 1 || format == .depth32Float ? .private : .shared
            guard let texture = gpu.device.makeTexture(descriptor: descriptor) else { throw GPUError.noEncoder }
            return texture
        }
        let msaa = try texture(.bgra8Unorm_srgb, samples: Self.sampleCount, usage: .renderTarget)
        let resolved = try texture(.bgra8Unorm_srgb, samples: 1, usage: [.renderTarget, .shaderRead])
        let depth = try texture(.depth32Float, samples: Self.sampleCount, usage: .renderTarget)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa
        pass.colorAttachments[0].resolveTexture = resolved
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = Self.clearColor
        pass.depthAttachment.texture = depth
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare

        guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw GPUError.noCommandBuffer }
        encodeFrame(commandBuffer, pass: pass, size: CGSize(width: width, height: height), time: 0, follow: 1)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw GPUError.execution(error) }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        resolved.getBytes(
            &pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw GPUError.noEncoder }
        return image
    }

    /// Linear RGB (the drawable is sRGB); must match `kBackground` in Render.metal.
    static let clearColor = MTLClearColor(red: 0.010, green: 0.012, blue: 0.018, alpha: 1)

    /// Lets the scene encode its compute work, then draws its instances, into `commandBuffer`.
    private func encodeFrame(
        _ commandBuffer: any MTLCommandBuffer,
        pass: MTLRenderPassDescriptor,
        size: CGSize,
        time: Float,
        follow: Float
    ) {
        if let scene {
            if let focus = scene.cameraFocus(step: playback.step, progress: playback.progress, part: playback.part) {
                camera.follow(focus, amount: follow)
            }
            let frame = FrameContext(
                gpu: gpu, commandBuffer: commandBuffer,
                step: playback.step, progress: playback.progress, part: playback.part, time: time)
            do { try scene.update(frame) } catch { onError?(error) }
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }
        guard let scene, scene.instanceCount > 0 else { return }

        var uniforms = AoCFrameUniforms()
        uniforms.viewProjection = camera.viewProjection(aspect: Float(size.width / max(size.height, 1)))
        uniforms.cameraPosition = camera.position
        uniforms.lightDirection = simd_normalize(SIMD3<Float>(0.45, 0.85, 0.3))
        uniforms.time = time
        uniforms.fogDensity = 0.35 / max(camera.distance * 2.5, 1)

        encoder.label = "Boxes"
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setVertexBuffer(scene.instances.raw, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<AoCFrameUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AoCFrameUniforms>.stride, index: 1)
        encoder.drawPrimitives(
            type: .triangle, vertexStart: 0, vertexCount: 36,
            instanceCount: min(scene.instanceCount, scene.instances.count))
    }
}
