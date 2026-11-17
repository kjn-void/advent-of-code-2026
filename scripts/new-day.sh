#!/usr/bin/env bash
# Scaffolds a new day from templates/ and registers it.
#
#   scripts/new-day.sh <day> ["Puzzle Title"]
#
# Creates
#   Sources/Solutions/DayNN.swift              parse + solve + visualization (one file per day)
#   Sources/Solutions/Shaders/DayNN.metal      the day's kernels
#   Sources/AoCShared/include/DayNNTypes.h     structs shared by Swift and Metal
#   Tests/SolutionsTests/DayNNTests.swift      examples from the puzzle text as unit tests
# and adds DayNN.self to Sources/Solutions/Registry.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

day="${1:-}"
if ! [[ "$day" =~ ^[0-9]+$ ]] || (( day < 1 || day > 12 )); then
    echo "usage: scripts/new-day.sh <1-12> [\"Puzzle Title\"]" >&2
    exit 1
fi
nn=$(printf '%02d' "$day")
year=2026
title="${2:-}"

if [[ -z "$title" ]]; then
    # The puzzle page is public once unlocked; scrape "--- Day 3: Title ---".
    title=$(curl -fsS -A "github.com/kjn-void/advent-of-code-2026 (new-day script)" \
        "https://adventofcode.com/$year/day/$day" 2>/dev/null \
        | sed -n 's/.*<h2>--- Day [0-9]*: \(.*\) ---<\/h2>.*/\1/p' | head -1 || true)
    title="${title:-Day $day}"
    title=$(printf '%s' "$title" | sed 's/&amp;/\&/g; s/&quot;/"/g; s/&#39;/'"'"'/g')
fi

targets=(
    "templates/Day.swift.template:Sources/Solutions/Day$nn.swift"
    "templates/Day.metal.template:Sources/Solutions/Shaders/Day$nn.metal"
    "templates/DayTypes.h.template:Sources/AoCShared/include/Day${nn}Types.h"
    "templates/DayTests.swift.template:Tests/SolutionsTests/Day${nn}Tests.swift"
)
for pair in "${targets[@]}"; do
    if [[ -e "${pair#*:}" ]]; then
        echo "${pair#*:} already exists; not overwriting anything." >&2
        exit 1
    fi
done

escaped_title=$(printf '%s' "$title" | sed 's/[\\"]/\\&/g; s/[&|]/\\&/g')
for pair in "${targets[@]}"; do
    sed -e "s|__NN__|$nn|g" -e "s|__N__|$day|g" -e "s|__TITLE__|$escaped_title|g" "${pair%%:*}" > "${pair#*:}"
    echo "created ${pair#*:}"
done

# The AoCShared module map uses an umbrella directory; SwiftPM's explicit-module cache only
# notices the new DayNNTypes.h when the module map itself changes.
touch Sources/AoCShared/include/module.modulemap

registry=Sources/Solutions/Registry.swift
if ! grep -q "Day$nn.self" "$registry"; then
    sed -i '' "s|^\([[:space:]]*\)// new-day: insert above|\1Day$nn.self,\\
\1// new-day: insert above|" "$registry"
    echo "registered Day$nn in $registry"
fi

cat <<EOF

Next:
  1. Paste the puzzle's examples into Tests/SolutionsTests/Day${nn}Tests.swift
  2. swift test --filter Day${nn}              # TDD against the examples
  3. swift run aoc2026 $day                    # downloads input/$year/day$nn.txt on first run
  4. swift run aoc2026-viz $day                # visualize
  5. swift run -c release aoc2026 --bench $day # benchmark
EOF
