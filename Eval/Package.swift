// swift-tools-version: 6.0

// karui-eval: runs a golden set from Karui for Mac's Grade History window through
// the Second Opinion prompt and variants of it, by way of the person's own
// "Karui Second Opinion" Shortcut, and compares them. A package of its own so the
// kit's Package.swift, which the iPhone app depends on, stays as it is.

import PackageDescription

let package = Package(
    name: "KaruiEval",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .target(name: "KaruiEvalKit", dependencies: [.product(name: "KaruiSorting", package: "karui-mac")]),
        .executableTarget(name: "karui-eval", dependencies: ["KaruiEvalKit"]),
        .testTarget(name: "KaruiEvalKitTests", dependencies: ["KaruiEvalKit"])
    ]
)
