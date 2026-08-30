#!/usr/bin/env sh
# PostToolUse hook: テストが固定名の一時ファイルを使っていないかを検出する。
#
# tools/tests/*.Tests.ps1 は `dev.ps1 test` から他のレーンと並べて走る。
# 一時ファイルの名前を固定すると、**2 つの実行が同じパスを共有して潰し合う。**
#
# 壊れ方が悪い。片方が消した直後にもう片方が読みに行くので、
# **落ちるのは無関係な assertion** である。実測（M4）: 16 KB page size の
# 検査に付けたテストが固定名の ELF を使っており、並行実行したときに
# 「ELF が見つからない」で別の検査が赤くなった。
#
# **「たまたま赤い」は「コードが理由で赤い」と区別できない。** そして
# 再実行すると緑になるので、フレークとして片付けられて残る —— M3 の
# handle table の use-after-free がまさにその形で、1 度だけ落ちたのを
# 再実行していれば配っていた。
#
# 一時ファイル名には実行ごとに一意な要素を混ぜる:
#
#     $runId = [guid]::NewGuid().ToString('n').Substring(0, 8)
#     $tmp = Join-Path ([IO.Path]::GetTempPath()) "ocvu-thing-$runId.bin"
#
# あるいは New-TemporaryFile / 一意なディレクトリを作る。
#
# jq が無い環境では黙って素通しする（hook が理由でツールが使えなくなる方が
# 有害なため）。

set -eu

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
[ -n "$file" ] || exit 0

# 対象は tools/tests/ の PowerShell テストだけ。本番のスクリプトは
# 決まった場所へ書くことがあり、そちらは意図した振る舞いである。
case "$file" in
  *tools/tests/*.Tests.ps1 | *tools\\tests\\*.Tests.ps1) ;;
  *) exit 0 ;;
esac

[ -f "$file" ] || exit 0

# GetTempPath() と Join-Path を使いつつ、同じ行に一意化の要素が無いものを拾う。
#
# 一意化と見なすもの: NewGuid / GetRandomFileName / New-TemporaryFile /
# $PID / $runId のような変数の補間（"$(" または "$" で始まる名前）。
hits=$(grep -nE 'GetTempPath\(\)' "$file" 2>/dev/null \
  | grep -vE 'NewGuid|GetRandomFileName|New-TemporaryFile|\$PID|\$\(' \
  | grep -E "'[^']*'|\"[^\"\$]*\"" \
  | head -5 || true)

[ -n "$hits" ] || exit 0

# 直前のコメントで明示的に許した場合は通す。
if grep -q 'SHARED_TEMP_OK:' "$file" 2>/dev/null; then
  exit 0
fi

context="固定名の一時ファイルの可能性がある行: $file

$hits

tools/tests/*.Tests.ps1 は \`dev.ps1 test\` から他のレーンと並べて走ります。
一時ファイル名を固定すると、2 つの実行が同じパスを共有して潰し合います。

**壊れ方が悪い**: 片方が消した直後にもう片方が読みに行くので、落ちるのは
無関係な assertion です。しかも再実行すると緑になるので、フレークとして
片付けられて残ります。

実行ごとに一意な要素を混ぜてください:

    \$runId = [guid]::NewGuid().ToString('n').Substring(0, 8)
    \$tmp = Join-Path ([IO.Path]::GetTempPath()) \"ocvu-thing-\$runId.bin\"

意図して固定名にする場合は、その行の近くに SHARED_TEMP_OK: と理由を
書いてください。"

jq -n --arg msg "固定名の一時ファイル: $file" --arg ctx "$context" '{
  systemMessage: $msg,
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $ctx
  }
}'
