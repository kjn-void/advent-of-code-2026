// swift-tools-version: 6.2
import PackageDescription

/// Compiler settings shared by every Swift target. Swift 6 language mode (strict
/// concurrency) is the default for tools-version 6.x; these add a few more upcoming
/// features that catch sloppy code early.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "AdventOfCode2026",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "aoc2026", targets: ["aoc2026"]),
        .executable(name: "aoc2026-viz", targets: ["AoCViz"]),
    ],
    targets: [
        // Build tool plugin: compiles every .metal file under a target's Shaders/ directory into
        // <Target>.metallib (with AoCShared on the include path and strict warnings). The Shaders
        // directories are `exclude`d so SwiftPM/Xcode don't also try to compile them natively.
        .plugin(name: "MetalCompiler", capability: .buildTool()),

        // C header-only module with structs shared bit-for-bit between Swift and Metal,
        // plus Metal-only kernel helpers (AoCKernels.h).
        .target(name: "AoCShared"),

        // Core: Solution protocol, input loading/fetching, parsing helpers, GPU wrapper, benchmarking.
        .target(
            name: "AoCKit",
            dependencies: ["AoCShared"],
            swiftSettings: swiftSettings
        ),

        // Metal renderer + scene protocol used by the visualizer.
        .target(
            name: "AoCRender",
            dependencies: ["AoCKit", "AoCShared"],
            exclude: ["Shaders"],  // compiled by the MetalCompiler plugin, not SwiftPM itself
            swiftSettings: swiftSettings,
            plugins: ["MetalCompiler"]
        ),

        // One DayNN.swift (+ Shaders/DayNN.metal) per puzzle.
        .target(
            name: "Solutions",
            dependencies: ["AoCKit", "AoCRender", "AoCShared"],
            exclude: ["Shaders"],  // compiled by the MetalCompiler plugin, not SwiftPM itself
            swiftSettings: swiftSettings,
            plugins: ["MetalCompiler"]
        ),

        .executableTarget(
            name: "aoc2026",
            dependencies: ["AoCKit", "Solutions"],
            swiftSettings: swiftSettings
        ),

        .executableTarget(
            name: "AoCViz",
            dependencies: ["AoCKit", "AoCRender", "Solutions"],
            swiftSettings: swiftSettings
        ),

        .testTarget(
            name: "SolutionsTests",
            dependencies: ["AoCKit", "AoCRender", "AoCShared", "Solutions"],
            swiftSettings: swiftSettings
        ),
    ]
)
