// swift-tools-version: 5.9
import Foundation
import PackageDescription

let package = Package(
    name: "Companion",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "Companion", targets: ["Companion"])
    ],
    targets: [
        .executableTarget(
            name: "Companion",
            path: "macos-menu-bar",
            exclude: [
                "CompanionMCP.swift"
            ],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Combine"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        )
    ]
)
