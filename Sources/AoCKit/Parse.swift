/// Allocation-light parsing helpers that work on UTF-8 bytes.
public enum Parse {
    /// All integers in `text`, in order.
    ///
    /// A `-` directly before a digit is treated as a sign unless the character before the `-`
    /// is itself a digit, so ranges keep working: `"x=-5"` → `[-5]`, `"3-4"` → `[3, 4]`.
    /// Pass `signed: false` to ignore `-` entirely.
    public static func integers(in text: some StringProtocol, signed: Bool = true) -> [Int] {
        var result: [Int] = []
        var value = 0
        var inNumber = false
        var negative = false
        var previous: UInt8 = 0
        var beforePrevious: UInt8 = 0

        for byte in text.utf8 {
            if isDigit(byte) {
                if !inNumber {
                    inNumber = true
                    negative = signed && previous == UInt8(ascii: "-") && !isDigit(beforePrevious)
                    value = 0
                }
                let digit = Int(byte &- UInt8(ascii: "0"))
                value = negative ? (value &* 10 &- digit) : (value &* 10 &+ digit)
            } else if inNumber {
                result.append(value)
                inNumber = false
            }
            beforePrevious = previous
            previous = byte
        }
        if inNumber { result.append(value) }
        return result
    }

    /// Parses a single decimal integer (surrounding whitespace allowed).
    public static func int(_ text: some StringProtocol) throws -> Int {
        guard let value = Int(text.trimmingWhitespace()) else {
            throw SolutionError.malformedInput("not an integer: '\(text)'")
        }
        return value
    }

    @inline(__always)
    public static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}

public extension StringProtocol {
    /// Leading/trailing spaces, tabs and newlines removed.
    func trimmingWhitespace() -> SubSequence {
        let isSpace: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        guard let start = firstIndex(where: { !isSpace($0) }),
            let end = lastIndex(where: { !isSpace($0) })
        else { return self[endIndex...] }
        return self[start...end]
    }
}
