import Foundation
import Metal
import Synchronization

/// Thin, synchronous wrapper around one Metal device + queue, tuned for AoC-style compute:
/// upload once, dispatch a few kernels, read back a counter.
///
/// All buffers use `.storageModeShared`: on Apple silicon CPU and GPU see the same memory,
/// so parsing can write straight into a buffer and answers can be read without blits.
public final class GPU: @unchecked Sendable {
    public let device: any MTLDevice
    public let queue: any MTLCommandQueue

    private struct Caches {
        var libraries: [String: any MTLLibrary] = [:]
        var pipelines: [String: any MTLComputePipelineState] = [:]
    }

    private let caches = Mutex(Caches())
    private let gpuNanoseconds = Atomic<UInt64>(0)

    /// Process-wide instance. Creating devices/queues is expensive; share this one.
    public static let shared: GPU = {
        do {
            return try GPU()
        } catch {
            fatalError("Metal is unavailable: \(error)")
        }
    }()

    public init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw GPUError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw GPUError.noQueue }
        queue.label = "AoC compute"
        self.device = device
        self.queue = queue
    }

    // MARK: Libraries & pipelines

    /// Loads `<name>.metallib` from `bundle` (cached). Targets using the MetalCompiler plugin
    /// produce `<TargetName>.metallib` in `Bundle.module`.
    public func library(named name: String, in bundle: Bundle) throws -> any MTLLibrary {
        let key = "\(bundle.bundlePath)#\(name)"
        if let cached = caches.withLock({ $0.libraries[key] }) { return cached }
        guard let url = bundle.url(forResource: name, withExtension: "metallib") else {
            throw GPUError.missingLibrary(name)
        }
        let library = try device.makeLibrary(URL: url)
        caches.withLock { $0.libraries[key] = library }
        return library
    }

    /// Compute pipeline for kernel `function` in `library` (cached by library + name).
    public func pipeline(_ function: String, in library: any MTLLibrary) throws -> any MTLComputePipelineState {
        let key = "\(ObjectIdentifier(library))#\(function)"
        if let cached = caches.withLock({ $0.pipelines[key] }) { return cached }
        guard let fn = library.makeFunction(name: function) else { throw GPUError.missingFunction(function) }
        let pipeline = try device.makeComputePipelineState(function: fn)
        caches.withLock { $0.pipelines[key] = pipeline }
        return pipeline
    }

    // MARK: Buffers

    /// Shared buffer initialised with `values`.
    public func buffer<T: BitwiseCopyable>(_ values: [T], label: String? = nil) -> GPUBuffer<T> {
        let length = max(values.count, 1) * MemoryLayout<T>.stride
        let raw = values.withUnsafeBytes { bytes -> (any MTLBuffer)? in
            guard let base = bytes.baseAddress else {
                return device.makeBuffer(length: length, options: .storageModeShared)
            }
            return device.makeBuffer(bytes: base, length: length, options: .storageModeShared)
        }
        return GPUBuffer(raw: raw.require(), count: values.count, label: label)
    }

    /// Shared, zero-filled buffer of `count` elements.
    public func buffer<T: BitwiseCopyable>(count: Int, of _: T.Type = T.self, label: String? = nil) -> GPUBuffer<T> {
        let length = max(count, 1) * MemoryLayout<T>.stride
        let raw = device.makeBuffer(length: length, options: .storageModeShared).require()
        memset(raw.contents(), 0, length)
        return GPUBuffer(raw: raw, count: count, label: label)
    }

    // MARK: Dispatch

    /// Encodes `body` into one command buffer, commits it and blocks until it finishes.
    /// Throws if the GPU reported an error (e.g. a kernel faulted).
    public func run(_ label: String? = nil, _ body: (ComputeEncoder) throws -> Void) throws {
        guard let commandBuffer = queue.makeCommandBuffer() else { throw GPUError.noCommandBuffer }
        commandBuffer.label = label
        try encode(into: commandBuffer, body)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw GPUError.execution(error) }
        let nanos = max(0, commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1e9
        gpuNanoseconds.add(UInt64(nanos), ordering: .relaxed)
    }

    /// Encodes compute work into an existing command buffer (used by the visualizer, which
    /// mixes compute and rendering in one frame).
    public func encode(into commandBuffer: any MTLCommandBuffer, _ body: (ComputeEncoder) throws -> Void) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        defer { encoder.endEncoding() }
        try body(ComputeEncoder(encoder: encoder))
    }

    /// Total GPU execution time of all `run` calls since the last reset (for benchmarks).
    public var gpuTime: Duration { .nanoseconds(Int64(gpuNanoseconds.load(ordering: .relaxed))) }

    public func resetGPUTime() { gpuNanoseconds.store(0, ordering: .relaxed) }
}

/// Kernel argument, bound to consecutive `[[buffer(n)]]` slots in the order given.
public enum KernelArgument {
    case buffer(any MTLBuffer, offset: Int = 0)
    case bytes([UInt8])

    /// A small constant struct/scalar, bound with `setBytes` (≤ 4 KB).
    public static func value<T: BitwiseCopyable>(_ value: T) -> Self {
        withUnsafeBytes(of: value) { .bytes(Array($0)) }
    }

    public static func buffer<T>(_ buffer: GPUBuffer<T>) -> Self { .buffer(buffer.raw) }
}

/// Convenience over `MTLComputeCommandEncoder` that sizes threadgroups automatically.
public struct ComputeEncoder {
    public let encoder: any MTLComputeCommandEncoder

    /// Dispatches `pipeline` over a 1D grid of `count` threads.
    public func dispatch(_ pipeline: any MTLComputePipelineState, count: Int, _ arguments: KernelArgument...) {
        bind(pipeline, arguments)
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, max(count, 1))
        encoder.dispatchThreads(
            MTLSize(width: max(count, 1), height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
    }

    /// Dispatches `pipeline` over a 2D grid (`thread_position_in_grid` is a `uint2`).
    public func dispatch(
        _ pipeline: any MTLComputePipelineState, width: Int, height: Int, _ arguments: KernelArgument...
    ) {
        bind(pipeline, arguments)
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(
            MTLSize(width: max(width, 1), height: max(height, 1), depth: 1),
            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1)
        )
    }

    /// Makes writes from previous dispatches visible to the next one (same encoder).
    public func barrier() { encoder.memoryBarrier(scope: .buffers) }

    private func bind(_ pipeline: any MTLComputePipelineState, _ arguments: [KernelArgument]) {
        encoder.setComputePipelineState(pipeline)
        for (slot, argument) in arguments.enumerated() {
            switch argument {
            case .buffer(let buffer, let offset):
                encoder.setBuffer(buffer, offset: offset, index: slot)
            case .bytes(let bytes):
                bytes.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: slot) }
            }
        }
    }
}

/// Typed view of a shared `MTLBuffer`.
public struct GPUBuffer<Element: BitwiseCopyable>: @unchecked Sendable {
    public let raw: any MTLBuffer
    public let count: Int

    init(raw: any MTLBuffer, count: Int, label: String?) {
        self.raw = raw
        self.count = count
        raw.label = label
    }

    /// CPU view of the contents. Only touch it while no GPU work using the buffer is in flight.
    public var contents: UnsafeMutableBufferPointer<Element> {
        UnsafeMutableBufferPointer(start: raw.contents().bindMemory(to: Element.self, capacity: count), count: count)
    }

    public subscript(index: Int) -> Element {
        get { contents[index] }
        nonmutating set { contents[index] = newValue }
    }

    public var array: [Element] { Array(contents) }

    /// Zero-fills the buffer (CPU side).
    public func clear() { memset(raw.contents(), 0, raw.length) }
}

public extension GPUBuffer where Element == UInt32 {
    /// Reads a `{lo, hi}` pair written by `aoc::atomicAdd64` / `aoc::reduceAdd64`.
    func uint64(at index: Int = 0) -> UInt64 {
        UInt64(self[index]) | (UInt64(self[index + 1]) << 32)
    }
}

public enum GPUError: Error, CustomStringConvertible {
    case noDevice
    case noQueue
    case noCommandBuffer
    case noEncoder
    case missingLibrary(String)
    case missingFunction(String)
    case execution(any Error)

    public var description: String {
        switch self {
        case .noDevice: "no Metal device available"
        case .noQueue: "could not create a command queue"
        case .noCommandBuffer: "could not create a command buffer"
        case .noEncoder: "could not create a compute encoder"
        case .missingLibrary(let name): "\(name).metallib not found in bundle"
        case .missingFunction(let name): "kernel '\(name)' not found in library"
        case .execution(let error): "GPU execution failed: \(error)"
        }
    }
}

extension Optional {
    fileprivate func require(file: StaticString = #file, line: UInt = #line) -> Wrapped {
        guard let self else { fatalError("Metal allocation failed", file: file, line: line) }
        return self
    }
}
