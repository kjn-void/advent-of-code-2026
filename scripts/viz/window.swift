// Window helper for the live aoc2026-viz visualizer. Run via scripts/viz/tool.sh window ...
//
//   window list <pid>              every window the process owns: id, layer, on-screen, bounds
//   window wait <pid> [seconds]    wait (default 20 s) for its content window; prints "<id> <bounds>"
//   window capture <pid> <out.png> capture ONLY that content window (needs Screen Recording permission)
//
// It only ever looks at windows owned by <pid>, and captures by window id: never the full screen.
// Needs the WindowServer, so run it outside agent sandboxes (inside one the window list is empty).
import CoreGraphics
import Foundation

struct Window {
    let id: Int
    let layer: Int
    let onScreen: Bool
    let bounds: CGRect

    /// The SwiftUI content window, as opposed to the ~30 px menu-bar strips the app also owns.
    var isContent: Bool { layer == 0 && onScreen && bounds.width >= 200 && bounds.height >= 200 }

    var summary: String {
        "\(id) layer \(layer) \(onScreen ? "on-screen" : "off-screen") "
            + "\(Int(bounds.width))x\(Int(bounds.height)) at (\(Int(bounds.minX)), \(Int(bounds.minY)))"
    }
}

func windows(of pid: Int32) -> [Window] {
    let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return all.compactMap { info in
        guard (info[kCGWindowOwnerPID as String] as? Int).map(Int32.init) == pid,
            let id = info[kCGWindowNumber as String] as? Int
        else { return nil }
        let boundsInfo = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary) ?? .zero
        return Window(
            id: id,
            layer: info[kCGWindowLayer as String] as? Int ?? -1,
            onScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false,
            bounds: bounds)
    }
}

func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("window: \(message)\n".utf8))
    exit(code)
}

let usage = "usage: window list <pid> | wait <pid> [seconds] | capture <pid> <out.png>"
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, let pid = Int32(args[1]) else { fail(usage, code: 2) }

switch args[0] {
case "list":
    let owned = windows(of: pid)
    for window in owned { print(window.summary) }
    print("\(owned.count) window(s) owned by pid \(pid)\(isAlive(pid) ? "" : " (process is not running)")")

case "wait":
    let timeout = args.count > 2 ? Double(args[2]) ?? 20 : 20
    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
        if let window = windows(of: pid).first(where: \.isContent) {
            print(window.summary)
            exit(0)
        }
        if !isAlive(pid) { fail("pid \(pid) exited before opening a window (see its log)", code: 3) }
        Thread.sleep(forTimeInterval: 0.25)
    }
    let owned = windows(of: pid)
    fail(
        "no content window after \(Int(timeout)) s; pid \(pid) owns \(owned.count) window(s):\n"
            + owned.map { "  \($0.summary)" }.joined(separator: "\n")
            + "\n  (0 windows: inside an agent sandbox, or AppKit never opened one; try `sample \(pid) 1`)")

case "capture":
    guard args.count == 3 else { fail(usage, code: 2) }
    let out = args[2]
    guard let window = windows(of: pid).first(where: \.isContent) else {
        fail("pid \(pid) has no on-screen content window (run `window list \(pid)`)")
    }
    try? FileManager.default.removeItem(atPath: out)
    let task = Process()
    task.executableURL = URL(filePath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-o", "-l", "\(window.id)", out]  // -l: this window only
    try task.run()
    task.waitUntilExit()
    let size = (try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? nil
    guard task.terminationStatus == 0, let size, size > 0 else {
        fail(
            "screencapture of window \(window.id) failed: the hosting terminal probably lacks Screen Recording "
                + "permission. Use offscreen snapshots instead: scripts/viz/frames.sh <puzzle> <pos>...")
    }
    print("\(out): window \(window.summary)")

default:
    fail(usage, code: 2)
}
