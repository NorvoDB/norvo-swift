// swift-tools-version: 6.1
import Foundation
import PackageDescription

/// The binaries release of this repository: `database` publishes its build of the engine under this tag. `NORVO_LOCAL=1` uses `Artifacts/`, which
/// `scripts/use-local.sh` links to a local `database` build.
let release = "binaries-v0.0.1"
let local = ProcessInfo.processInfo.environment["NORVO_LOCAL"] == "1"

func binary(_ name: String, _ file: String, checksum: String) -> Target {
    local
        ? .binaryTarget(name: name, path: "Artifacts/\(file)")
        : .binaryTarget(
            name: name,
            url: "https://github.com/NorvoDB/norvo-swift/releases/download/\(release)/\(file).zip",
            checksum: checksum
        )
}

let package = Package(
    name: "NorvoLite",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NorvoLite", targets: ["NorvoLite"]),
        .plugin(name: "NorvoCodegen", targets: ["NorvoCodegen"]),
    ],
    targets: [
        binary(
            "CNorvoLite", "CNorvoLite.xcframework",
            checksum: "f38782563851a787f393618110c608d0a40f5031d2f38c8d2892a96f49a8eda8"),
        binary(
            "norvo", "norvo.artifactbundle",
            checksum: "74c497cc4a093cb8f2983688747d11bf33282c2f58ec9ed8ba0dd0e12153f6d0"),
        .target(name: "NorvoLite", dependencies: ["CNorvoLite"]),
        .plugin(name: "NorvoCodegen", capability: .buildTool(), dependencies: ["norvo"]),
        .testTarget(name: "NorvoLiteTests", dependencies: ["NorvoLite"]),
        .testTarget(
            name: "CodegenTests",
            dependencies: ["NorvoLite"],
            exclude: ["schema.nql", "migrations", "operations"],
            plugins: ["NorvoCodegen"]
        ),
    ]
)
