// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TinyPrune",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TinyPruneDomain", targets: ["TinyPruneDomain"]),
        .library(name: "TinyPruneIPC", targets: ["TinyPruneIPC"]),
        .executable(name: "TinyPruneApp", targets: ["TinyPruneApp"]),
        .executable(name: "TinyPruneAgent", targets: ["TinyPruneAgent"]),
        .executable(name: "tinyprune", targets: ["tinyprune"]),
        .executable(name: "TinyPruneUISnapshots", targets: ["TinyPruneUISnapshots"]),
        .executable(name: "TinyPruneFinderExtension", targets: ["TinyPruneFinderExtension"]),
        .executable(name: "TinyPruneDomainCheck", targets: ["TinyPruneDomainCheck"]),
        .executable(name: "TinyPruneEngineCheck", targets: ["TinyPruneEngineCheck"]),
        .library(name: "TinyPrunePersistence", targets: ["TinyPrunePersistence"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.0"),
    ],
    targets: [
        .target(name: "TinyPruneDomain"),
        .target(name: "TinyPruneIPC", dependencies: ["TinyPruneDomain"]),
        .executableTarget(name: "TinyPruneAgent", dependencies: ["TinyPruneIPC", "TinyPrunePersistence", "TinyPruneAgentCore"]),
        .target(name: "TinyPruneUI", dependencies: ["TinyPruneDomain", "TinyPruneIPC"]),
        .executableTarget(
            name: "TinyPruneApp",
            dependencies: ["TinyPruneUI", "TinyPruneDomain", "TinyPruneIPC", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "TinyPruneUISnapshots",
            dependencies: ["TinyPruneUI", "TinyPruneAgentCore", "TinyPrunePersistence", "TinyPruneEngine", "TinyPruneDomain", "TinyPruneIPC"]
        ),
        .executableTarget(name: "tinyprune", dependencies: ["TinyPruneIPC", "TinyPruneDomain"]),
        .executableTarget(
            name: "TinyPruneFinderExtension",
            dependencies: ["TinyPruneIPC", "TinyPruneDomain"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(name: "TinyPruneDomainCheck", dependencies: ["TinyPruneDomain"]),
        .target(name: "TinyPruneEngine", dependencies: ["TinyPruneDomain", "TinyPruneIPC"]),
        .systemLibrary(name: "CSQLite"),
        .target(name: "TinyPrunePersistence", dependencies: ["CSQLite", "TinyPruneDomain", "TinyPruneEngine"]),
        .target(name: "TinyPruneAgentCore", dependencies: ["TinyPruneIPC", "TinyPrunePersistence", "TinyPruneEngine", "TinyPruneDomain"]),
        .testTarget(name: "TinyPruneAgentCoreTests", dependencies: ["TinyPruneAgentCore", "TinyPruneIPC", "TinyPrunePersistence", "TinyPruneEngine", "TinyPruneDomain"]),
        .testTarget(name: "TinyPrunePersistenceTests", dependencies: ["TinyPrunePersistence", "TinyPruneDomain", "TinyPruneEngine"]),
        .testTarget(name: "TinyPruneEngineTests", dependencies: ["TinyPruneEngine", "TinyPruneDomain"]),
        .executableTarget(name: "TinyPruneEngineCheck", dependencies: ["TinyPruneEngine", "TinyPruneDomain", "TinyPrunePersistence", "TinyPruneAgentCore", "TinyPruneIPC"]),
        .testTarget(name: "TinyPruneDomainTests", dependencies: ["TinyPruneDomain"]),
        .testTarget(name: "TinyPruneIPCTests", dependencies: ["TinyPruneIPC"]),
    ]
)
