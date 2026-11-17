import AoCKit
import AoCShared
import Metal
import Observation
import simd

/// A solution that can show itself in the visualizer. Implement it in the same DayNN.swift
/// file as the solution:
///
/// ```swift
/// extension Day03: Visualizable {
///     @MainActor static func makeScene(input: Input, gpu: GPU) throws -> any VisualizationScene {
///         try Day03Scene(solution: Day03(input: input, gpu: gpu))
///     }
/// }
/// ```
public protocol Visualizable: Solution {
    @MainActor static func makeScene(input: Input, gpu: GPU) throws -> any VisualizationScene
}

/// 2.5D/3D illustration of a solution, drawn as instanced boxes (`AoCInstance`).
///
/// The intended pattern is GPU-driven: the scene owns an instance buffer and, in `update`,
/// encodes compute kernels into the frame's command buffer that write instances directly
/// from the solution's own buffers. The renderer then draws `instanceCount` boxes from it,
/// so nothing is copied through the CPU.
///
/// Time is a continuous timeline: `step` (an integer in `0..<stepCount`, e.g. "line 12") plus
/// `progress` in [0, 1) within that step, so animations stay deterministic while scrubbing.
@MainActor
public protocol VisualizationScene: AnyObject {
    /// Boxes to draw. Only the first `instanceCount` are rendered.
    var instances: GPUBuffer<AoCInstance> { get }
    var instanceCount: Int { get }
    /// Region the camera frames when the scene loads (and on "reset view").
    var bounds: SceneBounds { get }
    /// Initial camera orientation.
    var preferredView: CameraView { get }
    /// Length of the timeline.
    var stepCount: Int { get }
    /// Default playback speed.
    var preferredStepsPerSecond: Double { get }

    /// Called every frame before drawing. Encode compute work into `frame.commandBuffer`
    /// (via `frame.gpu.encode(into:)`).
    func update(_ frame: FrameContext) throws

    /// One-line description of what the current step shows (overlaid in the UI).
    func caption(step: Int, part: Int) -> String
}

public extension VisualizationScene {
    var preferredView: CameraView { CameraView() }
    var preferredStepsPerSecond: Double { 1 }
    func caption(step _: Int, part _: Int) -> String { "" }
}

/// Everything a scene needs to encode one frame.
public struct FrameContext {
    public let gpu: GPU
    public let commandBuffer: any MTLCommandBuffer
    /// Timeline position, `0..<stepCount`.
    public let step: Int
    /// Position within the step, [0, 1).
    public let progress: Float
    /// Which part the user is looking at: 1 or 2.
    public let part: Int
    /// Seconds since the scene was created (for idle animation that need not be scrubbable).
    public let time: Float
}

/// Initial orbit angles; `distanceScale` < 1 frames tighter than the bounding sphere.
public struct CameraView: Sendable {
    public var yaw: Float
    public var pitch: Float
    public var distanceScale: Float

    public init(yaw: Float = .pi * 0.25, pitch: Float = 0.75, distanceScale: Float = 1) {
        self.yaw = yaw
        self.pitch = pitch
        self.distanceScale = distanceScale
    }
}

/// Axis-aligned bounds used for camera framing.
public struct SceneBounds: Sendable {
    public var min: SIMD3<Float>
    public var max: SIMD3<Float>

    public init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }

    public var center: SIMD3<Float> { (min + max) * 0.5 }
    public var radius: Float { simd_length(max - min) * 0.5 }
}

/// Timeline state shared by the UI (slider, play button) and the renderer (advances it).
@MainActor @Observable
public final class Playback {
    /// Continuous position in steps: `Int(position)` is the step, the fraction its progress.
    public var position: Double = 0
    public var isPlaying = false
    public var stepsPerSecond: Double = 1
    public var stepCount = 0
    public var part = 1

    public init() {}

    public var step: Int { min(Int(position), max(stepCount - 1, 0)) }
    public var progress: Float {
        position >= Double(stepCount) ? 0.9999 : Float(position - position.rounded(.down))
    }

    /// Advances by `seconds` of wall time; stops at the end of the timeline.
    public func advance(by seconds: Double) {
        guard isPlaying, stepCount > 0 else { return }
        position = min(position + seconds * stepsPerSecond, Double(stepCount))
        if position >= Double(stepCount) { isPlaying = false }
    }

    public func reset(stepCount: Int, stepsPerSecond: Double) {
        self.stepCount = stepCount
        self.stepsPerSecond = stepsPerSecond
        position = 0
        isPlaying = true
    }
}

public extension AoCInstance {
    init(position: SIMD3<Float>, scale: SIMD3<Float>, color: SIMD4<Float>) {
        self.init()
        self.position = position
        self.scale = scale
        self.color = color
    }
}
