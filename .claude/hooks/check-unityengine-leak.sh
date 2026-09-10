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
# <Compile> 要素のうち、**Include が $(OcvuPackageRuntime) を根に持つもの**
# である —— shim がコンパイルするフォルダが、そのまま「UnityEngine を
# 参照してはならない」フォルダの定義だからである。
# **「csproj の <Compile> を全部読む」ではない。** リテラルの相対パスで
# 同じフォルダを指す書き方は対象外で、そのフォルダは検査されない。
# 何を除いているかと、その理由は下の抽出のところに書いてある。
# **「行」ではなく「要素」を、合計ではなく要素ごとに見る。** そこも同じ。
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
# **読むのは <Compile> 要素のうち、Include が $(OcvuPackageRuntime) を根に
# 持つものだけである。** これは「csproj の <Compile> を全部読む」より狭い。
# **除いているもの**: リテラルの相対パスで同じフォルダを指す書き方
# （<Compile Include="..\..\..\Packages\...\Runtime\Cuda\**\*.cs" />）は
# 下の grep -F で落ち、そのフォルダはこの hook の対象にならない。
# **意図してそうしてある**（プロパティ経由が現在の唯一の書き方で、
# リテラル解決はこの hook の仕事ではない）が、**書き方を変えるなら
# ここも変える必要がある。** 網羅していると読ませないために明記しておく。
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

# **黙って素通ししない。** 読めないまま通すと、この hook は何も見なくなり、
# しかも指摘が出ないので気づけない（check-platform-list-drift.sh と同じ判断）。
#
# **そして、合計で守らない。要素ごとに守る。**
# ここは 2 度作り直している。1 度目は「N 件以上読めたか」（`-lt 2`）で、
# **4 フォルダのうち 2 つしか読めない誤読を、2 件読めているという理由で
# 通した。** 2 度目は合計 3 本（要素数・パス数・フォルダ数）の突き合わせで、
# **合計は釣り合わせられた** —— 実測: 3 パスを持つ要素 1 つと、
# `Include =` に空白があって 1 つも読めない要素 1 つを並べると
# 要素 2 / パス 3 / フォルダ 3 で 3 本とも成立し、**Runtime/Dnn が黙って
# 無防備になった。** 閾値より 1 段難しいだけで、形は同じである ——
# **誤った読みが門を満たす。**
#
# **合計は集約であり、情報は要素の側にある。** だから
# **「変数を根に持つ <Compile> 1 つにつき、その要素の Include から
# フォルダがちょうど同じ数だけ取れたか」**を要素ごとに見る。
# **この 1 本が、以前の合計 3 本のうち 2 本を吸収した** ——
# 「パスを 1 つ落とした」も「要素ごと落とした」も、要素の中で見れば
# 同じ 1 つの不一致になる。残したのは下限（要素が 1 つも無ければ
# 読めていない）だけで、そちらは要素ごとの検査では原理的に代替できない
# （要素が 0 個なら、要素ごとの検査は空虚に真になる）。
#
# **Include の書き方は MSBuild に合わせる**: 引用符は二重・単重の両方、
# `=` の前後の空白、そして **1 つの Include に ';' 区切りで複数のパス**。
# **Remove= / Update= は Include を持たないので、変数を名指ししていれば
# ここで声を上げて止まる。** それは意図した振る舞いである（対象フォルダを
# 減らす操作を、黙って無視するより止めたい）—— 実際に使うなら、この抽出を
# 拡張すること。**解析器の欠陥ではない。**
elem_count=$(printf '%s\n' "$compile_elements" | grep -c '[^[:space:]]' || true)
folders=""
bad_element=""
bad_detail=""

# here-doc を done に付けると、代入がサブシェルに閉じ込められない
# （check-platform-list-drift.sh と同じ形）。
while IFS= read -r elem; do
    [ -n "$elem" ] || continue
    [ -z "$bad_element" ] || continue

    e_paths=$(
        {
            printf '%s\n' "$elem" |
                sed -n 's/.*[Ii]nclude[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p'
            printf '%s\n' "$elem" |
                sed -n "s/.*[Ii]nclude[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p"
        } | tr ';' '\n' | grep '[^[:space:]]' || true
    )
    e_refs=$(printf '%s\n' "$e_paths" | grep -cF '$(OcvuPackageRuntime)' || true)
    e_folders=$(
        printf '%s\n' "$e_paths" |
            sed -n 's/^[[:space:]]*$(OcvuPackageRuntime)[\\/]\([^\\/]*\)[\\/].*/\1/p'
    )
    e_count=$(printf '%s\n' "$e_folders" | grep -c '[^[:space:]]' || true)

    if [ "$e_refs" -lt 1 ] || [ "$e_count" -ne "$e_refs" ]; then
        bad_element=$(printf '%s' "$elem" | cut -c1-160)
        bad_detail="変数を根に持つパス ${e_refs} / 取り出せたフォルダ ${e_count}"
        continue
    fi

    folders=$(printf '%s\n%s' "$folders" "$e_folders")
done <<ELEMENTS
$compile_elements
ELEMENTS

folders=$(printf '%s\n' "$folders" | grep '[^[:space:]]' || true)

if [ "$elem_count" -lt 1 ] || [ -n "$bad_element" ]; then
    if [ "$elem_count" -lt 1 ]; then
        # $( を二重引用符の中に置くとコマンド置換になる。単引用符で括る。
        detail='$(OcvuPackageRuntime) を根に持つ <Compile> が 1 つも見つかりませんでした'
    else
        detail="この <Compile> からフォルダを取り出せませんでした（${bad_detail}）: ${bad_element}"
    fi
    jq -n --arg src "$shim_csproj" --arg detail "$detail" '{
      systemMessage: "UnityEngine 非依存フォルダの正本を読めませんでした",
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: ($src + " を読み取れませんでした。" + $detail + "\n\n書き方が変わった可能性があります。check-unityengine-leak.sh の抽出を直してください（読めない間、この hook は UnityEngine の混入を検出しません）。**要素ごとに見て、1 つでも読めなければ止めます** —— 合計だけを見ていた頃は、読めない要素と多めに読めた要素が釣り合って素通りしました。")
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
