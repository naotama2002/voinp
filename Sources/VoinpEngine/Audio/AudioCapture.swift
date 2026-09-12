import AVFoundation
import Foundation
import VoinpCore

/// マイクから音声を取り込み、認識エンジンが要求する形式に変換して流す。
public actor AudioCapture {

    /// `AVAudioConverter` を保持する箱。**tap スレッドからのみ、直列にしか触らない。**
    /// この不変条件が守られる限り安全なので @unchecked Sendable にしている。
    private final class ConverterBox: @unchecked Sendable {
        let converter: AVAudioConverter
        let target: AVAudioFormat
        init(converter: AVAudioConverter, target: AVAudioFormat) {
            self.converter = converter; self.target = target
        }

        // AVAudioConverterInputBlock は @Sendable なので、バッファと消費フラグを
        // クロージャに直接キャプチャできない（Swift 6 strict concurrency）。
        // 参照型である自分自身のプロパティに置いて受け渡す。
        private var pending: AVAudioPCMBuffer?
        private var consumed = false

        func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            let ratio = target.sampleRate / input.format.sampleRate
            let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

            pending = input
            consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { [self] _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return pending
            }
            pending = nil
            guard error == nil, out.frameLength > 0 else { return nil }
            return out
        }
    }

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var levelHandler: (@Sendable (Float) -> Void)?
    private var isRunning = false

    public init() {}

    public func start(format desired: AudioFormatDescription,
                      onLevel: @escaping @Sendable (Float) -> Void) throws -> AsyncStream<AudioChunk> {
        guard !isRunning else { throw VoinpError.transcriberUnavailable }
        levelHandler = onLevel

        let input = engine.inputNode
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0 else { throw VoinpError.microphoneNotGranted }

        // **モノラルの tap フォーマットを engine に要求する。**
        // AVAudioConverter は非標準のマルチチャネルレイアウト（6ch の USB オーディオ I/F 等）を
        // ダウンミックスさせると、エラーを返さずゼロ埋めのバッファを返す。無音になって原因が掴めない。
        // installTap でモノラルを要求すれば engine 側が正しくダウンミックスし、
        // converter はリサンプルと型変換だけをすればよくなる。
        // なお**サンプルレートは hw と一致させること**。変えると installTap が throw する。
        let tapFormat: AVAudioFormat
        if hw.channelCount == 1 {
            tapFormat = hw
        } else if let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: hw.sampleRate,
                                           channels: 1, interleaved: false) {
            tapFormat = mono
        } else {
            tapFormat = hw
        }

        guard let target = AVAudioFormat(
            commonFormat: desired.isInt16 ? .pcmFormatInt16 : .pcmFormatFloat32,
            sampleRate: desired.sampleRate,
            channels: AVAudioChannelCount(desired.channelCount),
            interleaved: desired.isInt16),
            let conv = AVAudioConverter(from: tapFormat, to: target)
        else { throw VoinpError.transcriberUnavailable }

        let box = ConverterBox(converter: conv, target: target)
        let (stream, cont) = AsyncStream<AudioChunk>.makeStream(
            bufferingPolicy: .bufferingNewest(256))   // 約 22 秒。詰まっても無制限に食わない
        continuation = cont

        let level = onLevel
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
            // tap スレッド。**10 行以内に保つこと。**
            level(Self.rms(buffer))
            guard let out = box.convert(buffer) else { return }
            guard let data = Self.data(from: out) else { return }
            cont.yield(AudioChunk(format: desired, samples: data))
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        return stream
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        continuation?.finish()
        continuation = nil
    }

    // MARK: - ヘルパ

    /// 音量（RMS）。HUD の波形表示に使う。
    ///
    /// **Float32 と Int16 の両方を扱うこと。** tap のフォーマットは
    /// ハードウェア次第で、Int16 のときに floatChannelData だけ見ると
    /// 常に 0 が返り、波形が動かなくなる。
    private static func rms(_ b: AVAudioPCMBuffer) -> Float {
        let frames = Int(b.frameLength)
        guard frames > 0 else { return 0 }

        if let ch = b.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<frames { sum += ch[i] * ch[i] }
            return (sum / Float(frames)).squareRoot()
        }
        if let ch = b.int16ChannelData?[0] {
            var sum: Float = 0
            for i in 0..<frames {
                let v = Float(ch[i]) / Float(Int16.max)
                sum += v * v
            }
            return (sum / Float(frames)).squareRoot()
        }
        return 0
    }

    private static func data(from b: AVAudioPCMBuffer) -> Data? {
        let frames = Int(b.frameLength)
        guard frames > 0 else { return nil }
        if let i16 = b.int16ChannelData {
            return Data(bytes: i16[0], count: frames * MemoryLayout<Int16>.size)
        }
        if let f32 = b.floatChannelData {
            return Data(bytes: f32[0], count: frames * MemoryLayout<Float>.size)
        }
        return nil
    }
}
