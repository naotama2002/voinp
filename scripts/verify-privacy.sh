#!/bin/bash
# docs/06-privacy.md の検証レシピ。CI と `make verify` から呼ぶ。
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
ok()   { echo "  OK   $1"; }
bad()  { echo "  NG   $1"; fail=1; }

echo "== 1. サードパーティ依存ゼロ =="
if [ ! -s Package.resolved ]; then ok "Package.resolved は空"
else bad "サードパーティ依存が入っている"; cat Package.resolved; fi

echo "== 2. URLSession は VoinpNet の中だけ =="
hits=$(grep -rln --include='*.swift' -E 'URLSession\(|NWConnection\(|CFSocket|getaddrinfo' Sources/ \
       | grep -v '^Sources/VoinpNet/' || true)
if [ -z "$hits" ]; then ok "VoinpNet 以外にネットワーク API なし"
else bad "VoinpNet 以外にネットワーク API がある:"; echo "$hits" | sed 's/^/       /'; fi

echo "== 3. 音声側と UI 側が VoinpNet を知らない =="
hits=$(grep -rn --include='*.swift' -E 'import (VoinpNet|VoinpProviders)' \
       Sources/VoinpCore Sources/VoinpEngine Sources/VoinpUIKit 2>/dev/null || true)
if [ -z "$hits" ]; then ok "VoinpCore / VoinpEngine / VoinpUIKit は非ネットワーク"
else bad "依存違反:"; echo "$hits" | sed 's/^/       /'; fi

echo "== 4. オフライン版にネットワークコードが存在しない =="
swift build --product voinp-offline >/dev/null 2>&1 || { bad "voinp-offline がビルドできない"; }
BIN=$(swift build --show-bin-path 2>/dev/null)/voinp-offline
if [ -f "$BIN" ]; then
  # nm -u (未定義シンボル) では判定できない。静的リンクされるため両方 0 になる。
  # 定義シンボル (-U) で数える。
  n=$(nm -U "$BIN" 2>/dev/null | grep -cE '8VoinpNet|VoinpProviders')
  [ "$n" -eq 0 ] && ok "voinp-offline に VoinpNet/VoinpProviders のシンボルなし" \
                 || bad "voinp-offline に $n 件のシンボルが混入"
  REF=$(swift build --show-bin-path 2>/dev/null)/voinp
  if [ -f "$REF" ]; then
    m=$(nm -U "$REF" 2>/dev/null | grep -cE '8VoinpNet|VoinpProviders')
    [ "$m" -gt 0 ] && ok "対照: voinp には $m 件ある (検証が機能している)" \
                   || bad "対照が 0 件。検証コマンドが機能していない"
  fi
fi

echo "== 5. ログにユーザーテキストが漏れないこと =="
# os.log の既定は .public。SessionPhase / TranscriptSnapshot / 本文そのものを
# String(describing:) で補間すると、発話内容が unified log に載る。
# （実際に一度やらかした。logDescription を使うこと）
leaks=$(grep -rn --include='*.swift' 'privacy: *\.public' Sources/ \
        | grep -E 'String\(describing: *(phase|.*[Pp]hase|.*snapshot|.*[Tt]ext)' || true)
leaks="$leaks$(grep -rnE --include='*\.swift' 'Log\.[a-z]+\.[a-z]+\("[^"]*\\\((text|transcript|committed|volatileTail|snapshot)[,)]' Sources/ || true)"
# 本文そのものだけでなく、**本文から取り出した値を持つ型**も危ない。
# RefinementGuard.Rejection.numberMismatch は発話中の数値
# （電話番号・金額・番地）を保持する。String(describing:) でログに流すと
# そのまま unified log に残る。件数だけ出す logCode を必ず経由させる。
# 実際にこの経路で漏れていたのに、本文検出だけの検査では素通りした。
leaks="$leaks$(grep -rnE --include='*\.swift' \
    'Log\.[a-z]+\.[a-z]+\("[^"]*\\\((String\(describing: *)?(reason|rejection|verdict)\b' \
    Sources/ | grep -v '\.logCode' || true)"
if [ -z "$(echo "$leaks" | tr -d '[:space:]')" ]; then ok "本文の .public 補間なし"
else bad "ログに本文が漏れる可能性:"; echo "$leaks" | sed 's/^/       /'; fi

echo "== 6. 想定外の文字体系の混入がないこと =="
# 日本語ドキュメントにキリル / ハングル / タイ文字が紛れ込む事故を検出する。
# （生成時のタイプミスで実際に 3 回発生した）
strays=$(python3 - <<'PYEOF'
import glob, io, re
bad = re.compile(r'[\u0400-\u04FF\uAC00-\uD7AF\u0E00-\u0E7F\u0600-\u06FF]')
hits = []
for pat in ('docs/*.md', 'README.md', 'Resources/Prompts/*.md', 'Sources/**/*.swift'):
    for p in glob.glob(pat, recursive=True):
        for i, l in enumerate(io.open(p, encoding='utf-8'), 1):
            # 言語名の表示など、意図して書いた箇所は明示的に許可する
            if 'voinp:allow-script' in l:
                continue
            if bad.search(l):
                hits.append(f'{p}:{i}: {l.strip()[:70]}')
print('\n'.join(hits))
PYEOF
)
if [ -z "$strays" ]; then ok "混入なし"
else bad "想定外の文字:"; echo "$strays" | sed 's/^/       /'; fi

echo
[ $fail -eq 0 ] && echo "すべて通過" || echo "失敗あり"
exit $fail
