#!/usr/bin/env sh
# PostToolUse hook: 終了コードを決めた後ろに置かれた assertion を検出する。
#
# tools/tests/*.Tests.ps1 は末尾でこの形を取る:
#
#     if ($failures.Count -gt 0) {
#         Write-Host "`n$($failures.Count) assertion(s) failed"
#         exit 1
#     }
#     Write-Host "`nall assertions passed"
#
# この後ろに assertion を足すと、失敗しても終了コードに影響しない。
# PASS/FAIL の行は出るので、目で見ている限りは動いているように見える。
# CI と dev.ps1 が見るのは終了コードだけなので、緑のまま通る。
#
# **落ちないテストは、テストが無いより悪い。** 検証したという記録だけが
# 残り、実際には何も見ていないからである。M1 ではこのリポジトリで実際に
# 起きた（回帰テストを集計ブロックの後ろに追記した）。人が気づいたのは
# 変異テストを回したときで、それが無ければ気づけなかった。
#
# 追加する assertion は必ず集計ブロックより前に置くこと。
#
# 除外: 直前 10 行のコメントに ASSERT_AFTER_EXIT_OK: と理由を書いた場合。
#
# 実行系の選定理由と fail-open 方針は block-bulk-git-add.sh の冒頭を参照。

set -u

payload=$(cat)
[ -n "$payload" ] || exit 0

# 速い経路: Tests.ps1 を含まないなら jq を起動せず抜ける。
case "$payload" in
    *Tests.ps1*) ;;
    *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null) || exit 0
[ -n "$file" ] || exit 0

printf '%s' "$file" | grep -qE '\.Tests\.ps1$' || exit 0
[ -f "$file" ] || exit 0

grep -q 'ASSERT_AFTER_EXIT_OK:' "$file" && exit 0

# インデントの無い（= 関数やブロックの内側でない）exit を境界とみなし、
# その後ろに現れる Assert-* の呼び出しを拾う。関数定義の中の exit は
# 呼ばれる位置が動くので対象にしない。
stranded=$(awk '
    # 行頭に空白が無い exit N をトップレベルの終了とみなす
    /^exit[ \t]+[0-9]+/ { lastExit = NR; next }

    # 集計ブロック内の exit 1 も境界になる（if の内側なのでインデントされる）
    /^[ \t]+exit[ \t]+1[ \t]*$/ { if (inSummary) { lastExit = NR } ; next }

    /\$failures\.Count/ { inSummary = 1 }

    /Assert-[A-Za-z]+/ {
        if (lastExit > 0) print NR ": " $0
    }
' "$file" | head -5)

[ -n "$stranded" ] || exit 0

listing=$(printf '%s' "$stranded" | cut -c1-110 | sed 's/^/  /')
# printf '%s' は末尾に改行を付けないので wc -l だけだと 1 行を 0 と数える。
count=$(printf '%s\n' "$stranded" | grep -c '.')

reason=$(printf '%s' "終了コードを決めた後ろに assertion が置かれています: ${file}

${listing}

このファイルは末尾の集計ブロックで exit を呼びます。その後ろにある
assertion は、失敗しても終了コードに影響しません。PASS / FAIL の表示は
出るので目には動いて見えますが、CI と tools/dev.ps1 が見ているのは
終了コードだけなので、緑のまま通ります。

落ちないテストは、テストが無いより悪いです。検証したという記録だけが
残り、実際には何も見ていないからです。

集計ブロック（if (\$failures.Count -gt 0) { ... }）より**前**に移してください。

移した後は、そのテストが本当に判別することを確認してください。検査対象を
わざと壊して exit 1 になり、戻して exit 0 になることを見ます:

    # 壊す
    pwsh -NoProfile -File ${file} > /dev/null 2>&1; echo \$?   # 1 を期待
    # 戻す
    pwsh -NoProfile -File ${file} > /dev/null 2>&1; echo \$?   # 0 を期待

意図的に後ろへ置く理由がある場合は、直前のコメントに
ASSERT_AFTER_EXIT_OK: と理由を書いてください。")

jq -n --arg reason "$reason" --arg count "$count" --arg file "$file" '{
  systemMessage: ("終了コードに影響しない assertion が " + $count + " 件: " + $file),
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $reason
  }
}'
