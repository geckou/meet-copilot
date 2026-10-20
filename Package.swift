// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "meet-copilot",
    platforms: [.macOS(.v13)],
    targets: [
        // 音声の2トラック取得。ScreenCaptureKit でアプリ音声、AVAudioEngine でマイク
        .target(name: "Capture"),
        // 外部プロセスとの受け渡しの共通部分（起動、標準入力への書き込み、1行1件の JSON の読み取り、終了待ち）
        .target(name: "ExternalProcess"),
        // 外部の文字起こしプロセスとの受け渡し。文字起こし自体は外部（scripts/）に任せる
        .target(name: "Transcription", dependencies: ["ExternalProcess"]),
        // 外部の候補抽出プロセスとの受け渡し。抽出自体は外部（scripts/）に任せる
        .target(name: "Candidates", dependencies: ["ExternalProcess"]),
        .executableTarget(name: "meet-copilot", dependencies: ["Capture", "ExternalProcess", "Transcription", "Candidates"]),
        .testTarget(name: "CaptureTests", dependencies: ["Capture"]),
        .testTarget(name: "ExternalProcessTests", dependencies: ["ExternalProcess"]),
        .testTarget(name: "TranscriptionTests", dependencies: ["Transcription"]),
        .testTarget(name: "CandidatesTests", dependencies: ["Candidates"]),
    ]
)
