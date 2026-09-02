#!/usr/bin/env sh
# PreToolUse hook: **生成物が spec と食い違ったまま commit されるのを止める。**
#
# 2026-09-03 に実際に踏んだ。`prove-a-check-works` の手順で生成物
# （native/include/ocvu/infra.h）に検査用の行を注入し、**戻す前にコミットした。**
# 一緒に入ったのはレビュアーが別のファイルへ当てた変異で、どちらも
# `git add -u` が拾った。結果 `verify-generated` が落ち、**必須 21 本のうち
# 3 本が確実に赤くなる状態で push された。**
#
# **既存の 2 つでは止まらなかった:**
#   - block-bulk-git-add.sh は `-A` / `.` を止めるが **`-u` は素通しする**
#     （コメントは「生成物、一時的なデバッグ変更を巻き込む」と書いているのに、
#     実装がその 2 つを拾う経路を塞いでいない）
#   - check-generated-file-edit.sh は Write/Edit の直後に指摘するが、
#     **hook の外で書き換えたもの**（テストスクリプトが sed で注入した行）は見ない
#
# **`-u` だけを塞ぐ手は採らない。** `git commit -a` が同じ形で残り、
# 片方だけ塞ぐと塞がれていない動詞に移るだけである。このリポジトリは同じ形を
# 2 度踏んでいる（必須チェックの穴）。**動詞ではなく結果を見る。**
#
# **対象を一覧で持たない。** 生成物は先頭 5 行で「このファイルは生成物である」と
# 名乗る規約なので、それを見る。生成物が 1 つ増えても、この hook は変わらない。
#
# 実行系について: 他の hook と同じく sh で書く。この環境では pwsh の起動に
# 約 3.3 秒かかるのに対し sh は約 0.12 秒で、hook は毎回のツール呼び出しで走る。
#
# jq が無い環境では黙って素通しする（hook が理由でツールが使えなくなる方が有害）。

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
command=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$command" ] || exit 0

# commit する意図があるときだけ見る。`git add` は止めない —— 足すこと自体は
# 正しく、**戻し忘れたまま履歴に入る**ことだけが問題である。
printf '%s' "$command" | grep -Eq '(^|[;&|]|&&)[[:space:]]*git[[:space:]]+commit\b' || exit 0

# staged な生成物のうち、いま index に在る内容が spec からの生成結果と
# 食い違っているものを探す。**working tree ではなく index を見る** ——
# コミットされるのは index の中身である。
staged=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null) || exit 0
[ -n "$staged" ] || exit 0

dirty=""
for file in $staged; do
    [ -f "$file" ] || continue
    # 生成物だけを見る。名乗っていないファイルは対象外。
    git show ":$file" 2>/dev/null | head -5 | grep -q 'このファイルは生成物である' || continue

    # **index の中身と、いまディスクに在る生成結果を比べるのではない。**
    # ディスク側も汚れている可能性がある。`dev.ps1 generate` を走らせるのは
    # 高すぎる（hook は毎回走る）ので、**注入された痕跡だけを見る** ——
    # 生成器が書かない形のコメントが入っていたら止める。
    if git show ":$file" 2>/dev/null | grep -q '手で足した行\|XXXXXX\|_GONE\|REMOVED'; then
        dirty="$dirty $file"
    fi
done

[ -n "$dirty" ] || exit 0

cat >&2 <<EOF
生成物に、検査用に注入した痕跡が残ったまま stage されています:
$(for f in $dirty; do printf '  %s\n' "$f"; done)

**戻してからコミットしてください。** このままだと dev.ps1 verify-generated が
落ち、3 platform の ci-native が赤くなります。

  git checkout -- <上のファイル>
  ./tools/dev.ps1 verify-generated   # 18 ファイル一致になることを確かめる

**壊す作業とコミットを混ぜないこと。** prove-a-check-works の
「壊す前にコミットする」には対になる半分があります ——
**戻したことを確かめてからコミットする**（git status が壊す前と同じであること）。
EOF
exit 2
