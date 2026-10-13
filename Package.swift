// swift-tools-version: 6.1
import Foundation
import PackageDescription

/// The binaries release of this repository: `database` publishes its build of the engine under this tag. `NORVO_LOCAL=1` uses `Artifacts/`, which
/// `scripts/use-local.sh` links to a local `database` build.
let release = "binaries-v0.0.2"
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
            checksum: "b7381dd31ea4dc22b59521c5962bbadce0650dbb8505a80d71e14d906db4a5f1"),
        binary(
            "norvo", "norvo.artifactbundle",
            checksum: "e330e64e3aa811104b5cb1161e4f040681203a87f0facc05fbedf9acb9b4948c"),
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
