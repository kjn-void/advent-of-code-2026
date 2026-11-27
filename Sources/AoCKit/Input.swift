/// Raw puzzle input plus the parsing helpers almost every day needs.
///
/// Everything here produces flat arrays so the result can be copied straight into an
/// `MTLBuffer` with `GPU.buffer(_:)`.
public struct Input: Sendable {
    /// Raw text exactly as stored on disk (trailing newline included, `\r` removed).
    public let text: String

    public init(_ text: String) {
        // Work on Unicode scalars: Swift compares Characters, and "\r\n" is a single Character, so
        // `text.contains("\r")` is false for CRLF text and `replacing("\r", ...)` removes nothing.
        let scalars = text.unicodeScalars
        self.text = scalars.contains("\r") ? String(scalars.filter { $0 != "\r" }) : text
    }

    /// UTF-8 bytes of the input. AoC input is ASCII, so byte offsets equal character offsets.
    public var bytes: [UInt8] { Array(text.utf8) }

    /// Lines without the trailing empty line produced by the final newline.
    public var lines: [Substring] {
        var result = text.split(separator: "\n", omittingEmptySubsequences: false)
        while result.last?.isEmpty == true { result.removeLast() }
        return result
    }

    /// Blocks separated by blank lines, each split into lines.
    public var paragraphs: [[Substring]] {
        lines.split(whereSeparator: \.isEmpty).map(Array.init)
    }

    /// Every integer in the input, in order (a leading `-` makes it negative).
    public var integers: [Int] { Parse.integers(in: text) }

    /// Integers per line; handy for "one record per line" puzzles.
    public var integersPerLine: [[Int]] { lines.map { Parse.integers(in: $0) } }

    /// The input as a rectangular byte grid. Throws if the lines differ in length.
    public func grid() throws -> Grid<UInt8> {
        try Grid(lines: lines)
    }

    /// The input as a grid, mapping each ASCII byte through `transform`.
    public func grid<T>(_ transform: (UInt8) throws -> T) throws -> Grid<T> {
        try grid().map(transform)
    }
}

extension Input: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(value) }
}
