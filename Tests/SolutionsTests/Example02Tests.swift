import AoCKit
import Testing

@testable import Solutions

@Suite("Example 2 — Guard Gallivant (AoC 2024 day 6)", .requiresGPU)
struct Example02Tests {
    static let examples = [
        Example("puzzle example", part1: "41", part2: "6", Example02.exampleInput ?? ""),
        // Edge cases the example doesn't cover.
        Example("walks straight off", part1: "3", part2: "0", "..>.."),
        Example("facing down", part1: "2", part2: "0", ".#.\n.v.\n..."),
        Example(
            "one obstruction closes a square", part1: "7", part2: "1",
            """
            .#...
            ....#
            .^...
            ...#.
            """),
    ]

    @Test(arguments: examples)
    func example(_ example: Example) throws {
        try check(Example02.self, example)
    }

    @Test func rejectsMalformedMaps() {
        #expect(throws: SolutionError.self) { _ = try Example02(input: "....\n....", gpu: .shared) }
        #expect(throws: SolutionError.self) { _ = try Example02(input: "^..^", gpu: .shared) }
        #expect(throws: SolutionError.self) { _ = try Example02(input: "^.x.", gpu: .shared) }
        // Boxed in: she turns forever.
        #expect(throws: SolutionError.self) { _ = try Example02(input: ".#.\n#^#\n.#.", gpu: .shared).part1() }
    }

    /// The GPU loop search (jump table + Brent) must agree with a plain step-by-step simulation on
    /// lots of small random maps, including ones with no loops and guards that leave at once.
    @Test func matchesCPUReferenceOnRandomMaps() throws {
        var random = SplitMix64(seed: 2024_06)
        var checked = 0
        while checked < 60 {
            let width = Int(random.next() % 14) + 3
            let height = Int(random.next() % 14) + 3
            var cells = (0..<(width * height)).map { _ in random.next() % 100 < 18 ? "#" : "." }
            cells[Int(random.next() % UInt64(cells.count))] = ["^", ">", "v", "<"][Int(random.next() % 4)]
            let text = stride(from: 0, to: cells.count, by: width)
                .map { cells[$0..<($0 + width)].joined() }.joined(separator: "\n")
            guard let expected = Self.reference(text) else { continue }  // the original walk loops
            let solution = try Example02(input: Input(text), gpu: .shared)
            #expect(try solution.part1() == "\(expected.part1)", "part 1 of\n\(text)")
            #expect(try solution.part2() == "\(expected.part2)", "part 2 of\n\(text)")
            checked += 1
        }
    }

    @Test(.enabled(if: hasRealInput(Example02.id), "input/2024/day06.txt not downloaded"))
    func matchesCPUReferenceOnRealInput() throws {
        let input = try #require(realInput(Example02.id))
        let expected = try #require(Self.reference(input.text))
        let solution = try Example02(input: input, gpu: .shared)
        #expect(try solution.part1() == "\(expected.part1)")
        #expect(try solution.part2() == "\(expected.part2)")
    }

    /// Straightforward simulation: walk cell by cell, remembering (cell, direction) states; for
    /// part 2 put an obstruction on every visited cell but the start and rerun. Nil if the guard
    /// never leaves the original map.
    static func reference(_ text: String) -> (part1: Int, part2: Int)? {
        let rows = text.split(separator: "\n").map { Array($0.utf8) }
        let (width, height) = (rows[0].count, rows.count)
        let grid = rows.flatMap(\.self)
        let headings: [UInt8] = Array(">v<^".utf8)
        guard let start = grid.firstIndex(where: headings.contains) else { return nil }
        let startDirection = headings.firstIndex(of: grid[start]) ?? 0
        var seen = [Int](repeating: -1, count: 4 * grid.count)

        /// Visited cells, or nil if the guard loops. `run` stamps `seen` so it never needs clearing.
        func walk(extra: Int, run: Int) -> [Bool]? {
            var visited = [Bool](repeating: false, count: grid.count)
            var (cell, direction) = (start, startDirection)
            while true {
                visited[cell] = true
                if seen[cell * 4 + direction] == run { return nil }
                seen[cell * 4 + direction] = run
                let step = Direction.four[direction]
                let (x, y) = (cell % width + step.x, cell / width + step.y)
                if x < 0 || y < 0 || x >= width || y >= height { return visited }
                let next = y * width + x
                if grid[next] == UInt8(ascii: "#") || next == extra {
                    direction = (direction + 1) % 4
                } else {
                    cell = next
                }
            }
        }

        guard let visited = walk(extra: -1, run: 0) else { return nil }
        let candidates = visited.indices.filter { visited[$0] && $0 != start }
        let loops = candidates.enumerated().filter { walk(extra: $0.element, run: $0.offset + 1) == nil }.count
        return (visited.count(where: \.self), loops)
    }
}

/// Small deterministic generator for reproducible random tests.
struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
