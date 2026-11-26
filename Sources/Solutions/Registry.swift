import AoCKit

/// Every solution the CLI, visualizer, tests and benchmarks know about.
/// `scripts/new-day.sh` inserts new days above the marker line, so keep it.
public enum Registry {
    public static let all: [any Solution.Type] = [
        Example01.self,
        Example02.self,
        Example03.self,
            // new-day: insert above
    ].sorted { $0.id < $1.id }

    /// `Identifiable` wrappers for SwiftUI lists. (Avoid `\.id` key paths on `any Solution.Type`:
    /// key paths through existential metatypes crash SILGen in Swift 6.4.2.)
    public static var entries: [Entry] { all.map(Entry.init) }

    public struct Entry: Identifiable, Sendable {
        public let type: any Solution.Type
        public var id: PuzzleID { type.id }
    }

    /// Looks up a solution by CLI name: "3", "03", "day3", "e1", "example1".
    public static func solution(named name: String) -> (any Solution.Type)? {
        let lower = name.lowercased()
        let isExample = lower.hasPrefix("e")
        guard let number = Int(lower.drop { !$0.isNumber }) else { return nil }
        return all.first { $0.id.number == number && ($0.id.kind == .example) == isExample }
    }
}
