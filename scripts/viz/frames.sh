#!/usr/bin/env bash
# Renders visualizer frames OFFSCREEN and tiles them into a labelled contact sheet.
# No window and no WindowServer needed, so this works inside agent sandboxes and over SSH.
#
# Usage: scripts/viz/frames.sh [options] <puzzle> <position>...
#   <puzzle>      e1, 3, day3, ... (same names as the CLI)
#   <position>    timeline position in steps: 3.84 = step index 3 (e.g. line 4) at 84 % progress
#   -c <config>   debug (default) or release
#   --part <n>    1 (default) or 2
#   --size <WxH>  frame size, default 800x450
#   --input <f>   use this input file instead of the cached input/<year>/dayNN.txt
#   --example     use the puzzle's worked example (built into the solution) as input
#   --out <dir>   output directory, default .build/viz-frames/<puzzle>-p<part>
#   --cols <n>    columns in the sheet (default 2 for <= 4 frames, else 3)
#
# Extra swift build flags: SWIFT_BUILD_FLAGS=--disable-sandbox (needed inside some agent sandboxes).
# Output: one "position  caption" line per frame, frames as <dir>/frame-<pos>.png, sheet at <dir>/sheet.png.
# Example: scripts/viz/frames.sh --part 2 e1 3.10 3.30 3.60 3.86 3.91 3.97
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
cd "$root"

usage() { sed -n '2,19s/^# \{0,1\}//p' "$0"; }

config=debug
part=1
size=800x450
input=""
example=false
out=""
cols=""
puzzle=""
positions=()
while (($#)); do
    case "$1" in
        -c) config=$2; shift 2 ;;
        --part) part=$2; shift 2 ;;
        --size) size=$2; shift 2 ;;
        --input) input=$2; shift 2 ;;
        --example) example=true; shift ;;
        --out) out=$2; shift 2 ;;
        --cols) cols=$2; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)
            if [[ -z "$puzzle" ]]; then puzzle=$1; else positions+=("$1"); fi
            shift
            ;;
    esac
done
if [[ -z "$puzzle" || ${#positions[@]} -eq 0 ]]; then
    usage >&2
    exit 2
fi
suffix=""
if $example; then suffix="-example"; fi
out=${out:-.build/viz-frames/$puzzle-p$part$suffix}
mkdir -p "$out"
rm -f "$out"/frame-*.png "$out"/sheet.png

# Rebuild first: shader edits only take effect once the MetalCompiler plugin rebuilds the metallib.
# shellcheck disable=SC2086 # SWIFT_BUILD_FLAGS may hold several flags: split on purpose
if ! swift build -c "$config" ${SWIFT_BUILD_FLAGS:-} --product aoc2026-viz >"$out/build.log" 2>&1; then
    cat "$out/build.log" >&2
    exit 1
fi
# shellcheck disable=SC2086
bin="$(swift build -c "$config" ${SWIFT_BUILD_FLAGS:-} --show-bin-path)/aoc2026-viz"

frames=()
for pos in "${positions[@]}"; do
    frame="$out/frame-$pos.png"
    args=(--snapshot "$puzzle" --at "$pos" --part "$part" --size "$size" --out "$frame")
    if [[ -n "$input" ]]; then args+=(--input "$input"); fi
    if $example; then args+=(--example); fi
    caption=$("$bin" "${args[@]}")
    echo "$pos  ${caption#"$frame: "}"
    frames+=("$frame")
done

sheet_args=("$out/sheet.png")
if [[ -n "$cols" ]]; then sheet_args+=(--cols "$cols"); fi
"$here/tool.sh" contact-sheet "${sheet_args[@]}" "${frames[@]}"
