#!/usr/bin/env sh
# PostToolUse hook: Runtime/Interop と Runtime/Core への UnityEngine 混入を検出する。
#
# この 2 フォルダが UnityEngine に依存しないことが L3 レーンの前提である。
# 依存しない限り、同じ .cs を netstandard2.1 の shim としてコンパイルでき、
# Unity を起動せずに素の .NET 上で P/Invoke を検証できる（約 20 秒）。
# UnityEngine が入った瞬間にその高速レーンは成立しなくなり、
# 検証は Unity Test Runner（数分）に戻る。
#
# UnityEngine 依存コードは Runtime/UnityIntegration/（別 asmdef）に置く。
#
# 最終的な強制は shim のビルド（tests/Managed/CvUnity.Runtime.Shim）が行う。
# このフックはビルドを待たずに編集直後へ差し戻すための早期検出であって、
# 権威ではない。ここを通っても shim が落ちることはある。
#
# 実行系の選定理由と fail-open 方針は block-bulk-git-add.sh の冒頭を参照。
#
# パスの区切り文字は正規化しない。Windows の \ と POSIX の / を tr で
# 揃えようとするとクォート解釈が環境で揺れるため、パターン側で両方受ける。

set -u

payload=$(cat)
[ -n "$payload" ] || exit 0

# 速い経路: 対象フォルダのパスを含まないなら jq を起動せず抜ける。
# JSON 内では Windows のパス区切りが \\ にエスケープされるため両方見る。
case "$payload" in
    *"Runtime/Interop"* | *"Runtime/Core"* | *'Runtime\\Interop'* | *'Runtime\\Core'*) ;;
    *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null) || exit 0
[ -n "$file" ] || exit 0

case "$file" in
    *.cs) ;;
    *) exit 0 ;;
esac

printf '%s' "$file" | grep -qE '[/\\]Runtime[/\\](Interop|Core)[/\\]' || exit 0
[ -f "$file" ] || exit 0

# コメントを落としてから探す。「UnityEngine を参照してはならない」という
# 説明コメント自体を違反として拾わないため。
# 行コメントを消し、改行を \001 に畳んでブロックコメントを消し、戻す。
code=$(
    sed -e 's://.*::' "$file" |
        tr '\n' '\001' |
        sed -e 's:/\*[^\001]*\*/::g' |
        tr '\001' '\n'
)
printf '%s' "$code" | grep -qE '\bUnityEngine\b' || exit 0

case "$file" in
    */Runtime/Interop/* | *\\Runtime\\Interop\\*) layer="Runtime/Interop" ;;
    *) layer="Runtime/Core" ;;
esac

offending=$(grep -nE '\bUnityEngine\b' "$file" | sed -e 's://.*::' | grep -E '\bUnityEngine\b' | sed 's/^/  /')

reason=$(printf '%s' "${layer} に UnityEngine への参照が入りました: ${file}

${offending}

Runtime/Interop と Runtime/Core は UnityEngine を参照してはなりません。
この 2 フォルダは netstandard2.1 の shim としてもコンパイルされ、
Unity を起動しない L3 レーン（約 20 秒）はそれで成立しています。
UnityEngine が入ると shim のビルドが落ち、その高速レーンが失われます。

UnityEngine に依存するコードは Runtime/UnityIntegration/（別 asmdef）へ置いてください。
Unity の型を受け渡す必要がある場合は、境界で固定サイズ型か配列に落として渡します。

確認: pwsh tools/dev.ps1 test-managed")

jq -n --arg reason "$reason" --arg layer "$layer" '{
  systemMessage: ($layer + " に UnityEngine 参照が混入しています（L3 レーンが壊れます）"),
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $reason
  }
}'
