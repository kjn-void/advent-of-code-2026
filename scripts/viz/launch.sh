#!/usr/bin/env bash
# Builds and launches the LIVE visualizer window, detached, and waits until its window is on screen.
# Needs the WindowServer: run it OUTSIDE agent sandboxes (inside one the app fails with
# "!cgsConnection" or opens no window). For pictures without a window use scripts/viz/frames.sh.
#
# Usage: scripts/viz/launch.sh [-c debug|release] [--example] [puzzle]   start (replacing any running one)
#        scripts/viz/launch.sh --stop                                   stop the running instance
#   --example   start on the puzzle's worked example instead of the real input
#
# Environment is passed through, e.g. Metal API and shader validation:
#   MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 scripts/viz/launch.sh e1
# Extra swift build flags: SWIFT_BUILD_FLAGS=--disable-sandbox
# Log: .build/viz.log   PID: .build/viz.pid   Screenshot: scripts/viz/tool.sh window capture <pid> out.png
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
cd "$root"

log=.build/viz.log
pidfile=.build/viz.pid

stop() {
    if pkill -x aoc2026-viz; then
        echo "stopped aoc2026-viz"
        sleep 0.5
    fi
    rm -f "$pidfile"
}

config=debug
puzzle=""
args=()
while (($#)); do
    case "$1" in
        -c) config=$2; shift 2 ;;
        --stop) stop; exit 0 ;;
        --example) args+=(--example); shift ;;
        -h | --help) sed -n '2,13s/^# \{0,1\}//p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) puzzle=$1; shift ;;
    esac
done

mkdir -p .build
# shellcheck disable=SC2086 # SWIFT_BUILD_FLAGS may hold several flags: split on purpose
if ! swift build -c "$config" ${SWIFT_BUILD_FLAGS:-} --product aoc2026-viz >"$log" 2>&1; then
    cat "$log" >&2
    exit 1
fi
# shellcheck disable=SC2086
bin="$(swift build -c "$config" ${SWIFT_BUILD_FLAGS:-} --show-bin-path)/aoc2026-viz"
stop

# Detach fully (own stdin/stdout, nohup) so it survives the agent's shell command returning.
if [[ -n "$puzzle" ]]; then args=("$puzzle" "${args[@]}"); fi
nohup "$bin" ${args[@]+"${args[@]}"} >"$log" 2>&1 </dev/null &
pid=$!
disown "$pid" 2>/dev/null || true
echo "$pid" >"$pidfile"

if ! window=$("$here/tool.sh" window wait "$pid" 20); then
    echo "--- $log" >&2
    cat "$log" >&2
    exit 1
fi
echo "aoc2026-viz pid $pid, window $window"
echo "log $log · screenshot: scripts/viz/tool.sh window capture $pid shot.png · stop: scripts/viz/launch.sh --stop"
