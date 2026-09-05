#!/usr/bin/env sh
# PostToolUse hook: 生成物を手で編集したことを、その場で指摘する。
#
# M5 で境界の宣言が生成物になった。bindings/spec/*.json を正本として
# dev.ps1 generate が C ヘッダ・C# の P/Invoke・到達性テスト・API 対応表を
# 書き出す。生成物を手で編集しても、次の generate が黙って上書きするので
# 変更は全部消える。
#
# 一致は dev.ps1 verify-generated が見ており、これは dev.ps1 test に入って
# いるので CI も走らせる。**つまり最終的には赤くなる。** それでもこの hook が
# 要るのは、赤くなるのがずっと後だからである:
#
#   手で編集する  ->  （気づかない）  ->  dev.ps1 test か CI で落ちる
#                                        そこで初めて「その編集は無駄だった」と分かる
#
# 生成物は普通のファイルに見える。読んで直したくなるのが自然で、
# 「直す先は spec である」ことはファイルを開いただけでは分からない。
# だから編集した瞬間に言う。
#
# **対象を一覧で持たない。** 生成物は先頭 5 行で「このファイルは生成物である」と
# 名乗る規約になっており（Ocvu.Generator の 4 つの emitter が全部そうする）、
# この hook はその名乗りだけを見る。一覧を持つと 11 個目の生成物が
# 静かに漏れる —— M5 でまさにその形の穴を踏んだ（生成物 10 個のうち
# 名指しで守られていたのは 2 個だけで、配線を外しても検査は全部 PASS した）。
#
# 名乗り規約に依存するので、名乗らない生成物は素通しする。いまの 4 emitter は
# 全部名乗り、add-abi-function skill がその手順を持つ。
#
# 対象は Write / Edit のみで、generate 自身は対象外である（あれは hook を
# 通らない dotnet の実行なので、そもそも当たらない）。
#
# 実行系の選定理由と fail-open 方針は block-bulk-git-add.sh の冒頭を参照。

set -u

payload=$(cat)
[ -n "$payload" ] || exit 0

# 速い経路: 生成物になりうる拡張子を含まないなら jq を起動せず抜ける。
# ここで絞るのは速度のためだけで、判定は名乗りが行う。
case "$payload" in
    *.h* | *.cs* | *.md*) ;;
    *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null) || exit 0
[ -n "$file" ] || exit 0
[ -f "$file" ] || exit 0

# **判定はこの 1 行だけ。** ファイル自身が名乗っているかを見る。
# 先頭 5 行に絞るのは、本文中で生成物の話をしている文書（CLAUDE.md や
# skill）を誤って捕まえないためである。
head -5 "$file" | grep -q 'このファイルは生成物である' || exit 0

reason=$(printf '%s' "生成物を手で編集しました: ${file}

このファイルは bindings/spec/*.json から生成されます。**手で編集しても、
次の ./tools/dev.ps1 generate が黙って上書きするので変更は消えます。**

直す先は spec です:

  1. bindings/spec/<module>.json を編集する
  2. ./tools/dev.ps1 generate
  3. ./tools/dev.ps1 verify-generated

ABI 関数を足す・変える・消すなら add-abi-function skill の手順に従って
ください（L1 -> spec に 1 エントリ + generate -> 実装 -> L3 の順序と、
所有権・バッファ・例外バリアの規約があります）。

生成の形そのものを変えたいなら、直すのは bindings/generator/Ocvu.Generator/
の emitter です。

**この編集を残したまま dev.ps1 test を回すと verify-generated が落ちます。**
CI でも同じところで落ちるので、いま戻すのがいちばん安いです:

  git checkout -- ${file}")

jq -n --arg reason "$reason" --arg file "$file" '{
  systemMessage: ("生成物を手で編集しました（spec を直してください）: " + $file),
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $reason
  }
}'
