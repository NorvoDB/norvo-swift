import Foundation
import PackagePlugin

/// Runs `norvo codegen swift` over the target's directory: schema.nql, migrations/ and every other .nql.
@main
struct NorvoCodegen: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let dir = target.directoryURL
        let inputs = try FileManager.default
            .subpathsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".nql") }
            .map { dir.appending(path: $0) }
        guard !inputs.isEmpty else { return [] }
        let output = context.pluginWorkDirectoryURL.appending(path: "Norvo.generated.swift")
        return [
            .buildCommand(
                displayName: "norvo codegen swift \(target.name)",
                executable: try context.tool(named: "norvo").url,
                arguments: ["codegen", "swift", dir.path, "--out", output.path],
                inputFiles: inputs,
                outputFiles: [output]
            )
        ]
    }
}

#if canImport(XcodeProjectPlugin)
    import XcodeProjectPlugin

    /// The same, for an Xcode app target: the project is the directory holding the target's `schema.nql`.
    extension NorvoCodegen: XcodeBuildToolPlugin {
        func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
            let inputs = target.inputFiles.map(\.url).filter { $0.pathExtension == "nql" }
            guard let schema = inputs.first(where: { $0.lastPathComponent == "schema.nql" }) else { return [] }
            let dir = schema.deletingLastPathComponent()
            let output = context.pluginWorkDirectoryURL.appending(path: "Norvo.generated.swift")
            return [
                .buildCommand(
                    displayName: "norvo codegen swift \(target.displayName)",
                    executable: try context.tool(named: "norvo").url,
                    arguments: ["codegen", "swift", dir.path, "--out", output.path],
                    inputFiles: inputs,
                    outputFiles: [output]
                )
            ]
        }
    }
#endif
