# Advent of Code 2026 — Swift + Metal Compute

[![CI](https://github.com/kjn-void/advent-of-code-2026/actions/workflows/ci.yml/badge.svg)](https://github.com/kjn-void/advent-of-code-2026/actions/workflows/ci.yml)

Each puzzle is parsed in Swift into flat, GPU-friendly buffers and solved with Metal compute
kernels. The same code runs three ways:

| Mode | Command | What it does |
|------|---------|--------------|
| CLI | `swift run -c release aoc2026 3` | prints the answers to stdout |
| Visualizer | `swift run aoc2026-viz 3` | SwiftUI + Metal app: pick a day, see a 2.5D/3D animation of the solution |
| Benchmarks | `swift run -c release aoc2026 --bench all` | Parse / Part 1 / Part 2 / Full-pipeline timings, incl. GPU time |

**Example 1** is AoC 2023 day 1 ("Trebuchet?!"), kept as the end-to-end reference that exercises
every piece: input download, GPU solve, unit tests from the puzzle examples, benchmarks and a
visualization. **Example 2** is AoC 2024 day 6 ("Guard Gallivant"): a grid walk, a massively
parallel GPU search, and a 2.5D game-style visualization with a camera that follows the guard.

Requirements: an Apple silicon Mac, full Xcode 26 or later (Swift 6.2 or later), and the
separately installed Metal Toolchain. The binaries target macOS 15 or later; check
[Apple's Xcode system requirements](https://developer.apple.com/xcode/system-requirements/)
for the macOS version needed to run your version of Xcode.

## Quick start

Install [Xcode](https://developer.apple.com/xcode/), then select it and install the
[Metal Toolchain](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components):

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
xcodebuild -downloadComponent metalToolchain
swift --version
xcrun -sdk macosx metal --version
```

Adjust the path if Xcode is installed elsewhere. If `xcode-select -p` shows
`/Library/Developer/CommandLineTools`, the standalone tools are selected. They can provide
Swift, but this project's shader build also needs `xcrun -sdk macosx metal --version` to succeed.

From the repo root, build both executables and run the tests:

```bash
swift build
swift test
make help                           # all shortcuts
```

These commands need no Advent of Code account or puzzle input. To run Example 1 with real input,
set your session cookie as described below if the input isn't already cached:

```bash
swift run aoc2026 e1                # print the answers for Example 1
swift run aoc2026-viz e1            # open the visualizer on Example 1
```

## Puzzle input

Inputs are cached in `input/<year>/dayNN.txt` (gitignored: AoC asks people not to redistribute
inputs). On a cache miss the CLI and the visualizer download the input from
`https://adventofcode.com/<year>/day/<n>/input` using your session cookie, the same way the
2025 project's `aocnet` package did. Inputs are fetched once; `--refresh` forces a re-download.
Requests before a puzzle unlocks (midnight US Eastern) are refused locally.

**Getting the session cookie:** log in at adventofcode.com, open the browser dev tools
(Safari ⌥⌘I → Storage, Chrome F12 → Application, Firefox F12 → Storage), and copy the value of
the `session` cookie for `https://adventofcode.com`.

The cookie is looked up in this order:

1. `AOC_SESSION` environment variable (recommended, since nothing touches disk)
2. `.aoc-session` in the repo root (gitignored)
3. `~/.config/aoc/session`

Treat it like a password: it is your login. Logging out of adventofcode.com invalidates it.

`AOC_USER_AGENT` overrides the User-Agent sent with downloads (AoC asks automated tools to
identify themselves). `AOC_ROOT` overrides where the repo (and so `input/`) is found.

## CLI

```text
aoc2026 [options] <puzzle>...

  1 ... 12 | e1 | all       puzzles (days of 2026, examples, or everything registered)
  -p, --part <1|2>          one part only
  -q, --quiet               bare answers, one per line (for scripts)
  -t, --time                timings to stderr
  -i, --input <file>        explicit input file (e.g. an example you saved)
  -e, --example             the puzzle's worked example, built into the solution
  -r, --refresh             re-download input
  -b, --bench               benchmark instead of solving
      --budget <ms>         time budget per benchmark phase (default 500)
      --markdown <file>     also write the benchmark table as Markdown
  -l, --list                list registered puzzles
      --ui                  launch the visualizer
```

The exit code is non-zero if any part failed or is not implemented, so `aoc2026 -q all` works as a
smoke test.

## Visualizer

`swift run aoc2026-viz [puzzle] [--example]` opens a window with a sidebar of puzzles, the answers and
timings, and a Metal viewport:

* **drag** orbits, **shift-drag** or **right-drag** pans, **scroll/pinch** zooms, **double-click**
  resets the camera
* the timeline at the bottom plays/scrubs through the solution step by step (space = play/pause; Tab focuses a slider; ← / → nudge the focused or last-touched slider, timeline by default: one step or ×1.26 speed, ⇧ for ten steps or ×10),
  with a Part 1 / Part 2 toggle and a speed control (0.01 to 1000 steps/s)
* the toolbar's **Example / Puzzle input** switch shows the puzzle's worked example or your real
  input (for solutions that carry their example as `exampleInput`)
* scenes can make the camera follow something (Example 2 follows the guard); panning by hand
  stops that until you reset the view

Each scene is GPU-driven: per frame, the scene encodes a compute kernel that writes `AoCInstance`
boxes (position, scale, colour) straight from the solution's buffers, and the renderer draws them
instanced with simple lighting, edge shading and fog. Nothing goes through the CPU.

Example 1's animation: the line drops in as extruded 5×7 voxel text. Every digit token lights up
(in part 2 spelled-out words too), with the first one green and the last one orange. Characters
outside them turn red and explode, then those in the middle do the same. Spelled words convert
into their digit, the two digits slide together into the line's value, and the value flies into
the running total.

Example 2's animation is a little arcade game. Part 1: the guard patrols the map leaving a glowing
trail of horizontal and vertical bars, so corners and crossings show as "+" like in the puzzle's
drawings. Fresh trail is hot yellow and cools to teal. The floating score counts distinct tiles.
Stepping onto a tile already visited scores nothing: the tile flashes, a shockwave ring ripples
out and the score shakes and greys out. Every 100 tiles the score pops. Part 2 goes through every
candidate obstruction in the order the guard reaches it: a crate drops in front of her, and a cyan
ghost guard runs the altered route. A route that loops turns magenta, the crate stays as a magenta
marker and the score (loops found) pops; otherwise the ghost walks off the map and the crate sinks.

**Headless snapshots** render one frame to PNG without opening a window, which is handy for
checking a visualization or for docs:

```bash
swift run aoc2026-viz --snapshot e1 --at 1.55 --part 2 --size 1600x900 --out snapshot.png
```

`--at` is the timeline position in steps (`1.55` = second step, 55 % through its animation).
Add `--example` to render the puzzle's worked example instead of the real input.

For GPU frame capture and shader debugging, open `Package.swift` in Xcode and run the `aoc2026-viz`
scheme. Shaders are compiled with `-gline-tables-only -frecord-sources`, so sources show up in the
Metal debugger.

### Debugging the visualizer (scripts and agent skills)

`scripts/viz/` wraps the build, launch and screenshot steps. AI agents use the same scripts
through the `visualizer-debug` skill: [`.claude/skills/`](.claude/skills/visualizer-debug/SKILL.md)
for Claude Code, [`.agents/skills/`](.agents/skills/visualizer-debug/SKILL.md) for Codex.

```bash
scripts/viz/frames.sh --part 2 e1 3.10 3.60 3.86 3.91   # offscreen frames + labelled contact sheet
scripts/viz/launch.sh e1                                # live window, detached; log in .build/viz.log
scripts/viz/tool.sh window capture "$(cat .build/viz.pid)" live.png   # this window only
scripts/viz/launch.sh --stop
```

`frames.sh` needs no window, so it also works inside agent sandboxes and over SSH; its output goes to
`.build/viz-frames/`. `launch.sh` needs the WindowServer and passes the environment through, e.g.
`MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1`. Window capture needs Screen Recording permission for
the terminal and only ever grabs the visualizer's own window.

## Project layout

```text
Package.swift
Plugins/MetalCompiler/        build-tool plugin: Shaders/*.metal → <Target>.metallib (bundled resource)
Sources/
  AoCShared/include/          C headers shared bit-for-bit by Swift and Metal
    AoCShared.h               AoCInstance, AoCFrameUniforms, AoCGridSize
    AoCKernels.h              Metal-only helpers: grid indexing, 64-bit atomic add, SIMD reductions, colours
    Example01Types.h          per-puzzle shared structs (DayNNTypes.h)
  AoCKit/                     core (no UI)
    Solution.swift            Solution protocol + PuzzleID
    Input.swift Parse.swift Grid.swift    parsing helpers producing flat arrays
    GPU.swift                 device/queue, cached pipelines, typed shared buffers, dispatch helpers
    AoCClient.swift InputStore.swift      download + cache
    Runner.swift Benchmark.swift          solve with timings, benchmark runner + reports
  AoCRender/                  VisualizationScene protocol, Playback, orbit camera, instanced box renderer
  Solutions/                  ONE FILE PER PUZZLE: DayNN.swift = parse + solve + scene
    Shaders/DayNN.metal       that puzzle's kernels
    Registry.swift            list of all puzzles
  aoc2026/                    CLI
  AoCViz/                     SwiftUI visualizer
Tests/SolutionsTests/         DayNNTests.swift per puzzle (puzzle examples → tests)
templates/                    what scripts/new-day.sh copies
scripts/                      new-day.sh, format.sh, lint.sh
```

## Adding a day

```bash
scripts/new-day.sh 3            # or: make new-day D=3; fetches the title from the puzzle page
```

This creates `Sources/Solutions/Day03.swift`, `Shaders/Day03.metal`,
`AoCShared/include/Day03Types.h` and `Tests/SolutionsTests/Day03Tests.swift` from `templates/`
and registers `Day03` in `Registry.swift`. The skeleton builds and runs immediately: it sums all
integers on the GPU and shows them as bars, so you replace working code instead of filling in
blanks. Then:

1. Paste the puzzle's examples and expected answers into `Day03Tests.swift`.
2. `swift test --filter Day03` until green.
3. `swift run aoc2026 3` downloads the input and prints the answers.
4. `swift run aoc2026-viz 3` to build the visualization.
5. `swift run -c release aoc2026 --bench 3`.

### Writing a solution

```swift
public final class Day03: Solution {
    public static let id = PuzzleID.day(3)
    public static let title = "…"

    let gpu: GPU
    let grid: GPUBuffer<UInt8>
    let size: AoCGridSize
    private let countKernel: any MTLComputePipelineState

    public init(input: Input, gpu: GPU) throws {       // "Parse" in benchmarks
        let g = try input.grid()
        self.gpu = gpu
        grid = gpu.buffer(g.cells)
        size = g.size
        countKernel = try gpu.kernel("day03_count")    // from Shaders/Day03.metal, cached
    }

    public func part1() throws -> String {
        let total = gpu.buffer(count: 2, of: UInt32.self)   // {lo, hi} → 64-bit result
        try gpu.run("part 1") { encoder in
            encoder.dispatch(countKernel, width: Int(size.width), height: Int(size.height),
                             .buffer(grid), .buffer(total), .value(size))
        }
        return "\(total.uint64())"
    }
    …
}
```

```metal
#include "AoCKernels.h"
#include "Day03Types.h"
using namespace metal;

[[kernel]] void day03_count(const device uchar* grid [[buffer(0)]], device atomic_uint* total [[buffer(1)]],
                            constant AoCGridSize& size [[buffer(2)]], uint2 p [[thread_position_in_grid]]) {
    aoc::reduceAdd64(grid[aoc::index(p, size)] == '#' ? 1u : 0u, total);
}
```

Guidelines:

* **Parse into flat arrays** (`Grid`, `[SIMD2<Int32>]`, structs from `DayNNTypes.h`). Shared structs
  must live in `AoCShared/include` so Swift and Metal agree on the layout.
* **Kernel arguments** bind to `[[buffer(0)]]`, `[[buffer(1)]]`, … in the order passed to
  `dispatch`. Use `.value(x)` for small constants (≤ 4 KB).
* **64-bit answers:** Apple GPUs only have 32-bit atomic add. `aoc::atomicAdd64` and
  `aoc::reduceAdd64` emulate it with a `{lo, hi}` pair; read it back with `buffer.uint64()`.
* **Iterate until stable** with a `changed` flag (`aoc::markChanged`) and loop `gpu.run` on the CPU.
* Dispatches inside one `gpu.run` execute in order (serial encoder), so later kernels see earlier
  writes.
* **Don't force the GPU onto tiny problems.** A `gpu.run` round trip costs about 100–200 µs no
  matter how little work it does (Example 1: ~15 µs of kernel time inside ~200 µs of wall time).
  Plain Swift is fine where it wins, and the benchmark table shows which one does.

## Tests

`swift test` runs [Swift Testing](https://developer.apple.com/documentation/testing) suites:

* every example from a puzzle's text, as `Example("name", part1: "…", part2: "…", input)` entries
  in a parameterized `@Test`, so each example shows up as its own test case
* optional real-input checks, e.g. Example 1 cross-checks the GPU answers against a plain CPU
  implementation. They are skipped automatically when the input isn't downloaded (e.g. on CI).
* suites that dispatch Metal work carry the `.requiresGPU` trait, so they are skipped with a reason
  on a machine without a Metal device instead of crashing.

GitHub Actions ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs `scripts/lint.sh` and
`swift test` on every push to `main` and every pull request, on `macos-26` with the newest Xcode on
the image.

## Benchmarks

Modelled on the 2025 Go project's `benchmarkDay`: for each puzzle, on its real input, the runner
measures

| Phase | Measures |
|-------|----------|
| Parse | `init(input:gpu:)` |
| Part 1 / Part 2 | each part on an already-parsed instance; GPU execution time (from Metal's command-buffer timestamps) shown alongside |
| Full | parse + both parts on a fresh instance |

Each phase gets an untimed warm-up and then repeats until its time budget (default 500 ms) is
spent, at least 5 times. Medians are reported.

```bash
make bench P=all                 # table on stdout
make bench-md P=all              # also writes BENCHMARKS.md
```

Median wall-clock time per phase, plus the mean GPU execution time of each part:

```text
+-----------+----------+----------+------------+----------+------------+----------+------------+
| Puzzle    |    Parse |   Part 1 | Part 1 GPU |   Part 2 | Part 2 GPU |     Full | Iterations |
+-----------+----------+----------+------------+----------+------------+----------+------------+
| Example 1 | 513.8 µs | 206.4 µs |     9.0 µs | 223.4 µs |    16.8 µs | 941.4 µs |        207 |
+-----------+----------+----------+------------+----------+------------+----------+------------+
```

Always benchmark release builds (`-c release`); the CLI warns otherwise.

## Formatting & linting

| Language | Formatter | Linter / static rules |
|----------|-----------|-----------------------|
| Swift | `swift-format` (ships with Xcode), config `.swift-format` | `swift-format lint --strict`, **SwiftLint** (`.swiftlint.yml`, the Swift counterpart of clippy) and a `-warnings-as-errors` build in Swift 6 strict-concurrency mode |
| Metal (MSL = C++14 + extensions) and shared C headers | `clang-format`, config `.clang-format` | Metal compiler with `-Weverything -Werror` (minus C++98-compat noise), syntax only |

```bash
make format        # scripts/format.sh: format everything in place
make lint          # scripts/lint.sh: format check + SwiftLint + Metal -Weverything + warnings-as-errors build
make lint-fast     # same without the extra build
```

The normal build also compiles shaders with `-Wall -Wextra`, so Metal warnings show up in
`swift build` and Xcode. clang-tidy isn't used: it can't parse MSL's address spaces and attributes.

Tools: `swift-format` comes with Xcode, and `metal` comes from the Metal Toolchain installed
above. Get `clang-format` and SwiftLint from Homebrew (`brew install clang-format swiftlint`).
`lint.sh` fails if SwiftLint is missing, rather than quietly skipping it.

## Notes

* `swift build` compiles shaders through `Plugins/MetalCompiler` (`xcrun metal -std=metal3.2`) into
  `<Target>.metallib`, loaded with `gpu.library(named:in: .module)`. `Shaders/` folders are excluded
  from the targets so SwiftPM/Xcode don't also try to compile them natively without the include
  paths.
* Swift 6.4.2 crashes in SILGen on key paths through existential metatypes (`\.id` on
  `any Solution.Type`). Use closures, or `Registry.entries` in SwiftUI.

## License

The code is released under the [MIT License](LICENSE). Advent of Code puzzle texts and inputs belong
to their creator and are not covered: `input/` is gitignored and must not be committed.
