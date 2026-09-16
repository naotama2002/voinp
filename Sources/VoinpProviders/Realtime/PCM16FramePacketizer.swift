import Foundation

/// 任意長の PCM16 LE を 100ms の固定長フレームへ切り分ける。
///
/// **固定長にする理由**は 3 つある。
/// 1. `input_audio_buffer.append` の 1 回あたりが揃うので、送信レートが読める
/// 2. 接続前に溜める preroll と、退避時のリプレイの単位が揃う
/// 3. 参考実装（kinopeee/interpreter-openai）が実運用でこの値
///
/// `AudioCapture` は tap のバッファサイズ由来の半端な長さで流れてくるので、
/// ここで揃えないと 1 回の append が 30ms だったり 200ms だったりする。
public struct PCM16FramePacketizer: Sendable {
    /// Realtime API が受けるレート。**16000 は拒否される**（実測）:
    /// "PCM input rate must be 24000, or 16000 for MAI transcription."
    public static let sampleRate = 24_000
    public static let bytesPerSample = 2
    public static let frameDurationMilliseconds = 100
    public static let samplesPerFrame = sampleRate * frameDurationMilliseconds / 1_000
    public static let bytesPerFrame = samplesPerFrame * bytesPerSample   // 4,800

    private var pending = Data()

    public init() {}

    public var pendingByteCount: Int { pending.count }

    /// 溜めて、揃った分だけ返す。端数は次回へ繰り越す。
    public mutating func append(_ pcm16LE: Data) -> [Data] {
        guard !pcm16LE.isEmpty else { return [] }
        pending.append(pcm16LE)
        var frames: [Data] = []
        while pending.count >= Self.bytesPerFrame {
            frames.append(Data(pending.prefix(Self.bytesPerFrame)))
            pending.removeFirst(Self.bytesPerFrame)
        }
        return frames
    }

    /// 停止時に端数を無音で埋めて最後の 1 フレームにする。
    ///
    /// **捨ててはいけない。** 端数は発話の末尾なので、
    /// 落とすと「最後の一言だけ入らない」という形で現れる。
    public mutating func flushWithSilencePadding() -> Data? {
        guard !pending.isEmpty else { return nil }
        var frame = pending
        pending.removeAll(keepingCapacity: true)
        if frame.count < Self.bytesPerFrame {
            frame.append(Data(count: Self.bytesPerFrame - frame.count))
        } else if frame.count > Self.bytesPerFrame {
            frame = Data(frame.prefix(Self.bytesPerFrame))
        }
        return frame
    }

    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }
}

/// 接続が成立するまでの音声を保持する。
///
/// **ハンドシェイクは実測 1,089ms かかる**（社内 Azure / プロキシ経由）。
/// `DictationCoordinator` は `startSession()` が返るまでマイクを開かないので、
/// そこで接続を待つと**その 1 秒はマイクが閉じている時間**になり、
/// 発話の頭が物理的に存在しなくなる。取り返しがつかない。
///
/// そこでセッションは接続を待たずに返し、届いた音声をここへ積む。
/// `session.updated` を受けた瞬間に順番に吐き出す。
public struct PrerollBuffer: Sendable {
    private var frames: [Data] = []
    private let limit: Int

    /// - Parameter limit: 保持するフレーム数。既定は 150（＝ 15 秒）。
    ///   ハンドシェイクの実測値に対して十分な余裕がある。
    public init(limit: Int = 150) {
        self.limit = limit
    }

    public var count: Int { frames.count }
    public var isEmpty: Bool { frames.isEmpty }

    /// 溜める。上限を超えたら**古いものから捨てる**。
    /// `AudioCapture` の `bufferingNewest` と同じ思想で、
    /// 詰まったときに無制限にメモリを食わない。
    public mutating func append(_ frame: Data) {
        frames.append(frame)
        if frames.count > limit { frames.removeFirst(frames.count - limit) }
    }

    /// 溜めた分を順番に取り出して空にする。
    public mutating func drain() -> [Data] {
        defer { frames.removeAll(keepingCapacity: false) }
        return frames
    }

    public mutating func reset() {
        frames.removeAll(keepingCapacity: false)
    }
}

/// Float32 / Int16 のサンプル列を PCM16 LE にする。
public enum PCM16LittleEndianEncoder {
    /// Float32 mono を PCM16 LE へ。
    ///
    /// **NaN を素通しさせないこと。** `Int16(Float.nan)` は Swift で trap し、
    /// 録音経路ごとクラッシュする。`Infinity * 0` のように
    /// 途中の計算で NaN が生まれる経路もあるので、掛けた後にもう一度見る。
    /// （この注意は参考実装が実運用で残していたもの）
    public static func encode(floatSamples: UnsafePointer<Float>,
                              frameCount: Int, gain: Float = 1) -> Data {
        var data = Data(count: frameCount * 2)
        let safeGain = gain.isFinite ? gain : 1
        data.withUnsafeMutableBytes { raw in
            let output = raw.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                let sample = floatSamples[i]
                if sample.isNaN { output[i] = 0; continue }
                let amplified = sample * safeGain
                if amplified.isNaN { output[i] = 0; continue }
                let clipped = max(-1.0 as Float, min(1.0 as Float, amplified))
                output[i] = Int16((clipped * Float(Int16.max)).rounded())
            }
        }
        return data
    }

    public static func encode(int16Samples: UnsafePointer<Int16>, frameCount: Int) -> Data {
        Data(bytes: int16Samples, count: frameCount * MemoryLayout<Int16>.size)
    }
}
