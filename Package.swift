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
    ],
    targets: [
        .target(name: "TinyPruneDomain"),
        .target(name: "TinyPruneIPC", dependencies: ["TinyPruneDomain"]),
        .executableTarget(name: "TinyPruneAgent", dependencies: ["TinyPruneIPC"]),
        .executableTarget(name: "TinyPruneApp", dependencies: ["TinyPruneDomain", "TinyPruneIPC"]),
        .executableTarget(name: "tinyprune", dependencies: ["TinyPruneIPC"]),
        .executableTarget(name: "TinyPruneDomainCheck", dependencies: ["TinyPruneDomain"]),
        .testTarget(name: "TinyPruneDomainTests", dependencies: ["TinyPruneDomain"]),
        .testTarget(name: "TinyPruneIPCTests", dependencies: ["TinyPruneIPC"]),
    ]
)
