#!/usr/bin/env sh
# PreToolUse hook: **手で書き換えた生成物が commit されるのを止める。**
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
# 片方だけ塞ぐと塞がれていない動詞に移るだけである。**動詞ではなく結果を見る。**
#
# ---
#
# **判定の規則: 生成物が入っているのに bindings/ が入っていなければ止める。**
#
# 生成物は `bindings/spec/**` と `bindings/generator/**` からしか変わらない
# （`dev.ps1 generate` がそこから書き出す）。だから **生成物が commit に入って
# いるのに `bindings/` が入っていないなら、それは生成ではなく手作業である。**
#
# **痕跡の文字列を列挙しない。** 最初はそうしていた（`手で足した行` など 4 つ）が、
# レビューが 2 つの向きで穴だと実測した:
#   - **未知の文字列を通す** —— `/* 一時的な確認 */` で注入すると素通しした
#   - **誤検出の側にも危うい** —— `REMOVED` / `XXXXXX` は生成物の中身に自然に
#     現れうる（`docs/api-map.md` は spec の `summary` をそのまま並べるので、
#     spec にその語を 1 行書いた瞬間、正当な commit が止まる）
#
# **この規則が現実に働くことは履歴で測ってある**（2026-09-03 時点）:
# 生成物を触った commit 25 件のうち、`bindings/` を触っていないものは 2 件
# （`f7e4561` = 今回の事故そのもの、`339bba3` = その修復）。
# **23/25 の正当な commit は通り、止まるのは事故とその修復である。**
# 修復を止めるのは確かに誤検出だが、逃げ道を下のメッセージに書いてある。
#
# **なぜ `dev.ps1 generate` を走らせて厳密に比べないか。** 正確ではあるが、
# `verify-generated` が見るのは **index ではなく作業ツリー**なので、厳密にやるなら
# index の中身を一時ディレクトリへ書き出す必要がある。上の規則は列挙を持たず
# 未知の壊し方も捕まえるので、そこまでの複雑さを買っていない。
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
#
# `git` と `commit` が隣り合っていることを求めない —— `git -C <path> commit` や
# `git --no-pager commit` が抜ける（レビューの実測で見つかった）。
printf '%s' "$command" \
    | grep -Eq '(^|[;&|])[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?commit([[:space:]]|$)' \
    || exit 0

# **コミットされる対象を集める。index だけを見ない。**
# `git commit -a` は commit の時点で追跡済みの変更を stage するので、
# **hook が走る時点の index には現れない。** ここを index だけで判定していた
# のが、この hook 自身が「採らない」と宣言した形の穴だった（レビューが実測）。
staged=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)

# `-a` / `--all` の検出。**`-am` のような短縮の束も拾う** —— `git commit -am` は
# 日常的に使われる形で、`-a` だけを探すと抜ける。`--amend` は `--` で始まるので
# 当たらない（`--all` だけを名指しする）。
for tok in $command; do
    case "$tok" in
        --all) staged="$staged
$(git diff --name-only --diff-filter=ACM 2>/dev/null)"; break ;;
        --*) ;;
        -*a*) staged="$staged
$(git diff --name-only --diff-filter=ACM 2>/dev/null)"; break ;;
    esac
done

[ -n "$(printf '%s' "$staged" | tr -d '[:space:]')" ] || exit 0

# 生成物だけを見る。名乗っていないファイルは対象外。
# index に在ればそちらを、`-a` で拾った未 stage のものは作業ツリーを読む。
generated=""
for file in $staged; do
    { git show ":$file" 2>/dev/null || cat "$file" 2>/dev/null; } \
        | head -5 | grep -q 'このファイルは生成物である' || continue
    generated="$generated $file"
done
[ -n "$generated" ] || exit 0

# 生成の元が一緒に来ているなら、これは `dev.ps1 generate` の結果である。
printf '%s\n' "$staged" | grep -q '^bindings/' && exit 0

cat >&2 <<EOF
生成物が commit に入っていますが、その元（bindings/）が入っていません:
$(for f in $generated; do printf '  %s\n' "$f"; done)

生成物は bindings/spec/** と bindings/generator/** からしか変わりません。
元が無いということは、**手で書き換えたものが履歴に入ろうとしています。**

  - 検査のために壊したのなら、**戻してからコミットしてください**
      git checkout -- <上のファイル>
      ./tools/dev.ps1 verify-generated   # 一致することを確かめる

  - 本当に生成し直したのなら、**その元も一緒に stage してください**
      git add bindings/spec/<変えたもの>.json

  - 手で戻した修復なら、./tools/dev.ps1 generate で作り直してからコミットしてください

**壊す作業とコミットを混ぜないこと。** prove-a-check-works の
「壊す前にコミットする」には対になる半分があります ——
**戻したことを確かめてからコミットする**（git status が壊す前と同じであること）。
EOF
exit 2
