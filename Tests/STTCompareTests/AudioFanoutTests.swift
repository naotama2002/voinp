import Foundation
import Testing
import VoinpCore
@testable import STTCompare

/// 音声の分配。
///
/// **公平に比べるための要**。ここが狂うと、音質の差が精度の差に見える。
@Suite("音声の分配")
struct AudioFanoutTests {

    private func chunk(rate: Double, ms: Int = 100) -> AudioChunk {
        let frames = Int(rate) * ms / 1_000
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<frames { samples[i] = Int16(8_000 * sin(Double(i) * 0.05)) }
        return AudioChunk(
            format: AudioFormatDescription(sampleRate: rate, channelCount: 1, isInt16: true),
            samples: samples.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    private func format(_ rate: Double) -> AudioFormatDescription {
        AudioFormatDescription(sampleRate: rate, channelCount: 1, isInt16: true)
    }

    /// **同じ音声が全エンジンへ届くこと。**
    /// エンジンごとに録り直すと、話し方の違いが結果の違いに化ける。
    @Test("1 本の取り込みが全レーンへ届く")
    func distributesToAllLanes() async {
        let fanout = AudioFanout()
        await fanout.register(engineID: "apple", format: format(16_000))
        await fanout.register(engineID: "openai", format: format(24_000))
        await fanout.register(engineID: "gemini", format: format(16_000))

        let out = await fanout.distribute(chunk(rate: 24_000))
        #expect(out.count == 3, "登録した 3 レーンすべてに届くこと")
        #expect(Set(out.keys) == ["apple", "openai", "gemini"])
    }

    /// **レートはエンジンごとに変える。** 揃えてしまうと、
    /// 要求と違うレートで渡されたエンジンが不利になる。
    @Test("レーンごとに要求のレートへ変換する")
    func convertsPerLane() async {
        let fanout = AudioFanout()
        await fanout.register(engineID: "sixteen", format: format(16_000))
        await fanout.register(engineID: "twentyfour", format: format(24_000))

        let out = await fanout.distribute(chunk(rate: 24_000))
        #expect(out["sixteen"]?.format.sampleRate == 16_000)
        #expect(out["twentyfour"]?.format.sampleRate == 24_000)
    }

    /// 24kHz → 16kHz はサンプル数が 2/3 になる。
    /// 変わっていなければ、フォーマットだけ書き換えて中身は 1.5 倍速のまま。
    @Test("落とした側はサンプル数が減る")
    func downsampleShrinks() async {
        let fanout = AudioFanout()
        await fanout.register(engineID: "sixteen", format: format(16_000))
        await fanout.register(engineID: "twentyfour", format: format(24_000))

        let out = await fanout.distribute(chunk(rate: 24_000))
        let sixteen = out["sixteen"]?.samples.count ?? 0
        let twentyfour = out["twentyfour"]?.samples.count ?? 0
        #expect(twentyfour == 4_800, "100ms @24kHz Int16 = 4,800 バイト")
        #expect(sixteen > 2_800 && sixteen < 3_600,
                "2/3 程度に減ること。実際は \(sixteen) バイト")
    }

    /// 同じレートのレーンには、同じバイト列がそのまま届くこと。
    @Test("同じレートなら中身は変わらない")
    func passThroughWhenSameRate() async {
        let fanout = AudioFanout()
        await fanout.register(engineID: "same", format: format(24_000))
        let source = chunk(rate: 24_000)
        let out = await fanout.distribute(source)
        #expect(out["same"]?.samples == source.samples)
    }

    /// 連続したチャンクが全部通ること。
    /// 変換器の使い回しで 2 個目以降が落ちる不具合を voinp 側で踏んだ。
    @Test("連続したチャンクが全部通る")
    func allChunksPass() async {
        let fanout = AudioFanout()
        await fanout.register(engineID: "sixteen", format: format(16_000))
        var delivered = 0
        for _ in 0..<10 {
            if await fanout.distribute(chunk(rate: 24_000))["sixteen"] != nil { delivered += 1 }
        }
        #expect(delivered == 10, "10 個すべて。2 個目以降が落ちていないこと")
    }

    /// **水増ししない前提。** 取り込みは各エンジンの最高要求に合わせる。
    @Test("取り込みは最高要求のレート")
    func captureUsesHighestRate() {
        #expect(ComparisonAudioFormat.capture.sampleRate == 24_000,
                "16kHz から 24kHz へ水増しすると、された側が不利になる")
        #expect(ComparisonAudioFormat.capture.sampleRate
                >= Double(GeminiLiveConfig.sampleRate))
        #expect(ComparisonAudioFormat.capture.sampleRate
                >= Double(GPTLiveConfig.sampleRate))
    }
}
