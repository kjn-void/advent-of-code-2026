import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Downloads puzzle input from adventofcode.com using the `session` cookie, the same way the
/// 2025 Go project's `aocnet` package does. Respect the site: inputs are cached by
/// `InputStore` and only fetched when missing (or with `--refresh`).
public struct AoCClient: Sendable {
    public static let year = 2026
    /// AoC 2025 onwards has 12 puzzles.
    public static let days = 1...12

    public let session: String
    public let userAgent: String

    /// Per AoC's automation guidelines the User-Agent should identify the tool and a way to
    /// reach its owner. Override with `AOC_USER_AGENT`.
    public static var defaultUserAgent: String {
        ProcessInfo.processInfo.environment["AOC_USER_AGENT"]
            ?? "github.com/kjn-void/advent-of-code-2026 (Swift/Metal input fetcher)"
    }

    public init(session: String, userAgent: String = Self.defaultUserAgent) {
        self.session = session.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userAgent = userAgent
    }

    /// When the puzzle for `day` unlocks: midnight US Eastern (UTC-5) on December `day`.
    public static func unlockDate(day: Int, year: Int = year) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "America/New_York")
        components.year = year
        components.month = 12
        components.day = day
        return components.date ?? .distantFuture
    }

    public func fetchInput(year: Int = Self.year, day: Int) async throws -> String {
        let unlock = Self.unlockDate(day: day, year: year)
        guard Date.now >= unlock else { throw FetchError.notUnlocked(day: day, unlock: unlock) }

        let url = URL(string: "https://adventofcode.com/\(year)/day/\(day)/input")!
        var request = URLRequest(url: url)
        request.setValue("session=\(session)", forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            let body = String(validating: data.prefix(200), as: UTF8.self) ?? "<\(data.count) bytes, not UTF-8>"
            throw FetchError.http(status: status, body: body)
        }
        guard let text = String(validating: data, as: UTF8.self) else { throw FetchError.notUTF8(bytes: data.count) }
        return text
    }

    public enum FetchError: Error, CustomStringConvertible {
        case notUnlocked(day: Int, unlock: Date)
        case http(status: Int, body: String)
        case missingSession
        case notUTF8(bytes: Int)

        public var description: String {
            switch self {
            case .notUnlocked(let day, let unlock):
                "day \(day) unlocks at \(unlock.formatted(date: .abbreviated, time: .shortened))"
            case .http(400, _), .http(500, _):
                "the AoC server rejected the session cookie (expired?); grab a fresh one from your browser"
            case .http(let status, let body):
                "HTTP \(status): \(body.trimmingCharacters(in: .whitespacesAndNewlines))"
            case .missingSession:
                "no AoC session found: set AOC_SESSION, or put the cookie in .aoc-session or ~/.config/aoc/session"
            case .notUTF8(let bytes):
                "the downloaded input (\(bytes) bytes) is not valid UTF-8"
            }
        }
    }
}
