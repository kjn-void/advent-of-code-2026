import Foundation

/// Resolves puzzle input: cached `input/<year>/dayNN.txt`, otherwise download and cache it.
///
/// Inputs are personal and AoC asks people not to redistribute them, so `input/` is gitignored.
public struct InputStore: Sendable {
    /// Repository root (the directory containing Package.swift).
    public let root: URL

    public init(root: URL = Self.locateRoot()) {
        self.root = root
    }

    public var inputDirectory: URL { root.appending(path: "input", directoryHint: .isDirectory) }

    /// e.g. `input/2026/day03.txt`, `input/2023/day01.txt`.
    public func cachedInputURL(for id: PuzzleID) -> URL {
        inputDirectory
            .appending(path: "\(id.year)", directoryHint: .isDirectory)
            .appending(path: String(format: "day%02d.txt", id.aocDay))
    }

    public func hasCachedInput(for id: PuzzleID) -> Bool {
        FileManager.default.fileExists(atPath: cachedInputURL(for: id).path(percentEncoded: false))
    }

    /// Loads input for `id`, downloading and caching it on a cache miss.
    /// - Parameter refresh: re-download even if a cached file exists.
    public func load(_ id: PuzzleID, refresh: Bool = false) async throws -> Input {
        let cached = cachedInputURL(for: id)
        if !refresh, let text = try? String(contentsOf: cached, encoding: .utf8) {
            return Input(text)
        }
        guard let session = session() else { throw AoCClient.FetchError.missingSession }

        let text = try await AoCClient(session: session).fetchInput(year: id.year, day: id.aocDay)
        try FileManager.default.createDirectory(
            at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: cached, atomically: true, encoding: .utf8)
        return Input(text)
    }

    /// Loads a cached input synchronously, or nil when it has not been downloaded yet.
    public func cached(_ id: PuzzleID) -> Input? {
        (try? String(contentsOf: cachedInputURL(for: id), encoding: .utf8)).map { Input($0) }
    }

    /// Loads an explicit file (e.g. `--input example.txt`).
    public func load(file: String) throws -> Input {
        let url = URL(filePath: file, relativeTo: URL(filePath: FileManager.default.currentDirectoryPath))
        return Input(try String(contentsOf: url, encoding: .utf8))
    }

    /// Session cookie from `AOC_SESSION`, `<root>/.aoc-session` or `~/.config/aoc/session`.
    public func session() -> String? {
        if let env = ProcessInfo.processInfo.environment["AOC_SESSION"], !env.isEmpty { return env }
        let candidates = [
            root.appending(path: ".aoc-session"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/aoc/session"),
        ]
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// `AOC_ROOT`, else the first directory containing Package.swift walking up from the
    /// current directory, then from the executable (`.build/<config>/aoc2026` → repo root), then
    /// from this source file's build-time location (apps started by Xcode or the Dock run in `/`
    /// from a binary in DerivedData, so neither of the others finds the repo).
    public static func locateRoot() -> URL {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["AOC_ROOT"], !env.isEmpty {
            return URL(filePath: env, directoryHint: .isDirectory)
        }
        let starts = [
            URL(filePath: fm.currentDirectoryPath, directoryHint: .isDirectory),
            Bundle.main.executableURL?.deletingLastPathComponent(),
            URL(filePath: #filePath).deletingLastPathComponent(),
        ].compactMap(\.self)

        for start in starts {
            var dir = start.standardizedFileURL
            while dir.path(percentEncoded: false) != "/" {
                if fm.fileExists(atPath: dir.appending(path: "Package.swift").path(percentEncoded: false)) {
                    return dir
                }
                dir = dir.deletingLastPathComponent()
            }
        }
        return URL(filePath: fm.currentDirectoryPath, directoryHint: .isDirectory)
    }
}
