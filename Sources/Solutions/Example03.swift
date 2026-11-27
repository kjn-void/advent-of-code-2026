import AoCKit
import AoCRender
import AoCShared
import Metal
import simd

/// Example 3 — AoC 2022 day 17, "Pyroclastic Flow".
///
/// Five Tetris-like rock shapes fall in repeating order down a 7-wide chamber while hot gas jets
/// (`<` / `>`) push them sideways before every 1-unit drop. Part 1 asks for the tower height after
/// 2,022 rocks; Part 2 asks for the height after 1,000,000,000,000 rocks.
///
/// Each chamber row fits in 7 bits (`UInt8`) and all four rows of a rock pack into one `UInt32`, so
/// wall checks, horizontal pushes, and rock-vs-tower collision tests are single bitwise operations.
/// Part 2 detects an exact cycle using `(rockType, jetIndex, reachableContour)` where the contour
/// is the top of the tower down to where open air flood-filled from above is sealed off (see
/// `PyroclasticSim.CycleDetector` for why that stays exact when the tower never seals).
public final class Example03: Solution, Sendable {
    public static let id = PuzzleID.example(3, year: 2022, day: 17)
    public static let title = "Pyroclastic Flow"
    public static let exampleInput: String? = ">>><<><>><<<>><>>><<<>>><<<><<<>><>><<>>\n"

    static let part1Rocks: UInt64 = 2022
    static let part2Rocks: UInt64 = 1_000_000_000_000

    let gpu: GPU
    /// Gas jet directions: `-1` for `<`, `+1` for `>`.
    let jets: [Int8]

    public init(input: Input, gpu: GPU) throws {
        self.gpu = gpu
        var jets: [Int8] = []
        jets.reserveCapacity(input.text.utf8.count)
        for byte in input.text.utf8 {
            switch byte {
            case UInt8(ascii: "<"): jets.append(-1)
            case UInt8(ascii: ">"): jets.append(1)
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                break
            default:
                throw SolutionError.malformedInput("unexpected '\(Character(Unicode.Scalar(byte)))' in jet pattern")
            }
        }
        guard !jets.isEmpty else { throw SolutionError.malformedInput("empty jet pattern") }
        self.jets = jets
    }

    public func part1() throws -> String {
        "\(try PyroclasticSim.height(after: Self.part1Rocks, jets: jets))"
    }

    public func part2() throws -> String {
        "\(try PyroclasticSim.height(after: Self.part2Rocks, jets: jets))"
    }
}

// MARK: - Bitboard Simulation & Exact Cycle Detection

/// Bitboard rock shapes packed bottom-to-top in 4 bytes of a `UInt32` (bit `c` = column `c`,
/// 0 = left wall, 6 = right wall) at their initial spawn column `x = 2`.
enum PyroclasticSim {
    struct Shape {
        let mask: UInt32
        let height: Int
        let cells: [(dx: Int, dy: Int)]
    }

    static let shapes: [Shape] = [
        Shape(mask: 0x00_00_00_3C, height: 1, cells: [(0, 0), (1, 0), (2, 0), (3, 0)]),  // -
        Shape(mask: 0x00_08_1C_08, height: 3, cells: [(1, 0), (0, 1), (1, 1), (2, 1), (1, 2)]),  // +
        Shape(mask: 0x00_10_10_1C, height: 3, cells: [(0, 0), (1, 0), (2, 0), (2, 1), (2, 2)]),  // J
        Shape(mask: 0x04_04_04_04, height: 4, cells: [(0, 0), (0, 1), (0, 2), (0, 3)]),  // |
        Shape(mask: 0x00_00_0C_0C, height: 2, cells: [(0, 0), (1, 0), (0, 1), (1, 1)]),  // o
    ]

    struct CycleKey: Hashable {
        let rockType: UInt8
        let jetIndex: UInt32
        let contour: [UInt8]
    }

    /// Most chamber rows a cycle key holds. Real inputs seal the tower far above this; patterns that
    /// never seal it (every jet blowing one way leaves a column open down to the floor) are cut here.
    static let contourRows = 128
    /// Rocks to simulate before giving up on finding a cycle. The key space is finite, so a cycle
    /// always exists, but a pathological jet pattern could take unreasonably long to reach it.
    static let maxRocksWithoutCycle = 200_000

    /// Finds the first exact repeat of the chamber state.
    ///
    /// The key is (next rock, jet index, top rows down to where the open air is sealed off, at most
    /// `contourRows` of them). A repeat only counts if no rock in between inspected a row below the
    /// key's rows. Then the next period's rocks meet exactly the same rows and repeat it move for move,
    /// and by induction so does every period after it. That keeps truncated keys exact, not just
    /// likely.
    struct CycleDetector {
        /// Tower height after each rock; `heights[0] == 0`.
        private(set) var heights = [0]
        /// Lowest chamber row each rock inspected (-1: it reached the floor).
        private var lowest: [Int] = []
        private var seen: [CycleKey: Int] = [:]

        /// Call after every rock settles. Returns `(start, length)`: the state after rock `start`
        /// repeats after rock `start + length`, forever.
        mutating func observe(
            rocks: Int, jetIndex: Int, chamber: [UInt8], lowestRow: Int
        ) throws -> (start: Int, length: Int)? {
            heights.append(chamber.count)
            lowest.append(lowestRow)
            let key = CycleKey(
                rockType: UInt8(rocks % shapes.count), jetIndex: UInt32(jetIndex),
                contour: reachableContour(chamber))
            if let previous = seen[key] {
                let keyBottom = heights[previous] - key.contour.count
                if (lowest[previous..<rocks].min() ?? 0) >= keyBottom { return (previous, rocks - previous) }
            }
            seen[key] = rocks
            guard rocks < maxRocksWithoutCycle else {
                throw SolutionError.malformedInput("no repeating tower state within \(maxRocksWithoutCycle) rocks")
            }
            return nil
        }
    }

    struct CycleInfo {
        let cycleStart: Int
        let cycleLength: Int
        let cycleHeight: UInt64
    }

    struct Recording {
        let rows: Int
        let cells: [Example03Cell]
        let rocks: [Example03RockInfo]
        let fallSteps: [Example03FallStep]
        let cycle: CycleInfo
        let part2Height: UInt64
    }

    /// Exact tower height after `target` rocks, using exact contour cycle detection once a state
    /// repeats.
    static func height(after target: UInt64, jets: [Int8]) throws -> UInt64 {
        guard target > 0 else { return 0 }
        let jetCount = jets.count
        var chamber: [UInt8] = []
        chamber.reserveCapacity(4096)
        var detector = CycleDetector()
        var jetIndex = 0
        var rockCount = 0

        while UInt64(rockCount) < target {
            let shapeIndex = rockCount % shapes.count
            let shape = shapes[shapeIndex]
            let height = chamber.count
            var mask = shape.mask
            var y = height + 3

            while true {
                let dir = jets[jetIndex]
                jetIndex += 1
                if jetIndex == jetCount { jetIndex = 0 }

                let window = windowMask(chamber, at: y)
                if dir < 0 {
                    if (mask & 0x0101_0101) == 0 {
                        let shifted = mask >> 1
                        if (shifted & window) == 0 { mask = shifted }
                    }
                } else if (mask & 0x4040_4040) == 0 {
                    let shifted = mask << 1
                    if (shifted & window) == 0 { mask = shifted }
                }

                if y == 0 || (mask & windowMask(chamber, at: y - 1)) != 0 {
                    break
                }
                y -= 1
            }

            settle(mask: mask, shapeHeight: shape.height, at: y, into: &chamber)
            rockCount += 1

            if let cycle = try detector.observe(
                rocks: rockCount, jetIndex: jetIndex, chamber: chamber, lowestRow: y - 1)
            {
                let heights = detector.heights
                let cycleHeight = UInt64(chamber.count - heights[cycle.start])
                let remaining = target - UInt64(cycle.start)
                let fullCycles = remaining / UInt64(cycle.length)
                let remainder = Int(remaining % UInt64(cycle.length))
                return UInt64(heights[cycle.start + remainder]) + fullCycles * cycleHeight
            }
        }
        return UInt64(chamber.count)
    }

    /// Simulates enough rocks to record both Part 1 (`2022` rocks) and Part 2's visualization
    /// (prefix + Cycle 1 + Cycle 2 + remainder rocks).
    static func record(jets: [Int8], part1Rocks: Int, part2Target: UInt64) throws -> Recording {
        var chamber: [UInt8] = []
        var cells: [Example03Cell] = []
        var rocks: [Example03RockInfo] = []
        var fallSteps: [Example03FallStep] = []
        var detector = CycleDetector()
        var detectedCycle: CycleInfo?
        var targetToRecord = part1Rocks
        var jetIndex = 0

        while rocks.count < targetToRecord || detectedCycle == nil {
            let rockIndex = rocks.count
            let shapeIndex = rockIndex % shapes.count
            let shape = shapes[shapeIndex]
            let drop = dropRecordedRock(
                shape: shape, jets: jets, jetIndex: &jetIndex, chamber: chamber, fallSteps: &fallSteps)

            settle(mask: drop.mask, shapeHeight: shape.height, at: drop.y, into: &chamber)
            while cells.count < chamber.count * Int(EXAMPLE03_WIDTH) {
                cells.append(Example03Cell(rockIndex: EXAMPLE03_NONE, shape: 0))
            }
            for offset in shape.cells {
                let idx = (drop.y + offset.dy) * Int(EXAMPLE03_WIDTH) + (drop.x + offset.dx)
                cells[idx] = Example03Cell(rockIndex: UInt32(rockIndex), shape: UInt32(shapeIndex))
            }
            rocks.append(
                Example03RockInfo(
                    shape: UInt32(shapeIndex), finalX: UInt32(drop.x), finalY: UInt32(drop.y),
                    towerHeight: UInt32(chamber.count),
                    fallOffset: UInt32(drop.fallOffset), fallCount: UInt32(fallSteps.count - drop.fallOffset)))

            if detectedCycle == nil,
                let found = try detector.observe(
                    rocks: rocks.count, jetIndex: jetIndex, chamber: chamber, lowestRow: drop.y - 1)
            {
                let cycleHeight = UInt64(chamber.count - detector.heights[found.start])
                detectedCycle = CycleInfo(cycleStart: found.start, cycleLength: found.length, cycleHeight: cycleHeight)
                let remainder = Int((part2Target - UInt64(found.start)) % UInt64(found.length))
                targetToRecord = max(part1Rocks, found.start + 2 * found.length + remainder)
            }
        }

        guard let cycle = detectedCycle else { throw SolutionError.malformedInput("no repeating tower state") }
        // Tower height after each recorded rock (the detector stops tracking once it found the cycle).
        let heights = [0] + rocks.map { Int($0.towerHeight) }
        let remaining = part2Target - UInt64(cycle.cycleStart)
        let fullCycles = remaining / UInt64(cycle.cycleLength)
        let remainder = Int(remaining % UInt64(cycle.cycleLength))
        let part2Height = UInt64(heights[cycle.cycleStart + remainder]) + fullCycles * cycle.cycleHeight
        return Recording(
            rows: chamber.count, cells: cells, rocks: rocks, fallSteps: fallSteps,
            cycle: cycle, part2Height: part2Height)
    }

    private struct DroppedRock {
        let x: Int
        let y: Int
        let mask: UInt32
        let fallOffset: Int
    }

    private static func dropRecordedRock(
        shape: Shape, jets: [Int8], jetIndex: inout Int, chamber: [UInt8], fallSteps: inout [Example03FallStep]
    ) -> DroppedRock {
        let jetCount = jets.count
        var mask = shape.mask
        var x = 2
        var y = chamber.count + 3
        let fallOffset = fallSteps.count
        while true {
            let dir = jets[jetIndex]
            jetIndex += 1
            if jetIndex == jetCount { jetIndex = 0 }

            let window = windowMask(chamber, at: y)
            var blocked: UInt32 = 1
            if dir < 0 {
                if (mask & 0x0101_0101) == 0, ((mask >> 1) & window) == 0 {
                    mask >>= 1
                    x -= 1
                    blocked = 0
                }
            } else if (mask & 0x4040_4040) == 0, ((mask << 1) & window) == 0 {
                mask <<= 1
                x += 1
                blocked = 0
            }
            fallSteps.append(
                Example03FallStep(
                    xAfterJet: Int32(x), yBeforeDrop: Int32(y), jetDir: Int32(dir), blocked: blocked))

            if y == 0 || (mask & windowMask(chamber, at: y - 1)) != 0 {
                return DroppedRock(x: x, y: y, mask: mask, fallOffset: fallOffset)
            }
            y -= 1
        }
    }

    @inline(__always)
    private static func windowMask(_ chamber: [UInt8], at y: Int) -> UInt32 {
        let count = chamber.count
        guard y < count else { return 0 }
        var mask = UInt32(chamber[y])
        if y + 1 < count { mask |= UInt32(chamber[y + 1]) << 8 }
        if y + 2 < count { mask |= UInt32(chamber[y + 2]) << 16 }
        if y + 3 < count { mask |= UInt32(chamber[y + 3]) << 24 }
        return mask
    }

    @inline(__always)
    private static func settle(mask: UInt32, shapeHeight: Int, at y: Int, into chamber: inout [UInt8]) {
        let top = y + shapeHeight
        if chamber.count < top {
            chamber.append(contentsOf: repeatElement(0, count: top - chamber.count))
        }
        for row in 0..<shapeHeight {
            chamber[y + row] |= UInt8((mask >> (row * 8)) & 0x7F)
        }
    }

    /// Top rows of the tower, down to the row where open air flood-filled from above (down and
    /// sideways, the only ways a rock moves) is sealed off, or `contourRows` rows if it never is.
    /// `CycleDetector` checks that no rock looked below them, which keeps the cycle exact.
    private static func reachableContour(_ chamber: [UInt8]) -> [UInt8] {
        var contour: [UInt8] = []
        var air: UInt8 = 0x7F
        for y in stride(from: chamber.count - 1, through: 0, by: -1) {
            let row = chamber[y]
            contour.append(row)
            let open = ~row & 0x7F
            air &= open
            while true {
                let expanded = (air | ((air << 1) & 0x7F) | (air >> 1)) & open
                if expanded == air { break }
                air = expanded
            }
            if air == 0 || contour.count == contourRows { break }
        }
        return contour
    }
}

// MARK: - Visualization

extension Example03: Visualizable {
    public static func makeScene(input: Input, gpu: GPU) throws -> any VisualizationScene {
        try Example03Scene(solution: Example03(input: input, gpu: gpu))
    }
}

/// GPU-driven 3D visualization of Pyroclastic Flow: translucent obsidian chamber, pulsing jet vents,
/// wind streaks, falling mineral rocks, impact embers, and Part 2's cycle-match + 10^12 warp jump.
@MainActor
final class Example03Scene: VisualizationScene {
    let instances: GPUBuffer<AoCInstance>
    let bounds: SceneBounds
    var instanceCount: Int { instances.count }
    var stepCount: Int { Int(Example03.part1Rocks) }
    var preferredView: CameraView { CameraView(yaw: 0.28, pitch: 0.20, distanceScale: 0.80) }

    private let recording: PyroclasticSim.Recording
    private let cellsBuffer: GPUBuffer<Example03Cell>
    private let rocksBuffer: GPUBuffer<Example03RockInfo>
    private let fallStepsBuffer: GPUBuffer<Example03FallStep>
    private let pipeline: any MTLComputePipelineState

    private let part2JumpStep: Int
    private let part2SkippedCycles: UInt64
    private let part2Remainder: Int
    private let part2TotalSteps: Int

    nonisolated init(solution: Example03) throws {
        let gpu = solution.gpu
        let rec = try PyroclasticSim.record(
            jets: solution.jets,
            part1Rocks: Int(Example03.part1Rocks),
            part2Target: Example03.part2Rocks)
        recording = rec
        cellsBuffer = gpu.buffer(rec.cells, label: "chamberCells")
        rocksBuffer = gpu.buffer(rec.rocks, label: "rocks")
        fallStepsBuffer = gpu.buffer(rec.fallSteps, label: "fallSteps")
        pipeline = try gpu.kernel("example03_instances")
        let slotCount =
            Int(EXAMPLE03_WINDOW_ROWS * EXAMPLE03_WIDTH) + Int(EXAMPLE03_ROCK_CELLS)
            + Int(EXAMPLE03_FRAME_SLOTS) + Int(EXAMPLE03_JET_STREAKS)
            + Int(EXAMPLE03_PARTICLES) + Int(EXAMPLE03_SCORE_DIGITS * EXAMPLE03_GLYPH_PIXELS)
        instances = gpu.buffer(count: slotCount, of: AoCInstance.self, label: "instances")

        let c = rec.cycle
        part2JumpStep = c.cycleStart + 2 * c.cycleLength
        let remaining = Example03.part2Rocks - UInt64(c.cycleStart)
        let fullCycles = remaining / UInt64(c.cycleLength)
        part2SkippedCycles = fullCycles >= 2 ? fullCycles - 2 : 0
        part2Remainder = Int(remaining % UInt64(c.cycleLength))
        part2TotalSteps = part2JumpStep + 1 + part2Remainder

        bounds = SceneBounds(min: SIMD3(-7.5, -1.0, -4.0), max: SIMD3(7.5, 25.0, 4.0))
    }

    func stepCount(part: Int) -> Int {
        part == 2 ? part2TotalSteps : Int(Example03.part1Rocks)
    }

    func preferredStepsPerSecond(part: Int) -> Double {
        part == 2 ? (part2TotalSteps <= 150 ? 2.5 : 24) : 4
    }

    func cameraFocus(step: Int, progress: Float, part: Int) -> SIMD3<Float>? {
        let state = timelineState(step: step, progress: progress, part: part)
        return SIMD3(0, state.cameraY, 0)
    }

    func update(_ frame: FrameContext) throws {
        let state = timelineState(step: frame.step, progress: frame.progress, part: frame.part)
        let windowBottom = UInt32(max(0, Int(state.cameraY.rounded(.down)) - 18))
        let params = Example03VizParams(
            part: UInt32(frame.part),
            totalRows: UInt32(recording.rows),
            windowBottom: windowBottom,
            settledCount: UInt32(state.settledCount),
            activeRock: state.activeRock,
            progress: frame.progress,
            cameraY: state.cameraY,
            time: frame.time,
            cycleStart: UInt32(recording.cycle.cycleStart),
            cycleLength: UInt32(recording.cycle.cycleLength),
            isHyperJump: state.isHyperJump ? 1 : 0,
            padding: 0,
            displayHeight: state.displayHeight,
            previousHeight: state.previousHeight,
            impactAge: state.impactAge,
            popAmount: state.popAmount)

        try frame.gpu.encode(into: frame.commandBuffer) { encoder in
            encoder.dispatch(
                pipeline, count: instances.count,
                .buffer(cellsBuffer), .buffer(rocksBuffer), .buffer(fallStepsBuffer),
                .buffer(instances), .value(params))
        }
    }

    func caption(step: Int, part: Int) -> String {
        if part == 2 { return partTwoCaption(step: step) }
        let idx = min(step, recording.rocks.count - 1)
        let rock = recording.rocks[idx]
        let names = ["-", "+", "J", "|", "o"]
        return "Rock \(idx + 1)/\(Example03.part1Rocks) (\(names[Int(rock.shape)]))"
            + "   ·   lands at (\(rock.finalX), \(rock.finalY))"
            + "   ·   tower height \(rock.towerHeight)"
    }

    private func partTwoCaption(step: Int) -> String {
        let c = recording.cycle
        let c2Start = c.cycleStart + c.cycleLength
        if step < c.cycleStart {
            let h = recording.rocks[step].towerHeight
            return "Prefix rock \(step + 1)/\(c.cycleStart)   ·   height \(h)"
        }
        if step < c2Start {
            let h = recording.rocks[step].towerHeight
            return "Cycle 1 (cyan) rock \(step - c.cycleStart + 1)/\(c.cycleLength)   ·   height \(h)"
        }
        if step < part2JumpStep {
            let h = recording.rocks[step].towerHeight
            return "Cycle 2 match (magenta) \(step - c2Start + 1)/\(c.cycleLength)"
                + "   ·   +\(c.cycleHeight) rows / \(c.cycleLength) rocks   ·   height \(h)"
        }
        if step == part2JumpStep {
            let jumped =
                UInt64(recording.rocks[part2JumpStep - 1].towerHeight) + part2SkippedCycles * c.cycleHeight
            return "HYPER-JUMP × \(part2SkippedCycles) cycles (+\(part2SkippedCycles * c.cycleHeight) rows)"
                + "   ·   height \(jumped)"
        }
        let rockIdx = step - 1
        let tailPos = step - part2JumpStep
        let h = UInt64(recording.rocks[rockIdx].towerHeight) + part2SkippedCycles * c.cycleHeight
        return "Remainder rock \(tailPos)/\(part2Remainder)   ·   height \(h) / \(recording.part2Height)"
    }

    private struct TimelineState {
        let settledCount: Int
        let activeRock: UInt32
        let isHyperJump: Bool
        let cameraY: Float
        let displayHeight: UInt64
        let previousHeight: UInt64
        let impactAge: Float
        let popAmount: Float
    }

    private func timelineState(step: Int, progress: Float, part: Int) -> TimelineState {
        let landAt: Float = 0.86
        let rocks = recording.rocks

        if part == 2, step == part2JumpStep {
            let baseHeight = UInt64(rocks[part2JumpStep - 1].towerHeight)
            let added = part2SkippedCycles * recording.cycle.cycleHeight
            let t = 1.0 - Double(min(max(progress, 0), 1))
            let eased = 1.0 - t * t * t
            let current = baseHeight + UInt64(Double(added) * eased)
            let pop = sin(.pi * min(max(progress, 0), 1))
            return TimelineState(
                settledCount: part2JumpStep, activeRock: EXAMPLE03_NONE, isHyperJump: true,
                cameraY: max(10, Float(baseHeight) - 3),
                displayHeight: progress >= 0.999 ? baseHeight + added : current,
                previousHeight: baseHeight, impactAge: progress, popAmount: pop)
        }

        let afterJump = part == 2 && step > part2JumpStep
        let rockIdx = min(afterJump ? step - 1 : step, rocks.count - 1)
        let landed = progress >= landAt
        let prevSimHeight = rockIdx > 0 ? UInt64(rocks[rockIdx - 1].towerHeight) : 0
        let curSimHeight = UInt64(rocks[rockIdx].towerHeight)
        let offset: UInt64 = afterJump ? part2SkippedCycles * recording.cycle.cycleHeight : 0
        let displayHeight = (landed ? curSimHeight : prevSimHeight) + offset
        let previousHeight = prevSimHeight + offset

        let impactAge = landed ? (progress - landAt) / (1 - landAt) : 1
        let milestone = landed && curSimHeight / 100 > prevSimHeight / 100
        let popAmount: Float =
            milestone
            ? sin(.pi * impactAge) : (landed && curSimHeight > prevSimHeight ? 0.18 * sin(.pi * impactAge) : 0)
        let smoothHeight =
            Float(prevSimHeight) + Float(curSimHeight - prevSimHeight) * (landed ? impactAge : 0)

        return TimelineState(
            settledCount: landed ? rockIdx + 1 : rockIdx,
            activeRock: UInt32(rockIdx),
            isHyperJump: false,
            cameraY: max(10, smoothHeight - 3),
            displayHeight: displayHeight,
            previousHeight: previousHeight,
            impactAge: impactAge,
            popAmount: popAmount)
    }
}
