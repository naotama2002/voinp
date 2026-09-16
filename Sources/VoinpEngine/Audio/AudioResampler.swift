import AVFoundation
import Foundation
import VoinpCore

/// 連続して届くチャンクを、目的のフォーマットへ変換し続ける。
///
/// クラウド認識から退避するときに要る。Realtime は 24kHz 固定（16000 は拒否される）で、
/// Apple のエンジンは 16kHz を要求するため、保持した音声を流し直すには変換が要る。
/// **変換しないと無言で 1.5 倍速になり、エラーも出ないまま認識だけが壊れる。**
///
/// ## `.endOfStream` を返さないこと
///
/// `AVAudioConverter` は入力を要求するたびにブロックを呼ぶ。
/// 手持ちを渡し終えたときに `.endOfStream` を返すと、**変換器はそこで終端したとみなす**。
/// 同じ変換器を次のチャンクでも使うので、2 個目以降が 1 フレームも出てこなくなる。
/// 実機で「音量は出ているのに 0 文字」という形で踏んだ。
///
/// 正しいのは `.noDataNow`。「いまは無いが後で来る」という意味で、変換器は終端しない。
///
/// ## 変換器を作り直さないこと
///
/// リサンプルは内部にフィルタの状態を持つ。チャンクごとに作り直すと継ぎ目にノイズが乗る。
/// 入力フォーマットが変わったときだけ作り直す。
public final class AudioResampler {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    public init(target: AVAudioFormat) {
        self.target = target
    }

    /// チャンクを目的のフォーマットのバッファにする。変換不要ならそのまま包む。
    /// 変換できなければ `nil`。**呼び出し側は捨てずにログへ出すこと**（無言で落ちると原因が掴めない）。
    public func buffer(for chunk: AudioChunk) -> AVAudioPCMBuffer? {
        let matches = chunk.format.sampleRate == target.sampleRate
            && chunk.format.channelCount == Int(target.channelCount)
        if matches { return Self.wrap(chunk, as: target) }

        guard let source = AVAudioFormat(
            commonFormat: chunk.format.isInt16 ? .pcmFormatInt16 : .pcmFormatFloat32,
            sampleRate: chunk.format.sampleRate,
            channels: AVAudioChannelCount(chunk.format.channelCount),
            interleaved: chunk.format.isInt16),
            let input = Self.wrap(chunk, as: source),
            let converter = converter(for: source)
        else { return nil }

        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        else { return nil }

        let feeder = SingleBufferSource(input)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in feeder.next(status) }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private func converter(for source: AVAudioFormat) -> AVAudioConverter? {
        if let existing = converter, sourceFormat == source { return existing }
        let made = AVAudioConverter(from: source, to: target)
        converter = made
        sourceFormat = source
        return made
    }

    /// バイト列を `AVAudioPCMBuffer` に包む。**レートは書き換えない。**
    /// ここで嘘のフォーマットを付けると、倍速や半速になったまま誰も気づかない。
    static func wrap(_ chunk: AudioChunk, as format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let bytesPerSample = chunk.format.isInt16
            ? MemoryLayout<Int16>.size : MemoryLayout<Float>.size
        let frames = chunk.samples.count / bytesPerSample
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        chunk.samples.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            if let destination = buffer.int16ChannelData {
                destination[0].update(from: base.assumingMemoryBound(to: Int16.self),
                                      count: frames)
            } else if let destination = buffer.floatChannelData {
                destination[0].update(from: base.assumingMemoryBound(to: Float.self),
                                      count: frames)
            }
        }
        return buffer
    }
}

/// 変換器へ手持ちのバッファを 1 度だけ渡す。
///
/// **渡し終えたら `.noDataNow`。`.endOfStream` にしない。**
/// 終端を伝えると変換器がそこで閉じ、使い回している次のチャンクが変換されなくなる。
/// 変換は同期的に 1 回だけ回るので、`@unchecked Sendable` で包む。
final class SingleBufferSource: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var consumed = false

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        if consumed { status.pointee = .noDataNow; return nil }
        consumed = true
        status.pointee = .haveData
        return buffer
    }
}
