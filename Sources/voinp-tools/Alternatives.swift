import AVFoundation
import Foundation
import Speech
import VoinpCore

/// **「候補の中に正解が入っているか」を測るための道具。**
///
/// 候補から選び直す（再ランキング）という案は、すべてこの 1 点に乗っている。
/// `均等の` の候補が `[金等の, 近藤の]` しかないなら、どんな判定器を足しても
/// `kintone` は選べない。作る前にここを潰す。
///
/// ## マイクではなく音声ファイルを読む
///
/// 1. CLI をターミナルから起動するとマイクの許可が**ターミナルに付く**。
///    そこを避けるために `.app` を作るのは、測るだけの道具には重すぎる。
/// 2. **同じ音声で辞書あり／なしを比べたい。** 喋り直すと条件が変わって比較にならない。
///
/// QuickTime Player の「新規オーディオ収録」で録って渡せばよい（m4a で読める）。
enum AlternativesProbe {

    static func run(path: String, terms: [String]) async {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("❌ ファイルがありません: \(url.path)")
            exit(1)
        }

        let locale = Locale(identifier: "ja-JP")
        guard let canonical = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            print("❌ ja-JP が未対応です")
            exit(1)
        }

        // **暫定結果は切る。** 測りたいのは確定した候補の集合。
        let transcriber = DictationTranscriber(
            locale: canonical,
            contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.alternativeTranscriptions],
            attributeOptions: [.transcriptionConfidence])

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated,
                                            modelRetention: .processLifetime))

        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]) else {
            print("❌ 対応する音声フォーマットが取れません")
            exit(1)
        }

        if !terms.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = terms
            try? await analyzer.setContext(ctx)
            print("辞書: \(terms.count) 語 — \(terms.joined(separator: ", "))")
        } else {
            print("辞書: なし")
        }
        print("音声: \(url.lastPathComponent)")
        print(String(repeating: "─", count: 70))

        let parts = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)

        let printing = Task {
            var index = 0
            do {
                for try await result in transcriber.results {
                    guard result.isFinal else { continue }
                    index += 1
                    report(index: index, result: result)
                }
            } catch {
                print("❌ 認識に失敗: \(error)")
            }
        }

        do {
            try await analyzer.start(inputSequence: parts.stream)
            _ = try feed(url: url, target: target, into: parts.continuation)
            parts.continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            print("❌ 解析に失敗: \(error)")
            parts.continuation.finish()
        }
        await printing.value
    }

    // MARK: - 出力

    private static func report(index: Int, result: DictationTranscriber.Result) {
        let text = String(result.text.characters)
        print("\n[\(index)] \(text)")

        // 信頼度は文字の属性として付く。**低い区間が「どこを疑えばよいか」を教える。**
        // LLM を呼ばずに怪しい箇所を絞れるのが、この属性の価値。
        var runs: [(String, Double)] = []
        for run in result.text.runs {
            let piece = String(result.text[run.range].characters)
            guard !piece.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            runs.append((piece, confidence(of: run, in: result.text)))
        }
        if runs.contains(where: { $0.1 >= 0 }) {
            let body = runs.map { $0.1 < 0 ? $0.0 : String(format: "%@(%.2f)", $0.0, $0.1) }
            print("    信頼度: \(body.joined(separator: " "))")
        }

        if result.alternatives.isEmpty {
            print("    候補: なし  ← 再ランキングの余地がない")
        } else {
            for (i, alt) in result.alternatives.enumerated() {
                print("    候補\(i + 1): \(String(alt.characters))")
            }
        }
    }

    /// 信頼度属性を取り出す。取れなければ負値を返す（「無い」と「0.0」を混同しない）。
    private static func confidence(
        of run: AttributedString.Runs.Run, in text: AttributedString
    ) -> Double {
        let sliced = text[run.range]
        for r in sliced.runs {
            if let c = r.transcriptionConfidence { return Double(c) }
        }
        return -1
    }

    // MARK: - 音声を流し込む

    /// ファイルを読み、必要なら変換して 1 チャンクずつ渡す。
    /// **レートを書き換えずに変換する。** 嘘のフォーマットを付けると
    /// 無言で倍速になり、認識だけが静かに壊れる（実機で踏んだ）。
    private static func feed(
        url: URL, target: AVAudioFormat,
        into continuation: AsyncStream<AnalyzerInput>.Continuation
    ) throws -> Int {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let converter = source == target ? nil : AVAudioConverter(from: source, to: target)
        if converter == nil, source != target {
            throw NSError(domain: "voinp", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(source) → \(target) の変換器を作れません"])
        }

        let chunkFrames: AVAudioFrameCount = 4_096
        var sent = 0
        // **`framePosition` で止めること。**
        // 終端に達したあと `read(into:frameCount:)` を呼ぶと戻ってこない
        // （frameLength == 0 で抜ける書き方だと、そこで固まる。実測で踏んだ）。
        while file.framePosition < file.length {
            guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunkFrames)
            else { break }
            try file.read(into: input, frameCount: chunkFrames)
            if input.frameLength == 0 { break }

            guard let converter else {
                continuation.yield(AnalyzerInput(buffer: input))
                sent += 1
                continue
            }
            let ratio = target.sampleRate / source.sampleRate
            let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1_024
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
            else { break }

            let feeder = OneShot(input)
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in feeder.next(status) }
            if let error { throw error }
            if output.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: output))
                sent += 1
            }
        }
        return sent
    }
}

/// 手持ちを 1 度だけ渡す入力源。
/// **渡し終えたら `.noDataNow`。`.endOfStream` にすると変換器がそこで閉じ、
/// 次のチャンクが 1 フレームも出てこなくなる**（`AudioResampler` と同じ罠）。
private final class OneShot: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var consumed = false
    init(_ b: AVAudioPCMBuffer) { buffer = b }
    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        if consumed { status.pointee = .noDataNow; return nil }
        consumed = true
        status.pointee = .haveData
        return buffer
    }
}
