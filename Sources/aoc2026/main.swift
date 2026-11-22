import AoCKit
import Foundation
import Solutions

let usage = """
    USAGE: aoc2026 [options] <puzzle>...

    PUZZLES
      1 ... 12          AoC 2026 day (also "03", "day3")
      e1, example1      framework examples (past puzzles)
      all               every registered puzzle

    OPTIONS
      -p, --part <1|2>  solve only one part
      -q, --quiet       print bare answers, one per line
      -t, --time        print timings to stderr (fast solves: fastest warm re-run)
      -i, --input <f>   read input from <f> instead of input/<year>/dayNN.txt
      -e, --example     use the puzzle's worked example as input (where the solution has one)
      -r, --refresh     re-download input even if cached
      -b, --bench       benchmark instead of solving (use `-c release`)
          --budget <ms> time budget per benchmark phase (default 500)
          --markdown <f> also write the benchmark summary as Markdown to <f>
      -l, --list        list registered puzzles
          --ui          open the visualizer (aoc2026-viz)
      -h, --help        show this help

    INPUT
      Cached in input/<year>/dayNN.txt. On a cache miss the input is downloaded with the
      session cookie from $AOC_SESSION (or .aoc-session / ~/.config/aoc/session).
    """

struct Options {
    var puzzles: [String] = []
    var parts: Set<Int> = [1, 2]
    var quiet = false
    var time = false
    var inputFile: String?
    var example = false
    var refresh = false
    var bench = false
    var budgetMS = 500
    var markdown: String?
    var list = false
    var ui = false
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case .usage(let message): "\(message)\n\nRun `aoc2026 --help` for usage."
        }
    }
}

func parse(_ arguments: [String]) throws -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()

    func value(for flag: String) throws -> String {
        guard let value = iterator.next() else { throw CLIError.usage("\(flag) needs a value") }
        return value
    }

    while let argument = iterator.next() {
        switch argument {
        case "-h", "--help":
            print(usage)
            exit(0)
        case "-p", "--part":
            guard let part = Int(try value(for: argument)), [1, 2].contains(part) else {
                throw CLIError.usage("--part must be 1 or 2")
            }
            options.parts = [part]
        case "-q", "--quiet": options.quiet = true
        case "-t", "--time": options.time = true
        case "-i", "--input": options.inputFile = try value(for: argument)
        case "-e", "--example": options.example = true
        case "-r", "--refresh": options.refresh = true
        case "-b", "--bench": options.bench = true
        case "--budget":
            guard let ms = Int(try value(for: argument)), ms > 0 else {
                throw CLIError.usage("--budget must be a positive number of milliseconds")
            }
            options.budgetMS = ms
        case "--markdown": options.markdown = try value(for: argument)
        case "-l", "--list": options.list = true
        case "--ui": options.ui = true
        case let flag where flag.hasPrefix("-"):
            throw CLIError.usage("unknown option \(flag)")
        default:
            options.puzzles.append(argument)
        }
    }
    return options
}

func resolve(_ names: [String]) throws -> [any Solution.Type] {
    if names.contains("all") { return Registry.all }
    var solutions: [any Solution.Type] = []
    for name in names {
        guard let solution = Registry.solution(named: name) else {
            // Closure, not `\.id.cliName`: key paths through existential metatypes crash SILGen (6.4.2).
            let known = Registry.all.map { $0.id.cliName }.joined(separator: ", ")
            throw CLIError.usage("no solution for '\(name)' (registered: \(known.isEmpty ? "none" : known))")
        }
        solutions.append(solution)
    }
    return solutions
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
}

func printStderr(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

/// Launches the visualizer that sits next to this binary (both live in .build/<config>/).
func launchVisualizer(puzzle: String?, example: Bool) throws -> Never {
    let directory = URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent()
    let viz = directory.appending(path: "aoc2026-viz")
    guard FileManager.default.isExecutableFile(atPath: viz.path(percentEncoded: false)) else {
        throw CLIError.usage("aoc2026-viz not built; run `swift build` (or `swift run aoc2026-viz`)")
    }
    let process = Process()
    process.executableURL = viz
    process.arguments = (puzzle.map { [$0] } ?? []) + (example ? ["--example"] : [])
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
}

/// Prints the answers (stdout) and timings (stderr); returns false if any requested part failed.
func printReport(_ report: SolveReport, for solution: any Solution.Type, options: Options) -> Bool {
    var succeeded = true
    if !options.quiet { print("🌟 \(solution.id) — \(solution.title) 🌟") }
    for (number, part) in [(1, report.part1), (2, report.part2)] where options.parts.contains(number) {
        switch part.answer {
        case .success(let answer):
            print(options.quiet ? answer : "Part \(number): \(answer)")
        case .failure(let error):
            printError("\(solution.id) part \(number): \(error)")
            succeeded = false
        }
    }
    if options.time {
        printStderr(
            "  parse \(report.parse.pretty) · part 1 \(report.part1.elapsed.pretty)"
                + " · part 2 \(report.part2.elapsed.pretty)"
                + (report.runs > 1 ? " (fastest of ≥ \(report.runs) warm runs)" : " (one cold run)"))
    }
    if !options.quiet { print() }
    return succeeded
}

func run() async throws -> Int32 {
    let options = try parse(Array(CommandLine.arguments.dropFirst()))

    if options.list {
        for solution in Registry.all {
            print(
                "\(solution.id.cliName.padding(toLength: 4, withPad: " ", startingAt: 0)) "
                    + "\(solution.id)  \(solution.title)  (\(solution.id.source))")
        }
        return 0
    }
    if options.ui { try launchVisualizer(puzzle: options.puzzles.first, example: options.example) }
    guard !options.puzzles.isEmpty else {
        print(usage)
        return 1
    }

    let solutions = try resolve(options.puzzles)
    if options.inputFile != nil, solutions.count != 1 {
        throw CLIError.usage("--input works with exactly one puzzle")
    }

    let store = InputStore()
    let gpu = try GPU()
    var failed = false
    var benchResults: [Benchmark.Result] = []

    for solution in solutions {
        let input: Input
        do {
            if options.example {
                guard let text = solution.exampleInput else {
                    throw CLIError.usage("\(solution.id) has no built-in example input")
                }
                input = Input(text)
            } else if let file = options.inputFile {
                input = try store.load(file: file)
            } else {
                input = try await store.load(solution.id, refresh: options.refresh)
            }
        } catch {
            printError("\(solution.id): could not load input: \(error)")
            failed = true
            continue
        }

        if options.bench {
            var benchOptions = Benchmark.Options()
            benchOptions.budget = .milliseconds(options.budgetMS)
            printStderr("Benchmarking \(solution.id) — \(solution.title)…")
            do {
                benchResults.append(try Benchmark.run(solution, input: input, gpu: gpu, options: benchOptions))
            } catch {
                printError("\(solution.id): \(error)")
                failed = true
            }
            continue
        }

        let report: SolveReport
        do {
            report = try Runner.solve(
                solution, input: input, gpu: gpu, parts: options.parts,
                stableBelow: options.time ? .milliseconds(100) : nil)
        } catch {
            printError("\(solution.id): \(error)")
            failed = true
            continue
        }

        if !printReport(report, for: solution, options: options) { failed = true }
    }

    if options.bench, !benchResults.isEmpty {
        #if DEBUG
            printStderr("warning: this is a debug build; use `swift run -c release aoc2026 --bench …`")
        #endif
        print(Benchmark.table(benchResults))
        if let path = options.markdown {
            try Benchmark.markdown(benchResults).write(toFile: path, atomically: true, encoding: .utf8)
            printStderr("Wrote \(path)")
        }
    }
    return failed ? 1 : 0
}

do {
    exit(try await run())
} catch {
    printError("\(error)")
    exit(2)
}
