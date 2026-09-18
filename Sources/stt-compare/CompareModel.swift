import AppKit
import Foundation
import Observation
import STTCompare
import SwiftUI
import VoinpCore
import VoinpEngine

/// 比較の進行役。マイクを 1 回開き、取り込みを各エンジンへ配る。
@Observable
@MainActor
final class CompareModel {

    private(set) var results: [EngineResult] = []
    private(set) var isRecording = false
    private(set) var note: String?
    var script = ""

    let engines: [Engine]
    private let capture = AudioCapture()
    private let fanout = AudioFanout()
    private var run: ComparisonRun?
    private var pump: Task<Void, Never>?
    private var updates: Task<Void, Never>?

    init(engines: [Engine]) {
        self.engines = engines
        self.results = engines.map { EngineResult(id: $0.id, displayName: $0.displayName) }
    }

    /// 音声の送信先を常に見せる。**3 ベンダーへ同時に出る道具**なので、
    /// 何が起きているか分からないまま使われる状態にしない。
    var egressSummary: String {
        let cloud = engines.filter { $0.id != "apple" }.map(\.displayName)
        guard !cloud.isEmpty else { return "音声はこの Mac から出ません" }
        return "音声を送信: " + cloud.joined(separator: " / ")
    }

    func toggle() async {
        isRecording ? await stop() : await start()
    }

    private func start() async {
        note = nil
        results = engines.map { EngineResult(id: $0.id, displayName: $0.displayName) }

        for engine in engines {
            await fanout.register(engineID: engine.id, format: engine.format)
        }

        let run = ComparisonRun(engines: engines)
        self.run = run

        updates = Task { [weak self] in
            for await update in run.updates {
                await MainActor.run { self?.results = update.results }
            }
        }

        let request = TranscriptionRequest(
            locale: Locale(identifier: "ja-JP"),
            termHints: [],                 // 比較では全エンジン同条件にする
            wantsPartialResults: true,
            punctuation: true)
        await run.start(request: request)

        do {
            // **マイクは 1 回だけ開く。** エンジンごとに録り直すと、
            // 話し方の違いが結果の違いに化ける。
            let stream = try await capture.start(format: ComparisonAudioFormat.capture) { _ in }
            isRecording = true
            pump = Task { [weak self] in
                for await chunk in stream {
                    guard let self else { break }
                    let lanes = await self.fanout.distribute(chunk)
                    for (id, converted) in lanes {
                        await run.append(converted, for: id)
                    }
                }
            }
        } catch {
            note = "マイクを開けません: \((error as NSError).localizedDescription)"
            await run.cancel()
            self.run = nil
        }
    }

    private func stop() async {
        isRecording = false
        pump?.cancel()
        await capture.stop()
        await run?.stop()
    }

    /// 結果を表にしてコピーする。**そのまま社内に貼れる形**にしておく。
    func copyResults() {
        var lines: [String] = []
        if !script.isEmpty { lines.append("台本: \(script)"); lines.append("") }
        for result in results {
            lines.append("## \(result.displayName)")
            let first = result.firstTextMs.map { "\($0) ms" } ?? "—"
            let final = result.finalizeMs.map { "\($0) ms" } ?? "—"
            lines.append("初出 \(first) / 確定 \(final)")
            lines.append(result.text.isEmpty ? "(結果なし)" : result.text)
            if case .failed(let why) = result.state { lines.append("失敗: \(why)") }
            lines.append("")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        note = "結果をコピーしました"
    }
}
