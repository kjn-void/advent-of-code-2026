import AoCShared

/// Row-major 2D grid backed by one flat array, i.e. exactly the layout kernels index with
/// `aoc::index(p, size)`. Upload with `gpu.buffer(grid.cells)` and pass `grid.size`.
public struct Grid<Element> {
    public let width: Int
    public let height: Int
    public var cells: [Element]

    public init(width: Int, height: Int, cells: [Element]) {
        precondition(cells.count == width * height, "cell count must equal width * height")
        self.width = width
        self.height = height
        self.cells = cells
    }

    public init(width: Int, height: Int, repeating value: Element) {
        self.init(width: width, height: height, cells: Array(repeating: value, count: width * height))
    }

    /// Grid dimensions in the layout kernels expect.
    public var size: AoCGridSize { AoCGridSize(width: UInt32(width), height: UInt32(height)) }

    public var count: Int { cells.count }

    @inline(__always)
    public func contains(x: Int, y: Int) -> Bool { x >= 0 && y >= 0 && x < width && y < height }

    @inline(__always)
    public func contains(_ p: SIMD2<Int>) -> Bool { contains(x: p.x, y: p.y) }

    @inline(__always)
    public func index(x: Int, y: Int) -> Int { y * width + x }

    @inline(__always)
    public func point(at index: Int) -> SIMD2<Int> { SIMD2(index % width, index / width) }

    public subscript(x: Int, y: Int) -> Element {
        get { cells[index(x: x, y: y)] }
        set { cells[index(x: x, y: y)] = newValue }
    }

    public subscript(p: SIMD2<Int>) -> Element {
        get { self[p.x, p.y] }
        set { self[p.x, p.y] = newValue }
    }

    public func map<T>(_ transform: (Element) throws -> T) rethrows -> Grid<T> {
        Grid<T>(width: width, height: height, cells: try cells.map(transform))
    }

    /// In-bounds neighbours of `p` using the given offsets (defaults to 4-neighbourhood).
    public func neighbors(of p: SIMD2<Int>, _ offsets: [SIMD2<Int>] = Direction.four) -> [SIMD2<Int>] {
        offsets.map { p &+ $0 }.filter(contains)
    }
}

extension Grid: Sendable where Element: Sendable {}
extension Grid: Equatable where Element: Equatable {}

public extension Grid where Element == UInt8 {
    /// Builds a byte grid from equally long lines.
    init(lines: [Substring]) throws {
        guard let width = lines.first?.utf8.count else {
            self.init(width: 0, height: 0, cells: [])
            return
        }
        var cells: [UInt8] = []
        cells.reserveCapacity(width * lines.count)
        for (row, line) in lines.enumerated() {
            guard line.utf8.count == width else {
                throw SolutionError.malformedInput("line \(row + 1) has \(line.utf8.count) columns, expected \(width)")
            }
            cells.append(contentsOf: line.utf8)
        }
        self.init(width: width, height: lines.count, cells: cells)
    }

    /// Index of the first cell equal to `ascii`, as a point.
    func firstPoint(of ascii: Character) -> SIMD2<Int>? {
        guard let byte = ascii.asciiValue, let index = cells.firstIndex(of: byte) else { return nil }
        return point(at: index)
    }

    /// Text rendering, mostly for debugging and test failure messages.
    var text: String {
        (0..<height).map { row in
            String(validating: cells[(row * width)..<((row + 1) * width)], as: UTF8.self) ?? "<row \(row): not UTF-8>"
        }.joined(separator: "\n")
    }
}

/// Neighbourhood offsets matching `aoc::kDirs4` / `aoc::kDirs8` in AoCKernels.h.
public enum Direction {
    public static let four: [SIMD2<Int>] = [SIMD2(1, 0), SIMD2(0, 1), SIMD2(-1, 0), SIMD2(0, -1)]
    public static let eight: [SIMD2<Int>] = [
        SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1), SIMD2(-1, 1),
        SIMD2(-1, 0), SIMD2(-1, -1), SIMD2(0, -1), SIMD2(1, -1),
    ]
}
