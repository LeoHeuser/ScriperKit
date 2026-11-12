// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ScriperKit",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ScriperKit",
            targets: ["ScriperKit"]
        )
    ],
    targets: [
        // The app side only. The runner in `Scripts/` is run from the package checkout and is
        // not part of any target, so it never lands in an app bundle.
        .target(name: "ScriperKit")
    ]
)
