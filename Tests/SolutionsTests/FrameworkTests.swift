import AoCKit
import AoCRender
import AoCShared
import CoreGraphics
import Foundation
import Solutions
import Testing

@Suite("Framework helpers")
struct FrameworkTests {
    @Test func integersHandleSignsAndRanges() {
        #expect(Parse.integers(in: "x=-5, y=12") == [-5, 12])
        #expect(Parse.integers(in: "3-4 10-20") == [3, 4, 10, 20])
        #expect(Parse.integers(in: "a-1", signed: false) == [1])
        #expect(Parse.integers(in: "\(Int.min) \(Int.max)") == [Int.min, Int.max])
        #expect(" \r\n 42 \t\r\n".trimmingWhitespace() == "42")
    }

    @Test func linesDropTrailingNewlineButKeepBlankSeparators() {
        let input = Input("a\nb\n\nc\n")
        #expect(input.lines == ["a", "b", "", "c"])
        #expect(input.paragraphs == [["a", "b"], ["c"]])
    }

    @Test func windowsLineEndingsAreNormalised() throws {
        let input = Input("ab\r\ncd\r\n\r\nef\r\n")
        #expect(input.text == "ab\ncd\n\nef\n")
        #expect(input.lines == ["ab", "cd", "", "ef"])
        #expect(input.paragraphs == [["ab", "cd"], ["ef"]])
        #expect(try Input("ab\r\ncd\r\n").grid().text == "ab\ncd")
        #expect(Input("old\rmac\r").lines == ["oldmac"])
    }

    @Test func gridRejectsRaggedLines() {
        #expect(throws: SolutionError.self) { try Input("ab\nc\n").grid() }
        let grid = try? Input("ab\ncd\n").grid()
        #expect(grid?.text == "ab\ncd")
        #expect(grid?[1, 1] == UInt8(ascii: "d"))
    }

    @Test func registryResolvesCLINames() {
        #expect(Registry.solution(named: "e1")?.id == Example01.id)
        #expect(Registry.solution(named: "example1")?.id == Example01.id)
        #expect(Registry.solution(named: "E01")?.id == Example01.id)
        #expect(Registry.solution(named: "1") == nil || Registry.solution(named: "1")?.id.kind == .day)
        for junk in ["part2", "x1", "p2", "e", "day", "", "1x", "e-1", "e١"] {
            #expect(Registry.solution(named: junk) == nil, "'\(junk)'")
        }
    }

    @Test func sessionCookieMustComeFromAdventOfCode() {
        for domain in ["adventofcode.com", ".adventofcode.com", "www.adventofcode.com", "AdventOfCode.com"] {
            #expect(AoCClient.isAoCCookieDomain(domain), "\(domain)")
        }
        for domain in ["notadventofcode.com", ".evil-adventofcode.com", "adventofcode.com.evil.io", ""] {
            #expect(!AoCClient.isAoCCookieDomain(domain), "\(domain)")
        }
    }

    @Test func registryIDsAreUnique() {
        let ids = Registry.all.map { $0.id }
        #expect(Set(ids).count == ids.count)
    }

    @Test func unlockDateIsMidnightUSEastern() {
        // December 1, 2026 00:00:00 EST (UTC-5) == 2026-12-01T05:00:00Z.
        let unlock = AoCClient.unlockDate(day: 1, year: 2026)
        let utc = Calendar(identifier: .gregorian)
        let components = utc.dateComponents(
            in: TimeZone(secondsFromGMT: 0)!, from: unlock)
        #expect(components.year == 2026)
        #expect(components.month == 12)
        #expect(components.day == 1)
        #expect(components.hour == 5)
        #expect(components.minute == 0)
    }

    @Test @MainActor func playbackUpdatesSpeedEvenWhenStepCountsMatch() {
        final class DummyScene: VisualizationScene {
            let instances = GPU.shared.buffer(count: 1, of: AoCInstance.self)
            let instanceCount = 0
            let bounds = SceneBounds(min: .zero, max: SIMD3(1, 1, 1))
            let stepCount = 10
            func preferredStepsPerSecond(part: Int) -> Double { part == 2 ? 4 : 1 }
            func update(_: FrameContext) throws {}
        }
        guard GPU.isAvailable else { return }
        let playback = Playback()
        playback.reset(for: DummyScene())
        #expect(playback.stepsPerSecond == 1)
        playback.position = 3.5
        playback.part = 2
        #expect(playback.stepsPerSecond == 4)
        #expect(playback.position == 3.5)
    }
}

@Suite("Framework GPU & rendering", .requiresGPU)
struct FrameworkGPUTests {
    @Test func runnerAndBenchmarkWorkOnExample() throws {
        let input = Input(try #require(Example01.exampleInput))
        let report = try Runner.solve(Example01.self, input: input, gpu: .shared, stableBelow: .milliseconds(5))
        #expect(try report.part2.answer.get() == "281")

        var options = Benchmark.Options()
        options.budget = .milliseconds(5)
        options.minIterations = 2
        let result = try Benchmark.run(Example01.self, input: input, gpu: .shared, options: options)
        #expect(result.part1.iterations >= 2)
        #expect(result.part2.iterations >= 2)
    }

    @Test @MainActor func rendererSnapshotsScenesIncludingEmptyInput() throws {
        let renderer = try Renderer(gpu: .shared)
        for type in [Example01.self, Example02.self, Example03.self] as [any Visualizable.Type] {
            let example = type.exampleInput
            let input = Input(try #require(example))
            let scene = try type.makeScene(input: input, gpu: .shared)
            renderer.scene = scene
            renderer.playback.reset(for: scene)
            let image = try renderer.snapshot(width: 160, height: 90)
            #expect(image.width == 160)
            #expect(image.height == 90)
        }
        // Example 1 must not crash when rendering an empty input.
        let emptyScene = try Example01.makeScene(input: Input(""), gpu: .shared)
        renderer.scene = emptyScene
        renderer.playback.reset(for: emptyScene)
        let image = try renderer.snapshot(width: 160, height: 90)
        #expect(image.width == 160)
    }
}
