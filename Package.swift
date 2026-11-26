// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Datawatcher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DatawatcherCore", targets: ["DatawatcherCore"]),
        .executable(name: "Datawatcher", targets: ["Datawatcher"])
    ],
    targets: [
        .target(
            name: "DatawatcherCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("AppKit"),
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .executableTarget(
            name: "Datawatcher",
            dependencies: ["DatawatcherCore"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("Charts"),
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "DatawatcherTests",
            dependencies: ["DatawatcherCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)

