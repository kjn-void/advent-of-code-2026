import AoCKit
import Solutions
import Testing

/// One worked example from a puzzle description. `part1`/`part2` are nil when that example
/// does not apply to a part (AoC often gives a separate example for part 2).
struct Example: Sendable, CustomTestStringConvertible {
    let name: String
    let input: String
    let part1: String?
    let part2: String?

    init(_ name: String, part1: String? = nil, part2: String? = nil, _ input: String) {
        self.name = name
        self.input = input
        self.part1 = part1
        self.part2 = part2
    }

    var testDescription: String { name }
}

/// Solves `example` with `type` and checks every expected answer it carries.
func check<S: Solution>(_ type: S.Type, _ example: Example, gpu: GPU = .shared) throws {
    let solution = try type.init(input: Input(example.input), gpu: gpu)
    if let expected = example.part1 {
        #expect(try solution.part1() == expected, "part 1 of \(example.name)")
    }
    if let expected = example.part2 {
        #expect(try solution.part2() == expected, "part 2 of \(example.name)")
    }
}

/// Cached real input for `id`, or nil (tests depending on it are skipped when absent, e.g. CI).
func realInput(_ id: PuzzleID) -> Input? {
    InputStore().cached(id)
}

func hasRealInput(_ id: PuzzleID) -> Bool {
    InputStore().hasCachedInput(for: id)
}
