// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "meet-copilot",
    platforms: [.macOS(.v13)],
    targets: [
        // 音声の2トラック取得。ScreenCaptureKit でアプリ音声、AVAudioEngine でマイク
        .target(name: "Capture"),
        // 外部の文字起こしプロセスとの受け渡し。文字起こし自体は外部（scripts/）に任せる
        .target(name: "Transcription"),
        .executableTarget(name: "meet-copilot", dependencies: ["Capture", "Transcription"]),
        .testTarget(name: "CaptureTests", dependencies: ["Capture"]),
        .testTarget(name: "TranscriptionTests", dependencies: ["Transcription"]),
    ]
)
