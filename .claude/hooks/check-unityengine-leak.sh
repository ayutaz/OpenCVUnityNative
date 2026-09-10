#!/usr/bin/env sh
# PostToolUse hook: UnityEngine 非依存であるべき Runtime のフォルダへの
# UnityEngine 混入を検出する。
#
# それらのフォルダが UnityEngine に依存しないことが L3 レーンの前提である。
# 依存しない限り、同じ .cs を netstandard2.1 の shim としてコンパイルでき、
# Unity を起動せずに素の .NET 上で P/Invoke を検証できる（約 20 秒）。
# UnityEngine が入った瞬間にその高速レーンは成立しなくなり、
# 検証は Unity Test Runner（数分）に戻る。
#
# UnityEngine 依存コードは Runtime/UnityIntegration/（別 asmdef）に置く。
#
# **対象フォルダの一覧を写さない。正本から読む。**
# 正本は tests/Managed/CvUnity.Runtime.Shim/CvUnity.Runtime.Shim.csproj の
# <Compile> 要素の Include である —— shim がコンパイルするフォルダが、そのまま
# 「UnityEngine を参照してはならない」フォルダの定義だからである。
# **「行」ではなく「要素」を見る。** 理由は下の抽出のところに書いてある。
#
# 写していた頃の壊れ方（実測、2026-09-10）: M7c が profile の分離で
# Runtime/Interop.Dnn と Runtime/Dnn を足し、shim の csproj は 4 フォルダを
# コンパイルするようになったのに、この hook は 2 フォルダのままだった。
# 4 つに同じ probe を当てると Core と Interop だけが検知され、
# **Interop.Dnn と Dnn は素通りした。** どちらも asmdef が
# noEngineReferences: true を宣言しており、書けば shim のビルドが落ちる。
# profile が 1 つ増えれば同じ形でまた 2 フォルダ増えるので、写す形はやめた。
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

# 速い経路: Runtime 配下のパスを含まないなら jq も csproj の読み取りも起こさない。
# JSON 内では Windows のパス区切りが \\ にエスケープされるため両方見る。
#
# **ここでフォルダ名まで絞らない。** 絞ると一覧を写すことになり、上に書いた
# 壊れ方（新しいフォルダを黙って素通しする）がこの 1 行に戻ってくる。
# Runtime/ で切るだけでも、このリポジトリの編集の大半（native/ tools/ docs/
# tests/ .github/）はここで抜ける。
case "$payload" in
    *"Runtime/"* | *'Runtime\\'*) ;;
    *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null) || exit 0
[ -n "$file" ] || exit 0

case "$file" in
    *.cs) ;;
    *) exit 0 ;;
esac

# 正本の場所を cwd に依存させない。hook は任意の cwd で呼ばれうる。
# repo root で呼ばれるのが普通なので、まず相対で当たるかを見て、
# 外れたときだけ git を起こす（速い経路の一部である）。
shim_csproj="tests/Managed/CvUnity.Runtime.Shim/CvUnity.Runtime.Shim.csproj"
if [ ! -f "$shim_csproj" ]; then
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    shim_csproj="${repo_root:-.}/tests/Managed/CvUnity.Runtime.Shim/CvUnity.Runtime.Shim.csproj"
fi

# --------------------------------------------------------------------------
# csproj から「shim がコンパイルするフォルダ」を読む。
#
# **要素単位で切る。行単位で読まない。** 改行を空白に潰してから '<' で切ると、
# 1 行に複数の要素が並んでいても、属性が次の行にあっても、1 要素 1 行になる。
# XML コメントは範囲指定で落とす（'<' で切ると開始が `!--` で始まる行になり、
# 終了は `-->` を含む行になる）。実測: コメントアウトした <Compile> を、
# 以前は生きた行として数えていた。
#
# **<Compile> だけを見る。** 以前は「$(OcvuPackageRuntime) を含む行」を拾って
# おり、コメントのほうは「<Compile Include> 行を読む」と書いていた。実測:
# <None Include="$(OcvuPackageRuntime)\UnityIntegration\notes\readme.txt" /> を
# 足すと Runtime/UnityIntegration を対象と誤認し、負の対照が壊れた。
# block-bulk-git-add.sh で直したのと同じ「理由と実装のずれ」である。
compile_elements=""
[ -f "$shim_csproj" ] && compile_elements=$(
    tr '\n' ' ' < "$shim_csproj" |
        tr '<' '\n' |
        sed '/^[[:space:]]*!--/,/-->/d' |
        grep -E '^[[:space:]]*Compile[[:space:]]' |
        grep -F '$(OcvuPackageRuntime)'
)

# **1 つの Include に ';' 区切りで複数のパスを書ける**（MSBuild の仕様）。
# 以前は行ごとに貪欲な .* で 1 つだけ取っており、実測: 4 フォルダを
# 2 行（1 行 2 パス）で書いた csproj から **2 つしか読めなかった。**
# 引用符は二重・単重の両方を受ける（MSBuild はどちらも許す）。
inc_dq=$(printf '%s\n' "$compile_elements" | sed -n 's/.*[Ii]nclude="\([^"]*\)".*/\1/p')
inc_sq=$(printf '%s\n' "$compile_elements" | sed -n "s/.*[Ii]nclude='\([^']*\)'.*/\1/p")
include_paths=$(printf '%s\n%s\n' "$inc_dq" "$inc_sq" | tr ';' '\n' | grep '[^[:space:]]' || true)

# $(OcvuPackageRuntime)\Interop\**\*.cs -> Interop
folders=$(
    printf '%s\n' "$include_paths" |
        sed -n 's/^[[:space:]]*$(OcvuPackageRuntime)[\\/]\([^\\/]*\)[\\/].*/\1/p'
)

# **黙って素通ししない。** 読めないまま通すと、この hook は何も見なくなり、
# しかも指摘が出ないので気づけない（check-platform-list-drift.sh と同じ判断）。
#
# **ただし「N 件以上読めたか」で守ってはいけない。** 以前は `-lt 2` で守って
# いたが、4 フォルダのうち 2 つしか読めない上記の欠陥は **2 件読めているので
# この門を素通りした** —— **欠けた一覧が、揃った一覧と同じ顔をする**という、
# この hook がそもそも無くそうとした形そのものである。
#
# だから閾値ではなく**読みの整合**を見る。3 つとも満たして初めて信用する:
#
#   (a) 変数を参照する <Compile> が 1 つ以上ある —— 0 なら読めていない
#   (b) 変数を名指しした Include のパス 1 つにつき、フォルダがちょうど 1 つ
#       取れた —— 取り出せないパスの形があれば数が合わない
#   (c) フォルダ数が要素数以上 —— Include ごと読み落とした要素があれば
#       (b) は成立したまま (c) が落ちる（読めない引用符など）
#
# **(b) と (c) は対である。** 片方だけでは、それぞれ「パスを 1 つ落とした」
# 「要素ごと落とした」を見逃す。
elem_count=$(printf '%s\n' "$compile_elements" | grep -c '[^[:space:]]' || true)
path_ref_count=$(printf '%s\n' "$include_paths" | grep -cF '$(OcvuPackageRuntime)' || true)
folder_count=$(printf '%s\n' "$folders" | grep -c '[^[:space:]]' || true)

if [ "$elem_count" -lt 1 ] ||
    [ "$folder_count" -ne "$path_ref_count" ] ||
    [ "$folder_count" -lt "$elem_count" ]; then
    detail="<Compile> 要素 ${elem_count} / 変数を名指ししたパス ${path_ref_count} / 取り出せたフォルダ ${folder_count}"
    jq -n --arg src "$shim_csproj" --arg detail "$detail" '{
      systemMessage: "UnityEngine 非依存フォルダの正本を読めませんでした",
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: ($src + " の <Compile Include> を読み取れませんでした（" + $detail + "）。書き方が変わった可能性があります。check-unityengine-leak.sh の抽出を直してください（読めない間、この hook は UnityEngine の混入を検出しません）。**数が減ったまま黙って通すことはしません** —— 欠けた一覧は、揃った一覧と同じ顔をするからです。")
      }
    }'
    exit 0
fi

# 正規表現の . をエスケープする（Interop.Dnn）。**バックスラッシュを使わない** ——
# 動的に組む \. は環境で空振りしやすいと、このリポジトリが実測で記録している
# （check-platform-list-drift.sh の 95 行）。[.] なら bracket 式で literal になる。
#
# here-doc を done に付けると、代入がサブシェルに閉じ込められない
# （check-platform-list-drift.sh と同じ形）。
layer=""
while IFS= read -r folder; do
    [ -n "$folder" ] || continue
    [ -z "$layer" ] || continue
    esc=$(printf '%s' "$folder" | sed 's/[.]/[.]/g')
    if printf '%s' "$file" | grep -qE "[/\\]Runtime[/\\]${esc}[/\\]"; then
        layer="Runtime/$folder"
    fi
done <<FOLDERS
$folders
FOLDERS
[ -n "$layer" ] || exit 0
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

offending=$(grep -nE '\bUnityEngine\b' "$file" | sed -e 's://.*::' | grep -E '\bUnityEngine\b' | sed 's/^/  /')

folder_list=$(printf '%s\n' "$folders" | sed 's:^:  - Runtime/:')

reason=$(printf '%s' "${layer} に UnityEngine への参照が入りました: ${file}

${offending}

次のフォルダは UnityEngine を参照してはなりません（tests/Managed/CvUnity.Runtime.Shim/CvUnity.Runtime.Shim.csproj が正本）:
${folder_list}

これらは netstandard2.1 の shim としてもコンパイルされ、
Unity を起動しない L3 レーン（約 20 秒）はそれで成立しています。
UnityEngine が入ると shim のビルドが落ち、その高速レーンが失われます。
profile 付きの層（Interop.Dnn / Dnn）も例外ではありません —— Unity 側では
OCVU_PROFILE_DNN の defineConstraints で切れますが、shim はそれを見ずに
常にコンパイルします。

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
