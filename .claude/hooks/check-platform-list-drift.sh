#!/usr/bin/env sh
# PostToolUse hook: 対象 platform の一覧を持つファイルが、正本より短いまま
# 置いていかれていないかを検出する。
#
# このリポジトリには「配る native plugin の一覧」を持つ場所が 6 つある。
# 語彙が違う（ファイルのパス / platform 名 / Unity の BuildTarget / YAML の
# matrix）ので、**grep 1 回では揃わない。**
#
# 実測（M4、3 platform -> 5 platform）: 3 件のまま残った一覧が **3 つ**
# 見つかった。うち 1 つは、一度直したのに `git checkout --` で巻き戻して
# **再発した。**
#
# 壊れ方が悪い。片方は「揃っていないのに全部入りとして扱う」、もう片方は
# 「知らないファイルとして拒む」で、**どちらもビルドは通る。**
#
# 正本は tools/dev.ps1 の $script:AllPlatformBinaries である。
# **写さずにそこから読む** —— platform が増えたら、この hook の判定も
# 一緒に増える。
#
# 述語: 正本の 3 件以上を名指ししているファイルは「全件の一覧」と見なし、
# 全件を要求する。**リポジトリ全体に当てて誤検出 0 を実測してある**
# （6 ファイルが該当し、6 つとも 5/5）。3 件未満のファイルは、
# 意図して一部だけを扱っている（例: Linux の移植性検査）ので対象外。
#
# **見えないもの: 同じファイルの中の、2 つ目以降の一覧。** 判定はファイル
# 単位なので、正しい 5 件の一覧と古い 3 件の一覧が同居していると通る。
# 実物がそうだった —— tools/tests/PackageRelease.Tests.ps1 は 5/5 を満たし
# ながら、その中の $pluginMetas は 3 platform のまま残っていた。
# **そちらは検査側（同ファイルの Assert-That）が正本と突き合わせる。**
# この hook が担うのは「そのファイルが新しい platform を 1 度も知らない」形。
#
# jq が無い環境では黙って素通しする（hook が理由でツールが使えなくなる方が
# 有害なため）。

set -eu

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
[ -n "$file" ] || exit 0
[ -f "$file" ] || exit 0

# 散文は対象外。数は文書にも散らばるが、そちらは milestone-complete の担当。
case "$file" in
  *.md | *.md.meta) exit 0 ;;
esac

# 正本の場所を cwd に依存させない。hook は任意の cwd で呼ばれうる。
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
canon_src="${repo_root:-.}/tools/dev.ps1"

# 正本から読む。写さない。
if [ -f "$canon_src" ]; then
  canon=$(sed -n '/AllPlatformBinaries[[:space:]]*=[[:space:]]*@(/,/^)/p' "$canon_src" \
          | sed -n "s/^[[:space:]]*'\([^']*\)'.*/\1/p")
else
  canon=""
fi

# **「見つからない」も「解析できない」も、同じだけ声を上げる。**
# 以前は前者を無言で通していた（実測）—— 正本が消えても改名されても、
# この hook は何も言わずに何も見なくなる。
#
# 件数の下限も見る。判定は「3 件以上を名指ししているファイル」を対象に
# するので、正本が 3 件未満に読めた時点で**その判定は原理的に成立しない**
# （配列が 1 行に畳まれた等）。数えられないまま黙るより、落とす。
canon_count=$(printf '%s\n' "$canon" | grep -c '[^[:space:]]' || true)
if [ -z "$canon" ] || [ "$canon_count" -lt 3 ]; then
  # **黙って素通ししない。** 読めないまま通すと、この hook は何も見ない
  # ようになり、しかも指摘が出ないので気づけない。
  jq -n '{
    systemMessage: "platform 一覧の正本を読めませんでした",
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: "tools/dev.ps1 の $script:AllPlatformBinaries を読み取れませんでした。書き方が変わった可能性があります。check-platform-list-drift.sh の抽出を直してください（読めない間、この hook は platform 一覧のずれを検出しません）。"
    }
  }'
  exit 0
fi

total=0
found=0
missing=""
# here-doc を done に付けると、加算がサブシェルに閉じ込められない。
while IFS= read -r p; do
  [ -n "$p" ] || continue
  total=$((total + 1))
  # **部分一致にしない。** '…/libopencv_unity_native.a' は
  # '…/libopencv_unity_native.a.meta' の一部でもあるので、素の grep -F だと
  # **.meta だけを並べたファイルが「binary が揃っている」と判定される**
  # （実測で再現した）。PackageRelease.Tests.ps1 で一度潰した欠陥の再導入で、
  # 「.meta は足したが binary を足し忘れた」を見逃す。
  #
  # **正規表現に逃げない。** パスに含まれる '.' を環境依存なくエスケープ
  # するのが難しく（この環境の sed で実際に空振りした）、壊れたエスケープは
  # 「常に真」か「常に偽」になって静かに検査を殺す。
  # 代わりに固定文字列の出現回数を比べる: パス自身の出現が、'.meta' 付きの
  # 出現より多ければ、binary そのものを名指ししている行が在る。
  hits=$(grep -oF -- "$p" "$file" 2>/dev/null | wc -l)
  meta_hits=$(grep -oF -- "$p.meta" "$file" 2>/dev/null | wc -l)
  if [ "$hits" -gt "$meta_hits" ]; then
    found=$((found + 1))
  else
    missing="$missing
  - $p"
  fi
done <<CANON
$canon
CANON

# 3 件未満なら「全件の一覧」ではない。
[ "$found" -ge 3 ] || exit 0
[ "$found" -lt "$total" ] || exit 0

# 意図して一部だけを扱う場合は、理由を添えて明示的に許す。
if grep -q 'PLATFORM_LIST_OK:' "$file" 2>/dev/null; then
  exit 0
fi

context="platform の一覧が正本より短いままです: $file

正本 $total 件のうち $found 件しか名指ししていません。欠けているもの:
$missing

正本は $canon_src の \$script:AllPlatformBinaries です。

このリポジトリでは M4 で同じ形が 3 つ見つかりました（3 platform 用の一覧が
5 platform になっても 3 件のまま残った）。**どちらもビルドは通ります** ——
壊れるのは「揃っていないのに全部入りとして扱う」か「知らないファイルとして
拒む」のどちらかで、**気づくのは配った後か CI の Unity レーンです。**

一覧を持つ場所の全体は add-a-platform skill にあります。

意図して一部だけを扱う場合は、その近くに PLATFORM_LIST_OK: と理由を
書いてください。"

jq -n --arg msg "platform 一覧のずれ: $file ($found/$total)" --arg ctx "$context" '{
  systemMessage: $msg,
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $ctx
  }
}'
