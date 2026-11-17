import AoCKit
import Solutions
import Testing

@Suite("Framework helpers")
struct FrameworkTests {
    @Test func integersHandleSignsAndRanges() {
        #expect(Parse.integers(in: "x=-5, y=12") == [-5, 12])
        #expect(Parse.integers(in: "3-4 10-20") == [3, 4, 10, 20])
        #expect(Parse.integers(in: "a-1", signed: false) == [1])
    }

    @Test func linesDropTrailingNewlineButKeepBlankSeparators() {
        let input = Input("a\nb\n\nc\n")
        #expect(input.lines == ["a", "b", "", "c"])
        #expect(input.paragraphs == [["a", "b"], ["c"]])
    }

    @Test func gridRejectsRaggedLines() {
        #expect(throws: SolutionError.self) { try Input("ab\nc\n").grid() }
        let grid = try? Input("ab\ncd\n").grid()
        #expect(grid?.text == "ab\ncd")
        #expect(grid?[1, 1] == UInt8(ascii: "d"))
    }

    @Test func registryResolvesCLINames() {
        #expect(Registry.solution(named: "e1")?.id == Example01.id)
        #expect(Registry.solution(named: "example1")?.id == Example01.id)
        #expect(Registry.solution(named: "1") == nil || Registry.solution(named: "1")?.id.kind == .day)
    }

    @Test func registryIDsAreUnique() {
        let ids = Registry.all.map { $0.id }
        #expect(Set(ids).count == ids.count)
    }
}
