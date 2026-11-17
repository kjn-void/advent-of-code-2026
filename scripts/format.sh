#!/usr/bin/env bash
# Formats all Swift (swift-format) and Metal/C (clang-format) sources in place.
# Usage: scripts/format.sh [--check]   (--check: report unformatted files, change nothing)
set -euo pipefail
cd "$(dirname "$0")/.."

check=false
[[ "${1:-}" == "--check" ]] && check=true

swift_files=$(find Sources Tests Plugins Package.swift -name '*.swift' -not -path '*/.build/*')
metal_files=$(find Sources -name '*.metal' -o -name '*.h' | grep -v '/.build/')

if $check; then
    echo "→ swift-format (check)"
    # shellcheck disable=SC2086
    xcrun swift-format lint --strict --parallel $swift_files
    echo "→ clang-format (check)"
    # shellcheck disable=SC2086
    clang-format --dry-run --Werror $metal_files
else
    echo "→ swift-format"
    # shellcheck disable=SC2086
    xcrun swift-format format --in-place --parallel $swift_files
    echo "→ clang-format"
    # shellcheck disable=SC2086
    clang-format -i $metal_files
fi
echo "✔ formatting done"
