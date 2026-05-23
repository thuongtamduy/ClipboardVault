// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ClipboardVault",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ClipboardVault",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]),
        .testTarget(
            name: "ClipboardVaultTests",
            dependencies: ["ClipboardVault"]
        ),
    ]
)
