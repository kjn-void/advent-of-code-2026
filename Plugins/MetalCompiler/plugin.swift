import Foundation
import PackagePlugin

/// Compiles all `.metal` files in a target's `Shaders/` directory into a single `<TargetName>.metallib`, which
/// SwiftPM then bundles as a resource (load it through `Bundle.module`).
///
/// Headers from every C target the target depends on (e.g. `AoCShared/include`) are put on
/// the include path, so kernels can `#include "AoCShared.h"` / `"AoCKernels.h"`.
@main
struct MetalCompiler: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: any Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }

        // Shaders/ is excluded from the target (see Package.swift), so enumerate it directly.
        let shaderDir = target.directoryURL.appending(path: "Shaders", directoryHint: .isDirectory)
        let shaderFiles = files(in: shaderDir)
        let sources = shaderFiles.filter { $0.pathExtension == "metal" }.sorted { $0.path() < $1.path() }
        guard !sources.isEmpty else { return [] }

        let includeDirs = target.recursiveTargetDependencies
            .compactMap { ($0 as? ClangSourceModuleTarget)?.publicHeadersDirectoryURL }
        let headers = (includeDirs.flatMap { files(in: $0) } + shaderFiles).filter { $0.pathExtension == "h" }

        let work = context.pluginWorkDirectoryURL
        let output = work.appending(path: "\(target.name).metallib")
        let moduleCache = work.appending(path: "ModuleCache")

        var arguments = [
            "-sdk", "macosx", "metal",
            "-std=metal3.2",
            "-mmacosx-version-min=15.0",
            "-Wall", "-Wextra",
            // Keep line tables + sources so Xcode's GPU debugger / shader profiler can show kernels.
            "-gline-tables-only", "-frecord-sources",
            "-fmodules-cache-path=\(moduleCache.path(percentEncoded: false))",
        ]
        arguments += ([shaderDir] + includeDirs).map { "-I\($0.path(percentEncoded: false))" }
        arguments += sources.map { $0.path(percentEncoded: false) }
        arguments += ["-o", output.path(percentEncoded: false)]

        return [
            .buildCommand(
                displayName: "Compiling Metal shaders for \(target.name)",
                executable: URL(filePath: "/usr/bin/xcrun"),
                arguments: arguments,
                // The plugin sandbox only allows writes inside the work directory.
                environment: ["TMPDIR": work.path(percentEncoded: false)],
                inputFiles: sources + headers,
                outputFiles: [output]
            )
        ]
    }

    private func files(in directory: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return enumerator?.allObjects as? [URL] ?? []
    }
}
