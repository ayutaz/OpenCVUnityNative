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

canon_src="tools/dev.ps1"
[ -f "$canon_src" ] || exit 0

# 正本から読む。写さない。
canon=$(sed -n '/AllPlatformBinaries[[:space:]]*=[[:space:]]*@(/,/^)/p' "$canon_src" \
        | sed -n "s/^[[:space:]]*'\([^']*\)'.*/\1/p")

if [ -z "$canon" ]; then
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
  if grep -qF "$p" "$file" 2>/dev/null; then
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
