# Convenience wrappers around SwiftPM and the scripts in scripts/.
# Puzzles: P=3, P=e1, P="1 2 3", P=all

P ?= all

.PHONY: build release run ui test bench bench-md format lint lint-fast new-day clean

build:            ## Debug build of everything
	swift build

release:          ## Optimised build of everything
	swift build -c release

run:              ## Solve puzzles:            make run P=e1
	swift run -c release aoc2026 $(P)

ui:               ## Open the visualizer:       make ui P=e1
	swift run aoc2026-viz $(filter-out all,$(P))

test:             ## Unit tests (examples + real-input cross-checks when input is cached)
	swift test

bench:            ## Benchmarks (release):      make bench P=e1
	swift run -c release aoc2026 --bench $(P)

bench-md:         ## Benchmarks + write BENCHMARKS.md
	swift run -c release aoc2026 --bench --markdown BENCHMARKS.md $(P)

format:           ## Format Swift + Metal in place
	scripts/format.sh

lint:             ## Formatting check, SwiftLint, Metal -Weverything, warnings-as-errors build
	scripts/lint.sh

lint-fast:        ## lint without the warnings-as-errors build
	scripts/lint.sh --fast

new-day:          ## Scaffold a day:            make new-day D=3 [T="Title"]
	scripts/new-day.sh $(D) $(if $(T),"$(T)")

clean:
	swift package clean
	rm -rf .build/lint

help:
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/' | expand -t 18
