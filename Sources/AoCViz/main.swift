import AoCKit
import AoCRender
import AppKit
import Foundation
import ImageIO
import Solutions
import SwiftUI
import UniformTypeIdentifiers

/// Visualizer entry point.
///
///     swift run aoc2026-viz [puzzle] [--example]      open the window (optionally preselecting e.g. e1;
///                                                     --example starts on the puzzle's example input)
///     swift run aoc2026-viz --snapshot e1 [options]   render one frame offscreen to a PNG and exit
///         --at <position>   timeline position in steps, e.g. 3.45 = line 4 at 45 % (default 0.5)
///         --part <1|2>      default 1
///         --size <WxH>      default 1600x900
///         --out <file.png>  default snapshot.png
///         --input <file>    use this input instead of input/<year>/dayNN.txt
///         --example         use the puzzle's worked example as input
struct AoCVizApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel(
        initialSelection: CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") },
        example: CommandLine.arguments.contains("--example"))

    var body: some Scene {
        WindowGroup("Advent of Code — Metal") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1400, height: 900)
    }
}

/// A bare SwiftPM executable is not an .app bundle, so AppKit does not give it a regular
/// activation policy. Set it in `willFinishLaunching`: by `didFinishLaunching` SwiftUI has already
/// skipped opening the WindowGroup, leaving a process with a menu bar and no window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
}

@MainActor
func snapshot(_ arguments: [String]) async throws {
    var puzzle: String?
    var position = 0.5
    var part = 1
    var size = (1600, 900)
    var out = "snapshot.png"
    var inputFile: String?
    var example = false
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--at": position = Double(iterator.next() ?? "") ?? position
        case "--part": part = Int(iterator.next() ?? "") ?? part
        case "--out": out = iterator.next() ?? out
        case "--input": inputFile = iterator.next()
        case "--example": example = true
        case "--size":
            let parts = (iterator.next() ?? "").split(separator: "x").compactMap { Int($0) }
            if parts.count == 2 { size = (parts[0], parts[1]) }
        default: puzzle = argument
        }
    }
    guard let name = puzzle, let type = Registry.solution(named: name) else {
        throw SolutionError.malformedInput(
            "usage: aoc2026-viz --snapshot <puzzle> [--at N] [--part N] [--example] [--out f.png]")
    }
    guard let visual = type as? any Visualizable.Type else {
        throw SolutionError.malformedInput("\(type.id) is not Visualizable")
    }

    let gpu = GPU.shared
    let store = InputStore()
    let input: Input
    if example {
        guard let text = type.exampleInput else {
            throw SolutionError.malformedInput("\(type.id) has no example input")
        }
        input = Input(text)
    } else if let inputFile {
        input = try store.load(file: inputFile)
    } else {
        input = try await store.load(type.id)
    }
    let renderer = try Renderer(gpu: gpu)
    let scene = try visual.makeScene(input: input, gpu: gpu)
    renderer.scene = scene
    renderer.playback.part = part
    renderer.playback.reset(for: scene)
    renderer.playback.isPlaying = false
    renderer.playback.position = position

    try writePNG(try renderer.snapshot(width: size.0, height: size.1), to: out)
    print("\(out): \(scene.caption(step: renderer.playback.step, part: part))")
}

/// Writes `cgImage` as a PNG to `path`.
func writePNG(_ cgImage: CGImage, to path: String) throws {
    let url = URL(filePath: path) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        throw SolutionError.malformedInput("cannot write \(path)")
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { throw SolutionError.malformedInput("cannot write \(path)") }
}

// Keep this top-level code synchronous: a top-level `await` turns it into an async main, and
// SwiftUI's App.main() then never connects to the window server.
let arguments = Array(CommandLine.arguments.dropFirst())
if let index = arguments.firstIndex(of: "--snapshot") {
    var rest = arguments
    rest.remove(at: index)
    Task { @MainActor in
        do {
            try await snapshot(rest)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}
// AppKit treats bare arguments ("e1") as files to open; that "open" fails silently and SwiftUI
// then skips the default WindowGroup window, leaving a running app with no window at all.
UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
AoCVizApp.main()
