#!/usr/bin/env sh
# PostToolUse hook: 非 ASCII を出力する PowerShell スクリプトの
# [Console]::OutputEncoding 未設定を検出する。
#
# Windows の PowerShell は既定で ANSI コードページに書き出す。日本語環境なら
# cp932、CI の en-US runner なら cp1252 である。UTF-8 を指定しないと、
# 日本語を含む失敗メッセージは次のどちらかになる:
#
#   ローカル (cp932)   文字化けして読めない
#   CI      (cp1252)   日本語部分が可逆でない形で失われる
#
# どちらも「失敗の理由を伝える」という、そのメッセージが存在する唯一の目的を
# 潰す。しかも失敗したときにしか現れないので、平常時のテストでは気づけない。
#
# この欠陥は M1 で 3 つの別々のスクリプト（tools/opencv.ps1、
# tools/verify-opencv-artifact.ps1、tools/dev.ps1）に順番に現れた。修正が
# 隣のファイルに既に在っても再発したので、「近くのコードを読めば分かる」
# 類のものではない。だから機械で見る。
#
# 検査するのは「非 ASCII を含み、かつ何かを出力する」スクリプトだけである。
# 非 ASCII がコメントにしか無いスクリプトは出力に影響しないので対象外。
#
# 除外: 直前 10 行のコメントに PS_NO_UTF8_OUTPUT: と理由を書いた場合。
#
# 実行系の選定理由と fail-open 方針は block-bulk-git-add.sh の冒頭を参照。

set -u

payload=$(cat)
[ -n "$payload" ] || exit 0

# 速い経路: .ps1 / .psm1 を含まないなら jq を起動せず抜ける。
case "$payload" in
    *.ps1* | *.psm1*) ;;
    *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null) || exit 0
[ -n "$file" ] || exit 0

printf '%s' "$file" | grep -qE '\.(ps1|psm1)$' || exit 0
[ -f "$file" ] || exit 0

# 既に設定済みなら何も言わない。
grep -q 'Console\]::OutputEncoding' "$file" && exit 0

# 明示的な opt-out。
grep -q 'PS_NO_UTF8_OUTPUT:' "$file" && exit 0

# 出力する経路を持たないスクリプト（module の定義だけ等）は対象外。
grep -qE 'Write-Host|Write-Output|Write-Error|Write-Warning|Console\]::Error|Console\]::Out' "$file" || exit 0

# コメント行を除いて非 ASCII があるか見る。コメントにしか無いなら
# 出力には出ないので指摘しない。
offending=$(sed 's/#.*$//' "$file" | grep -nP '[^\x00-\x7F]' 2>/dev/null | head -3)

# grep -P が無い環境（BusyBox 等）では LC_ALL=C で代替する。
if [ -z "$offending" ]; then
    offending=$(sed 's/#.*$//' "$file" | LC_ALL=C grep -n '[^ -~]' 2>/dev/null | head -3)
fi

[ -n "$offending" ] || exit 0

listing=$(printf '%s' "$offending" | cut -c1-100 | sed 's/^/  /')

reason=$(printf '%s' "非 ASCII を出力する PowerShell スクリプトに [Console]::OutputEncoding の指定がありません: ${file}

非 ASCII を含む行（コメントを除く、先頭 3 件）:
${listing}

Windows の PowerShell は既定で ANSI コードページに書き出します。ローカル
（cp932）では文字化けし、CI の en-US runner（cp1252）では日本語部分が
可逆でない形で失われます。失敗メッセージが読めなくなるので、その
メッセージが存在する意味が無くなります。

スクリプト冒頭（param ブロックの直後、最初の出力より前）に足してください:

    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

**この綴りで書いてください。** CLAUDE.md が定めている形がこれで、tools/ の
新しいスクリプトはすべてこれで揃えてあります。[System.Text.Encoding]::UTF8 でも
コンソールの文字コードは UTF-8 になります（違いは preamble（BOM）を持つことだけで、
PowerShell 7.6.5 ではリダイレクトした出力に BOM は出ませんでした —— 2026-08-30 に
このマシンで実測。両者とも先頭は e3 81 82 だった）。**動く / 動かないの話では
なく、綴りが混在すると次に書く人が毎回どちらが正しいのかを調べ直すことになる
ためです。**

この欠陥は M1 で tools/opencv.ps1、tools/verify-opencv-artifact.ps1、
tools/dev.ps1 に順番に現れました。修正が隣のファイルに既に在っても
再発しています。

出力に非 ASCII が出ないことが確かな場合は、直前のコメントに
PS_NO_UTF8_OUTPUT: と理由を書いてください。")

jq -n --arg reason "$reason" --arg file "$file" '{
  systemMessage: ("PowerShell の出力エンコーディング未設定: " + $file),
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $reason
  }
}'
