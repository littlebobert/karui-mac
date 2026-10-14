// swift-tools-version: 6.0

// KaruiLinkKit: the part of the Mac app that the iPhone app shares, so both
// identify a notification the same way and agree on what the Mac sends. The Mac
// app itself is the XcodeGen project described by project.yml.

import PackageDescription

let package = Package(
    name: "KaruiLinkKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v17)
    ],
    products: [
        .library(name: "KaruiLinkKit", targets: ["KaruiLinkKit"])
    ],
    targets: [
        .target(name: "KaruiLinkKit"),
        .testTarget(name: "KaruiLinkKitTests", dependencies: ["KaruiLinkKit"])
    ]
)
