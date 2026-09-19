# 05. UI・ホットキー・テキスト挿入

## UI の 3 面

```swift
@main
struct VoinpApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.privacy.symbolName)
                .symbolEffect(.variableColor, isActive: model.phase.isListening)
        }
        .menuBarExtraStyle(.menu)

        Window("Voinp 設定", id: WindowID.settings) {
            SettingsRootView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 580, height: 440)

        Window("Voinp へようこそ", id: WindowID.onboarding) {
            OnboardingView(model: model)
        }
        .windowResizability(.contentSize)
    }
}
```

### 勘所 1: `Settings { }` シーンを使わない

`LSUIElement = true` のアプリにはアプリメニューがないため **⌘, が届かず、
`Settings` シーンは死にシーンになる。**
通常の `Window` を使い、メニューバー項目から `@Environment(\.openWindow)` で開く。

さらに、`openWindow(id:)` の**直前に `NSApp.activate()` を呼ぶ**こと。
アクセサリアプリのウィンドウは、そうしないと他のウィンドウの背後に開く。

`applicationDidFinishLaunching` で `NSApp.setActivationPolicy(.accessory)` も明示的に呼ぶ。
`LSUIElement` が既に含意しているが、開発中に素のバイナリを直接起動するとき
(Info.plist がロードパスにない) に効く。

## HUD パネル

**フォーカスを奪わないこと。奪うと挿入先を見失う。**
SwiftUI では非アクティブ化パネルを表現できないので AppKit に落ちる。

```swift
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool  { false }   // ← これが無いと挿入先を失う
    override var canBecomeMain: Bool { false }
}

@MainActor final class HUDPanelController {
    private let panel: NonActivatingPanel

    init(model: AppModel) {
        panel = NonActivatingPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false)

        panel.isFloatingPanel = true
        panel.level = .floating                    // .statusBar より下
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .none                  // 画面キャプチャ対象から外す意図 (下記の注意)
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    func show() { panel.orderFrontRegardless() }   // makeKeyAndOrderFront は絶対に使わない
    func hide() { panel.orderOut(nil) }
}
```

フォーカスを守る 3 点:

1. `styleMask` に `.nonactivatingPanel`
2. 表示は **`orderFrontRegardless()`**。`makeKeyAndOrderFront(_:)` も `NSApp.activate()` も使わない
3. `canBecomeKey` / `canBecomeMain` を `false` で override

これで HUD はクリック (キャンセルボタン) を受け取れるが、キーフォーカスは決して取らない。
純粋に表示だけなら `panel.ignoresMouseEvents = true` がさらに安全。

#### 編集したくなったら: HUD を編集可能にしない

挿入前に直したい、という要求はある（[08](08-editing-and-learning.md)）。
**そのときも HUD のこの性質を条件分岐で覆さないこと。**
編集は別ウィンドウ（`Sources/VoinpUIKit/Edit/`）で行い、確定したら
挿入先を前面へ戻してから挿入する。
覆すと、`InsertionTargetResolver.assertStillCurrent` から見て
「挿入先が voinp 自身に変わった」ことになり、挿入が中止される。

#### `sharingType = .none` の位置づけ — 保証ではない

`NSWindowSharingNone` は SDK ヘッダで
"Window contents may not be read by another process" と記述されており、
**このプロパティも `.none` も非推奨ではない** (macOS 26.2 SDK で確認)。
非推奨になったのは `NSWindowSharingReadWrite` という別の定数
(`API_DEPRECATED(..., macos(10.5, 15.0))`) なので、混同しないこと。

ただし**保証として扱わない。** 理由は 2 つ:

1. ヘッダ自身が副作用を警告している:

   > your window will also not be able to participate in a number of system services,
   > so this setting should be used with caution.

   どのシステムサービスが影響を受けるかは列挙されていない。
2. 新しい画面キャプチャ経路 (ScreenCaptureKit 等) に対する挙動が
   契約として文書化されていない。**実測するまで「写らない」と書かない。**

したがって docs でもコード上でも扱いはこうする:

- `.none` は設定する (これが正しい API であり、非推奨でもない)
- **「会議の画面共有に写りません」とユーザーに約束しない**
- **`ui.hudShowText` (既定 `true`) を設ける。**
  `false` にすると HUD は波形と状態だけを表示し、認識テキストを出さない。
  画面共有しながら使う場面では、キャプチャ除外に頼るより
  **そもそも表示しない**ほうが確実である
- 未検証項目として残す (この章末の未決事項)

**表示位置:** マウスのあるスクリーンの下部中央、Dock の約 120 pt 上。
キャレット追従 (`AXBoundsForRange`) は約 150 行の脆い AX コードの割に得るものが少ない。やらない。

**内容:** RMS 駆動の波形バー、確定テキストを `.primary`、暫定テキストを `.secondary`、
状態ラベル、「esc でキャンセル」のヒント。20 Hz にスロットルした snapshot で更新する。

## ホットキー

### 機構は `CGEvent.tapCreate` 一本にする

macOS 26 では 3 系統フォールバックは正当化できない。

| 候補 | 判定 |
|---|---|
| Carbon `RegisterEventHotKey` | **SDK のヘッダから消滅** (`.tbd` にのみ残存、実測確認済み)。使うには `@_silgen_name` が必要。そもそも**キーアップを配送しないので push-to-talk が作れない**。不採用 |
| `NSEvent.addGlobalMonitorForEvents` | **イベントを抑止できない** → ⌥Space がエディタに空白を漏らす。自アプリがキーのときは発火しないので local monitor も要る。主機構として不適 |
| **`CGEvent.tapCreate`** | `.keyDown` / `.keyUp` / `.flagsChanged` を見られる。コールバックで `nil` を返すと**イベントを飲み込める**。`.headInsertEventTap` なら、システムの Globe キー処理より先に見える。**これを使う** |

```swift
CGEvent.tapCreate(tap: .cgSessionEventTap,
                  place: .headInsertEventTap,
                  options: .defaultTap,
                  eventsOfInterest: mask,
                  callback: cb, userInfo: ctx)
```

### 権限は 1 つで足りる

| 能力 | 必要な TCC サービス |
|---|---|
| 抑止する (active) キーボードタップ | **アクセシビリティ** |
| 監視のみのタップ | 入力監視 (`CGPreflightListenEventAccess`) |
| ⌘V 合成のための `CGEvent.post` | **アクセシビリティ** (`CGPreflightPostEventAccess`) |
| 他アプリへの `AXUIElementSetAttributeValue` | **アクセシビリティ** |

**テキスト挿入のためにアクセシビリティはどのみち必要**なので、
抑止するタップを使っても追加コストはゼロ。
**権限 1 つ、プロンプト 1 回、機構 1 つ。**
入力監視は要求しない — オンボーディングで権限を 2 つ求めると離脱がおよそ倍になる。

`AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true] as CFDictionary)` で誘導し、
`CGPreflightPostEventAccess()` で確認する。

### 勘所 2: タップを必ず再武装する

コールバックが遅すぎたとき (`.tapDisabledByTimeout`)、
または特定のユーザー入力時 (`.tapDisabledByUserInput`) に、システムはタップを無効化する。
これを処理しないと **一度詰まっただけでホットキーが静かに死に、二度と復活しない。**
この種のアプリで最も多いバグ。

```swift
if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    CGEvent.tapEnable(tap: machPort, enable: true)
    return Unmanaged.passUnretained(event)
}
```

8 行。必須。

### 勘所 3: タップは専用 run loop スレッドに載せる

コールバックはイベント配送経路の中で同期的に走る。
メインの run loop に付けると、メインスレッドが詰まったとき
(SwiftUI のレイアウト、20 Hz の `NSPanel` 更新) にタップがタイムアウトして無効化される。

独自の `CFRunLoop` を持つ `Thread` を作り、ソースを追加して `CFRunLoopRun()` する。
約 25 行で、断続的な失敗のクラス全体が消える。

コールバックは **非同期処理を一切しない。**
本体は「`(keyCode, CGEventFlags, timestamp)` を取り出す → ロックで保護した
`HotkeyInterpreter` に渡す → `(suppress: Bool, command: SessionCommand?)` を受け取る →
`AsyncStream` に `yield` → `event` か `nil` を返す」だけ。

### 動作: ホールド / トグル / ハイブリッド

設定で切り替え可能にする (`hotkey.behavior`)。

| 値 | 動作 |
|---|---|
| `hold` | 押している間だけ録音。離すと確定 |
| `toggle` | 押して開始、もう一度押して終了 |
| `hybrid` (**既定を推奨**) | 200 ms を超えて押し続けたらホールド式、200 ms 未満で離したらトグルに latch する |

`hybrid` は良いディクテーションアプリが収束する形で、説明書なしで発見でき、
短い入力にも長文にも同じキーで対応できる。
ユーザーの要望 (ホールド / トグル切り替え可能) は `behavior` で満たしつつ、
既定を最も使いやすいものにできる。

```swift
public struct HotkeyInterpreter: Sendable {
    public mutating func handle(_ raw: RawKeyEvent,
                                at now: ContinuousClock.Instant) -> Decision
    public struct Decision: Sendable, Equatable {
        let suppress: Bool
        let command: SessionCommand?
    }
}
```

`VoinpCore` に置く純粋な型。ホールド/タップの判別、ダブルタップ検出、
修飾キー単独の和音、イベントごとの抑止判断を持つ。
時刻を引数で受けるので完全に決定的で、モックなしで 30 本ほどのテストが書ける。

### `KeyCombo` と左右の修飾キー

```swift
public struct KeyCombo: Sendable, Hashable, Codable {
    public var keyCode: UInt16?          // nil なら修飾キー単独の和音
    public var modifiers: Modifiers      // OptionSet。左右を区別する
    public var requiresDoubleTap: Bool
}
```

文字列でシリアライズする: `"ctrl+opt+space"` / `"rightCommand"` / `"fn"` /
`"doubleTap:rightCommand"`。パースと整形の往復は純粋関数でテストする。

**左右の区別には `CGEventFlags.rawValue` のデバイス依存ビットが要る。**
公開の `.maskCommand` 等では左右が分からない。「右 ⌘ を押しっぱなし」を
サポートするための非自明な部分。

| 定数 | 値 |
|---|---|
| `NX_DEVICELCTLKEYMASK` | `0x0001` |
| `NX_DEVICELSHIFTKEYMASK` | `0x0002` |
| `NX_DEVICERSHIFTKEYMASK` | `0x0004` |
| `NX_DEVICELCMDKEYMASK` | `0x0008` |
| `NX_DEVICERCMDKEYMASK` | `0x0010` |
| `NX_DEVICELALTKEYMASK` | `0x0020` |
| `NX_DEVICERALTKEYMASK` | `0x0040` |
| `NX_DEVICERCTLKEYMASK` | `0x2000` |

**Fn / Globe キーの注意:** `kVK_Function = 0x3F` は `.flagsChanged` として届き、
`.headInsertEventTap` ならシステムより先に抑止できる。
ただし システム設定 → キーボード → 「🌐 キーを押して」と衝突する。
サポートはするが、ユーザーが Fn を登録したら
`x-apple.systempreferences:com.apple.preference.keyboard` へのリンク付きで警告を出す。

### キーレコーダ UI

**CGEvent タップではなく `NSEvent` の local monitor を使う。**

```swift
NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { ... }
```

理由: **キーレコーダはオンボーディングの一部であり、
オンボーディングはアクセシビリティ権限を得る前に起きる。**
local monitor は権限を一切必要としない。
ユーザーは先にホットキーを設定し、後から権限を与えられる — これが正しい順序。

動作規則:

- `Esc` でキャンセル、`Delete` / `Backspace` で割り当てクリア
- **peak modifiers** (押された修飾キーの最大集合) を保持する。
  修飾キー単独の和音は 400 ms の settle タイマで確定する
  (非修飾キーが来ないまま全修飾キーが離れたら、peak を採用)
- 小さなブロックリスト (素の `Space`、素の英字、`⌘Q`、`⌘Tab`) に対して検証し、
  インラインでエラーを出す

## 権限の判定 — キャッシュとの戦い

**TCC の許可状態は、プロセス内でキャッシュされる。**
システム設定で許可しても、アプリからは古い値が見え続けることがある。
macOS が「終了して再度開く」を促してくるのはこのためで、
Zoom などで「マイクを許可したのに再起動するまで使えない」のと同じ現象である。

2 つの権限で事情が違う。**実測した結果を記録しておく。**

### アクセシビリティ — 機能判定で回避できる

| 判定方法 | 許可を反映するか |
|---|---|
| `AXIsProcessTrusted()` | **しない**（プロセス内でキャッシュ） |
| **`CGEvent.tapCreate` の成否** | **する** |

`tapCreate` はウィンドウサーバへの実際の要求なのでキャッシュされない。
そもそも必要な能力そのものを試しているので、間接的な指標より正確でもある。

**判定は「ホットキーが動いているか」で行う。** `AXIsProcessTrusted()` で事前ゲートしない。

### マイク — 回避できない。再起動が要る

| 判定方法 | 許可を反映するか |
|---|---|
| `AVCaptureDevice.authorizationStatus` | **しない** |
| `AVAudioEngine.start()` | **判定に使えない**（拒否されていても成功し、無音を返す） |
| `AVCaptureDeviceInput` の生成 | **しない**（未許可なら throw するが、許可後も再起動まで throw し続ける） |

TCC の判断が音声サブシステム側で握られており、
**プロセス内から現在の状態を知る方法がない。**

> 機能判定を実装して確かめたが効かなかったので削除した。
> 効くか分からないものを残すのは、動かない処理を抱えるのと同じである。

したがって `authorizationStatus` を素直に使い、再起動が要る場面ではそう案内する。

### 唯一の「再起動不要」経路

**未決定 (`.notDetermined`) のうちにアプリ内ダイアログで許可してもらうこと。**
`AVCaptureDevice.requestAccess` で出るダイアログなら、許可は即座に反映される。

一度拒否されると、そのダイアログは二度と出せず、
システム設定経由 → 再起動が必須になる。

だからウィザードは:

1. `.notDetermined` なら**アプリ内ダイアログを最優先**で出す（設定画面は開かない）
2. `.denied` なら手順を番号で示し、**再起動ボタンを主役にする**
   （小さなリンクでは見落とされる）

## テキスト挿入

### 既定はペースト (⌘V)、AX は検証付きフォールバック

TypeWhisper は AX 優先だが、**逆にする。** 理由:

1. `kAXSelectedTextAttribute` の設定は、実際の挿入先の**かなりの割合で失敗するか
   無言で何もしない**。Electron 系 (VS Code / Slack / Discord) はアプリ要素に
   `AXManualAccessibility` を立てないと駄目、Chrome の web textarea も条件付き、
   Terminal.app と iTerm2 は設定可能な AX テキストを持たない、Xcode のエディタも Emacs も駄目。
   結局ほとんどの場合に検証 → フォールバックの経路を通り、
   その前に 2 回のブロッキング AX 往復を払っている
2. ⌘V はターミナルを含めほぼ 100% の挿入先で動く
3. **AX の set-value は挿入先アプリの undo 履歴を作らないことが多い。**
   ⌘V は綺麗な undo ステップを 1 つ作る。ユーザーが即座に気づく実用上の差

設定: `insertion.strategy = "paste" | "accessibility" | "keystroke" | "auto"`、既定 `paste`。
`auto` はバンドル ID ごとの小さな表 (`insertion.overrides`) を見て、
AX が確実に速いと分かっているアプリだけ AX にする。

### ペーストの手順

```swift
actor PasteInserter: TextInserter {
    func insert(_ text: String, into target: InsertionTarget) async throws {
        guard !(await target.isSecureInput) else { throw VoinpError.secureInputActive }
        guard CGPreflightPostEventAccess()   else { throw VoinpError.accessibilityNotGranted }

        let saved = await MainActor.run { PasteboardSnapshot.capture(.general) }
        let ourChangeCount = await MainActor.run { Pasteboard.write(text) }
        try await postCommandV()
        try? await Task.sleep(for: .milliseconds(settings.pasteRestoreDelayMs))   // 既定 250
        await MainActor.run { saved.restoreIfUnchanged(since: ourChangeCount) }
    }
}
```

### 勘所 4: ペーストボード復元の正しさ — 正直に書く

**「ペーストが着弾したか」は検証できない。**
`NSPasteboard.changeCount` は**読み取りでは増えない**ので、観測できる信号が存在しない。
「貼り付いたことをポーリング確認する」は、挿入先の AX 値を見るしかないが、
それは循環している — AX はまさにペーストが必要なアプリで動かないものだから。

正しくできるのは以下:

1. **守るのはペーストではなく復元のほう。**
   復元の直前に `NSPasteboard.general.changeCount == ourChangeCount` を確認し、
   一致しなければ **復元しない** (その間に誰か — ユーザーのコピー、クリップボードマネージャ —
   が新しい内容を書いており、それを壊してはいけない)。
   **これが実際に保証できる唯一の不変条件。**
2. **閉じられない競合:** 挿入先が復元**後**にペーストボードを読むと古い内容を貼る。
   250 ms の余裕を持った固定遅延と、バンドル ID ごとの上書き
   (Electron は 400〜500 ms 必要なことがある) で緩和する。
   復元自体も `insertion.restore_clipboard = true` で切れるようにし、制約を文書化する。
3. **クリップボードマネージャを汚さない。** 事実上の標準マーカーを付ける
   (Maccy / Paste / Alfred / Raycast が尊重する):

   ```swift
   pb.setString("", forType: .init("org.nspasteboard.TransientType"))
   pb.setString("", forType: .init("org.nspasteboard.ConcealedType"))
   pb.setString("", forType: .init("org.nspasteboard.AutoGeneratedType"))
   ```

   4 行で、ディクテーションしたテキストが履歴を埋め尽くすのを止められる。
4. **スナップショットの忠実度:** 全 `NSPasteboardItem` の全 `type` → `data` を取る。
   復元は `clearContents()` + `writeObjects`。
   遅延約束型 (ファイルプロミス等) には非可逆。受け入れて文書化する。

### 勘所 5: ⌘V の合成

```swift
let src = CGEventSource(stateID: .hidSystemState)
let v = virtualKeyCodeForV()                  // 下記参照
let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)!
down.flags = .maskCommand
let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)!
up.flags = .maskCommand
down.post(tap: .cghidEventTap)
try await Task.sleep(for: .milliseconds(8))
up.post(tap: .cghidEventTap)
```

3 点:

- **⌘ の down/up を別イベントとして送らない。** V のイベントに `.maskCommand` を立てるだけ。
  素の ⌘ keyDown を送るとアプリによってはメニューが開く
- **`kVK_ANSI_V = 0x09` は物理キーコードでレイアウト依存。**
  Dvorak では 0x09 の物理キーは "v" ではない。
  `TISCopyCurrentKeyboardInputSource()` + `UCKeyTranslate` で現在のレイアウトから逆引きする
  (約 60 行)。加えて `insertion.paste_key_code` で上書きできるようにしておく
- **押しっぱなし修飾キーのバグ — push-to-talk 最大の実害。**
  ユーザーが PTT のホットキー ⌃⌥ をまだ押している状態で ⌘V を送ると、
  挿入先には ⌃⌥⌘V が届く。これはペーストではない。

  だから状態機械に **`awaitingModifierRelease(text:)`** が存在する ([01](01-architecture.md))。
  校正の後、`CGEventSource.flagsState(.hidSystemState)` をポーリングして
  修飾キーが全部離れるのを待ってから挿入する。

  **タイムアウトしたら「そのまま挿入」してはいけない。**
  それではこの節が問題にしている ⌃⌥⌘V をそのまま再現してしまう。
  遷移は次のとおり:

  | 経過 | 動作 |
  |---|---|
  | 修飾キーが離れた | 直ちに挿入する (通常はミリ秒で到達する) |
  | 500 ms 経過 | **挿入しない。** HUD に「修飾キーを離してください」と出して待ち続ける |
  | 3 秒経過 | 諦める。テキストをペーストボードに退避し、`failed(.modifiersStuck)` へ。HUD に「⌘V で貼り付けてください」と出す |

  ユーザーの言葉は必ずどこかに残る ([01](01-architecture.md) の端条件) が、
  **誤った修飾キー付きで他アプリにキーを送りつけることは絶対にしない。**

  **未検証の代替案:** `CGEventSource(stateID: .privateState)` は
  ハードウェアの修飾キー状態を継承しないため、
  物理的に押されたままでも正しい ⌘V を送れる可能性がある。
  もし成立するなら待機自体が不要になり、状態機械から
  `awaitingModifierRelease` を削れる。**実装時にスパイクで検証する** (章末の未決事項)。
  検証できるまでは上表の待機方式を採る。

投げ先は `.cghidEventTap` が正しい。
`CGEvent.postToPid(_:)` はグローバル修飾キー状態を回避できるが、
いくつかの Electron アプリが無視するので、既定ではなくアプリ別の上書きとして出す。

> TypeWhisper は `.cgSessionEventTap` を使い「App Sandbox 互換のため」とコメントしている。
> こちらはサンドボックスを使わないので `.cghidEventTap` でよい。
> 実機で問題が出たら切り替えられるよう設定に逃がす。

### AX フォールバック

```swift
actor AccessibilityInserter: TextInserter {
    func insert(_ text: String, into target: InsertionTarget) async throws {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)     // 既定 6 秒を絞る

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let el = focused as! AXUIElement? else { throw VoinpError.noFocusedElement }
        AXUIElementSetMessagingTimeout(el, 0.5)

        let before = try? el.stringValue(kAXValueAttribute)
        guard AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString,
                                           text as CFString) == .success
        else { throw VoinpError.axSetFailed }

        // AX は嘘をつく。読み戻して値が実際に変わったか検証する。
        let after = try? el.stringValue(kAXValueAttribute)
        guard after != before else { throw VoinpError.axSilentNoop }
    }
}
```

**`.success` を信用しない。** 成功を返しても値が変わらないアプリがある。必ず読み戻す。

Electron が相手のときは、まずアプリ要素側で AX を強制する:

```swift
AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
```

この属性は非公開でヘッダ宣言もないので、文字列で指定する。

**AX 呼び出しは `@MainActor` に置かない** ([01](01-architecture.md))。
相手がハングしていると既定 6 秒ブロックする。
専用 actor に置き、かつ `AXUIElementSetMessagingTimeout` で 0.5 秒に絞る。両方やる。

### Secure Input の検知

`IsSecureEventInputEnabled` は **SDK のヘッダから消滅している** (実測確認済み)。
AX の subrole で判定する。こちらのほうが精度も高い
(「どこかのプロセスが secure input を主張している」ではなく
「フォーカス中のフィールドが secure である」が分かる)。

```swift
let subrole = try? focusedElement.stringValue(kAXSubroleAttribute)
let isSecure = subrole == (kAXSecureTextFieldSubrole as String)   // "AXSecureTextField"
```

`kAXSecureTextFieldSubrole` は `AXRoleConstants.h` に現存する。
検知したらセッションを `failed(.secureInputActive)` にし、
HUD に「パスワード欄にフォーカスしています」と出す。

### キーストローク方式 (逃げ道)

`insertion.strategy = "keystroke"` で、ペーストボードを一切触らずに
`CGEvent` + `keyboardSetUnicodeString` で 1 文字ずつ送る経路も用意する。

利点: ペーストボードを経由しないので **Universal Clipboard の懸念が消える** ([06](06-privacy.md))。
欠点: 長文で遅い、undo が 1 ステップにならない、アプリによっては文字を取りこぼす。

**既定にはしない。** 「ペーストボードを一切使いたくない」ユーザーのための選択肢。

## メニューバーの表示

アイコンは **`PrivacyPosture.Level`** を常時表示する ([06](06-privacy.md))。
録音中は `.symbolEffect(.variableColor)` でアニメーションさせる。

メニューの内容:

- 状態行 (プライバシー姿勢: 「完全ローカル — 送信先なし」等)
- 「録音を開始」(ホットキーが使えないときのフォールバック)
- プリセット選択のサブメニュー (チェックマーク付き)
- 「直近の書き起こしをコピー」
- 「設定…」「Voinp について」「終了」
- エラーがあればその行

## 未決事項

- **`sharingType = .none` で HUD が実際に画面キャプチャから除外されるか。**
  ScreenCaptureKit / QuickTime 画面収録 / Zoom・Meet の画面共有で実測する。
  除外できない場合でも `ui.hudShowText = false` があるので機能は成立するが、
  既定値の判断が変わる
- **`CGEventSource(stateID: .privateState)` が物理修飾キー状態を継承しないか。**
  成立すれば `awaitingModifierRelease` 状態を削除できる
- **`org.nspasteboard.ConcealedType` が Universal Clipboard を実際に抑止するか。**
  クリップボードマネージャはこの規約を尊重するが、
  Apple の Universal Clipboard の挙動は契約として文書化されていない。
  **実装前にスパイクで実測する。** それまでは [06](06-privacy.md) に制約として明記し、
  プライバシー画面に注意書きを出す
- `.cghidEventTap` と `.cgSessionEventTap` のどちらが実機で安定か

## 勘所: 挿入先は「直前」に取り直す

`InsertionTarget` は録音開始時に解決するが、キーイベントは `cghidEventTap` へ
post するので、**実際には post した瞬間の最前面アプリ**へ届く。
認識と LLM 校正の間には数秒あり、その間にアプリを切り替えたり
パスワード欄をクリックしたりすると、発話内容が意図しない場所へ入る。

開始時の判定だけを信用していたため、この経路が空いていた。
`InsertionTargetResolver.assertStillCurrent(_:)` を
**両方の挿入方式の先頭**で呼ぶ。

| 直前の状態 | 動作 |
|---|---|
| パスワード欄にフォーカス | 中止。**ペーストボードにも残さない** |
| 相手が変わった | 中止。テキストはペーストボードへ退避し ⌘V で貼れるようにする |
| 同じ相手 | そのまま挿入 |

パスワード欄のときに退避しないのは、そこへ向けて話した内容が
退避先から読み出せるほうが、挿入できないことより悪いため。

## 勘所: 最大録音時間を配線する

`audio.maxRecordingSeconds` は設定ファイルにも UI にもあったのに、
**どこからも参照されていなかった。** トグル方式で録音したまま忘れると
無期限にマイクが開き続ける。`audioStarted` の直後にタイマを張り、
上限に達したら `stopRequested` を投げる（キャンセルではなく確定にするのは、
それまでの発話を捨てないため）。0 以下は無制限の意として扱う。

`audio.minRecordingMs` も同様に、状態機械が固定値 250ms を使っていた。
`SessionMachine.Limits` へ写して渡す。待機中にだけ作り直す
（録音中に差し替えると開始時刻とバッファが消える）。

## 勘所: 音声エンジンの開始失敗で tap を残さない

`installTap` の後に `engine.start()` が失敗すると `isRunning` は false のまま。
後始末の `stop()` は `guard isRunning` で即 return するため tap が残り、
次の開始で同じ bus へ二重に `installTap` して落ちる。
`teardown()` を分けて、**開始失敗の経路からも呼ぶ**。
