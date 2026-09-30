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
        .executable(name: "TinyPruneDomainCheck", targets: ["TinyPruneDomainCheck"]),
        .library(name: "TinyPruneEngine", targets: ["TinyPruneEngine"]),
        .executable(name: "TinyPruneEngineCheck", targets: ["TinyPruneEngineCheck"]),
        .library(name: "TinyPrunePersistence", targets: ["TinyPrunePersistence"]),
    ],
    targets: [
        .target(name: "TinyPruneDomain"),
        .target(name: "TinyPruneIPC", dependencies: ["TinyPruneDomain"]),
        .executableTarget(name: "TinyPruneAgent", dependencies: ["TinyPruneIPC", "TinyPrunePersistence", "TinyPruneAgentCore"]),
        .executableTarget(name: "TinyPruneApp", dependencies: ["TinyPruneDomain", "TinyPruneIPC"]),
        .executableTarget(name: "tinyprune", dependencies: ["TinyPruneIPC", "TinyPruneDomain"]),
        .executableTarget(name: "TinyPruneDomainCheck", dependencies: ["TinyPruneDomain"]),
        .target(name: "TinyPruneEngine", dependencies: ["TinyPruneDomain"]),
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
