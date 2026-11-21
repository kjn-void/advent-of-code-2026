import simd

/// Orbit camera: drag to rotate around `target`, scroll/pinch to zoom, shift-drag to pan.
public struct OrbitCamera: Sendable {
    public var target = SIMD3<Float>(0, 0, 0)
    public var distance: Float = 10
    /// Radians around +Y.
    public var yaw: Float = .pi * 0.25
    /// Radians above the horizon.
    public var pitch: Float = 0.6
    public var fieldOfView: Float = .pi / 4
    /// Whether `target` tracks the scene's camera focus. Panning by hand turns it off;
    /// framing (reset view) turns it back on.
    public var isFollowing = true

    public init() {}

    public mutating func frame(_ bounds: SceneBounds, view: CameraView = CameraView()) {
        isFollowing = true
        target = bounds.center
        distance = max(bounds.radius / sin(fieldOfView * 0.5), 1) * 1.05 * view.distanceScale
        yaw = view.yaw
        pitch = view.pitch
    }

    public mutating func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.008
        pitch = min(max(pitch + dy * 0.008, -1.5), 1.5)
    }

    public mutating func zoom(_ factor: Float) {
        distance = min(max(distance * factor, 0.5), 100_000)
    }

    public mutating func pan(dx: Float, dy: Float) {
        isFollowing = false
        let (right, up) = basis
        let scale = distance * 0.0015
        target += (-right * dx + up * dy) * scale
    }

    /// Moves `target` a fraction `amount` (0...1) of the way to `focus`, if following.
    public mutating func follow(_ focus: SIMD3<Float>, amount: Float) {
        guard isFollowing else { return }
        target += (focus - target) * min(max(amount, 0), 1)
    }

    public var position: SIMD3<Float> {
        let dir = SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
        return target + dir * distance
    }

    public func viewProjection(aspect: Float) -> simd_float4x4 {
        let near = max(distance * 0.01, 0.05)
        let far = distance * 4 + 1000
        return Self.perspective(fovY: fieldOfView, aspect: aspect, near: near, far: far)
            * Self.lookAt(eye: position, target: target, up: SIMD3(0, 1, 0))
    }

    private var basis: (SIMD3<Float>, SIMD3<Float>) {
        let forward = simd_normalize(target - position)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        return (right, simd_cross(right, forward))
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - target)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return simd_float4x4(
            columns: (
                SIMD4(x.x, y.x, z.x, 0),
                SIMD4(x.y, y.y, z.y, 0),
                SIMD4(x.z, y.z, z.z, 0),
                SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
            ))
    }

    /// Right-handed perspective projection with Metal's [0, 1] depth range.
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(
            columns: (
                SIMD4(x, 0, 0, 0),
                SIMD4(0, y, 0, 0),
                SIMD4(0, 0, z, -1),
                SIMD4(0, 0, z * near, 0)
            ))
    }
}
