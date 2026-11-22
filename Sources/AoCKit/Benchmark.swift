import Foundation

/// Benchmarks for a solution on its real input, modelled on the 2025 Go project's
/// `benchmarkDay`: Parse (`init`), Part 1, Part 2 and the full pipeline
/// (parse + both parts on a fresh instance).
///
/// Each phase gets one untimed warm-up run (pipeline compilation, page faults), then repeats
/// until `budget` is spent (bounded by `minIterations`...`maxIterations`). For parts we also
/// record the GPU execution time reported by Metal for the command buffers they submitted.
public enum Benchmark {
    public struct Stats: Sendable {
        public let iterations: Int
        public let min: Duration
        public let median: Duration
        public let mean: Duration
        /// Mean GPU execution time per iteration (zero if the phase never touched the GPU).
        public let gpuMean: Duration

        init(samples: [Duration], gpuTotal: Duration) {
            let sorted = samples.sorted()
            iterations = sorted.count
            min = sorted.first ?? .zero
            median = sorted.isEmpty ? .zero : sorted[sorted.count / 2]
            mean = sorted.isEmpty ? .zero : sorted.reduce(.zero, +) / sorted.count
            gpuMean = sorted.isEmpty ? .zero : gpuTotal / sorted.count
        }
    }

    public struct Result: Sendable {
        public let id: PuzzleID
        public let title: String
        public let parse: Stats
        public let part1: Stats
        public let part2: Stats
        public let full: Stats
    }

    public struct Options: Sendable {
        public var budget: Duration = .milliseconds(500)
        public var minIterations = 5
        public var maxIterations = 10_000

        public init() {}
    }

    public static func run(
        _ type: any Solution.Type, input: Input, gpu: GPU, options: Options = Options()
    ) throws -> Result {
        let parse = try measure(gpu, options) { _ = try type.init(input: input, gpu: gpu) }
        let solution = try type.init(input: input, gpu: gpu)
        let part1 = try measure(gpu, options) { _ = try solution.part1() }
        let part2 = try measure(gpu, options) { _ = try solution.part2() }
        let full = try measure(gpu, options) {
            let fresh = try type.init(input: input, gpu: gpu)
            _ = try fresh.part1()
            _ = try fresh.part2()
        }
        return Result(id: type.id, title: type.title, parse: parse, part1: part1, part2: part2, full: full)
    }

    /// Warm-up run, then timed runs until `options.budget` is spent (within the iteration bounds).
    static func measure(_ gpu: GPU, _ options: Options, _ body: () throws -> Void) throws -> Stats {
        try body()  // warm-up
        gpu.resetGPUTime()

        let clock = ContinuousClock()
        var samples: [Duration] = []
        var spent = Duration.zero
        while samples.count < options.minIterations
            || (spent < options.budget && samples.count < options.maxIterations)
        {
            let elapsed = try clock.measure(body)
            samples.append(elapsed)
            spent += elapsed
        }
        return Stats(samples: samples, gpuTotal: gpu.gpuTime)
    }

    // MARK: Reporting

    /// Terminal table: median wall-clock times and mean GPU times, as a bordered ASCII table.
    public static func table(_ results: [Result]) -> String {
        var rows = [["Puzzle", "Parse", "Part 1", "Part 1 GPU", "Part 2", "Part 2 GPU", "Full", "Iterations"]]
        for r in results {
            rows.append([
                r.id.description, format(r.parse.median),
                format(r.part1.median), format(r.part1.gpuMean),
                format(r.part2.median), format(r.part2.gpuMean),
                format(r.full.median), "\(r.full.iterations)",
            ])
        }
        return asciiTable(rows)
    }

    /// Bordered ASCII table (MySQL-client style). The first row is the header; the first column is
    /// left-aligned, the others right-aligned.
    ///
    ///     +-----------+----------+
    ///     | Puzzle    |    Parse |
    ///     +-----------+----------+
    ///     | Example 1 | 520.2 µs |
    ///     +-----------+----------+
    static func asciiTable(_ rows: [[String]]) -> String {
        let widths = rows[0].indices.map { col in rows.map { $0[col].count }.max() ?? 0 }
        let border = "+" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "+") + "+"
        let lines = rows.map { row in
            let cells = row.enumerated().map { col, cell in
                let fill = String(repeating: " ", count: widths[col] - cell.count)
                return col == 0 ? cell + fill : fill + cell
            }
            return "| " + cells.joined(separator: " | ") + " |"
        }
        return ([border, lines[0], border] + lines.dropFirst() + [border]).joined(separator: "\n")
    }

    /// Markdown summary in the same shape as the 2025 project's `benchmark_summary.md`.
    public static func markdown(_ results: [Result], machine: String = Machine.description) -> String {
        var out = "# Benchmark Summary — \(machine)\n\n"
        out += "Median wall-clock time per call in µs (GPU execution time in parentheses), "
        out += "release build.\n\n"
        out += "| Puzzle | Parse (µs) | Part 1 (µs) | Part 2 (µs) | Full pipeline (µs) |\n"
        out += "|--------|-----------:|------------:|------------:|-------------------:|\n"
        for r in results {
            out += "| \(r.id) | \(micros(r.parse.median)) "
            out += "| \(micros(r.part1.median)) (\(micros(r.part1.gpuMean))) "
            out += "| \(micros(r.part2.median)) (\(micros(r.part2.gpuMean))) "
            out += "| \(micros(r.full.median)) |\n"
        }
        return out
    }

    static func format(_ d: Duration) -> String {
        let ns = Double(d.components.seconds) * 1e9 + Double(d.components.attoseconds) / 1e9
        switch ns {
        case 0: return "-"
        case ..<1e3: return String(format: "%.0f ns", ns)
        case ..<1e6: return String(format: "%.1f µs", ns / 1e3)
        case ..<1e9: return String(format: "%.2f ms", ns / 1e6)
        default: return String(format: "%.2f s", ns / 1e9)
        }
    }

    static func micros(_ d: Duration) -> String {
        let us = Double(d.components.seconds) * 1e6 + Double(d.components.attoseconds) / 1e12
        return us < 10 ? String(format: "%.2f", us) : String(format: "%.1f", us)
    }
}

/// Machine description for benchmark headers, e.g. "Apple M4 Max (macOS 27.2)".
public enum Machine {
    public static var description: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let cpu = String(validating: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) ?? ""
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(cpu.isEmpty ? "Unknown CPU" : cpu) (macOS \(os.majorVersion).\(os.minorVersion))"
    }
}
