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

        // ── テスト ────────────────────────────────────────────────
        .testTarget(name: "VoinpCoreTests", dependencies: ["VoinpCore"], swiftSettings: strict),
        .testTarget(name: "VoinpEngineTests", dependencies: ["VoinpEngine"], swiftSettings: strict),
    ]
)
