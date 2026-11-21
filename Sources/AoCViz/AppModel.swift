import AoCKit
import AoCRender
import Foundation
import Observation
import Solutions

/// Visualizer state: which puzzle is selected, its answers, and the scene being shown.
@MainActor @Observable
final class AppModel {
    struct PuzzleState {
        var report: SolveReport?
        var isSolving = false
        var error: String?
    }

    let gpu = GPU.shared
    let store = InputStore()
    let renderer: Renderer?
    let rendererError: String?

    /// Which input to visualize: the puzzle's worked example or the real (downloaded) input.
    enum InputSource: Hashable {
        case example, puzzle
    }

    private(set) var states: [PuzzleID: PuzzleState] = [:]
    /// Per puzzle, so switching puzzles keeps each one's choice.
    private var sources: [PuzzleID: InputSource] = [:]
    /// Source used when a puzzle has no choice yet (`--example` on the command line).
    private let defaultSource: InputSource
    private(set) var sceneError: String?
    private(set) var hasScene = false
    var selection: PuzzleID? {
        didSet { if selection != oldValue { Task { await load() } } }
    }

    var playback: Playback { renderer?.playback ?? fallbackPlayback }
    private let fallbackPlayback = Playback()

    init(initialSelection: String?, example: Bool = false) {
        defaultSource = example ? .example : .puzzle
        do {
            renderer = try Renderer(gpu: gpu)
            rendererError = nil
        } catch {
            renderer = nil
            rendererError = "Renderer unavailable: \(error)"
        }
        let initial = initialSelection.flatMap(Registry.solution(named:)) ?? Registry.all.first
        selection = initial?.id
        Task { await load() }
    }

    var selectedType: (any Solution.Type)? {
        Registry.all.first { $0.id == selection }
    }

    func state(for id: PuzzleID) -> PuzzleState { states[id] ?? PuzzleState() }

    /// The input source in effect for `type`: the example only if the solution has one.
    func source(for type: any Solution.Type) -> InputSource {
        type.exampleInput == nil ? .puzzle : sources[type.id] ?? defaultSource
    }

    func setSource(_ source: InputSource, for type: any Solution.Type) {
        guard source != self.source(for: type) else { return }
        sources[type.id] = source
        states[type.id] = nil
        Task { await load() }
    }

    func caption() -> String {
        guard let scene = renderer?.scene else { return "" }
        return scene.caption(step: playback.step, part: playback.part)
    }

    /// Loads input (downloading if needed), builds the scene and solves both parts.
    func load(refresh: Bool = false) async {
        guard let type = selectedType else { return }
        let id = type.id
        states[id, default: PuzzleState()].isSolving = true
        states[id, default: PuzzleState()].error = nil
        sceneError = nil

        let input: Input
        do {
            if source(for: type) == .example, let example = type.exampleInput {
                input = Input(example)
            } else {
                input = try await store.load(id, refresh: refresh)
            }
        } catch {
            states[id, default: PuzzleState()].isSolving = false
            states[id, default: PuzzleState()].error = "Input: \(error)"
            clearScene()
            return
        }
        guard selection == id else { return }

        buildScene(type, input: input)

        let gpu = gpu
        let result = await Task.detached { () -> Result<SolveReport, SolveFailure> in
            Result { try Runner.solve(type, input: input, gpu: gpu) }.mapError(SolveFailure.init)
        }.value
        switch result {
        case .success(let report): states[id, default: PuzzleState()].report = report
        case .failure(let error): states[id, default: PuzzleState()].error = error.description
        }
        states[id, default: PuzzleState()].isSolving = false
    }

    private func buildScene(_ type: any Solution.Type, input: Input) {
        guard let renderer else { return }
        guard let visual = type as? any Visualizable.Type else {
            sceneError = "\(type.id) has no visualization yet (conform it to Visualizable)."
            clearScene()
            return
        }
        do {
            let scene = try visual.makeScene(input: input, gpu: gpu)
            renderer.scene = scene
            renderer.onError = { [weak self] error in self?.sceneError = "\(error)" }
            renderer.playback.reset(for: scene)
            hasScene = true
        } catch {
            sceneError = "Scene: \(error)"
            clearScene()
        }
    }

    private func clearScene() {
        renderer?.scene = nil
        renderer?.playback.reset(stepCount: 0, stepsPerSecond: 1)
        renderer?.playback.isPlaying = false
        hasScene = false
    }
}
