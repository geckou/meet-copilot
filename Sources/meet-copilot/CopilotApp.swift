import AppKit
import Candidates
import SwiftUI

/// メニューバー常駐の画面。`swift run meet-copilot ui` で起動する。
/// 録音・文字起こし・候補の抽出・候補を押したときの調査を1画面にまとめる。権限は起動したターミナルに付く。
struct CopilotApp: App {
    /// main.swift から main() の前に入れる。機械用のファイルの置き場所（--out）
    static var outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = CopilotModel(outputDir: CopilotApp.outputDir)

    var body: some Scene {
        MenuBarExtra {
            CopilotView(model: model)
                .onAppear { delegate.model = model }
        } label: {
            Image(systemName: model.state == .idle ? "waveform" : "record.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: CopilotModel?
    private var sigint: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock に出さず、メニューバーだけに置く
        NSApp.setActivationPolicy(.accessory)
        // ターミナルの Ctrl-C でも、録音を止めてから終わる
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                if let model = self?.model { model.quit() } else { NSApp.terminate(nil) }
            }
        }
        source.resume()
        sigint = source
    }
}

struct CopilotView: View {
    @ObservedObject var model: CopilotModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let message = model.message {
                HStack(alignment: .top) {
                    Text(message).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button { model.message = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .font(.callout)
            }
            Divider()
            Text("候補").font(.headline)
            candidates
            Divider()
            Text("文字起こし").font(.headline)
            transcript
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 460, height: 640)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                switch model.state {
                case .idle:
                    Button { model.start() } label: { Label("録音を開始", systemImage: "record.circle") }
                        .keyboardShortcut(.defaultAction)
                case .starting:
                    ProgressView().controlSize(.small)
                    Text("開始中...")
                case .recording:
                    Button { model.stop() } label: { Label("録音を停止", systemImage: "stop.circle") }
                    Text("録音中").foregroundStyle(.red)
                    Text("相手側: " + model.capturedApps.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                case .stopping:
                    ProgressView().controlSize(.small)
                    Text("文字起こしの残りを処理中...")
                }
                Spacer()
            }
            HStack {
                Image(systemName: model.repoPath == nil ? "globe" : "folder")
                Text(model.repoPath ?? "リポジトリ未選択（Web で調べる）")
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(model.repoPath == nil ? .secondary : .primary)
                Spacer()
                Button("選ぶ...") { model.chooseRepo() }
                if model.repoPath != nil {
                    Button("外す") { model.clearRepo() }
                }
            }
            .font(.callout)
        }
    }

    private var candidates: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if model.items.isEmpty {
                    Text("相手が答えを求めている箇所がここに並ぶ")
                        .foregroundStyle(.secondary)
                }
                // 新しい候補を上に
                ForEach(model.items.reversed()) { item in
                    CandidateRow(item: item) { model.ask(item.id) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(formatTime(line.start)).monospacedDigit().foregroundStyle(.secondary)
                            Text(line.speaker).foregroundStyle(line.speaker == "相手" ? .blue : .secondary)
                            Text(line.text).textSelection(.enabled)
                        }
                        .font(.caption)
                        .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
            .onChange(of: model.lines.last?.id) { last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("議事録: " + model.minutesDir.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Button("変更...") { model.chooseMinutesDir() }
                .font(.caption)
                .disabled(model.state != .idle)
            Button("開く") { model.openMinutesDir() }.font(.caption)
            Spacer()
            Button("終了") { model.quit() }
        }
    }
}

private struct CandidateRow: View {
    let item: CopilotModel.Item
    let ask: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(formatTime(item.candidate.at)).monospacedDigit().foregroundStyle(.secondary)
                Text(item.candidate.question).fontWeight(.medium)
                Spacer()
                switch item.status {
                case .inProgress:
                    ProgressView().controlSize(.small)
                case .answered:
                    Button("調べ直す", action: ask)
                default:
                    Button("調べる", action: ask)
                }
            }
            Text("「\(item.candidate.quote)」").font(.caption).foregroundStyle(.secondary)
            switch item.status {
            case .answered(let answer):
                VStack(alignment: .leading, spacing: 4) {
                    Text(answer.answer).textSelection(.enabled)
                    let sources = answer.sources.map { source in source.line.map { "\(source.path):\($0)" } ?? source.path }
                    Text("確度: \(answer.confidence)" + (sources.isEmpty ? "" : "　根拠: " + sources.joined(separator: ", ")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            case .failed(let error):
                Text("調べられなかった: \(error)").font(.caption).foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
    }
}
