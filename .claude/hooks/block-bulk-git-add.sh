#!/usr/bin/env sh
# PreToolUse hook: `git add -A` / `git add .` を拒否する。
#
# このリポジトリは build/、bin/、obj/、artifacts/ を .gitignore しているが、
# 一括 add はそれ以外の意図しないファイル（生成物、一時的なデバッグ変更、
# 別作業の途中経過）まで巻き込む。M0 では全 8 タスクのディスパッチで
# 「変更したパスだけを個別に stage せよ」と手で書き続けた。それを機械化する。
#
# 実行系について: このフックは PowerShell ではなく sh で書いてある。
# 計測したところ、この環境では pwsh の起動に約 3.3 秒、python に約 2.4 秒
# かかるのに対し sh は約 0.12 秒だった。フックは毎回のツール呼び出しで走るため、
# 起動コストがそのまま開発ループの速度になる。副次的に macOS / Linux でも
# そのまま動くので、M3 でプラットフォームが増えても書き直さなくてよい。
#
# jq が無い環境では黙って素通しする（fail-open）。フックが理由でツールが
# 一切使えなくなる方が、ガードが 1 つ無いことより有害なため。

set -u

payload=$(cat)
[ -n "$payload" ] || exit 0

# 速い経路: "git add" という文字列すら無いなら、jq を起動せずに抜ける。
# このフックはあらゆるシェル呼び出しで走るので、素通しの場合のコストが
# そのまま開発ループの速度になる。ここは組み込みの case だけで判定する。
case "$payload" in
    *"git add"*) ;;
    *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# `cd foo && git add -A` のような連結コマンドも見る必要があるため、
# 区切り文字で分割してから各セグメントを調べる。
segments=$(printf '%s' "$cmd" | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/;/\n/g' -e 's/|/\n/g')

# 一括 add とみなす引数。完全一致でのみ拒否する。
# `git add .claude/settings.json` のようにドットで始まるパスを
# 巻き込まないよう、前方一致ではなく完全一致で判定する。
offender=$(
    printf '%s\n' "$segments" | while IFS= read -r segment; do
        echo "$segment" | grep -qE '(^|[[:space:]])git[[:space:]]+add([[:space:]]|$)' || continue
        args=$(echo "$segment" | sed -E 's/^.*(^|[[:space:]])git[[:space:]]+add[[:space:]]*//')
        for arg in $args; do
            bare=$(printf '%s' "$arg" | tr -d '"'"'")
            case "$bare" in
                -A | --all | --no-ignore-removal | . | :/ | :)
                    printf '%s\n' "$bare"
                    ;;
            esac
        done
    done | head -1
)

[ -n "$offender" ] || exit 0

reason=$(printf '%s' "この一括 add は拒否されました: \`git add ${offender}\`

変更したパスを個別に指定してください。例:
  git add native/src/ocvu_mat.cpp native/tests/test_mat.cpp

一括 add は生成物や別作業の途中経過を巻き込みます。
何を変更したか分からない場合は、まず \`git status --short\` で確認してください。")

jq -n --arg reason "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
