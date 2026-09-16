import Foundation
import Testing
@testable import VoinpProviders

@Suite("100ms フレームへの分割")
struct PCM16FramePacketizerTests {

    /// 24kHz / Int16 / 100ms = 4,800 バイト。この定数が動くと送信レートが変わる。
    @Test("フレーム長は 4,800 バイト")
    func frameSize() {
        #expect(PCM16FramePacketizer.bytesPerFrame == 4_800)
        #expect(PCM16FramePacketizer.sampleRate == 24_000, "16000 は Realtime に拒否される")
    }

    @Test("揃った分だけ返し、端数は繰り越す")
    func carriesRemainder() {
        var p = PCM16FramePacketizer()
        #expect(p.append(Data(count: 1_000)).isEmpty)
        #expect(p.pendingByteCount == 1_000)

        let frames = p.append(Data(count: 4_000))     // 計 5,000
        #expect(frames.count == 1)
        #expect(frames[0].count == 4_800)
        #expect(p.pendingByteCount == 200)
    }

    @Test("一度に複数フレーム分が来たら全部返す")
    func multipleFrames() {
        var p = PCM16FramePacketizer()
        let frames = p.append(Data(count: 4_800 * 3 + 5))
        #expect(frames.count == 3)
        #expect(p.pendingByteCount == 5)
    }

    /// **端数を捨てると発話の末尾が消える。** 「最後の一言だけ入らない」という形で出る。
    @Test("停止時の端数は無音で埋めて送る")
    func flushPadsWithSilence() {
        var p = PCM16FramePacketizer()
        _ = p.append(Data(repeating: 0x7F, count: 100))
        let tail = p.flushWithSilencePadding()
        #expect(tail?.count == 4_800, "1 フレームに満たなくても捨てない")
        #expect(tail?.prefix(100) == Data(repeating: 0x7F, count: 100), "元の音は保つ")
        #expect(tail?.suffix(4_700) == Data(count: 4_700), "残りは無音")
        #expect(p.flushWithSilencePadding() == nil, "2 回目は何も出ない")
    }

    @Test("バイト列は分割で失われない")
    func noBytesLost() {
        var p = PCM16FramePacketizer()
        let source = Data((0..<10_000).map { UInt8($0 % 251) })
        var rebuilt = Data()
        for frame in p.append(source) { rebuilt.append(frame) }
        if let tail = p.flushWithSilencePadding() { rebuilt.append(tail) }
        #expect(rebuilt.prefix(source.count) == source)
    }
}

@Suite("接続前の音声の保持")
struct PrerollBufferTests {

    /// ハンドシェイクは実測 1,089ms。その間の音声を落とすと発話の頭が消える。
    @Test("溜めて順番どおりに取り出せる")
    func drainsInOrder() {
        var b = PrerollBuffer()
        for i in 0..<5 { b.append(Data([UInt8(i)])) }
        #expect(b.drain().map { $0[0] } == [0, 1, 2, 3, 4])
        #expect(b.isEmpty, "取り出したら空になる")
    }

    /// 詰まったときに無制限にメモリを食わない。AudioCapture の bufferingNewest と同じ思想。
    @Test("上限を超えたら古いものから捨てる")
    func dropsOldest() {
        var b = PrerollBuffer(limit: 3)
        for i in 0..<5 { b.append(Data([UInt8(i)])) }
        #expect(b.count == 3)
        #expect(b.drain().map { $0[0] } == [2, 3, 4], "新しいほうを残す")
    }

    /// 既定の 15 秒はハンドシェイク実測値に対して十分な余裕がある。
    @Test("既定の上限は 15 秒分")
    func defaultLimitIsFifteenSeconds() {
        var b = PrerollBuffer()
        for _ in 0..<200 { b.append(Data(count: PCM16FramePacketizer.bytesPerFrame)) }
        #expect(b.count == 150)
    }
}

@Suite("NaN でクラッシュしないこと")
struct PCM16EncoderTests {

    /// `Int16(Float.nan)` は Swift で trap する。素通しさせると録音経路ごと落ちる。
    @Test("NaN と Infinity を無音に倒す")
    func nanBecomesSilence() {
        let samples: [Float] = [.nan, .infinity, -.infinity, 0.5, -0.5]
        let data = samples.withUnsafeBufferPointer {
            PCM16LittleEndianEncoder.encode(floatSamples: $0.baseAddress!, frameCount: 5)
        }
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(values[0] == 0, "NaN は無音")
        #expect(values[1] == Int16.max, "+Inf は上限へクリップ")
        #expect(values[2] == Int16.min + 1 || values[2] == Int16.min, "-Inf は下限へ")
        #expect(values[3] > 0 && values[4] < 0)
    }

    /// Infinity * 0 のように、掛けた後に NaN が生まれる経路もある。
    @Test("ゲインを掛けた後に NaN になっても落ちない")
    func nanAfterGain() {
        let samples: [Float] = [.infinity]
        let data = samples.withUnsafeBufferPointer {
            PCM16LittleEndianEncoder.encode(floatSamples: $0.baseAddress!, frameCount: 1, gain: 0)
        }
        #expect(data.withUnsafeBytes { $0.bindMemory(to: Int16.self)[0] } == 0)
    }
}
