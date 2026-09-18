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

        // ── ライブラリとしての公開 ───────────────────────────────
        // 認識エンジンの比較ツールなど、別パッケージから部品を使うため。
        //
        // **公開しても依存の向きは変わらない。** VoinpCore と VoinpEngine は
        // 引き続き VoinpNet を知らず、`scripts/verify-privacy.sh` の検査 3 が
        // それを見ている。オフライン版の保証にも影響しない
        // （検査 4 は voinp-offline のバイナリを見ているため）。
        .library(name: "VoinpCore", targets: ["VoinpCore"]),
        .library(name: "VoinpEngine", targets: ["VoinpEngine"]),
        .library(name: "VoinpNet", targets: ["VoinpNet"]),
        .library(name: "VoinpProviders", targets: ["VoinpProviders"]),
    ],
    targets: [
        // ── ネットワークに依存しない層 ──────────────────────────────
        .target(name: "VoinpCore", swiftSettings: strict),
        .target(name: "VoinpEngine", dependencies: ["VoinpCore"], swiftSettings: strict),
        .target(name: "VoinpUIKit", dependencies: ["VoinpEngine"], swiftSettings: mainActorDefault),

        // ── ネットワーク層 ─────────────────────────────────────────
        .target(name: "VoinpNet", dependencies: ["VoinpCore"], swiftSettings: strict),
        .target(name: "VoinpProviders", dependencies: ["VoinpCore", "VoinpNet"], swiftSettings: strict),

        // ── 合成ルート ────────────────────────────────────────────
        .executableTarget(
            name: "voinp",
            dependencies: ["VoinpUIKit", "VoinpProviders", "VoinpNet"],
            swiftSettings: mainActorDefault),
        .executableTarget(
            name: "voinp-offline",
            dependencies: ["VoinpUIKit"],
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
    ]
)
