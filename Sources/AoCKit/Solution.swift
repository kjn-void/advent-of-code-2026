/// One Advent of Code puzzle solution.
///
/// Lifecycle (identical in the CLI, tests, benchmarks and visualizer):
/// 1. `init(input:gpu:)` parses the raw text on the CPU into flat, GPU-friendly buffers
///    (`GPUBuffer`, `Grid`, arrays of `BitwiseCopyable` structs). Benchmarked as "Parse".
/// 2. `part1()` / `part2()` encode and run Metal kernels (or plain Swift where the GPU is
///    pointless) and return the answer as a string.
///
/// Parts must not mutate shared state: benchmarks call each part repeatedly on one instance.
public protocol Solution: AnyObject, SendableMetatype {
    /// Which puzzle this solves and where its input comes from.
    static var id: PuzzleID { get }
    /// Puzzle title shown in the CLI header and the visualizer sidebar.
    static var title: String { get }
    /// The worked example from the puzzle text, if the solution carries one. The visualizer can
    /// show it instead of the real input (`--example` on the command line).
    static var exampleInput: String? { get }

    init(input: Input, gpu: GPU) throws
    func part1() throws -> String
    func part2() throws -> String
}

public extension Solution {
    static var exampleInput: String? { nil }
}

/// Identifies a solution slot.
///
/// * `.day(n)` — this year's puzzle `n` (AoC 2026, days 1...12). CLI name `n`.
/// * `.example(n, year:day:)` — a past puzzle used to exercise the framework end to end.
///   CLI name `e<n>`.
public struct PuzzleID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public enum Kind: Int, Sendable { case example, day }

    public let kind: Kind
    public let number: Int
    /// AoC event year the input is downloaded from.
    public let year: Int
    /// AoC day the input is downloaded from.
    public let aocDay: Int

    public static func day(_ number: Int) -> Self {
        Self(kind: .day, number: number, year: AoCClient.year, aocDay: number)
    }

    public static func example(_ number: Int, year: Int, day: Int) -> Self {
        Self(kind: .example, number: number, year: year, aocDay: day)
    }

    /// "Day 03" / "Example 1".
    public var description: String {
        switch kind {
        case .day: "Day \(twoDigit)"
        case .example: "Example \(number)"
        }
    }

    /// Name used on the command line: "3" / "e1".
    public var cliName: String {
        switch kind {
        case .day: "\(number)"
        case .example: "e\(number)"
        }
    }

    /// Where the puzzle lives, e.g. "AoC 2023 day 1".
    public var source: String { "AoC \(year) day \(aocDay)" }

    public var url: String { "https://adventofcode.com/\(year)/day/\(aocDay)" }

    private var twoDigit: String { number < 10 ? "0\(number)" : "\(number)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.kind.rawValue, lhs.number) < (rhs.kind.rawValue, rhs.number)
    }
}

/// Errors a solution may throw instead of crashing on malformed input.
public enum SolutionError: Error, CustomStringConvertible {
    case malformedInput(String)
    case notImplemented

    public var description: String {
        switch self {
        case .malformedInput(let why): "malformed input: \(why)"
        case .notImplemented: "not implemented yet"
        }
    }
}
