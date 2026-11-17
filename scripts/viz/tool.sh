#!/usr/bin/env bash
# Compiles one of the Swift helpers in scripts/viz (once, cached in .build/viz-tools) and runs it.
# Usage: scripts/viz/tool.sh <window|contact-sheet> [args...]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

name=${1:?"usage: scripts/viz/tool.sh <window|contact-sheet> [args...]"}
shift
src="$here/$name.swift"
[[ -f "$src" ]] || { echo "no such tool: $name (expected $src)" >&2; exit 2; }

out="$root/.build/viz-tools"
bin="$out/$name"
if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
    mkdir -p "$out"
    xcrun swiftc -O -module-cache-path "$out/ModuleCache" "$src" -o "$bin" >&2
fi
exec "$bin" "$@"
