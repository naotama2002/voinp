import AVFoundation
import Foundation
import VoinpCore
import VoinpEngine

/// 1 本の取り込みを、エンジンごとのフォーマットへ変換して配る。
///
/// ## なぜ取り込みを 1 本にするか
///
/// **エンジンごとに録り直すと、話し方の違いが結果の違いに化ける。**
/// 「macOS は正しく、Gemini は間違えた」のか「2 回目の発話が明瞭だった」のか
/// 区別がつかなくなる。マイクは 1 回だけ開き、同じ PCM を配る。
///
/// ## なぜ最高レートで取り込むか
///
/// エンジンの要求は 16kHz（macOS / Gemini）と 24kHz（OpenAI 系）に割れている。
/// 16kHz で取り込んで 24kHz へ**水増しすると、情報が無いまま尺だけ伸びる**。
/// アップサンプルされた側が不利になり、比較が歪む。
/// ハードウェアの最高レートから各々へ**落とす**方向に揃える。
///
/// 変換器はエンジンごとに 1 つ持って使い回す。チャンクごとに作り直すと
/// 継ぎ目にノイズが乗る（voinp 側で踏んだ）。
public actor AudioFanout {

    private struct Lane {
        let format: AudioFormatDescription
        let resampler: AudioResampler
    }

    private var lanes: [String: Lane] = [:]

    public init() {}

    /// 配り先を登録する。
    public func register(engineID: String, format: AudioFormatDescription) {
        guard let target = AVAudioFormat(
            commonFormat: format.isInt16 ? .pcmFormatInt16 : .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channelCount),
            interleaved: format.isInt16)
        else { return }
        lanes[engineID] = Lane(format: format, resampler: AudioResampler(target: target))
    }

    /// 取り込んだチャンクを、各エンジンの形に変換して返す。
    ///
    /// **変換に失敗したレーンは黙って落とさない。** 落ちた事実を返して、
    /// 呼び出し側が画面に出せるようにする。無言で捨てると
    /// 「そのエンジンだけ精度が悪い」ように見える（voinp 側で踏んだ）。
    public func distribute(_ chunk: AudioChunk) -> [String: AudioChunk] {
        var output: [String: AudioChunk] = [:]
        for (id, lane) in lanes {
            guard let buffer = lane.resampler.buffer(for: chunk),
                  let data = Self.data(from: buffer) else { continue }
            output[id] = AudioChunk(format: lane.format, samples: data)
        }
        return output
    }

    /// 変換できなかったレーン。比較の信頼性に関わるので呼び出し側へ伝える。
    public func failedLanes(for chunk: AudioChunk) -> [String] {
        lanes.compactMap { id, lane in
            lane.resampler.buffer(for: chunk) == nil ? id : nil
        }
    }

    public func reset() {
        lanes.removeAll()
    }

    private static func data(from buffer: AVAudioPCMBuffer) -> Data? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        if let channel = buffer.int16ChannelData {
            return Data(bytes: channel[0], count: frames * MemoryLayout<Int16>.size)
        }
        if let channel = buffer.floatChannelData {
            return Data(bytes: channel[0], count: frames * MemoryLayout<Float>.size)
        }
        return nil
    }
}

/// 比較で使う取り込みフォーマット。
///
/// **各エンジンの要求より高いレートで取り込む。** そこから落とすぶんには
/// 情報が減るだけだが、逆（水増し）は無い情報を作ることになり、
/// アップサンプルされた側が不利になる。
public enum ComparisonAudioFormat {
    /// 24kHz mono Int16。いま比べる 4 エンジンの最高要求に合わせてある。
    public static let capture = AudioFormatDescription(
        sampleRate: 24_000, channelCount: 1, isInt16: true)
}
