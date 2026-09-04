# C ABI の所有権と versioning

**状態: 確定（2026-08-26、M2 着手前）。その後、M3 で §1.5（スレッドの規約）、M3.5 で
§1.6（blob の規約）と §3.5（allowlist の追加）を足した。** `docs/unity-opencv-integration-research-and-plan.md` §12 が
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

**stride を取らない借用もある**（M5 の `ocvu_find_homography`）。あれが受けるのは
点の座標が x, y, x, y … と隙間なく並んだ配列で、**行という概念が無いので stride が
意味を持たない。** 受け取るのはポインタと長さの 2 つだけである。
**長さの単位はバイトで統一してある** —— `ocvu_mat_copy_from_buffer` /
`ocvu_mat_copy_to_buffer` / `ocvu_imdecode` と同じで、ここだけ要素数にすると
**既存に慣れた呼び手が 4 倍の値を渡して検査を通過する**方向に倒れる。

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

### 追記（M2 実装後）: ポインタを受ける公開 API を足した

当初この節は「Unity 側の buffer はその場でポインタ・長さ・stride を受け取る」とだけ書き、
その受け取り口が C# のどこに現れるかは書いていなかった。M2 の実装で `CvMat` に
`CopyFrom(IntPtr, long, long)` / `CopyTo(IntPtr, long, long)` を、`Runtime/UnityIntegration/`
に `NativeArray<T>` を受ける拡張メソッドを足したので、ここに記録する。

**「表現できなくする」方針との関係を正確に述べておく。** 借用 handle を作らない決定は
今も守られている — ポインタは handle にならず、native は呼び出しの内側でしか触らず、
戻った後は一切保持しない。表現できなくしたのは「借用したものが呼び出しより長く生きる」
状態であって、「危険な引数を渡せてしまう」ことではない。

ただし `IntPtr` を公開した以上、**寿命の正しさは型ではなく規約が担う**。ポインタの
生存期間は C# の型で表せないからである。これは方針の後退ではなく、方針の適用範囲の
明確化である: 借用を 1 回の呼び出しに閉じ込めてあるからこそ、規約に頼る範囲が
「この呼び出しが戻るまで生かす」の一点で済む。

`NativeArray<T>` 版を別に用意したのは、`IntPtr` 版だけだと利用者側の asmdef に
`allowUnsafeCode` が要り、アドレス取得とバイト長計算を自分で書くことになるためである。
**`NativeArray<T>.Length` は要素数であってバイト数ではない**（`Color32` なら 4 倍ずれる）
ので、その計算を利用者に任せると取り違えがそのまま任意アドレスへの書き込みになる。
拡張メソッド側で `UnsafeUtility.SizeOf<T>()` を掛けている理由はこれである。

**Unity 層は native の検証に依存しきってはならない。** native が見るのは
「stride が 1 行以上か」「stride * rows が長さに収まるか」だけで、渡された長さと stride の
組み合わせが**意味を成すか**は見ない。実際、`ToTexture` がチャンネル数の合わない Mat を
受け取ると、native は成功を返しつつテクスチャの先頭へ一部だけ書いた（実測: 48 バイト中
12 バイト）。`byte[]` 経路では Unity の `LoadRawTextureData` が長さ不一致を例外にしていた
関門が、ポインタ経路では通らなくなっていたためである。安全網を外す変更をするときは、
外した分を同じ層に置き直すこと。

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


## 1.5. 複数スレッドから呼ぶときの規約

**決定（2026-08-28、M3 中に実バグを踏んで追加）。**

この節はもともと存在しなかった。`native/src/ocvu_mat_table.cpp` の実装コメントは
「mutex は Unity のワーカースレッドから同時に呼ばれ得るので必須である」と書いて
いたのに、**呼ぶ側が何をしてよくて何をしてはいけないかは、どこにも書かれて
いなかった。** 書かれていない契約は守りようがないので、ここで固定する。

### 決定

| してよいこと | |
| --- | --- |
| **別々の handle を、別々のスレッドから同時に使う** | 支える。table の内部は mutex で保護され、handle が指す `Mat` のアドレスは他の handle の作成・解放で動かない |
| 同じ handle を、複数のスレッドから同時に**読む**だけ | 支えない（下記のとおり `Mat` 自体は保護しない） |

| してはいけないこと | 起きること |
| --- | --- |
| **同じ handle を、他のスレッドが使っている最中に `ocvu_mat_release` する** | 解放済みの `Mat` へのアクセス。検出されず、後から無関係な場所が壊れる |
| **同じ handle を、複数のスレッドから同時に ABI 関数へ渡す** | `cv::Mat` 自体のデータ競合。OpenCV は個々の `Mat` をスレッド安全にしない |

要するに、**table はスレッド安全だが、`Mat` はそうではない。** handle 1 つを
1 スレッドが持つ限り、いくつ並行して走らせてもよい。

### 「使っている最中」がいつ始まるか

**handle を ABI 関数に渡した瞬間から、その関数が戻るまで**である。「native が
実際に `Mat` のデータへ触れている一瞬」ではない。

この違いが効く実例が `resolve_pair`（`native/src/ocvu_imgproc.cpp`）である。
`ocvu_resize` などは src と dst を**別々に** `mat_table_get` で解決し、その
たびに table の mutex を取って離す。つまり 1 回の ABI 呼び出しの内側にも、
ロックを持たない窓が複数ある——src を解決してから dst を解決するまでと、
両方を解決してから `cv::resize` を呼ぶまで。

この窓の間に別スレッドがどちらかの handle を解放すれば、上の表の
「してはいけないこと」の 1 行目に当たる。**新しい抜け穴ではなく、同じ規約の
具体例である**が、実装を読まないと窓の存在に気づけないので明示しておく。

窓を無くすには、1 回の ABI 呼び出しの間じゅう table のロックを保持するか、
handle ごとに参照カウントを持つことになる。前者は無関係な handle を触る
他スレッドまで待たせるので、上の表の「してよいこと」の 1 行目を実質的に
損なう。後者のコストを払う判断は、実際に困る事例が出てからにする。

### なぜここまで細かく書くか

M3 の最中に、この 2 つの区別が実際に効くバグを踏んだ。table は
`std::vector<Slot>` で `Slot` が `cv::Mat` を**値で**持っており、
`mat_table_get` が返すのはその配列内部を指すポインタだった。別スレッドが
`ocvu_mat_create` を呼んで配列が伸びると、先に解決されたポインタが全部
ぶら下がる。

**壊れるのは `create` した側ではなく、まったく無関係な handle を使っている側
である。** つまり上の表の「してよいこと」の 1 行目 —— 契約上まったく正しい
使い方 —— で壊れていた。`Slot` を `std::unique_ptr<cv::Mat>` にして、
配列が伸びても `Mat` 本体のアドレスが動かないようにして直した
（`native/tests/test_mat_table_stability.cpp` が固定している）。

見つかった経緯も記録しておく価値がある。**ローカルでは 3 回とも通り、同じ
ブランチの直前 3 回の CI も緑だった。** CI の Windows job で L3 の
`Resize_MapsWidthToColsAndHeightToRows` が 1 度だけ落ち、`Expected: 2,
Actual: 1` を出した。xUnit がテストクラスを並列に走らせるため、`resize` の
書き込みが旧バッファへ、直後の `get_info` が引っ越し後の `Mat` へ向かい、
`1x1` のまま残った `dst` を読んでいた。**タイミング依存なので、これを
「フレーク」として再実行していたら、そのまま残っていた。**

### 受け入れているコスト

「してはいけないこと」の 2 つは、**表現できなくする形にしていない。**
借用 handle を作らない決定（§1）は、危険を型で表現不能にすることで守って
いるが、こちらは規約でしか守れない。理由は、これを機械的に防ぐには handle
ごとの参照カウントか読み書きロックが要り、1 回の ABI 呼び出しあたりの
コストが上がるからである。毎フレーム呼ばれる層でそれを払う判断は、
実際に困る事例が出てからにする。

代わりに、**解放済み handle の再利用は世代検査で捕まる**（`OCVU_STATUS_INVALID_HANDLE`）。
捕まらないのは「解放と使用が本当に同時に起きた」場合だけである。

## 1.6. 呼ぶ側が大きさを知り得ない出力（blob）の規約

**決定（2026-08-30、M3.5）。** `ocvu_imencode` が、**出力の大きさを呼ぶ側が事前に
計算できない最初の ABI 関数**である。それまで出力は 2 種類しかなかった —— native が
所有する handle（§1）と、呼ぶ側が形から大きさを決められる buffer（`stride * rows`。
§3 の検証規約）。符号化された画像はどちらでもない: 大きさは中身と codec が決めるので、
`Mat` の形からは導けない。

### 決定

**出力の所有権は最初から最後まで呼ぶ側にある。** 必要量を問い合わせ、呼ぶ側が確保し、
native はそこへ書くだけで、戻った後は一切保持しない。

| 選ばなかった形 | 理由 |
| --- | --- |
| **native が確保した blob を handle で返し、`ocvu_blob_release` で解放させる** | §1 に無い**第 3 の所有権**（native が確保して呼ぶ側が解放を指示する）が増える。解放漏れという新しい壊れ方を、規約でしか防げない形で持ち込むことになる |
| native 側で確保した領域へのポインタを返し、次の呼び出しまで有効とする | 「次の呼び出しまで」はスレッドを跨いだ瞬間に守れない。§1.5 の「別々の handle を別々のスレッドから」と両立しない |

### 2 回呼びの作法

1. 1 回目: `buffer = NULL` / `buffer_size = 0`。`out_required_size` に必要バイト数が入り、
   戻り値は `OCVU_STATUS_BUFFER_TOO_SMALL`。**これは失敗ではない**（§2 のとおり
   `OCVU_STATUS_OK` と `OCVU_STATUS_BUFFER_TOO_SMALL` だけが成功側である。C# の
   `CvNative.IsFailure` がこの形）
2. 呼ぶ側がその大きさの領域を確保する
3. 2 回目: その領域を渡す。成功時、`out_required_size` には**実際に書いたバイト数**が入る

**新しい作法ではない。** last-error message / OpenCV version / build information の取得が
既に同じ形である。新しいのは、これが**診断用の文字列ではなく画像データそのもの**に
適用される点だけである。

規約として固定すること:

- **`out_required_size` は必須**（NULL なら `OCVU_STATUS_NULL_POINTER`）。これが無いと
  呼ぶ側は 2 回目の大きさを決められないので、省略可能にしてはならない。
  **関数の入口で 0 を書く** —— 失敗経路で古い値が残っていると、呼ぶ側はそれを
  必要量として読む
- **足りないときは 1 バイトも書かない。** 部分的に書くと、呼ぶ側は途中まで正しい
  buffer を掴むことになり、壊れ方が分かりにくくなる（§3 の buffer 検証と同じ思想）
- **`buffer_size > 0` なのに `buffer` が NULL は、書く前に断る**（`OCVU_STATUS_NULL_POINTER`）。
  「長さがあるのに領域が無い」は呼ぶ側の取り違えである
- **`int32_t` に収まらない出力は表現しない**（`OCVU_STATUS_INVALID_ARGUMENT`）。
  ABI が `int32_t` で大きさを返す以上、収まらないものは切り詰めずに断る

### blob の検証は buffer の検証とは別形である

`native/src/ocvu_mat_buffer.cpp` の `validate()` は画像の行（`length` / `stride` / `rows` の
整合）を見るが、**符号化された blob には行も stride も無い。** 見るのは長さと NULL だけで
ある。§3 の「`stride * rows` を計算してはならない」という桁あふれの注意は、blob には
そもそも当てはまらない —— 掛け算が無いからである。**同じ関数を使い回さないこと。**

### 入力の blob は §1 の借用そのものである

`ocvu_imdecode` の `data` は、`ocvu_mat_copy_from_buffer` の `src` とまったく同じ扱いで
ある: **この呼び出しの内側でだけ読み、戻った時点で借用は終わる。** 実装は呼ぶ側の
メモリをその場で `cv::Mat` の view で包むが、`cv::imdecode` は自前のメモリに結果を作るので、
関数を抜ける前に view は用済みになる。`length` は 1 以上 `INT32_MAX` 以下（`cv::Mat` の
列数が `int` のため）。**画像として解釈できない byte 列は `OCVU_STATUS_OPENCV_ERROR` で
断り、メモリは壊さない。**

### ファイルパスを受けない

**この決定は所有権とは別の理由による。** (1) Windows の文字コードの扱いが境界に増える。
(2) **Android では `StreamingAssets` が APK の中にあり、パスでは開けない** —— モバイルへ
進む前提（M4）と噛み合わない。ファイルを開くのは呼ぶ側の仕事とし、ABI が受けるのは
メモリ上の byte 列だけにする。

### ABI version は上げていない

関数を足しただけなので `OCVU_ABI_VERSION` は 1 のままである（§2「bump しない変更」）。

## 2. C ABI の versioning と後方互換

> **上流の版を上げるときの前提**（2026-08-30 に確認）。OpenCV の
> [Branches wiki](https://github.com/opencv/opencv/wiki/Branches) は **5.x について
> 「API 互換は保つ、ABI 互換は保たない」**と明記している。したがって 5.0 → 5.1 は
> **再リンクを伴う**（構成ハッシュに tag を混ぜてあるので、機構としては既に成立している）。
> **ただしその明文は破られている** —— PR #29341 が `dnn` の公開列挙子を削除・改名した。
> **明文のポリシーを実測より強い保証として読まないこと。** 経緯は
> [roadmap](./roadmap.md) の M7 節「上流が動いている」にある。


### 決定

`OCVU_ABI_VERSION` は**単一の整数**のままとし、C# 側は**完全一致**で検査する。

native library と C# は同じ UPM パッケージで同時に配布されるので、両者がずれるのは
利用者が古い DLL を混ぜた場合など、事故のときだけである。「以上」で通すと、その事故を
見逃す方向に働く。完全一致なら必ず検出できる。

**M5 で C ABI を module ごとのヘッダに割ったが、`OCVU_ABI_VERSION` は
単一の整数のままである。** 宣言は `native/include/ocvu/{infra,core,imgproc,imgcodecs}.h`
に分かれ、いずれも `bindings/spec/*.json` からの生成物になったが、
**module ごとに版を持たせてはいない** —— 配るのは 1 つの binary で、
**「部分的に古い module」というものが存在しない**からである。
`dnn` を別 target・別 binary にした場合はこの前提が崩れうるので、
**そのとき再検討する**（roadmap の M7 節の決定 1。**この決定の正本はここであって、
あちらではない**）。

**M5 は bump に当たらない。** 既存の関数の signature を 1 本も 1 バイトも変えておらず、
変わったのは宣言が置かれているファイルと、それを人が書くか機械が書くかだけである
（下の「bump しない変更」の「実装の内部変更で、観測できる挙動が変わらないもの」）。

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

**実例（2 つ目）**: `OCVU_STATUS_NOT_FOUND` は M5 で `OCVU_STATUS_LIST` の末尾に足した
status で、bump しなかった。`ocvu_qr_decode` が「QR コードが写っていない」ことを
`OCVU_STATUS_OK` + 長さ 0（＝「空文字列の QR」と区別が付かない）ではなくこの新しい
status で表すために追加した。既存の status の数値・意味は 1 つも変えていない。

status の追加が bump にならないのは、**呼ぶ側が未知の status を扱えることを契約にしている**
ためである。`OCVU_STATUS_OK` と `OCVU_STATUS_BUFFER_TOO_SMALL` 以外はすべて失敗として扱う
（C# 側の `CvNative.IsFailure` がこの形になっている）。網羅的な分岐を書いて未知の値で壊れる
呼び出し側は、この契約に従っていない。

### platform 間の差は bump に当たらない（M6 で足した）

**上の 2 つの一覧は「版と版の間」を規定していて、「platform と platform の間」を
規定していなかった。** M6 で実際にその差が出たので、扱いをここに書く。

**同じ版の中で、platform によって観測できる挙動が違うことがある。**
実例は `imgcodecs` で、**Web だけが PNG を扱えない**（§3.5）—— 同じ
`ocvu_imencode(mat, ".png", ...)` が、**Web 以外では** `OCVU_STATUS_OK` を、
Web では `OCVU_STATUS_OPENCV_ERROR` を返す。

**これは bump に当たらない。** `OCVU_ABI_VERSION` が追うのは**宣言の形**
（関数の signature、struct のレイアウト、status の数値と意味）であって、
**その版でその platform が何をできるかではない。** 版が同じなら、
どの platform でも同じ宣言・同じ struct・同じ status 表が使える。

**「bump する変更」の『既存の呼び出しに対する挙動が変わる』と混同しないこと。**
あちらは**時間方向**の話である —— 同じ platform で、版を上げたら答えが変わる。
こちらは**空間方向**で、版は動いていない。

**代わりに要求することが 2 つある。**

1. **差は API 文書に明記する**（`docs/api-reference.md` の該当クラス）。
   利用者が読むのはそちらで、ここではない。
2. **allowlist からは外さない。** 出すと決めた関数は全 platform に在り、
   `verify-generated` も到達性テストも全 platform で同じものを見る。
   **「その platform では失敗する」と「その platform には無い」は別である。**

### 検査

`OCVU_ABI_VERSION` と C# の期待値が一致することは L3 が既に見ている
（`AbiContractTests.AbiVersion_MatchesTheVersionThisPackageWasBuiltAgainst`）。
status 表の同期は `StatusCodeSyncTests` が見ている。**この 2 つを消さないこと。**

---

## 3. API の allowlist（M2 で確定、M3.5・M5 で追加）

M2 で公開する `ocvu_` 関数は次で全部とする。広さを追わないのが M2 の目的である。
**M3.5 で 2 本、M5 で 7 本、2026-09 の API 拡張で 26 本足したので、現在の
allowlist は §3.5〜§3.13 を含めて 44 本である。**

**この節は「何を出すと決めたか」の正本であって、「いま何が出ているか」の一覧ではない。**
後者は `bindings/spec/*.json`（機械可読の正本）と、そこから生成される
[API 対応表](./api-map.md) が持つ（M5）。**両者を突き合わせるのは人の仕事である** ——
spec に無い関数を実装すると `tools/tests/BindingGenerator.Tests.ps1` が落とすが、
**この節に無い関数を spec に足しても、機械は何も言わない。**

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

### 3.5 imgcodecs（M3.5 で追加）

| 関数 | 内容 |
| --- | --- |
| `ocvu_imencode` | `Mat` を画像形式に符号化して呼ぶ側の buffer へ書く。**2 回呼び**（§1.6）|
| `ocvu_imdecode` | 符号化された byte 列を復号して owned handle に入れる。入力は呼び出し内で完結する借用 |

**これで allowlist は 11 本になった**（M2 の 9 本 + この 2 本）。**扱うのはメモリ上の
byte 列だけで、ファイルパスは受けない**（理由は §1.6）。

**扱える形式は platform で揃っていない**（M6 で確定、2026-09-03）。
**Web だけは JPEG のみで、PNG を持たない**（encode も decode も通らない）。
**理由は [ロードマップ](./roadmap.md) の M6 節にある** —— **ここには写さない。**

**この差は ABI の形を変えない。** 関数の signature も status code も同じで、
**Web では PNG の入出力が `OCVU_STATUS_OPENCV_ERROR` になる**だけである
（**実測ではなく導出である** —— 扱えない拡張子がその status になることは
L3 と共有の検証本体が確かめているが、`.png` そのものは測っていない）。
**allowlist から外しもしない** —— 出すと決めた関数は全 platform に在る。
**`OCVU_ABI_VERSION` の扱いは §2 の「platform 間の差は bump に当たらない」にある。**

**`imgcodecs` は M3.5 で初めてリンクされた。** それ以前の
`cmake/FindOpenCvUnityDeps.cmake` は `COMPONENTS core imgproc` だけで、リポジトリ内の
複数箇所にあった「モジュールはリンク済みで、足りないのは呼ぶ関数だけ」という記述は
**誤りだった**。誤解の出どころも記録しておく: `tools/opencv-config.psd1` の `Modules` には
`imgcodecs` が入っているので **OpenCV 自体はそれを含めてビルドされており**、
`ocvu_get_build_information()` も `To be built: … imgcodecs …` と報告する。
**「OpenCV に入っている」と「このプラグインがリンクしている」は別である。**
気づいたのは CMake を読んだからではなく、実装を書いた時点で `cv::imencode` /
`cv::imdecode` が未解決の外部シンボル（`LNK2019`）になったからである —— linker が
証拠を出した。**component を足しただけではサイズが 1 バイトも変わらなかった** ——
静的リンクは参照された object しか取り込まない。増えたのは関数を書いてからで、
Windows の debug ビルドで 8,831,488 → 10,177,536 バイト（+1.35 MB。2026-08-30 実測）。

### 3.6 objdetect / features（M5 で追加）

| 関数 | 内容 |
| --- | --- |
| `ocvu_qr_encode` | text を QR コードの画像に符号化して `dst` に入れる。`dst` は結果に応じて丸ごと置き換わり、8 bit 1 channel の正方形になる |
| `ocvu_qr_decode` | `src` に写っている QR コードを 1 つ検出して復号する。**2 回呼び**（§1.6） |
| `ocvu_orb_detect` | `src` から ORB の特徴点を検出する。**1 回呼び**（下記） |

**これで allowlist は 14 本になった**（M2 の 9 本 + M3.5 の 2 本 + この 3 本）。

### 3.7 geometry（M5 の module 追加、その 2）

| 関数 | 内容 |
| --- | --- |
| `ocvu_find_homography` | 2 組の点の対応から射影変換（3x3）を求める。**1 回呼び** |

**これで allowlist は 15 本になった。**

**リンクは無料だった。** `geometry` は `flann` と同じく `features` / `objdetect` の
依存として **CMake が推移的に引いており**、`COMPONENTS` に足す前から
リンク行に入っていた（実測: 足す前も後もライブラリは同じ 7 つ）。
**それでも `COMPONENTS` に明示してある** —— あそこは「このプラグインが何を
リンクするか」を宣言する場所で、上流が依存関係を変えたときに黙って壊れない
ようにするためである。**no-op であることを実測で確かめたうえで足している。**

**解が無いことを `OCVU_STATUS_NOT_FOUND` で返す 2 つ目の関数である**
（1 つ目は `ocvu_qr_decode`）。点が退化していると
射影変換が存在しないが、**入力の形は正しいので誤りではない。**
`OCVU_STATUS_INVALID_ARGUMENT`（4 点未満、知らない method）とは区別する。

**配る binary の大きさ**（M3.5 が §3.5 に同じ数字を残しているので、こちらも残す）。
Windows の debug ビルドで **10,177,536 → 20,136,960 バイト**（+9,959,424。約 2 倍。
2026-09-01 実測）。**`COMPONENTS` に `objdetect features` を足しただけの時点では
1 バイトも増えていない**（Task 1 で実測）—— 静的リンクは参照された object しか
引かないので、増やしたのは 3 本の関数を書いたことである。M3.5 の `imgcodecs` と
同じ形で、そのときは 8,831,488 → 10,177,536 だった。

**quiet zone の 40 px は倍率に追従しない。** 拡大は「短辺 < 200 px なら整数倍」と大きさに追従するが、余白は常に 40 px 固定である。1 module が 20 px ある大きな画像では40 px は 2 module 分にしかならず、QR の仕様が求める 4 module に届かない —— **「余白が無い画像でも検出できる」という無条件化の根拠が、まさにその大きい画像で弱い。**テストが覆っているのは encoder の出力（小さい画像）だけである。**測定が無いので今は変えない**（測定なしに形を変えないのが M5 のこの作業での判断である）。

**Release ビルドと他の 4 platform では測っていない。** debug の値なので、
配布物そのものの大きさではない（全部入りの tarball の実測は 9.6 MB で、
`tools/pack-upm-tarball.ps1` の `-MaxBytes` 既定 512 MB に対して 1 桁以上余っている）。

**`ocvu_qr_encode` を出した理由は decode 単体では説明できない** —— decode の
conformance test を fixture 画像に頼らず自己完結させるためで、`ocvu_imencode` /
`ocvu_imdecode` の関係と対になっている。

**`ocvu_qr_decode` は「見つからない」を新しい status で表す。** QR コードが
写っていない場合は `OCVU_STATUS_OK` + 長さ 0 ではなく `OCVU_STATUS_NOT_FOUND` を
返す —— 前者だと「空文字列を符号化した QR コード」と区別が付かないためである
（§2 の bump しない変更の実例）。それ以外は `ocvu_imdecode` と同じ 2 回呼びの
作法に従う。検出の前に白い余白（quiet zone）を足し、短い辺が 200 px 未満なら
拡大してから検出する（渡した `Mat` 自体は変更しない、加工済みの内部コピーに対して行う）。

**`ocvu_orb_detect` は `ocvu_imencode` / `ocvu_qr_decode` と違い 1 回呼びである。**
出力の必要量（検出された特徴点の個数）は呼ぶ側に事前には分からないが、
**上限は `max_features` で呼ぶ側が決める**ので、その上限ぶんの buffer を
最初から用意させれば 2 回呼びにする理由が無い。`capacity` が `max_features` に
満たなければ何も書かずに `OCVU_STATUS_BUFFER_TOO_SMALL` を返し、`out_count` に
`max_features` を入れる。`max_features` の上限（`OCVU_ORB_MAX_FEATURES` = 10000）は
C の `#define` と C# の `CvFeatures.MaxFeatures` に**二重に定義されている** —— C# から
C の `#define` を読む経路が無いためで、両側が native に同じ値を問うテスト
（`FeaturesTests.TheManagedUpperBoundMatchesWhatNativeAccepts`）が同期を守る。

出力の struct は `ocvu_keypoint`（`x` / `y` / `size` / `angle` / `response` /
`octave` / `class_id`、いずれも `cv::KeyPoint` のフィールドをそのまま写した固定サイズ型）。
buffer の所有権は `ocvu_mat_copy_from_buffer` などと同じく最初から最後まで呼ぶ側にある。

### 3.8 カメラの歪み補正（M5 の module 追加、その 3）

| 関数 | 内容 |
| --- | --- |
| `ocvu_undistort` | カメラ行列と歪み係数で画像の歪みを補正する。**1 回呼び** |
| `ocvu_find_chessboard_corners` | チェスボードの内側の格子点を見つける。**1 回呼び** |

**これで allowlist は 17 本になった。**

**`calib` module は使っていない。** `undistort` は `imgproc`、
`findChessboardCorners` は `objdetect` にあり、どちらも既にリンク済みだった
（実測。`native/tests/test_module_linkage.cpp` がその前提を固定している）。
**構成ハッシュは変わっていない。**

**係数を求める `cv::calibrateCamera` は、この時点では出していなかった。**
**2026-09-02 に出した** —— §3.9 を見ること。そこで `calib` module を足し、
構成ハッシュは実際に `4785d98e9aad` → `09fcbe260d87` へ変わった。

**`ocvu_find_chessboard_corners` の上限も二重に定義されている。** `pattern_cols * pattern_rows`
の上限（`OCVU_CHESSBOARD_MAX_CORNERS` = 10000）は C の `#define` と C# の
`CvCalibration.MaxCorners` に写しがあり、`CvFeatures.MaxFeatures` と同じ形で
`CalibrationTests.TheManagedCornerLimitMatchesWhatNativeAccepts` が両側を native に問う。

### 3.9 カメラ校正（M5 の module 追加、その 4。**`calib` module を足した**）

| 関数 | 内容 |
| --- | --- |
| `ocvu_calibrate_camera` | 複数 view の対応点からカメラ行列・歪み係数・各 view の姿勢を求める。**1 回呼び** |

**これで allowlist は 18 本になった。**

**これが校正の輪を閉じる段である。** §3.8 で出した 2 本は
「格子点を見つける」と「係数で補正する」で、その間の「係数を求める」が
欠けていた。**利用者は係数を別の手段でどこかから得なければ、あの 2 本を
使えなかった。**

**`calib` module を実際に足した。** 構成ハッシュは
`4785d98e9aad` → `09fcbe260d87` に変わり、**5 platform 分の OpenCV を作り直した**
（run 33589583504、2026-09-02）。**最初のビルドは 4 platform とも依存 allowlist で
落ちた** —— `calib` が `stereo` を推移的に引き込み、
`tools/verify-opencv-artifact.ps1` の `$AcceptedTransitiveModules` に無いとして
拒否された。**検査が意図どおり働いた例である**（気づかずに通ることはなかった）。
`stereo` は OpenCV 本体の module で third-party ではなく、新しい bundled 依存も
持ち込まない。このプラグインは `stereo` のシンボルを 1 つも参照しないので、
静的リンクの性質上、配布する binary には入らない。

**`geometry` のときと違い、`COMPONENTS` の追加は本物の RED を出した。**
`cv::calibrateCamera` を参照する L1 テストを先に書くと、未解決の外部シンボルで
リンクに失敗した（`native/tests/test_module_linkage.cpp` の `CalibIsLinked`）。
`calib` はどの module からも推移的に引かれない。**この時点では binary は
1 バイトも増えず**（21,190,144 のまま）、増えたのは関数を実装したときである
（21,464,576 バイト、+274,432。いずれも Windows の debug plugin で実測）。

**姿勢も返す。** `out_view_poses` は 1 view につき 6 個の double で、
**回転ベクトル 3 個のあとに並進ベクトル 3 個が続く**。rvec と tvec を別々の
buffer にすると引数が 2 本増えるので、点列を平坦化するのと同じ作法で
1 本にまとめた。**この並びは spec の `summary` が呼ぶ側に約束している。**

**上限がまた二重に定義されている。** `view_count * points_per_view` の上限
（`OCVU_CALIB_MAX_POINTS` = 100000）は C の `#define` と C# の
`CvCalibration.MaxCalibrationPoints` に写しがあり、
`CalibrationTests.TheManagedCalibrationPointLimitMatchesWhatNativeAccepts` が
両側を native に問う。**status だけでは区別できない**（上限内でも上限超えでも
`INVALID_ARGUMENT` になる）ので、last-error のメッセージで分けている。

**`OCVU_ABI_VERSION` は 1 のままである。** §2 の規約では「新しい関数を足す」は
bump しない変更に当たり、既存関数の signature も struct の layout も status の
意味も 1 つも変えていない。**`calib` module が増えたことは ABI の版に影響しない**
—— 呼ぶ側から見えるのは新しい entry point が 1 本増えたことだけである。

**出していないもの**: ステレオ校正（`stereoCalibrate`）、魚眼。

**この段落は M5 時点の記録である。** ここに挙げていた `solvePnP` と
`cornerSubPix` は **2026-09 の API 拡張で出した**（§3.10 と §3.11）——
**消さずに移動先を書くのは、同じ誤解が別の場所に残っているかを
次に読む人が確かめられるようにするため**である。
**「カメラ校正に対応した」と読める書き方をしないこと** —— 出したのは
単眼の校正 1 本である。

### 3.10 姿勢と ArUco（2026-09 の API 拡張、その 1）

**M5 で閉じた校正の輪の上に立つ 6 本。** 校正で求めた内部パラメータを使って、
マーカーの姿勢を求められる。

| 関数 | module | 所有権 |
| --- | --- | --- |
| `ocvu_solve_pnp` | `geometry` | 出力は呼ぶ側が確保した配列。`rvec_capacity` / `tvec_capacity` は**要素数**で、どちらも 3 以上 |
| `ocvu_rodrigues_to_matrix` | `geometry` | 同上。`matrix_capacity` は 9 以上 |
| `ocvu_rodrigues_to_vector` | `geometry` | 同上。`vector_capacity` は 3 以上 |
| `ocvu_project_points` | `geometry` | 同上。`out_capacity` は `point_count` の 2 倍以上 |
| `ocvu_aruco_generate_marker` | `objdetect` | `dst` の Mat が結果で丸ごと置き換わる |
| `ocvu_aruco_detect_markers` | `objdetect` | 2 本の配列に書く。溢れたら**何も書かず**に実際の個数を返す |

**`ocvu_solve_pnp` と `ocvu_project_points` は焦点距離を自分で検査する。**
`camera_matrix` の `[0]` と `[4]`（fx と fy）が 0 なら `OCVU_STATUS_INVALID_ARGUMENT`
を返す —— **OpenCV はこれを検出せず、例外も投げず false も返さず、
有限だが無意味な姿勢を成功として返す**（2026-09-05 に実測）。
**一般的な特異性の検査ではない。** 見ているのはその 2 要素だけで、
`fx = 1e-300` のような病的な値までは見ない（そこまで行くと「どこで線を引くか」の
判断になり、この境界の仕事ではない）。

**マーカーの姿勢推定は C ABI に無い。** 4 隅を `ocvu_solve_pnp` へ
`OCVU_SOLVEPNP_IPPE_SQUARE` で渡すだけなので、C# の `CvAruco.EstimateMarkerPose`
が純 C# として持つ（`WebCamTextureConverter` と同じ形）。

### 3.11 imgproc の実用関数（2026-09 の API 拡張、その 2）

**9 本。うち `ocvu_get_perspective_transform` だけが `geometry` module である** ——
`cv::getPerspectiveTransform` は OpenCV 5 で `imgproc` ではなく `geometry` に在る（実測）。

`ocvu_threshold` / `ocvu_canny` / `ocvu_morphology_ex` / `ocvu_match_template` /
`ocvu_warp_perspective` / `ocvu_get_perspective_transform` / `ocvu_hough_lines_p` /
`ocvu_corner_sub_pix` / `ocvu_find_contours`

**`ocvu_match_template` は大きさを自分で検査する。** OpenCV は template が image より
両方向とも大きいとき**例外を投げず、入れ替えて計算する**（実測）——
それでは `summary` が約束する出力の形が黙って破られるので `INVALID_ARGUMENT` で断る。

**`ocvu_corner_sub_pix` の `points` はこの ABI で唯一の入出力兼用である。**
渡した位置を読み、精緻化した位置でその場を上書きする。**断った場合は 1 バイトも
書き換えない** —— 呼ぶ側の buffer を直接 OpenCV に渡さず、写してから戻している。

**`ocvu_hough_lines_p` は `src` の写しを OpenCV に渡す。** doc が
`The image may be modified by the function.` と明記しており（同じファイルの
`findContours` はわざわざ「書き換えない」と断っている）、**書き忘れではなく契約である。**
実測では書き換わらなかったが、それを根拠に省略していない。

**`ocvu_find_contours` は階層を返さない。** 入れ子の可変長を、平らな 2 本の配列
（全点 + 輪郭ごとの点数）で表す。呼ぶ側は点数を前から足せば各輪郭の範囲が決まる。

### 3.12 core の基本演算（2026-09 の API 拡張、その 3）

**8 本。** `ocvu_extract_channel` / `ocvu_insert_channel` / `ocvu_min_max_loc` /
`ocvu_in_range` / `ocvu_normalize` / `ocvu_bitwise` / `ocvu_lut` / `ocvu_copy_make_border`

**`ocvu_insert_channel` は dst を置き換えない唯一の関数である。**
他はすべて結果で丸ごと置き換わるが、これは指定した channel だけを書き換える。

**`ocvu_min_max_loc` は 6 つの出力を個別に受け、どれも NULL を許す。**
**位置の 4 つがすべて NULL なら、OpenCV にも位置を要求しない** ——
`cv::minMaxLoc` は複数 channel でも値は返すが、**位置を要求したときだけ例外を
投げる**（実測。`minmax.dispatch.cpp` の assertion がそうなっている）。
常に位置を要求する実装だと、値だけを求めた呼び出しまで失敗する。

**`OCVU_BITWISE_*` は OpenCV の定数の写しではない。** `cv::bitwise_and` などは
関数であって定数ではないので、対応する値が上流に存在しない ——
**この 4 つはこちらが決めた値**であり、`static_assert` で固定する相手が無い。
同じことが `OCVU_FEATURE_*` と `OCVU_STEREO_*` にも当てはまる。

**`OCVU_BITWISE_NOT` は `src2` を一切見ない。** 無効な handle を渡しても成功する
（黙って無視するのではなく、そう決めてある。L1 がそれを実証している）。

### 3.13 マッチングとステレオ（2026-09 の API 拡張、その 4。**`stereo` module を足した**）

| 関数 | module | 何を |
| --- | --- | --- |
| `ocvu_detect_and_compute` | `features` | 特徴点と記述子を 1 回で求める。記述子は Mat の handle に入る |
| `ocvu_match_descriptors` | `features` | 2 つの記述子集合を総当たりで対応づける |
| `ocvu_compute_disparity` | **`stereo`** | 左右の画像から視差画像を作る |

**`stereo` は 8 つ目のリンク済み module である。**
`tools/opencv-config.psd1` の `Modules` は触っていない —— `calib` が推移的に引くので
OpenCV 側は既にビルドしており、`cmake/FindOpenCvUnityDeps.cmake` の `COMPONENTS` に
1 語足すだけで済んだ。**構成ハッシュは変わらず、6 platform 分の OpenCV 再ビルドは
起きていない。**

**`ocvu_dmatch` は境界に出る 3 つ目の struct である**（`ocvu_mat_info` /
`ocvu_keypoint` に続く）。layout の正本は native のヘッダで、
`sizeof == 16` と offset 4 本を `static_assert` が固定し、L3 が
`Marshal.SizeOf` **と** `Marshal.OffsetOf` の両方で突き合わせる ——
**合計だけを固定した検査は、同じ型のフィールドの入れ替えを通す**
（`query_index` / `train_index` / `image_index` は 3 つとも `int32_t` である）。

**`max_features` は上限ではない。** `cv::ORB::create(n)` も `cv::SIFT::create(n)` も
`n` を守らず、それより多く返す（実測: ORB は `create(5)` で 24 個、
SIFT は `create(200)` で 240 個）。**`capacity` を `max_features` と同じ値にすると、
正しい使い方のまま `BUFFER_TOO_SMALL` が返る。**

**溢れたとき `out_descriptors` は書き換わらない。** 更新されるのは `out_count`
だけである —— そのまま `ocvu_match_descriptors` へ渡しても**例外にならず、
もっともらしい結果が返る**（実測）ので、`summary` に明記してある。

**`ocvu_compute_disparity` の制限は OpenCV の要求ではない。**
`num_disparities` が 16 の倍数であること・`block_size` が 5 以上の奇数であることを
強制するのは `StereoBM` だけで、`StereoSGBM` はどちらも検査しない（実測）——
**この ABI が自分で決めた、OpenCV より厳しい契約である**（呼ぶ側にとって単純になる）。

### まだ作らないもの

`Mat` の部分参照（ROI）、型変換、算術演算、**`imgcodecs` の
ファイルパス経路**、ステレオの平行化（`stereoRectify`）、視差から 3D への復元、
`knnMatch` / `radiusMatch`、FLANN ベースの照合、輪郭の階層、描画関数、
Haar / HOG（**OpenCV 5 で contrib へ移った**ので、この構成では出せない）、

**`geometry` は 2026-09-01 に出した**（§3.7）。
**`calib` は 2026-09-02 に足した**（§3.9）—— 歪み補正とチェスボードの格子点検出
（§3.8）に続いて `cv::calibrateCamera` を出したので、**単眼カメラ校正の輪は
閉じている。**

**ただし `calib` module に出していない関数は多い。** `stereoCalibrate`（ステレオ）、
`calibrateHandEye`、魚眼系。**「`calib` を出した」は「`calib` の全部を出した」ではない。**
いずれも契約が固まってから足す。

**`solvePnP` はこの段落に挙げていたが、2026-09 の API 拡張で出した**（§3.10）。

**同じ拡張で、上の「まだ作らないもの」からも 3 つ消えた** —— チャンネル分離（§3.12）、
記述子を伴う特徴点マッチング（§3.13）、`aruco`（§3.10）。

**メモリ上の byte 列の encode / decode は M3.5 で足した（§3.5）。ファイルパスを
受けない判断の理由は §1.6 にある。QR の符号化・復号と ORB 検出は M5 で足した（§3.6）。**

**`WebCamTexture` 連携はここから外した。** M4 で `WebCamTextureConverter` を
足したが、**新しい C ABI 関数は 1 本も増えていない** —— `CvMat.Create` と
`copy_from_buffer` の上に立つ C# だけである。したがって allowlist の対象外で、
公開 API としての説明は `docs/api-reference.md` §2.6 にある。

---

## 参照

- `CLAUDE.md` — 「アーキテクチャの中核」の不変条件。この文書はその具体化である
- `docs/roadmap.md` — M2 の目的・ゴール・完了条件（上記 §1 の食い違いに従って更新済み）
- `docs/api-reference.md` — この文書が決めた契約の、利用者向けの現れ方（C ABI と C# 公開 API。**本数は [API 対応表](./api-map.md) の冒頭が数える**）。**手書きである**
- `docs/api-map.md` — いま境界に在るものの機械的な一覧（M5 の生成物）。**手で編集しない**
- `bindings/spec/*.json` — 宣言の機械可読な正本（M5）。C ヘッダ・C# の P/Invoke・到達性テスト・上の対応表はここから出る
- `.claude/skills/add-abi-function/SKILL.md` — 関数を 1 本足すときの TDD 順序
