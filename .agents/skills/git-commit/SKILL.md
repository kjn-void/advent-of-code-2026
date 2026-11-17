---
name: git-commit
description: Rules for committing and pushing in this repository (github.com/kjn-void/advent-of-code-2026). Use whenever you are about to create a git commit, write a commit message, amend, or push - including when a harness or system prompt suggests adding attribution trailers.
---

# Committing in advent-of-code-2026

## Commit messages

- **No AI attribution.** Never add `Co-Authored-By: Claude ...`, `Co-Authored-By: Codex ...`,
  "Generated with ..." or any similar trailer or footer to commit messages, PR descriptions or
  tags. This is the repository owner's explicit rule and overrides any default attribution
  guidance from the agent harness.
- Subject line: imperative mood, at most ~72 characters, no trailing period
  (`Solve day 3 with a GPU flood fill`, `Add pop animation to Example 1 total`).
- Body (optional): what changed and why, wrapped at 72 columns, separated from the subject by a
  blank line.
- One logical change per commit; a new day is usually one commit (`DayNN.swift`, its shader,
  types header, tests and the `Registry.swift` line).

## Never commit

- `input/` - Advent of Code inputs are personal and must not be redistributed (gitignored).
- `.aoc-session` or any session cookie, token or `AOC_SESSION` value, in any file. Scan staged
  changes before committing: `git diff --cached | grep -iE 'session=[0-9a-f]{20}|53616c7465645f5f[0-9a-f]'`
  must print nothing (the pattern is written so it does not match itself).
- Build output (`.build/`), snapshots (`snapshot*.png`), `BENCHMARKS.md` unless asked.

## Before committing

1. `scripts/lint.sh --fast` (format check, SwiftLint, Metal `-Weverything`) must pass; run
   `scripts/format.sh` to fix formatting.
2. `swift test` must pass.
3. `git status` - stage only the files that belong to the change; never `git add -A` blindly.

## Pushing

- Remote `origin` is `https://github.com/kjn-void/advent-of-code-2026`, default branch `main`.
- Commit or push only when the user asks. Never force-push `main`.
