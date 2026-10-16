// swift-tools-version: 6.0

// KaruiLinkKit: the part of the Mac app that the iPhone app shares, so both
// identify a notification the same way and agree on what the Mac sends.
// KaruiSorting: how Karui sorts a notification, shared so the Mac sorts exactly as
// the iPhone does. The Mac app itself is the XcodeGen project described by project.yml.

import PackageDescription

let package = Package(
    name: "KaruiLinkKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(name: "KaruiLinkKit", targets: ["KaruiLinkKit"]),
        .library(name: "KaruiSorting", targets: ["KaruiSorting"])
    ],
    targets: [
        .target(name: "KaruiLinkKit"),
        .target(name: "KaruiSorting", dependencies: ["KaruiLinkKit"]),
        .testTarget(name: "KaruiLinkKitTests", dependencies: ["KaruiLinkKit"])
    ]
)
