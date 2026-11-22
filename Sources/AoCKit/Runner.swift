/// Solves a puzzle and records how long each phase took. Shared by CLI and visualizer.
public struct SolveReport: Sendable {
    public struct Part: Sendable {
        public let answer: Result<String, SolveFailure>
        public let elapsed: Duration
    }

    public let id: PuzzleID
    public let parse: Duration
    public let part1: Part
    public let part2: Part
    /// Timed runs per phase behind the durations: 1 for the cold first run, more when a fast
    /// solve was re-timed (the durations are then the fastest warm run of each phase).
    public var runs = 1
}

/// Error wrapper that keeps the message (errors from Metal are not `Sendable`).
public struct SolveFailure: Error, Sendable, CustomStringConvertible {
    public let description: String

    public init(_ error: any Error) { description = String(describing: error) }
}

public enum Runner {
    /// Parses `input` and solves the requested parts. Parse errors throw; part errors are
    /// captured in the report so one unfinished part does not hide the other.
    ///
    /// A single run is noisy for fast solutions (pipeline compilation, page faults, clock ramp-up).
    /// If the whole first run took less than `stableBelow`, every phase is timed again, warm,
    /// for about `stableBelow` in total, and the report carries each phase's fastest run: in such a
    /// short window the GPU may still be ramping its clock, which drags medians around between
    /// launches while the minimum stays put. Answers always come from the first run.
    public static func solve(
        _ type: any Solution.Type,
        input: Input,
        gpu: GPU,
        parts: Set<Int> = [1, 2],
        stableBelow: Duration? = nil
    ) throws -> SolveReport {
        let first = try solveOnce(type, input: input, gpu: gpu, parts: parts)
        guard let threshold = stableBelow, first.parse + first.part1.elapsed + first.part2.elapsed < threshold else {
            return first
        }
        return try retime(first, type, input: input, gpu: gpu, budget: threshold)
    }

    /// Re-times every phase of `first` with the benchmark loop (warm-up, then repeat until each
    /// phase used a third of `budget`) and swaps in the fastest runs. Failed or skipped parts keep
    /// their single run.
    private static func retime(
        _ first: SolveReport,
        _ type: any Solution.Type,
        input: Input,
        gpu: GPU,
        budget: Duration
    ) throws -> SolveReport {
        var options = Benchmark.Options()
        options.budget = budget / 3
        options.minIterations = 3
        options.maxIterations = 1000

        let parse = try Benchmark.measure(gpu, options) { _ = try type.init(input: input, gpu: gpu) }
        let solution = try type.init(input: input, gpu: gpu)
        var runs = parse.iterations
        func stable(_ part: SolveReport.Part, _ body: () throws -> String) throws -> SolveReport.Part {
            guard case .success = part.answer else { return part }
            let stats = try Benchmark.measure(gpu, options) { _ = try body() }
            runs = min(runs, stats.iterations)
            return .init(answer: part.answer, elapsed: stats.min)
        }
        var report = SolveReport(
            id: first.id, parse: parse.min,
            part1: try stable(first.part1, solution.part1), part2: try stable(first.part2, solution.part2))
        report.runs = runs
        return report
    }

    private static func solveOnce(
        _ type: any Solution.Type, input: Input, gpu: GPU, parts: Set<Int>
    ) throws -> SolveReport {
        let clock = ContinuousClock()
        var solution: (any Solution)?
        let parse = try clock.measure { solution = try type.init(input: input, gpu: gpu) }
        guard let solution else { throw SolutionError.malformedInput("init produced no solution") }

        func run(_ part: Int, _ body: () throws -> String) -> SolveReport.Part {
            guard parts.contains(part) else {
                return .init(answer: .failure(SolveFailure(SkippedPart())), elapsed: .zero)
            }
            var result: Result<String, SolveFailure> = .failure(SolveFailure(SkippedPart()))
            let elapsed = clock.measure {
                do { result = .success(try body()) } catch { result = .failure(SolveFailure(error)) }
            }
            return .init(answer: result, elapsed: elapsed)
        }

        return SolveReport(
            id: type.id,
            parse: parse,
            part1: run(1, solution.part1),
            part2: run(2, solution.part2)
        )
    }

    struct SkippedPart: Error, CustomStringConvertible {
        var description: String { "skipped" }
    }
}

public extension Duration {
    /// Compact human-readable form: "812 ns", "41.3 µs", "2.10 ms".
    var pretty: String { Benchmark.format(self) }
}
