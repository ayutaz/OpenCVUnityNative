#!/usr/bin/env sh
# PreToolUse hook: **OpenCV をローカルでビルドさせない。**
#
# `CLAUDE.md` はこれを 3 箇所で書いている:
#
#   - 確定事項の表:「allowlist 構成で CI がビルドし artifact 配布。
#     **ローカルではビルドしない**」
#   - 不変条件:「**ローカルループは秒単位を死守する。** 重い処理を持ち込まない。
#     OpenCV はローカルでビルドせず、CI が生成した artifact を download する」
#   - `opencv.ps1 build` の行:「ローカル再現用の遅い経路。
#     **CI の結果を検証するときだけ使う**」
#
# **3 箇所書いてあっても踏んだ。** 2026-09-03、M6（Web / Wasm）で新しい
# platform の CMake flag を探すために **5 回続けてローカルで回した。**
# 1 回あたり 10〜40 分で、しかも 5 回とも落ちた。**これは「検証」ではなく
# 「反復」で、まさに禁じられている使い方である。**
#
# **文書は読まれても効かなかったので、機械に見させる。**
#
# ---
#
# **なぜローカルで回したくなるのか**（次に踏む人のために書いておく）:
# 新しい platform を足すときだけは「CI に投げる → 20〜40 分待つ → 1 行直す」
# の繰り返しになり、手元で回したほうが速く見える。**見えるだけである** ——
# 上のとおり手元でも 10〜40 分かかり、しかも手元の環境は CI と違うので、
# **通っても CI で通る保証にならない。**
#
# `add-a-platform` skill が「CI 往復を前提に計画する」と書いているのは
# この状況のことで、M4 では**クロスビルドが緑になってから CI で 8 回落ちた。**
# **往復は避けるものではなく、この作業の既定の形である。**
#
# ---
#
# **逃げ道**: 本当にローカルで回す必要があるなら（CI の結果を検証する、
# CI が構造的に落ちる原因を切り分ける）、環境変数を明示的に置く:
#
#     OCVU_ALLOW_LOCAL_OPENCV_BUILD=1 ./tools/opencv.ps1 build -Platform ...
#
# **意図して回したことが履歴に残る形にしてある。**
#
# jq が無い環境では黙って素通しする（hook が理由でツールが使えなくなる方が有害）。

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
command=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$command" ] || exit 0

# `opencv.ps1 build` を探す。連結コマンドの中も見る。
# `restore` / `verify` / `status` / `clean` は止めない —— 止めたいのは build だけ。
printf '%s' "$command" \
    | grep -Eq 'opencv\.ps1[^;&|]*[[:space:]]build([[:space:]]|$)' \
    || exit 0

# 明示的な逃げ道。コマンドの中で渡す形と、既に環境に在る形の両方を見る。
printf '%s' "$command" | grep -q 'OCVU_ALLOW_LOCAL_OPENCV_BUILD' && exit 0
[ -n "$OCVU_ALLOW_LOCAL_OPENCV_BUILD" ] && exit 0

cat >&2 <<'EOF'
OpenCV をローカルでビルドしようとしています。**このリポジトリはそれをしません。**

  CLAUDE.md:「allowlist 構成で CI がビルドし artifact 配布。ローカルではビルドしない」
  CLAUDE.md:「ローカルループは秒単位を死守する。重い処理を持ち込まない」

代わりにすること:

  - 既存の構成なら          ./tools/opencv.ps1 restore
  - 構成を変えたなら        変更を push して build-opencv を走らせ、
                            artifact が出てから restore する
  - 新しい platform なら    build-opencv.yml の matrix に足して CI に作らせる

**新しい platform の flag 探しを手元でやらないこと。** 2026-09-03 に M6 で
5 回続けて回し、5 回とも落ちた（1 回 10〜40 分）。手元の環境は CI と違うので、
**通っても CI で通る保証にならない。** add-a-platform skill の
「CI 往復を前提に計画する」を読むこと —— 往復は避けるものではなく既定の形です。

本当に必要なら（CI の結果の検証、CI 側の切り分け）、明示してください:

  OCVU_ALLOW_LOCAL_OPENCV_BUILD=1 ./tools/opencv.ps1 build -Platform <platform>
EOF
exit 2
