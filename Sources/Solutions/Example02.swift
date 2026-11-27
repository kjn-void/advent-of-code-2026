import AoCKit
import AoCRender
import AoCShared
import Metal
import simd

/// Example 2 — AoC 2024 day 6, "Guard Gallivant".
///
/// A guard walks the map, turning right whenever an obstacle is in front of her, until she walks
/// off it. Part 1 counts the distinct cells she visits. Part 2 counts the cells where one extra
/// obstruction would trap her in a loop instead.
///
/// Part 1 is one sequential walk, so it runs on the CPU. Part 2 tests every cell of that walk
/// (except the start) at once on the GPU, one thread per candidate obstruction:
/// * a jump table gives, for every cell and direction, where a straight run stops, so a thread
///   moves from turn to turn instead of cell by cell (adjusting a run for its own obstruction);
/// * Brent's cycle detection finds the loop without any per-thread memory;
/// * each thread starts where the guard first reaches its candidate, since nothing before that
///   point can change.
public final class Example02: Solution, Sendable {
    public static let id = PuzzleID.example(2, year: 2024, day: 6)
    public static let title = "Guard Gallivant"
    public static let exampleInput: String? = """
        ....#.....
        .........#
        ..........
        ..#.......
        .......#..
        ..........
        .#..^.....
        ........#.
        #.........
        ......#...
        """

    let gpu: GPU
    let width: Int
    let height: Int
    /// 1 for obstacles ('#'), 0 for open floor.
    let blocked: [UInt8]
    /// The guard's initial state, `cell * 4 + direction` (direction indexes `Direction.four`).
    let startState: UInt32
    /// `jumps[direction * cells + cell]`: the last free cell of a straight run from `cell`, with
    /// `EXAMPLE02_EXIT_BIT` set if the run then leaves the map.
    let jumps: GPUBuffer<UInt32>
    private let search: any MTLComputePipelineState

    var cellCount: Int { width * height }
    var size: AoCGridSize { AoCGridSize(width: UInt32(width), height: UInt32(height)) }

    public init(input: Input, gpu: GPU) throws {
        self.gpu = gpu
        let grid = try input.grid()
        guard !grid.cells.isEmpty else { throw SolutionError.malformedInput("empty map") }
        width = grid.width
        height = grid.height

        let headings: [UInt8: UInt32] = [
            UInt8(ascii: ">"): 0, UInt8(ascii: "v"): 1, UInt8(ascii: "<"): 2, UInt8(ascii: "^"): 3,
        ]
        var start: UInt32?
        var blocked = [UInt8](repeating: 0, count: grid.count)
        for (cell, byte) in grid.cells.enumerated() {
            if byte == UInt8(ascii: "#") {
                blocked[cell] = 1
            } else if let heading = headings[byte] {
                guard start == nil else { throw SolutionError.malformedInput("more than one guard") }
                start = UInt32(cell) * 4 + heading
            } else if byte != UInt8(ascii: ".") {
                throw SolutionError.malformedInput("unexpected '\(Character(Unicode.Scalar(byte)))' in the map")
            }
        }
        guard let start else { throw SolutionError.malformedInput("no guard (^ > v <) on the map") }
        self.blocked = blocked
        startState = start
        jumps = gpu.buffer(Self.jumpTable(blocked: blocked, width: width, height: height), label: "jumps")
        search = try gpu.kernel("example02_search")
    }

    public func part1() throws -> String { "\(try walk().order.count)" }

    public func part2() throws -> String { "\(try searchLoops(walk()).total)" }

    /// Where a straight run from every cell in every direction stops. Built in one sweep per
    /// direction, visiting cells against that direction so each entry can copy its neighbour's.
    static func jumpTable(blocked: [UInt8], width: Int, height: Int) -> [UInt32] {
        let cells = width * height
        var table = [UInt32](repeating: 0, count: 4 * cells)
        for (direction, step) in Direction.four.enumerated() {
            let xs = step.x > 0 ? Array((0..<width).reversed()) : Array(0..<width)
            let ys = step.y > 0 ? Array((0..<height).reversed()) : Array(0..<height)
            for y in ys {
                for x in xs where blocked[y * width + x] == 0 {
                    let cell = y * width + x
                    let (nx, ny) = (x + step.x, y + step.y)
                    let entry: UInt32
                    if nx < 0 || ny < 0 || nx >= width || ny >= height {
                        entry = UInt32(cell) | EXAMPLE02_EXIT_BIT
                    } else if blocked[ny * width + nx] != 0 {
                        entry = UInt32(cell)
                    } else {
                        entry = table[direction * cells + ny * width + nx]
                    }
                    table[direction * cells + cell] = entry
                }
            }
        }
        return table
    }

    // MARK: Part 1: the walk

    /// The guard's original walk, one tick per move or turn.
    struct Walk {
        /// State after every tick; `ticks[0]` is the start, the last one is her final cell.
        var ticks: [UInt32]
        /// Tick at which each cell is first entered, or `EXAMPLE02_NONE`.
        var firstVisit: [UInt32]
        /// Visited cells in the order she first reaches them, the start first.
        var order: [UInt32]
    }

    func walk() throws -> Walk {
        var ticks = [startState]
        var firstVisit = [UInt32](repeating: EXAMPLE02_NONE, count: cellCount)
        var order = [startState >> 2]
        firstVisit[Int(startState >> 2)] = 0
        var state = startState
        while true {
            let cell = Int(state >> 2)
            let direction = Int(state & 3)
            let step = Direction.four[direction]
            let (x, y) = (cell % width + step.x, cell / width + step.y)
            guard x >= 0, y >= 0, x < width, y < height else { break }
            let next = y * width + x
            if blocked[next] != 0 {
                state = UInt32(cell * 4 + (direction + 1) % 4)
            } else {
                state = UInt32(next * 4 + direction)
                if firstVisit[next] == EXAMPLE02_NONE {
                    firstVisit[next] = UInt32(ticks.count)
                    order.append(UInt32(next))
                }
            }
            ticks.append(state)
            // More ticks than there are states means a state repeated: she never leaves.
            guard ticks.count <= 4 * cellCount + 1 else {
                throw SolutionError.malformedInput("the guard never leaves the map")
            }
        }
        return Walk(ticks: ticks, firstVisit: firstVisit, order: order)
    }

    // MARK: Part 2: loops

    /// GPU result of part 2, kept per candidate for the visualization.
    struct LoopSearch {
        /// Candidate cells, in the order the guard first reaches them.
        let candidates: [UInt32]
        /// State the guard is in just before stepping onto each candidate (facing it).
        let starts: [UInt32]
        /// 1 where the candidate traps the guard.
        let loops: GPUBuffer<UInt32>
        let total: Int
    }

    func searchLoops(_ walk: Walk) throws -> LoopSearch {
        let candidates = Array(walk.order.dropFirst())
        let starts = candidates.map { walk.ticks[Int(walk.firstVisit[Int($0)]) - 1] }
        let loops = gpu.buffer(count: candidates.count, of: UInt32.self, label: "loops")
        guard !candidates.isEmpty else { return LoopSearch(candidates: [], starts: [], loops: loops, total: 0) }

        let total = gpu.buffer(count: 1, of: UInt32.self, label: "total")
        let params = Example02Params(size: size, candidateCount: UInt32(candidates.count))
        try gpu.run("Example02 part 2") { encoder in
            encoder.dispatch(
                search, count: candidates.count,
                .buffer(jumps), .buffer(gpu.buffer(candidates, label: "candidates")),
                .buffer(gpu.buffer(starts, label: "starts")), .buffer(loops), .buffer(total), .value(params))
        }
        return LoopSearch(candidates: candidates, starts: starts, loops: loops, total: Int(total[0]))
    }
}

// MARK: - Visualization

extension Example02: Visualizable {
    public static func makeScene(input: Input, gpu: GPU) throws -> any VisualizationScene {
        try Example02Scene(solution: Example02(input: input, gpu: gpu))
    }
}

/// A 2.5D arcade take on the guard's patrol, with the camera following her.
///
/// Part 1, one timeline step per tick: she walks the map leaving a glowing trail (horizontal and
/// vertical bars, so crossings and corners read as "+" like the puzzle's drawings). The score is
/// the number of distinct tiles visited. Stepping onto an already visited tile scores nothing:
/// the tile flashes, a shockwave ripples out and the score shakes and greys out.
///
/// Part 2, one step per candidate obstruction, in the order she reaches them: she walks up to the
/// cell, a crate drops onto it, and a ghost guard runs the altered route. If the ghost gets stuck
/// in a loop, the loop lights up magenta, the crate stays as a magenta marker and the score (loops
/// found) pops; otherwise the ghost walks off the map and the crate sinks.
///
/// Phases are listed in Example02.metal.
@MainActor
final class Example02Scene: VisualizationScene {
    /// Camera pitch; the score is drawn facing it. Must match `kPitch` in Example02.metal.
    nonisolated static let pitch: Float = 1.05
    /// Ticks a ripple lives. Must match `kRippleLife` in Example02.metal.
    nonisolated static let rippleLife = 8.0

    let instances: GPUBuffer<AoCInstance>
    let bounds: SceneBounds
    var instanceCount: Int { instances.count }
    var stepCount: Int { walk.ticks.count }
    var preferredView: CameraView { CameraView(yaw: 0, pitch: Self.pitch, distanceScale: 0.8) }

    private let solution: Example02
    private let walk: Example02.Walk
    private let loopSearch: Example02.LoopSearch
    private let timeline: Example02Timeline

    private let blocked: GPUBuffer<UInt8>
    private let firstHorizontal: GPUBuffer<UInt32>
    private let firstVertical: GPUBuffer<UInt32>
    private let candidateOf: GPUBuffer<UInt32>
    private let route: GPUBuffer<Example02Route>
    private let segments: GPUBuffer<Example02Segment>
    private let seen: GPUBuffer<SIMD2<UInt32>>
    private let drawPipeline: any MTLComputePipelineState
    private let routePipeline: any MTLComputePipelineState
    private var stamp: UInt32 = 0

    /// Score placement relative to the guard: up the screen by `scoreOffset`, voxels `scoreVoxel`.
    private let scoreOffset: Float
    private let scoreVoxel: Float

    nonisolated init(solution: Example02) throws {
        self.solution = solution
        let gpu = solution.gpu
        walk = try solution.walk()
        loopSearch = try solution.searchLoops(walk)
        timeline = Example02Timeline(walk: walk, loops: loopSearch, width: solution.width)

        let cells = solution.cellCount
        blocked = gpu.buffer(solution.blocked, label: "blocked")
        firstHorizontal = gpu.buffer(timeline.firstHorizontal, label: "firstHorizontal")
        firstVertical = gpu.buffer(timeline.firstVertical, label: "firstVertical")
        var candidateOf = [UInt32](repeating: EXAMPLE02_NONE, count: cells)
        for (index, cell) in loopSearch.candidates.enumerated() { candidateOf[Int(cell)] = UInt32(index) }
        self.candidateOf = gpu.buffer(candidateOf, label: "candidateOf")
        route = gpu.buffer(count: 1, of: Example02Route.self, label: "route")
        segments = gpu.buffer(count: Int(EXAMPLE02_MAX_SEGMENTS), of: Example02Segment.self, label: "segments")
        seen = gpu.buffer(count: 4 * cells, of: SIMD2<UInt32>.self, label: "seen")
        drawPipeline = try gpu.kernel("example02_instances")
        routePipeline = try gpu.kernel("example02_route")

        let slotCount =
            3 * cells + Int(EXAMPLE02_MAX_SEGMENTS) + Int(EXAMPLE02_ACTOR_SLOTS)
            + Int(EXAMPLE02_RIPPLES * EXAMPLE02_RIPPLE_CUBES)
            + Int(EXAMPLE02_SCORE_DIGITS * EXAMPLE02_GLYPH_PIXELS)
        instances = gpu.buffer(count: slotCount, of: AoCInstance.self, label: "instances")

        // Frame a window around the guard (the camera then follows her), not the whole map.
        let span = Float(min(max(solution.width, solution.height), 24))
        let start = Self.world(Int(solution.startState >> 2), width: solution.width, height: solution.height)
        bounds = SceneBounds(
            min: start - SIMD3(span / 2, 0, span / 2), max: start + SIMD3(span / 2, 2, span / 2))

        // Put the score near the top of the initial view, at a size that reads at that distance.
        let fieldOfView = Float.pi / 4
        let distance = max(bounds.radius / sin(fieldOfView / 2), 1) * 1.05 * 0.8
        let halfHeight = distance * tan(fieldOfView / 2)
        scoreOffset = halfHeight * 0.66
        scoreVoxel = halfHeight * 0.04
    }

    func stepCount(part: Int) -> Int { part == 2 ? max(loopSearch.candidates.count, 1) : walk.ticks.count }

    func preferredStepsPerSecond(part: Int) -> Double {
        part == 2 ? (loopSearch.candidates.count <= 60 ? 0.6 : 3) : (walk.ticks.count <= 200 ? 6 : 15)
    }

    func cameraFocus(step: Int, progress: Float, part: Int) -> SIMD3<Float>? {
        guardPose(at: guardTime(step: step, progress: progress, part: part)).position * SIMD3(1, 0, 1)
    }

    func update(_ frame: FrameContext) throws {
        var params = makeParams(step: frame.step, progress: frame.progress, part: frame.part)
        let candidate = Int(params.candidate)
        try frame.gpu.encode(into: frame.commandBuffer) { encoder in
            if frame.part == 2, candidate < loopSearch.candidates.count {
                stamp = stamp == .max ? 1 : stamp + 1
                let routeParams = Example02RouteParams(
                    size: solution.size, startState: loopSearch.starts[candidate],
                    extra: loopSearch.candidates[candidate], stamp: stamp)
                encoder.dispatch(
                    routePipeline, count: 1,
                    .buffer(solution.jumps), .buffer(seen), .buffer(route), .buffer(segments), .value(routeParams))
                encoder.barrier()
            } else {
                params.candidateCell = EXAMPLE02_NONE
            }
            encoder.dispatch(
                drawPipeline, count: instances.count,
                .buffer(blocked), .buffer(firstHorizontal), .buffer(firstVertical), .buffer(candidateOf),
                .buffer(loopSearch.loops), .buffer(route), .buffer(segments), .buffer(instances), .value(params))
        }
    }

    func caption(step: Int, part: Int) -> String {
        part == 2 ? partTwoCaption(candidate: step) : partOneCaption(tick: step)
    }

    // MARK: Frame parameters

    private func makeParams(step: Int, progress: Float, part: Int) -> Example02VizParams {
        var params = Example02VizParams()
        params.size = solution.size
        params.part = UInt32(part)
        let time = guardTime(step: step, progress: progress, part: part)
        params.time = Float(time)
        let pose = guardPose(at: time)
        params.guardPosition = pose.position
        params.guardDirection = pose.direction
        let up = SIMD3<Float>(0, cos(Self.pitch), -sin(Self.pitch))
        params.scoreAnchor = pose.position * SIMD3(1, 0, 1) + up * scoreOffset
        params.scoreVoxel = scoreVoxel
        params.bumpCell = EXAMPLE02_NONE
        params.candidateCell = EXAMPLE02_NONE
        let never: Float = 1e6
        params.sinceIncrement = never
        params.sinceRevisit = never
        params.sinceMilestone = never
        var ripples: [(cell: UInt32, age: Float)] = []

        if part == 2 {
            let candidate = min(step, max(loopSearch.candidates.count - 1, 0))
            params.candidate = UInt32(candidate)
            params.progress = progress
            guard candidate < loopSearch.candidates.count else { return params }
            params.candidateCell = loopSearch.candidates[candidate]
            let loops = loopSearch.loops[candidate] != 0
            params.candidateLoops = loops ? 1 : 0
            let verdict = loops && progress >= 0.8
            params.score = UInt32(timeline.loopsBefore[candidate] + (verdict ? 1 : 0))
            if verdict {
                let age = (progress - 0.8) * 40  // the 0.8...1 verdict phase spans one ripple life
                params.sinceIncrement = age
                params.sinceMilestone = age
                ripples.append((params.candidateCell, age))
            }
        } else {
            let event = timeline.events(at: time)
            params.score = event.score
            params.sinceIncrement = event.sinceIncrement
            params.sinceRevisit = event.sinceRevisit
            params.sinceMilestone = event.sinceMilestone
            if let bump = event.bump {
                params.bumpCell = bump.cell
                params.bumpAge = bump.age
            }
            ripples = event.ripples
        }

        withUnsafeMutableBytes(of: &params.rippleCell) { raw in
            let cells = raw.bindMemory(to: UInt32.self)
            for index in cells.indices { cells[index] = index < ripples.count ? ripples[index].cell : EXAMPLE02_NONE }
        }
        withUnsafeMutableBytes(of: &params.rippleAge) { raw in
            let ages = raw.bindMemory(to: Float.self)
            for index in ages.indices { ages[index] = index < ripples.count ? ripples[index].age : never }
        }
        return params
    }

    /// Where the guard is on her original walk, in ticks. In part 2 she walks from one candidate's
    /// start to the next during the first 15 % of a step.
    private func guardTime(step: Int, progress: Float, part: Int) -> Double {
        guard part == 2 else { return Double(step) + Double(progress) }
        let starts = timeline.candidateStartTicks
        guard !starts.isEmpty else { return 0 }
        let candidate = min(step, starts.count - 1)
        let from = Double(candidate > 0 ? starts[candidate - 1] : 0)
        let to = Double(starts[candidate])
        let t = Double(min(max(progress / 0.15, 0), 1))
        return from + (to - from) * t * t * (3 - 2 * t)
    }

    /// Guard position (with a small hop per step) and facing at `time` ticks into her walk.
    private func guardPose(at time: Double) -> (position: SIMD3<Float>, direction: UInt32) {
        let ticks = walk.ticks
        let index = min(max(Int(time.rounded(.down)), 0), ticks.count - 1)
        let fraction = Float(min(max(time - Double(index), 0), 1))
        let current = ticks[index]
        let from = world(Int(current >> 2))
        let to: SIMD3<Float>
        let nextDirection: UInt32
        if index + 1 < ticks.count {
            to = world(Int(ticks[index + 1] >> 2))
            nextDirection = ticks[index + 1] & 3
        } else {  // the last tick: she walks off the map
            let step = Direction.four[Int(current & 3)]
            to = from + SIMD3(Float(step.x), 0, Float(step.y))
            nextDirection = current & 3
        }
        var position = from + (to - from) * fraction
        if to != from { position.y = 0.15 * sin(.pi * fraction) }
        return (position, fraction < 0.5 ? current & 3 : nextDirection)
    }

    // MARK: Captions

    private func partOneCaption(tick: Int) -> String {
        let ticks = walk.ticks
        guard tick < ticks.count else { return "" }
        let state = ticks[tick]
        let (x, y) = (Int(state >> 2) % solution.width, Int(state >> 2) / solution.width)
        let arrow = ["→", "↓", "←", "↑"][Int(state & 3)]
        var text = "Tick \(tick + 1)/\(ticks.count)   guard at (\(x), \(y)) facing \(arrow)"
        text += "   ·   score \(timeline.scoreAt[tick])/\(walk.order.count)"
        if timeline.streakAt[tick] > 0 {
            text += "   ·   already visited, no points (×\(timeline.streakAt[tick]))"
        }
        if tick == ticks.count - 1 { text += "   ·   walks off the map" }
        return text
    }

    private func partTwoCaption(candidate: Int) -> String {
        guard candidate < loopSearch.candidates.count else { return "No cells to obstruct" }
        let cell = Int(loopSearch.candidates[candidate])
        let loops = loopSearch.loops[candidate] != 0
        return "Obstruction \(candidate + 1)/\(loopSearch.candidates.count) at "
            + "(\(cell % solution.width), \(cell / solution.width))   ·   "
            + (loops ? "the guard is stuck in a loop!" : "the guard still escapes")
            + "   ·   loops found \(timeline.loopsBefore[candidate] + (loops ? 1 : 0))/\(loopSearch.total)"
    }

    // MARK: Geometry

    private func world(_ cell: Int) -> SIMD3<Float> {
        Self.world(cell, width: solution.width, height: solution.height)
    }

    /// Centre of `cell` in world units: the map is centred on the origin, rows run towards +z.
    nonisolated static func world(_ cell: Int, width: Int, height: Int) -> SIMD3<Float> {
        SIMD3(
            Float(cell % width) - Float(width) / 2 + 0.5, 0,
            Float(cell / width) - Float(height) / 2 + 0.5)
    }
}

/// Per-tick bookkeeping for the part 1 effects (score, revisits, bumps), precomputed once so a
/// frame anywhere on the timeline is a few binary searches.
struct Example02Timeline {
    /// Tick each cell is first crossed horizontally / vertically (trail bars), or EXAMPLE02_NONE.
    var firstHorizontal: [UInt32]
    var firstVertical: [UInt32]
    /// Distinct tiles visited after each tick.
    var scoreAt: [UInt32] = []
    /// Tick of the latest score increase at or before each tick.
    var lastIncrease: [Int] = []
    /// Consecutive moves onto already visited tiles ending at each tick (0 if this tick scored or
    /// was not a move).
    var streakAt: [Int] = []
    /// Moves onto an already visited tile, and the tile.
    var revisits: [Int] = []
    var revisitCells: [UInt32] = []
    /// Ticks where the score reached a multiple of 100.
    var milestones: [Int] = []
    /// Turn ticks and the obstacle the guard turned at.
    var turns: [Int] = []
    var turnObstacles: [UInt32] = []
    /// Part 2: tick at which the guard stands just before each candidate, and loops found before it.
    var candidateStartTicks: [Int]
    var loopsBefore: [Int]

    init(walk: Example02.Walk, loops: Example02.LoopSearch, width: Int) {
        let cells = walk.firstVisit.count
        firstHorizontal = [UInt32](repeating: EXAMPLE02_NONE, count: cells)
        firstVertical = firstHorizontal
        var score: UInt32 = 0
        for (tick, state) in walk.ticks.enumerated() {
            let cell = Int(state >> 2)
            if state & 1 == 0 {
                if firstHorizontal[cell] == EXAMPLE02_NONE { firstHorizontal[cell] = UInt32(tick) }
            } else if firstVertical[cell] == EXAMPLE02_NONE {
                firstVertical[cell] = UInt32(tick)
            }

            let previous = tick > 0 ? walk.ticks[tick - 1] : state
            let moved = tick > 0 && previous >> 2 != state >> 2
            if walk.firstVisit[cell] == UInt32(tick) {
                score += 1
                if score.isMultiple(of: 100) { milestones.append(tick) }
            }
            scoreAt.append(score)
            lastIncrease.append(walk.firstVisit[cell] == UInt32(tick) ? tick : lastIncrease.last ?? 0)
            if moved, walk.firstVisit[cell] < UInt32(tick) {
                revisits.append(tick)
                revisitCells.append(UInt32(cell))
                streakAt.append((streakAt.last ?? 0) + 1)
            } else {
                streakAt.append(moved ? 0 : (streakAt.last ?? 0))
            }
            if tick > 0, !moved {
                let step = Direction.four[Int(previous & 3)]
                let from = Int(previous >> 2)
                turns.append(tick)
                turnObstacles.append(UInt32(from + step.y * width + step.x))
            }
        }
        candidateStartTicks = loops.candidates.map { Int(walk.firstVisit[Int($0)]) - 1 }
        var found = 0
        loopsBefore = (0..<loops.candidates.count).map { index in
            defer { found += Int(loops.loops[index]) }
            return found
        }
    }

    /// What is going on at `time` ticks into part 1.
    struct Events {
        var score: UInt32
        var sinceIncrement: Float
        var sinceRevisit: Float
        var sinceMilestone: Float
        var bump: (cell: UInt32, age: Float)?
        var ripples: [(cell: UInt32, age: Float)]
    }

    /// Events are dated half a tick before their tick: that is when the guard crosses into the cell.
    func events(at time: Double) -> Events {
        let tick = min(max(Int((time + 0.5).rounded(.down)), 0), scoreAt.count - 1)
        let since = { (eventTick: Int) in Float(time - (Double(eventTick) - 0.5)) }
        var events = Events(
            score: scoreAt[tick], sinceIncrement: since(lastIncrease[tick]), sinceRevisit: 1e6,
            sinceMilestone: 1e6, bump: nil, ripples: [])

        var index = Self.lastIndex(in: revisits, atMost: time + 0.5)
        if let latest = index { events.sinceRevisit = since(revisits[latest]) }
        while let current = index, events.ripples.count < Int(EXAMPLE02_RIPPLES) {
            let age = since(revisits[current])
            guard Double(age) < Example02Scene.rippleLife else { break }
            events.ripples.append((revisitCells[current], age))
            index = current > 0 ? current - 1 : nil
        }
        if let latest = Self.lastIndex(in: milestones, atMost: time + 0.5) {
            events.sinceMilestone = since(milestones[latest])
        }
        // A bump starts when the turn tick starts animating, a whole tick before the turn.
        if let latest = Self.lastIndex(in: turns, atMost: time + 1) {
            events.bump = (turnObstacles[latest], Float(time - Double(turns[latest] - 1)))
        }
        return events
    }

    /// Index of the last element `<= limit` in sorted `array`.
    static func lastIndex(in array: [Int], atMost limit: Double) -> Int? {
        var low = 0
        var high = array.count
        while low < high {
            let mid = (low + high) / 2
            if Double(array[mid]) <= limit { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }
}
