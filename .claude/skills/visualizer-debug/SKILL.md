---
name: visualizer-debug
description: Build, launch and screenshot the aoc2026-viz Metal visualizer to debug or verify a puzzle's 2.5D/3D visualization. Use when asked to check what a visualization looks like, debug a scene or shader (Sources/Solutions/DayNN.swift, Shaders/DayNN.metal), verify an animation change, take a screenshot of the visualizer, or figure out why its window does not appear.
---

# Debugging the aoc2026-viz visualizer (Claude Code)

The visualizer is the SwiftPM product `aoc2026-viz` (target `Sources/AoCViz`). Each puzzle's scene
lives in `Sources/Solutions/DayNN.swift` (or `ExampleNN.swift`), with its kernels and animation
in `Sources/Solutions/Shaders/DayNN.metal`. The animation timeline and its phases are documented in
that `.metal` file's header comment (see `Example01.metal`).

All tooling is in `scripts/viz/`. Every script takes `--help`.

## 1. Look at frames offscreen first (works inside the sandbox)

Offscreen rendering needs no window and no WindowServer, so run it with the normal sandboxed Bash tool:

```bash
scripts/viz/frames.sh --part 2 e1 3.10 3.30 3.60 3.86 3.91 3.97
```

- It rebuilds first, so shader edits are picked up (the MetalCompiler plugin builds the metallib).
- Positions are in timeline steps. `3.84` means step index 3 (in Example 1, line 4) at 84 % of that
  step's animation. Pick positions on either side of the phase boundaries from the shader header.
- It prints one `position  caption` line per frame. The caption is the scene's own text (values,
  totals), so check numbers there instead of reading them off pixels.
- Frames go to `.build/viz-frames/<puzzle>-p<part>/frame-<pos>.png`, and a labelled contact sheet
  to `sheet.png` in the same folder. **Look at the sheet with the Read tool.** Use the caption to
  check values; use the image for layout, colour and timing.
- Options: `-c release`, `--size WxH` (default 800x450; use 1600x900 for detail), `--input <file>`
  (e.g. a saved puzzle example), `--out <dir>`, `--cols N`.
- A single frame without the script:
  `$(swift build --show-bin-path)/aoc2026-viz --snapshot e1 --at 3.5 --part 1 --size 1600x900 --out f.png`

The real input must be cached in `input/<year>/dayNN.txt`. Otherwise the app downloads it using
`AOC_SESSION`. If it is missing, ask the user, or use `--input` with an example file.
**Never write the AoC session cookie to disk.**

## 2. The live window (only for interaction, UI chrome or real-time behaviour)

The app needs the WindowServer, so it must run **outside the sandbox**. Sandboxed runs fail with
`!cgsConnection`, or run but open no window.

- Desktop app (Code tab): run it with the Bash tool and `dangerouslyDisableSandbox: true` (the user
  approves this). Alternatively, use the Terminal-panel tool (`run_in_terminal`) so the user can
  watch the app and stop it.
- Claude Code CLI: Bash with the sandbox disabled.

```bash
scripts/viz/launch.sh e1                 # build, replace any running instance, wait for the window
scripts/viz/launch.sh -c release e1
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 scripts/viz/launch.sh e1   # Metal API + shader validation
scripts/viz/launch.sh --stop             # always stop it when you are done
```

`launch.sh` detaches the app with nohup, so it survives your command returning. It prints the PID
and window ID. The app's stdout and stderr go to `.build/viz.log`, and the PID to `.build/viz.pid`.

**Screenshot of the live window**, also outside the sandbox:

```bash
scripts/viz/tool.sh window capture "$(cat .build/viz.pid)" .build/viz-frames/live.png
```

Then Read the PNG. This captures **only the visualizer's own window**, by window ID.

- **Never capture the full screen.** No bare `screencapture`, and no desktop screenshots: the
  user's other apps (chat, mail) are private.
- If capture fails with a Screen Recording permission message, do not work around it. Use
  `frames.sh` instead, or ask the user to look.

## 3. When something is wrong

- **No window appears:** run `scripts/viz/tool.sh window list <pid>`.
  - The content window is layer 0, about 1400x900. The ~30-px strips are the menu bar.
  - If there is no content window, check `.build/viz.log`, and run `sample <pid> 1` to see whether
    the main thread is idle in `NSApplication run`.
  - Known cause, already fixed: AppKit treats bare arguments such as `e1` as files to open, and then
    SwiftUI skips the window. `Sources/AoCViz/main.swift` registers
    `NSTreatUnknownArgumentsAsOpen = NO`. Keep it.
- **Black or empty frames:** check that the scene's `instanceCount` and `bounds` are right. Look for
  NaN positions from kernels, or instances with zero scale (that is how kernels hide voxels).
  Validation (`MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1`) reports out-of-bounds buffer access in
  `.build/viz.log`.
- **Build fails inside the sandbox with `sandbox_apply` / `Operation not permitted`:** run with
  `SWIFT_BUILD_FLAGS=--disable-sandbox`, or run the command outside the sandbox.
- **GPU frame capture or shader debugging:** that needs Xcode, so it is for the user. Open
  `Package.swift`, choose the `aoc2026-viz` scheme, then Debug › Capture GPU Workload.
