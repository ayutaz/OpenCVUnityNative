# C ABI の所有権と versioning

**状態: 確定（2026-08-26、M2 着手前）。** `docs/unity-opencv-integration-research-and-plan.md` §12 が
未決定として挙げていた 3 件のうち、M2 が必要とする分をここで決める。

M2 の目的は API の広さではなく契約の正しさである。ここで決めた規約は M5 の generator が
複製するので、曖昧さを残すと誤りが増殖する。

---

## 1. Unity のメモリを借りる規約

### 決定

**Unity が所有するメモリを指す handle を返さない。** 借用は 1 回の ABI 呼び出しの内側で
完結し、呼び出しが戻った時点で終わる。

`ocvu_mat_handle` が指す `cv::Mat` は、**常に native 側が確保して native 側が解放する**。
例外は無い。Unity 側の buffer は、その場でポインタ・長さ・stride を受け取って読み書きする
だけで、handle にはならない。

### なぜ

Unity は自分の都合でメモリを捨てられる。テクスチャの更新、確保方式による自動解放、利用者に
よる明示的な破棄のいずれでも起きる。こちらが借りた handle を保持したままそれが起きると、
存在しないメモリへの読み書きになる。

壊れ方が問題である。**即座に落ちず、後から無関係な場所が壊れる。** 発生するのは配布された
Player の中であり、Windows の AddressSanitizer は Unity のアロケータを見られない
（リーク検出そのものが非対応で、M3 の Linux レーンの担当）。

`docs/native-backend-language-tdd-evaluation.md` の評価表がこの状態を最も危険と位置づけている:

> エージェントは所有権ミスを必ず作る。テストが green でも UB が残る状態が最も危険

「呼ぶ側が正しく解放すること」という規約は、この危険を**文章で禁じるだけ**で、機械的には
何も強制しない。借用 handle を作らなければ、その誤りは**表現できなくなる**。禁じるのではなく
作れなくする方を選ぶ。

### この決定が受け入れているコスト

複数の処理を連ねるとき、Unity 側の buffer に対して毎回ポインタと形状を渡し直すことになる。
handle を 1 つ持って続けて呼ぶ、という書き方はできない。

これは既存方針と矛盾しない。`CLAUDE.md` は既に
「毎フレームの細かな境界呼び出しを避ける。必要に応じて処理をまとめた粒度の粗い API も用意する」
と定めている。粗い粒度の API では、1 回の呼び出しの中で複数の処理が終わる。

低コピー連携も失われない。Unity の buffer から native の `Mat` へ入れる／戻すのは 1 回ずつの
コピーで、OpenCV の各処理の間で往復は発生しない。捨てているのは「Unity のメモリの上で
直接 OpenCV を動かす」形だけである。

### roadmap の完了条件との食い違い（重要）

`docs/roadmap.md` の M2 完了条件は次の 2 点を挙げている。

> - `ocvu_mat_*`（create / **wrap** / clone / query / release）
> - 所有権契約が L3 で明示的にテストされている — borrowed と owned の区別、二重解放、
>   解放後アクセス、**Unity 側 buffer を wrap した際の lifetime**

この決定は `wrap`（Unity の buffer を handle にする関数）を**作らない**ので、上記 2 点は
そのままでは満たせない。文言を実装に合わせて更新する。

- `wrap` は `ocvu_mat_copy_from_buffer` / `ocvu_mat_copy_to_buffer` に置き換える
- 「wrap した際の lifetime」のテストは、「借用 handle が存在しないこと」と
  「buffer 引数の検証（長さ・stride の不整合、NULL）」のテストに置き換える
- 「borrowed と owned の区別」は残る。ただし区別されるのは handle の種類ではなく、
  **handle（常に owned）と buffer 引数（常に borrowed、呼び出し内で完結）** である

**この置き換えは完了条件の緩和ではない。** 検証すべき危険が消えたのではなく、危険な状態を
作れなくしたので、その状態が作られていないことを検証する形に変わっている。

---

## 2. C ABI の versioning と後方互換

### 決定

`OCVU_ABI_VERSION` は**単一の整数**のままとし、C# 側は**完全一致**で検査する。

native library と C# は同じ UPM パッケージで同時に配布されるので、両者がずれるのは
利用者が古い DLL を混ぜた場合など、事故のときだけである。「以上」で通すと、その事故を
見逃す方向に働く。完全一致なら必ず検出できる。

### bump する変更

- 既存関数の signature（引数の数・型・順序、戻り値の型）が変わる
- 既存 struct の layout・field の意味・サイズが変わる
- 既存 status code の**数値**または**意味**が変わる
- 既存関数が削除される、または名前が変わる
- 既存の呼び出しに対する挙動が変わる（同じ入力に別の status を返すようになる等）

### bump しない変更

- 新しい関数を足す
- `OCVU_STATUS_LIST` の**末尾**に新しい status code を足す
- 実装の内部変更で、観測できる挙動が変わらないもの
- コメント・文書

status の追加が bump にならないのは、**呼ぶ側が未知の status を扱えることを契約にしている**
ためである。`OCVU_STATUS_OK` と `OCVU_STATUS_BUFFER_TOO_SMALL` 以外はすべて失敗として扱う
（C# 側の `CvNative.IsFailure` がこの形になっている）。網羅的な分岐を書いて未知の値で壊れる
呼び出し側は、この契約に従っていない。

### 検査

`OCVU_ABI_VERSION` と C# の期待値が一致することは L3 が既に見ている
（`AbiContractTests.AbiVersion_MatchesTheVersionThisPackageWasBuiltAgainst`）。
status 表の同期は `StatusCodeSyncTests` が見ている。**この 2 つを消さないこと。**

---

## 3. 初期 API の allowlist

M2 で公開する `ocvu_` 関数は次で全部とする。広さを追わないのが M2 の目的である。

### Mat のライフサイクル

| 関数 | 内容 |
| --- | --- |
| `ocvu_mat_create` | rows / cols / type を指定して確保する。**native が所有する** |
| `ocvu_mat_release` | 解放する。二重解放は検出して status を返す（落とさない） |
| `ocvu_mat_clone` | 内容を複製した別の owned handle を作る |
| `ocvu_mat_get_info` | rows / cols / type / channels / step / 総バイト数を struct で返す |

### Unity の buffer との受け渡し（借用は呼び出し内で完結）

| 関数 | 内容 |
| --- | --- |
| `ocvu_mat_copy_from_buffer` | 外部 buffer から Mat へ。ポインタ・長さ・stride を受け取り、**整合を検証してから**書く |
| `ocvu_mat_copy_to_buffer` | Mat から外部 buffer へ。同上 |

長さと stride は必ず検証し、buffer が `stride * rows` 分の長さを持たないなら
`OCVU_STATUS_INVALID_ARGUMENT` を返して何も書かない。**呼ぶ側を信用しない。**

**この検査で `stride * rows` を計算してはならない。** `stride` は呼び出し側が
自由に決める `int64_t` なので積が桁あふれし、負に反転して比較が偽になる。M2 の
初回実装がこれを踏み、`stride = 2^62` で検証を素通りしてアクセス違反に至った
（レビューで再現）。`stride > length / rows` と書けば乗算が無く、あふれる余地も無い。

### imgproc

| 関数 | 内容 |
| --- | --- |
| `ocvu_cvt_color` | 色空間変換 |
| `ocvu_resize` | 拡大縮小 |
| `ocvu_gaussian_blur` | ぼかし |

いずれも入出力とも owned handle を取る。

### 情報の問い合わせ（既存）

`ocvu_get_abi_version` / `ocvu_get_opencv_version` / `ocvu_get_build_information` は M1 で
存在する。M2 の完了条件「ABI version / OpenCV version / build features を実行時に
問い合わせられる」はこれで満たされている。

### M2 で作らないもの

`Mat` の部分参照（ROI）、型変換、算術演算、チャンネル分離、`imgcodecs` の読み書き、
`WebCamTexture` 連携。いずれも契約が固まってから足す。

---

## 参照

- `CLAUDE.md` — 「アーキテクチャの中核」の不変条件。この文書はその具体化である
- `docs/roadmap.md` — M2 の目的・ゴール・完了条件（上記 §1 の食い違いに従って更新済み）
- `.claude/skills/add-abi-function/SKILL.md` — 関数を 1 本足すときの TDD 順序
