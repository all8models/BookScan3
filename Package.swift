// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "BookScanModules",
    defaultLocalization: "ko",
    platforms: [
        .iOS("18.0"),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "BookScanCore",
            targets: ["BookScanCore"]
        ),
        .library(
            name: "BookScanStorage",
            targets: ["BookScanStorage"]
        ),
        .library(
            name: "BookScanVision",
            targets: ["BookScanVision"]
        ),
        .library(
            name: "BookScanNetwork",
            targets: ["BookScanNetwork"]
        ),
    ],
    targets: [
        // MARK: - Core Domain Models & Protocols
        .target(
            name: "BookScanCore",
            path: "BookScan3/Models"
        ),
        // MARK: - Storage & Persistence Engine
        .target(
            name: "BookScanStorage",
            dependencies: ["BookScanCore"],
            path: "BookScan3/Services",
            sources: ["StorageManager.swift", "Protocols.swift", "BookSearchIndexer.swift"]
        ),
        // MARK: - Vision, Document Dewarping & OCR
        .target(
            name: "BookScanVision",
            dependencies: ["BookScanCore"],
            path: "BookScan3/Services",
            sources: [
                "BookSpreadDetector.swift",
                "CylindricalDewarpService.swift",
                "DewarpEngine.swift",
                "ImageProcessor.swift",
                "CameraService.swift"
            ]
        ),
        // MARK: - HTTP Transfer & Networking
        .target(
            name: "BookScanNetwork",
            dependencies: ["BookScanCore"],
            path: "BookScan3/Services",
            sources: ["PCTransferServer.swift"]
        ),
    ]
)
