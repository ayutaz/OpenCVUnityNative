#!/usr/bin/env sh
# PostToolUse hook: 公開 ABI 関数の例外バリア囲い忘れを検出する。
#
# C++ 例外が extern "C" 関数を抜けて FFI 境界を越えると未定義動作になる。
# IL2CPP / CLR の P/Invoke フレームへ unwind した先で何が起きるかは保証がない。
# このため公開 ABI 関数は OCVU_TRY_BEGIN / OCVU_TRY_END で本体を囲み、
# 例外を status code と thread-local last-error に変換する。
#
# 検査対象は `ocvu_status` を返す extern "C" 関数だけである。
# int32_t を返す関数（ocvu_get_abi_version、ocvu_get_status_count）は
# OCVU_TRY_END の return と型が合わないので構造的に対象外。
#
# 除外:
#   - ocvu_get_last_error_status / ocvu_get_last_error_message
#     OCVU_TRY_BEGIN は clear_last_error() を呼ぶ。エラーを報告するために
#     存在する関数を囲むと、報告すべきエラーを読む直前に自分で消してしまう。
#   - 直前 10 行のコメントに OCVU_NO_TRY_BARRIER: と理由を書いた関数
#     将来「囲えないが throw し得ない」関数が出た場合の逃げ道。
#     理由がソースの隣に残ることを条件にする。
#
# 根拠は native/src/ocvu_error.h のマクロ定義の隣に書いてある。
#
# 実行系の選定理由と fail-open 方針は block-bulk-git-add.sh の冒頭を参照。

set -u

payload=$(cat)
[ -n "$payload" ] || exit 0

# 速い経路: native/src のパスを含まないなら jq を起動せず抜ける。
case "$payload" in
    *"native/src"* | *'native\\src'*) ;;
    *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null) || exit 0
[ -n "$file" ] || exit 0

printf '%s' "$file" | grep -qE '[/\\]native[/\\]src[/\\].+\.(cpp|cc|cxx)$' || exit 0
[ -f "$file" ] || exit 0

# awk で 1 パスする。extern "C" ocvu_status の定義ごとに、次の extern "C"
# までを本体とみなし、その中に OCVU_TRY_BEGIN があるかを見る。
unguarded=$(awk '
    /OCVU_NO_TRY_BARRIER:/ { optout = NR }

    /extern[ \t]+"C"/ {
        if (pending != "" && !guarded) print pendingLine ": " pending
        pending = ""; guarded = 0
    }

    /extern[ \t]+"C"[ \t]+ocvu_status[ \t]+ocvu_[A-Za-z0-9_]*[ \t]*\(/ {
        name = $0
        sub(/^.*extern[ \t]+"C"[ \t]+ocvu_status[ \t]+/, "", name)
        sub(/[ \t]*\(.*$/, "", name)

        if (name == "ocvu_get_last_error_status") next
        if (name == "ocvu_get_last_error_message") next
        if (optout > 0 && NR - optout <= 10) next

        pending = name; pendingLine = NR; guarded = 0
        next
    }

    /OCVU_TRY_BEGIN/ { guarded = 1 }

    END { if (pending != "" && !guarded) print pendingLine ": " pending }
' "$file")

[ -n "$unguarded" ] || exit 0

listing=$(printf '%s' "$unguarded" | sed 's/^/  /')
names=$(printf '%s' "$unguarded" | sed 's/^[0-9]*: //' | tr '\n' ' ' | sed 's/ $//')

reason=$(printf '%s' "例外バリアで囲まれていない公開 ABI 関数があります: ${file}

${listing}

C++ 例外が extern \"C\" 関数を抜けて FFI 境界を越えると未定義動作になります。
\`ocvu_status\` を返す公開 ABI 関数は本体を次で囲んでください:

    extern \"C\" ocvu_status ocvu_example(int32_t value) {
        OCVU_TRY_BEGIN
        // ここに本体。throw し得る処理はすべてこの内側に置く。
        return OCVU_STATUS_OK;
        OCVU_TRY_END
    }

OCVU_TRY_BEGIN は clear_last_error() を呼び、OCVU_TRY_END は例外を
status code と thread-local last-error に変換します（native/src/ocvu_error.h）。

囲えないことに正当な理由がある場合は、関数の直前のコメントに OCVU_NO_TRY_BARRIER:
と理由を書いてください。囲まない条件は「throw し得ない実装であること」です。
エラー報告関数（ocvu_get_last_error_status / ocvu_get_last_error_message）は
囲うと報告すべきエラーを自分で消すため、最初から除外されています。

確認: pwsh tools/dev.ps1 test-native")

jq -n --arg reason "$reason" --arg names "$names" '{
  systemMessage: ("例外バリアの囲い忘れ: " + $names),
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $reason
  }
}'
