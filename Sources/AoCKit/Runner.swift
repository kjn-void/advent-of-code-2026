/// Runs a solution once and records how long each phase took. Shared by CLI and visualizer.
public struct SolveReport: Sendable {
    public struct Part: Sendable {
        public let answer: Result<String, SolveFailure>
        public let elapsed: Duration
    }

    public let id: PuzzleID
    public let parse: Duration
    public let part1: Part
    public let part2: Part
}

/// Error wrapper that keeps the message (errors from Metal are not `Sendable`).
public struct SolveFailure: Error, Sendable, CustomStringConvertible {
    public let description: String

    public init(_ error: any Error) { description = String(describing: error) }
}

public enum Runner {
    /// Parses `input` and solves the requested parts. Parse errors throw; part errors are
    /// captured in the report so one unfinished part does not hide the other.
    public static func solve(
        _ type: any Solution.Type, input: Input, gpu: GPU, parts: Set<Int> = [1, 2]
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
