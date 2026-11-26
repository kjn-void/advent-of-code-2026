#!/usr/bin/env bash
# Static analysis — the Swift/Metal equivalent of `cargo fmt --check && cargo clippy -D warnings`.
#
#   1. Formatting       swift-format lint --strict, clang-format --dry-run --Werror
#   2. Swift lints      SwiftLint --strict (best-practice rules, see .swiftlint.yml)
#   3. Metal lints      metal -Weverything -Werror (minus pure C++98-compat noise), syntax only
#   4. Compiler         swift build with -warnings-as-errors (strict concurrency is on: Swift 6 mode)
#
# Usage: scripts/lint.sh [--fast]   (--fast skips the warnings-as-errors build)
set -euo pipefail
cd "$(dirname "$0")/.."

fast=false
[[ "${1:-}" == "--fast" ]] && fast=true
failed=0
step() { printf '\n\033[1m→ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m✘ %s\033[0m\n' "$1"; failed=1; }

step "Formatting"
scripts/format.sh --check || fail "formatting (run scripts/format.sh)"

step "SwiftLint"
if command -v swiftlint >/dev/null 2>&1; then
    swiftlint lint --strict --quiet || fail "swiftlint"
else
    fail "swiftlint not installed (brew install swiftlint)"
fi

step "Metal (-Weverything -Werror)"
metal_flags=(
    -std=metal3.2 -mmacosx-version-min=15.0 -fsyntax-only
    -Weverything -Werror
    -Wno-c++98-compat -Wno-c++98-c++11-compat-binary-literal  # we target C++14-based MSL
    -Wno-padded                                                # layout is checked by shared headers
    -ISources/AoCShared/include
)
while IFS= read -r file; do
    xcrun -sdk macosx metal "${metal_flags[@]}" -I"$(dirname "$file")" "$file" || fail "$file"
done < <(find Sources -name '*.metal')

if ! $fast; then
    step "Swift build + tests (warnings as errors)"
    # Separate scratch path so the normal debug build cache is not invalidated.
    mkdir -p .build/lint
    build_log=.build/lint/build.log
    if swift build --build-tests --scratch-path .build/lint -Xswiftc -warnings-as-errors >"$build_log" 2>&1; then
        grep -E 'Compiling|Build complete' "$build_log" | grep -v '^\[' || true
    else
        cat "$build_log" >&2
        fail "swift build --build-tests -warnings-as-errors"
    fi
fi

echo
if [[ $failed -ne 0 ]]; then
    printf '\033[31m✘ lint failed\033[0m\n'
    exit 1
fi
printf '\033[32m✔ lint clean\033[0m\n'
