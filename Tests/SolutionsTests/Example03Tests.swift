import AoCKit
import Testing

@testable import Solutions

@Suite("Example 3 — Pyroclastic Flow (AoC 2022 day 17)", .requiresGPU)
struct Example03Tests {
    static let examples = [
        Example(
            "puzzle example", part1: "3068", part2: "1514285714288",
            Example03.exampleInput ?? "")
    ]

    @Test(arguments: examples)
    func example(_ example: Example) throws {
        try check(Example03.self, example)
    }

    @Test func rejectsMalformedInputs() {
        #expect(throws: SolutionError.self) { _ = try Example03(input: "", gpu: .shared) }
        #expect(throws: SolutionError.self) { _ = try Example03(input: "   \n", gpu: .shared) }
        #expect(throws: SolutionError.self) { _ = try Example03(input: ">>x<<", gpu: .shared) }
    }

    /// Cycle detection must match a brute-force cell-by-cell simulation on both the puzzle example
    /// (verified at intermediate rock counts) and random jet patterns.
    @Test func cycleDetectionMatchesBruteForceReference() throws {
        let exampleJets = try Example03(input: Input(try #require(Example03.exampleInput)), gpu: .shared).jets
        for rocks in [1, 10, 50, 200, 2022, 4000] {
            let fast = PyroclasticSim.height(after: UInt64(rocks), jets: exampleJets)
            let brute = Self.bruteForceHeight(after: rocks, jets: exampleJets)
            #expect(fast == UInt64(brute), "rock count \(rocks)")
        }

        var random = SplitMix64(seed: 2022_17)
        for _ in 0..<15 {
            let len = Int(random.next() % 45) + 7
            let jets: [Int8] = (0..<len).map { _ in random.next().isMultiple(of: 2) ? -1 : 1 }
            let target = 1500
            let fast = PyroclasticSim.height(after: UInt64(target), jets: jets)
            let brute = Self.bruteForceHeight(after: target, jets: jets)
            #expect(fast == UInt64(brute), "random jet pattern of length \(len)")
        }
    }

    @Test(.enabled(if: hasRealInput(Example03.id), "input/2022/day17.txt not downloaded"))
    func matchesBruteForcePart1OnRealInput() throws {
        let input = try #require(realInput(Example03.id))
        let solution = try Example03(input: input, gpu: .shared)
        let brute = Self.bruteForceHeight(after: 2022, jets: solution.jets)
        #expect(try solution.part1() == "\(brute)")
        // Ensure Part 2 agrees with the recording's cycle calculation.
        let rec = PyroclasticSim.record(
            jets: solution.jets, part1Rocks: 2022, part2Target: Example03.part2Rocks)
        #expect(try solution.part2() == "\(rec.part2Height)")
    }

    /// Plain 2D array simulation without bitboards or cycle skipping, as an independent check.
    static func bruteForceHeight(after rocks: Int, jets: [Int8]) -> Int {
        let shapes: [[(Int, Int)]] = [
            [(0, 0), (1, 0), (2, 0), (3, 0)],
            [(1, 0), (0, 1), (1, 1), (2, 1), (1, 2)],
            [(0, 0), (1, 0), (2, 0), (2, 1), (2, 2)],
            [(0, 0), (0, 1), (0, 2), (0, 3)],
            [(0, 0), (1, 0), (0, 1), (1, 1)],
        ]
        var occupied: [[Bool]] = []
        var jetIndex = 0

        func fits(_ cells: [(Int, Int)], x: Int, y: Int) -> Bool {
            for (dx, dy) in cells {
                let (cx, cy) = (x + dx, y + dy)
                if cx < 0 || cx >= 7 || cy < 0 { return false }
                if cy < occupied.count, occupied[cy][cx] { return false }
            }
            return true
        }

        for r in 0..<rocks {
            let cells = shapes[r % shapes.count]
            var x = 2
            var y = occupied.count + 3
            while true {
                let dx = Int(jets[jetIndex])
                jetIndex = (jetIndex + 1) % jets.count
                if fits(cells, x: x + dx, y: y) { x += dx }
                if fits(cells, x: x, y: y - 1) {
                    y -= 1
                } else {
                    break
                }
            }
            for (dx, dy) in cells {
                let (cx, cy) = (x + dx, y + dy)
                while occupied.count <= cy { occupied.append([Bool](repeating: false, count: 7)) }
                occupied[cy][cx] = true
            }
        }
        return occupied.count
    }
}
