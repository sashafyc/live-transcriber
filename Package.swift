// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LiveTranscriber",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "LiveTranscriber",
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
