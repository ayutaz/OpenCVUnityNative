---
name: prove-a-check-works
description: Use when adding or changing anything whose job is to catch a problem - a test, an assertion, a validation script, an allowlist, a CI gate, a hook. Establishes that the check actually fails when what it guards is broken, and that it covers the shape production supplies rather than the shape its author had in mind. Triggers on writing a new test or assertion, adding a validation or verification step, changing an allowlist or denylist, or reporting that a check passes.
---

# 検査が本当に検査していることを示す

**通ったことは、見ていることの証拠にならない。** 何も見ていない検査も通る。

M1 では、実装の各タスクが同じ欠陥を 1 つずつ生んだ。名前は違うが構造は同一である。

| タスク | 検査が見ていた形 | 外に落ちた隣の形 |
| --- | --- | --- |
| T1 | 区切り文字で join したハッシュ | 区切り文字を値に含む要素 |
| T2 | 終了コード | StrictMode の scalar 例外で「成功」した経路 |
| T3 | 拡張子と場所（denylist を allowlist と呼んでいた） | 想定外の名前・隠し属性・列挙されないファイル |
| T4 | 指定したコンパイラ | PATH から拾われた MinGW アセンブラ |
| T5 | 存在する manifest | 0 バイト・`[]`・`42`・空白だけの manifest |
| T7 | 送信した CMake flag | 上流の cmake が黙って上書きした結果 |
| F1 | `getBuildInformation()` の戻り値 | 本番が渡す cmake stdout（各行に `-- ` が付く） |
| F5 | 新しい license ファイルが増えたこと | 一覧に名前を足すだけで緑に戻せること |

**共通形: 著者が列挙した形は塞がれ、その隣が外に落ちる。** 列挙を長くしても閉じない。
次に足されるものは、その一覧に載っていない。

## 手順

### 1. 失敗を既定にする

「怪しいものを弾く」ではなく「積極的に認識されたものだけを通す」形にする。

分類できないものが `return $true` や `continue` に落ちる構造は、常に間違っている。
`verify-opencv-artifact.ps1` の冒頭にこの不変条件が書いてある:

> ツリーの下のどのファイルも、何かに積極的に認識されない限り
> 「問題無し」の判定に到達してはならない。

### 2. 本番が渡す入力で書く

**推測した入力に対して正しいテストは、検証しているように見えて何も見ていない。**

書く前に、本番の経路が実際に何を渡すか確かめる。関数を呼ぶ、ログを見る、実物を出力する。
形式が 2 通りあるなら両方を固定する。

F1 はこれを外した。抽出器のテストは `getBuildInformation()` の戻り値を使い、本番は
cmake の stdout を渡していた。内容は同じでも行頭が違い、本番だけが常に 0 件を返して
いた。テストは緑のままだった。

T7 も同じで、計画が推測した期待文字列（`FFMPEG: YES` の桁揃え）は実物に一度も現れず、
書いていれば永久に通る assertion になっていた。

### 3. 壊して、落ちることを見る

**これを飛ばしてよい検査は無い。**

検査対象をわざと壊し、検査が落ちることを確認してから戻す。

```
# 壊す（1 行変えるだけでよい）
pwsh -NoProfile -File <test>; echo $?   # 1 を期待
# 戻す
pwsh -NoProfile -File <test>; echo $?   # 0 を期待
```

両方の数字を実際に見るまで、その検査は「動く」と言えない。M1 では次がこれで見つかった:

- 回帰テストを集計ブロックの**後ろ**に書いていた。PASS 表示は出るが終了コードに
  影響せず、落ちないテストになっていた（hook `check-assertions-reachable.sh` が
  以後これを見る）
- 一覧と通知文書を突き合わせる検査が、実際に欠落を検出することの確認

### 4. 終了コードを見る。出力を数えない

`grep -c PASS` は検査ではない。失敗した実行にも PASS 行は出る。

M1 では実際に、`test-tools-slow` を「27 PASS 緑」と報告した直後に、その実行が
exit 1 だったことが分かった。PASS 行を数えて終了コードを見ていなかった。

パイプを通すと `$?` はパイプ最後のコマンドの値になる。`| tail -3` を付けたまま
`echo $?` すると `tail` の終了コードを読むことになる。

```
cmd > /tmp/out.txt 2>&1; echo $?    # これは cmd の終了コード
cmd | tail -3; echo $?              # これは tail の終了コード
```

### 5. その検査が実際に走る場所を確かめる

**どのレーンからも走らないテストは、検証機構ではない。**

`CLAUDE.md` は「CI が唯一の正本の検証結果」と定めている。人が思い出したときだけ
走るものは、その基準を満たさない。

書いたら `tools/dev.ps1` の該当サブコマンドか、`.github/workflows/` のどこかに
実際に配線されていることを `grep` で確認する。コメントに「CI 側の担当」と書くのは
配線ではない。M1 ではまさにこれが起きた — comment がその分担を宣言していたが、
どの workflow もそのファイルを呼んでいなかった。

秒単位のローカルループに乗らない重い検査は `test-tools-slow` に置き、CI で走らせる。
どちらにも置かない、という選択肢は無い。

### 6. 一段先が空いていないか見る

検査が落ちたとき、**何をすれば緑に戻るか**を考える。その操作だけで戻せてしまい、
本来直すべきものが直らないなら、そこが次の穴である。

F5 がこれだった。新しい license ファイル → verify が落ちる → 一覧に名前を足す →
緑に戻る。利用者が読む文書は放置されたままで、何も赤くならない。

## やってはいけないこと

- 通ったことを、検査していることの証拠として報告する
- 推測した入力形式に対して assertion を書く（実物を見ずに）
- 壊して落ちることを確認せずに「テストを追加した」と報告する
- 出力の PASS 行を数えて緑と判断する
- 検査を書いたが、どこからも呼ばれていない状態で完了とする
- 列挙を 1 つ足して「同種の問題を塞いだ」とする

## 参照

- `tools/verify-opencv-artifact.ps1` 冒頭 — 積極的認識の不変条件と、それを破った 2 例
- `.claude/hooks/check-assertions-reachable.sh` — 終了コードに効かない assertion の検出
- `docs/roadmap.md` M1 の「既知の欠陥」 — 構成ハッシュが入力を固定し、出力を見ない件
