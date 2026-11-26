import AoCKit
import AoCRender
import AppKit
import Solutions
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if let type = model.selectedType {
                PuzzleDetail(model: model, type: type)
            } else {
                ContentUnavailableView("No puzzle selected", systemImage: "star")
            }
        }
    }
}

private struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            let days = Registry.entries.filter { $0.id.kind == .day }
            let examples = Registry.entries.filter { $0.id.kind == .example }
            Section("Advent of Code \(String(AoCClient.year))") {
                if days.isEmpty {
                    Text("No days yet — run scripts/new-day.sh 1").foregroundStyle(.secondary)
                }
                ForEach(days) { row($0.type) }
            }
            Section("Examples") {
                ForEach(examples) { row($0.type) }
            }
        }
    }

    private func row(_ type: any Solution.Type) -> some View {
        let state = model.state(for: type.id)
        return HStack {
            VStack(alignment: .leading) {
                Text(type.id.description).font(.headline)
                Text(type.title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state.isSolving {
                ProgressView().controlSize(.small)
            } else if state.error != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if state.report != nil {
                Image(systemName: "star.fill").foregroundStyle(.yellow)
            }
        }
        .tag(type.id)
    }
}

private struct PuzzleDetail: View {
    @Bindable var model: AppModel
    let type: any Solution.Type

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let renderer = model.renderer {
                    MetalSceneView(renderer: renderer)
                } else {
                    Color.black
                }
                AnswerPanel(type: type, state: model.state(for: type.id))
                    .padding(12)
                if let message = model.sceneError ?? model.rendererError {
                    Text(message)
                        .padding(8)
                        .background(.red.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding()
                }
            }
            if model.hasScene {
                TimelineBar(model: model, playback: model.playback)
            }
        }
        .sheet(isPresented: $model.isShowingPuzzleBrowser) {
            if let url = URL(string: type.id.url) { PuzzleBrowser(url: url, model: model) }
        }
        .navigationTitle("\(type.id.description) — \(type.title)")
        .navigationSubtitle(type.id.source)
        .toolbar {
            ToolbarItemGroup {
                if type.exampleInput != nil {
                    Picker(
                        "Input",
                        selection: Binding(
                            get: { model.source(for: type) }, set: { model.setSource($0, for: type) })
                    ) {
                        Text("Example").tag(AppModel.InputSource.example)
                        Text("Puzzle input").tag(AppModel.InputSource.puzzle)
                    }
                    .pickerStyle(.segmented)
                    .help("Visualize the puzzle's worked example or your real input")
                }
                Button("Reset View", systemImage: "scope") { model.renderer?.resetCamera() }
                Button("Re-download Input", systemImage: "arrow.down.circle") {
                    Task { await model.load(refresh: true) }
                }
                .help("Download this puzzle's input from adventofcode.com again (needs login or AOC_SESSION)")
                .disabled(model.source(for: type) == .example)
                Button("Puzzle", systemImage: "safari") { model.isShowingPuzzleBrowser = true }
                    .help("Open the puzzle page. Log in there and the app downloads all missing inputs.")
            }
        }
    }
}

private struct AnswerPanel: View {
    let type: any Solution.Type
    let state: AppModel.PuzzleState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let report = state.report {
                answer("Part 1", report.part1)
                answer("Part 2", report.part2)
                Text("parse \(report.parse.pretty)" + (report.runs > 1 ? " · fastest of ≥ \(report.runs) runs" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                    .help(
                        report.runs > 1
                            ? "Fast solve: each phase was re-run warm for ~100 ms; the fastest run is shown"
                            : "Single cold run (the solve took over 100 ms)")
            } else if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Solving…")
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func answer(_ label: String, _ part: SolveReport.Part) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            switch part.answer {
            case .success(let value):
                Text(value).font(.title3.monospacedDigit().bold()).textSelection(.enabled)
            case .failure(let error):
                Text(error.description).foregroundStyle(.orange)
            }
            Text(part.elapsed.pretty).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct TimelineBar: View {
    let model: AppModel
    @Bindable var playback: Playback

    /// The slider ←/→ adjust: whichever was focused (Tab) or touched last; timeline by default.
    private enum ArrowTarget { case timeline, speed }
    @State private var arrowTarget = ArrowTarget.timeline
    @FocusState private var focusedSlider: ArrowTarget?
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.caption())
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 12) {
                Picker("Part", selection: $playback.part) {
                    Text("Part 1").tag(1)
                    Text("Part 2").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)

                // Space is handled by the key monitor below, so it works whatever has focus.
                Button(action: togglePlay) {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
                }
                .help("Play / pause (Space)")

                Button("Previous step", systemImage: "backward.frame.fill") {
                    playback.position = max(0, Double(playback.step - 1))
                }
                .labelStyle(.iconOnly)
                Button("Next step", systemImage: "forward.frame.fill") {
                    playback.position = min(Double(playback.stepCount) - 0.0001, Double(playback.step + 1))
                }
                .labelStyle(.iconOnly)

                Slider(value: $playback.position, in: 0...Double(max(playback.stepCount, 1))) { editing in
                    if editing { arrowTarget = .timeline }
                }
                .tint(arrowTarget == .timeline ? .accentColor : .secondary)
                .help("← / → one step, ⇧ ten steps")
                // `.edit` puts the slider in the Tab loop like a text field, even with macOS
                // "Keyboard navigation" off (plain controls are skipped then).
                .focusable(interactions: .edit)
                .focused($focusedSlider, equals: .timeline)
                Text("\(min(playback.step + 1, playback.stepCount))/\(playback.stepCount)")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 70, alignment: .trailing)

                Image(systemName: "tortoise").foregroundStyle(.secondary)
                Slider(value: speedExponent, in: Self.speedRange) { editing in
                    if editing { arrowTarget = .speed }
                }
                .tint(arrowTarget == .speed ? .accentColor : .secondary)
                .help("← / → ×1.26 speed, ⇧ ×10")
                .focusable(interactions: .edit)
                .focused($focusedSlider, equals: .speed)
                .frame(width: 110)
                Image(systemName: "hare").foregroundStyle(.secondary)
                Text(String(format: "%.2g/s", playback.stepsPerSecond))
                    .font(.caption.monospacedDigit())
                    .frame(width: 48, alignment: .leading)
            }
        }
        .padding(10)
        .background(.bar)
        .onChange(of: focusedSlider) { _, focused in
            if let focused { arrowTarget = focused }
        }
        .onAppear {
            // A local monitor sees Space and the arrows whatever has focus (the Metal view, a slider,
            // the sidebar, ...); a modifier-less keyboardShortcut or onKeyPress loses them to the
            // focused view.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated { handleKey(event) } ? nil : event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    /// Speed on a log scale: 10^-2 ... 10^3 steps per second.
    private static let speedRange = -2.0...3.0

    private var speedExponent: Binding<Double> {
        Binding(
            get: { log10(playback.stepsPerSecond) },
            set: { playback.stepsPerSecond = pow(10, $0) }
        )
    }

    private func togglePlay() {
        if playback.position >= Double(playback.stepCount) { playback.position = 0 }
        playback.isPlaying.toggle()
    }

    /// Space plays/pauses; ←/→ nudge the active slider. Returns true if the key was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        // Don't hijack keys while a sheet (such as the in-app login browser) is open.
        guard !model.isShowingPuzzleBrowser,
            event.window?.sheetParent == nil,
            event.window?.attachedSheet == nil
        else { return false }
        // Arrow keys carry .numericPad and .function; any other modifier means "not for us".
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        guard modifiers.isSubset(of: .shift), !(event.window?.firstResponder is NSText) else { return false }

        if event.charactersIgnoringModifiers == " ", modifiers.isEmpty {
            if !event.isARepeat { togglePlay() }  // holding Space must not flicker play/pause
            return true
        }
        switch event.specialKey {
        case .leftArrow?: nudge(by: modifiers.contains(.shift) ? -10 : -1)
        case .rightArrow?: nudge(by: modifiers.contains(.shift) ? 10 : 1)
        default: return false
        }
        return true
    }

    /// One timeline step (keeping the phase within the step) or a tenth of a decade of speed,
    /// per unit of `amount`.
    private func nudge(by amount: Double) {
        switch arrowTarget {
        case .timeline:
            playback.position = min(max(playback.position + amount, 0), Double(playback.stepCount))
        case .speed:
            let exponent = log10(playback.stepsPerSecond) + amount * 0.1
            playback.stepsPerSecond = pow(
                10, min(max(exponent, Self.speedRange.lowerBound), Self.speedRange.upperBound))
        }
    }
}
