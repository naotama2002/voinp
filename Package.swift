// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .treatAllWarnings(as: .error),
]
let mainActorDefault: [SwiftSetting] = strict + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "voinp",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "voinp", targets: ["voinp"]),
        .executable(name: "voinp-offline", targets: ["voinp-offline"]),
        .executable(name: "voinp-tools", targets: ["voinp-tools"]),
        // 認識エンジンの比較ツール。社内で何を採用するかの判断材料にする。
        .executable(name: "stt-compare", targets: ["stt-compare"]),
    ],
    targets: [
        // ── ネットワークに依存しない層 ──────────────────────────────
        .target(name: "VoinpCore", swiftSettings: strict),
        .target(name: "VoinpEngine", dependencies: ["VoinpCore"], swiftSettings: strict),
        .target(name: "VoinpUIKit", dependencies: ["VoinpEngine"], swiftSettings: mainActorDefault),

        // ── ネットワーク層 ─────────────────────────────────────────
        .target(name: "VoinpNet", dependencies: ["VoinpCore"], swiftSettings: strict),
        .target(name: "VoinpProviders", dependencies: ["VoinpCore", "VoinpNet"], swiftSettings: strict),

        // ── 認識エンジンの比較 ─────────────────────────────────────
        // macOS 標準 / gpt-live-transcribe / gpt-live-1 /
        // gemini-3.5-transcribe-live を横に並べて同じ音声で比べる。
        //
        // **本体の依存方向には影響しない。** VoinpProviders に依存するのは
        // このターゲットだけで、VoinpCore と VoinpEngine は引き続き
        // VoinpNet を知らない（verify-privacy.sh の検査 3）。
        // voinp-offline のバイナリにも入らない（検査 4）。
        .target(name: "STTCompare",
                dependencies: ["VoinpCore", "VoinpEngine", "VoinpNet", "VoinpProviders"],
                swiftSettings: strict),

        // ── 合成ルート ────────────────────────────────────────────
        .executableTarget(
            name: "voinp",
            dependencies: ["VoinpUIKit", "VoinpProviders", "VoinpNet"],
            swiftSettings: mainActorDefault),
        .executableTarget(
            name: "voinp-offline",
            dependencies: ["VoinpUIKit"],
            swiftSettings: mainActorDefault),
        .executableTarget(
            name: "stt-compare",
            dependencies: ["STTCompare"],
            swiftSettings: mainActorDefault),
        // モデル取得などの開発用ユーティリティ
        .executableTarget(
            name: "voinp-tools",
            dependencies: ["VoinpEngine", "VoinpNet", "VoinpProviders"],
            swiftSettings: strict),

        // ── テスト ────────────────────────────────────────────────
        .testTarget(name: "VoinpCoreTests", dependencies: ["VoinpCore"], swiftSettings: strict),
        .testTarget(name: "VoinpEngineTests", dependencies: ["VoinpEngine"], swiftSettings: strict),
        .testTarget(name: "VoinpNetTests", dependencies: ["VoinpNet"], swiftSettings: strict),
        .testTarget(name: "VoinpProvidersTests", dependencies: ["VoinpProviders"],
                    swiftSettings: strict),
        .testTarget(name: "STTCompareTests", dependencies: ["STTCompare"],
                    swiftSettings: strict),
    ]
)
