import AoCKit
import Testing

@testable import Solutions

@Suite("Example 1 — Trebuchet?! (AoC 2023 day 1)", .requiresGPU)
struct Example01Tests {
    static let examples = [
        Example(
            "part 1 example", part1: "142",
            """
            1abc2
            pqr3stu8vwx
            a1b2c3d4e5f
            treb7uchet
            """),
        Example(
            "part 2 example", part2: "281",
            """
            two1nine
            eightwothree
            abcone2threexyz
            xtwone3four
            4nineeightseven2
            zoneight234
            7pqrstsixteen
            """),
        // Edge cases the examples don't cover.
        Example("single digit counts twice", part1: "77", part2: "77", "treb7uchet"),
        Example("overlapping words", part2: "82", "eightwo"),
        Example("no trailing newline", part1: "11", part2: "11", "1"),
        Example("empty input", part1: "0", part2: "0", ""),
    ]

    @Test(arguments: examples)
    func example(_ example: Example) throws {
        try check(Example01.self, example)
    }

    /// The GPU answer must match a straightforward CPU implementation on the real input.
    @Test(.enabled(if: hasRealInput(Example01.id), "input/2023/day01.txt not downloaded"))
    func matchesCPUReferenceOnRealInput() throws {
        let input = try #require(realInput(Example01.id))
        let solution = try Example01(input: input, gpu: .shared)
        #expect(try solution.part1() == "\(Self.reference(input, spelled: false))")
        #expect(try solution.part2() == "\(Self.reference(input, spelled: true))")
    }

    static func reference(_ input: Input, spelled: Bool) -> Int {
        let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        return input.lines.reduce(0) { sum, line in
            var digits: [Int] = []
            let bytes = Array(line.utf8)
            for i in bytes.indices {
                if Parse.isDigit(bytes[i]) {
                    digits.append(Int(bytes[i] - UInt8(ascii: "0")))
                } else if spelled, let w = words.firstIndex(where: { line.dropFirst(i).hasPrefix($0) }) {
                    digits.append(w + 1)
                }
            }
            guard let first = digits.first, let last = digits.last else { return sum }
            return sum + first * 10 + last
        }
    }
}
