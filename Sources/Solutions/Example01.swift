import AoCKit
import AoCRender
import AoCShared
import Metal

/// Example 1 — AoC 2023 day 1, "Trebuchet?!". Kept around as the framework's end-to-end
/// reference: fetch → parse → Metal compute → answer → visualization.
///
/// Each line's calibration value is its first and last digit glued together (part 2 also
/// counts spelled-out digits, which may overlap). The GPU looks at every byte in parallel and
/// keeps the smallest/largest digit offset per line with atomic min/max.
public final class Example01: Solution {
    public static let id = PuzzleID.example(1, year: 2023, day: 1)
    public static let title = "Trebuchet?!"
    /// The part 2 example (part 1's has no spelled digits, so this one shows both parts).
    public static let exampleInput: String? = """
        two1nine
        eightwothree
        abcone2threexyz
        xtwone3four
        4nineeightseven2
        zoneight234
        7pqrstsixteen
        """

    let gpu: GPU
    let bytes: GPUBuffer<UInt8>
    /// Line index for every byte.
    let lineOf: GPUBuffer<UInt32>
    /// Offset of the first byte of every line.
    let lineStart: GPUBuffer<UInt32>
    let lines: [Substring]
    let longestLine: Int

    private let scan: any MTLComputePipelineState
    private let combine: any MTLComputePipelineState

    public init(input: Input, gpu: GPU) throws {
        self.gpu = gpu
        lines = input.lines
        longestLine = lines.map(\.utf8.count).max() ?? 0

        // Rebuild the text from the lines so every line, including the last, ends in "\n".
        var raw: [UInt8] = []
        var lineOf: [UInt32] = []
        var lineStart: [UInt32] = []
        raw.reserveCapacity(input.text.utf8.count + 1)
        for (index, line) in lines.enumerated() {
            lineStart.append(UInt32(raw.count))
            raw.append(contentsOf: line.utf8)
            raw.append(UInt8(ascii: "\n"))
            lineOf.append(contentsOf: repeatElement(UInt32(index), count: line.utf8.count + 1))
        }

        bytes = gpu.buffer(raw, label: "bytes")
        self.lineOf = gpu.buffer(lineOf, label: "lineOf")
        self.lineStart = gpu.buffer(lineStart, label: "lineStart")
        scan = try gpu.kernel("example01_scan")
        combine = try gpu.kernel("example01_combine")
    }

    public func part1() throws -> String { "\(try evaluate(spelledDigits: false).total)" }
    public func part2() throws -> String { "\(try evaluate(spelledDigits: true).total)" }

    /// GPU results for one part; the scene reuses the per-line buffers.
    struct Evaluation {
        let first: GPUBuffer<UInt32>
        let last: GPUBuffer<UInt32>
        let lineValue: GPUBuffer<UInt32>
        let total: UInt64
    }

    func evaluate(spelledDigits: Bool) throws -> Evaluation {
        let lineCount = lines.count
        let first = gpu.buffer([UInt32](repeating: .max, count: lineCount), label: "first")
        let last = gpu.buffer(count: lineCount, of: UInt32.self, label: "last")
        let lineValue = gpu.buffer(count: lineCount, of: UInt32.self, label: "lineValue")
        let total = gpu.buffer(count: 2, of: UInt32.self, label: "total")
        let params = Example01Params(
            byteCount: UInt32(bytes.count), lineCount: UInt32(lineCount), spelledDigits: spelledDigits ? 1 : 0)

        try gpu.run("Example01 part \(spelledDigits ? 2 : 1)") { encoder in
            encoder.dispatch(
                scan, count: bytes.count,
                .buffer(bytes), .buffer(lineOf), .buffer(first), .buffer(last), .value(params))
            encoder.dispatch(
                combine, count: lineCount,
                .buffer(bytes), .buffer(first), .buffer(last), .buffer(lineValue), .buffer(total), .value(params))
        }
        return Evaluation(first: first, last: last, lineValue: lineValue, total: total.uint64())
    }
}

// MARK: - Visualization

extension Example01: Visualizable {
    @MainActor public static func makeScene(input: Input, gpu: GPU) throws -> any VisualizationScene {
        try Example01Scene(solution: Example01(input: input, gpu: gpu))
    }
}

/// Voxel-text animation, one input line per timeline step (see the phase list at the bottom of
/// Example01.metal): highlight digit tokens → explode everything outside first/last → explode
/// the middle → convert spelled tokens to digits → slide them into the two-digit value → add it
/// to the running total.
@MainActor
final class Example01Scene: VisualizationScene {
    let instances: GPUBuffer<AoCInstance>
    let bounds: SceneBounds
    var instanceCount: Int { instances.count }
    var stepCount: Int { solution.lines.count }
    var preferredStepsPerSecond: Double { 0.4 }
    var preferredView: CameraView { CameraView(yaw: 0.22, pitch: 0.18, distanceScale: 0.72) }

    private let solution: Example01
    private let parts: [Example01.Evaluation]
    /// Running totals per part: prefix[part][k] = sum of the first k line values.
    private let prefix: [[UInt64]]
    private let pipeline: any MTLComputePipelineState
    private let queuedLines = 2
    private let slots: Int

    init(solution: Example01) throws {
        self.solution = solution
        parts = [try solution.evaluate(spelledDigits: false), try solution.evaluate(spelledDigits: true)]
        prefix = parts.map { part in part.lineValue.array.reduce(into: [0]) { $0.append($0.last! + UInt64($1)) } }
        pipeline = try solution.gpu.kernel("example01_instances")

        let maxLength = max(solution.longestLine, 1)
        slots = (queuedLines + 1) * maxLength + 2 + Int(EXAMPLE01_TOTAL_DIGITS)
        instances = solution.gpu.buffer(
            count: slots * Int(EXAMPLE01_GLYPH_PIXELS), of: AoCInstance.self, label: "instances")

        // Frame a typical line, not the longest one; long lines may run off-screen at the edges.
        let averageLength = Float(solution.lines.reduce(0) { $0 + $1.utf8.count }) / Float(max(solution.lines.count, 1))
        let halfWidth = averageLength * 3 + 6
        bounds = SceneBounds(min: SIMD3(-halfWidth, -24, -10), max: SIMD3(halfWidth, 30, 4))
    }

    func update(_ frame: FrameContext) throws {
        let part = frame.part == 2 ? 1 : 0
        let line = min(frame.step, max(solution.lines.count - 1, 0))
        let params = Example01VizParams(
            byteCount: UInt32(solution.bytes.count),
            lineCount: UInt32(solution.lines.count),
            spelledDigits: UInt32(part),
            line: UInt32(line),
            progress: frame.progress,
            maxLineLength: UInt32(max(solution.longestLine, 1)),
            queuedLines: UInt32(queuedLines),
            totalBefore: UInt32(clamping: prefix[part][line]),
            totalAfter: UInt32(clamping: prefix[part][line + 1]))

        let evaluation = parts[part]
        try frame.gpu.encode(into: frame.commandBuffer) { encoder in
            encoder.dispatch(
                pipeline, width: Int(EXAMPLE01_GLYPH_PIXELS), height: slots,
                .buffer(solution.bytes), .buffer(solution.lineStart),
                .buffer(evaluation.first), .buffer(evaluation.last), .buffer(instances), .value(params))
        }
    }

    func caption(step: Int, part: Int) -> String {
        let index = part == 2 ? 1 : 0
        let lines = solution.lines
        guard step < lines.count else { return "" }
        let sums = prefix[index]
        let value = sums[step + 1] - sums[step]
        let tokens = Self.tokens(in: lines[step], spelled: part == 2)
        let conversion =
            tokens.isEmpty
            ? "no digits"
            : "\(tokens.first!.text) → \(tokens.first!.value), \(tokens.last!.text) → \(tokens.last!.value)"
        return "Line \(step + 1)/\(lines.count)   \(lines[step])   [\(conversion)]   = \(value)"
            + "   ·   total \(sums[step + 1])"
    }

    /// Digit tokens of a line on the CPU, for the caption only.
    private static func tokens(in line: Substring, spelled: Bool) -> [(text: String, value: Int)] {
        let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        var result: [(String, Int)] = []
        for i in line.indices {
            if let digit = line[i].wholeNumberValue {
                result.append((String(line[i]), digit))
            } else if spelled, let w = words.firstIndex(where: { line[i...].hasPrefix($0) }) {
                result.append((words[w], w + 1))
            }
        }
        return result
    }
}
