import AVFoundation
import Foundation
import Testing
import VoinpCore
@testable import VoinpEngine

/// 退避時の再サンプル。
///
/// **実機で「音量は出ているのに 0 文字」を踏んだ箇所。**
/// 変換器を使い回しているのにチャンクごとに `.endOfStream` を返していたため、
/// 2 個目以降が 1 フレームも出てこなかった。
@Suite("音声の再サンプル")
struct AudioResamplerTests {

    private func target(_ rate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate,
                      channels: 1, interleaved: true)!
    }

    /// 100ms 分の 24kHz Int16 mono。無音ではなく振幅を入れる
    /// （無音だと変換の成否が判別しにくい）。
    private func chunk(rate: Double, ms: Int = 100) -> AudioChunk {
        let frames = Int(rate) * ms / 1_000
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            samples[i] = Int16(8_000 * sin(Double(i) * 0.05))
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return AudioChunk(
            format: AudioFormatDescription(sampleRate: rate, channelCount: 1, isInt16: true),
            samples: data)
    }

    /// **一番効く検査。** 1 個目だけでなく、続くチャンクも全部変換されること。
    @Test("連続したチャンクが全部変換される")
    func allChunksConvert() {
        let resampler = AudioResampler(target: target(16_000))
        var converted = 0
        var totalFrames: AVAudioFrameCount = 0
        for _ in 0..<10 {
            if let out = resampler.buffer(for: chunk(rate: 24_000)) {
                converted += 1
                totalFrames += out.frameLength
            }
        }
        #expect(converted == 10, "10 個すべて変換されること（2 個目以降が落ちていた）")
        // 24kHz の 100ms × 10 → 16kHz では約 1,600 フレーム × 10
        #expect(totalFrames > 14_000, "フレーム数が 2/3 程度になること: \(totalFrames)")
    }

    @Test("レートが同じなら変換せずそのまま包む")
    func passThroughWhenRatesMatch() {
        let resampler = AudioResampler(target: target(24_000))
        let out = resampler.buffer(for: chunk(rate: 24_000))
        #expect(out?.frameLength == 2_400, "100ms @24kHz = 2,400 フレーム")
        #expect(out?.format.sampleRate == 24_000)
    }

    /// **レートを書き換えないこと。** ここで嘘のフォーマットを付けると
    /// 倍速や半速になったまま誰も気づかない。
    @Test("出力は目的のレートになる")
    func outputHasTargetRate() {
        let resampler = AudioResampler(target: target(16_000))
        let out = resampler.buffer(for: chunk(rate: 24_000))
        #expect(out?.format.sampleRate == 16_000)
    }

    /// 24kHz を 16kHz として解釈すると 1.5 倍速になる。
    /// フレーム数が 2/3 に減っていれば、実際にリサンプルされている。
    @Test("1.5 倍速にならない（フレーム数が 2/3 になる）")
    func doesNotPlayFast() {
        let resampler = AudioResampler(target: target(16_000))
        guard let out = resampler.buffer(for: chunk(rate: 24_000)) else {
            Issue.record("変換できなかった"); return
        }
        // 2,400 フレーム（24kHz/100ms）→ 1,600 フレーム（16kHz/100ms）付近
        #expect(out.frameLength > 1_400 && out.frameLength < 1_800,
                "実際は \(out.frameLength) フレーム")
    }

    @Test("空のチャンクは変換しない")
    func emptyChunkReturnsNil() {
        let resampler = AudioResampler(target: target(16_000))
        let empty = AudioChunk(
            format: AudioFormatDescription(sampleRate: 24_000, channelCount: 1, isInt16: true),
            samples: Data())
        #expect(resampler.buffer(for: empty) == nil)
    }
}
