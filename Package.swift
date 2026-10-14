// swift-tools-version:5.10

import PackageDescription

let package = Package(
    name: "meet-copilot",
    platforms: [.macOS(.v13)],
    targets: [
        // 音声の2トラック取得。ScreenCaptureKit でアプリ音声、AVAudioEngine でマイク
        .target(name: "Capture"),
        .executableTarget(name: "meet-copilot", dependencies: ["Capture"]),
        .testTarget(name: "CaptureTests", dependencies: ["Capture"]),
    ]
)
