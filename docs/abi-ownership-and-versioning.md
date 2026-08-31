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

**M5 は bump に当たらない。** 既存 20 本の signature を 1 バイトも変えておらず、
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

status の追加が bump にならないのは、**呼ぶ側が未知の status を扱えることを契約にしている**
ためである。`OCVU_STATUS_OK` と `OCVU_STATUS_BUFFER_TOO_SMALL` 以外はすべて失敗として扱う
（C# 側の `CvNative.IsFailure` がこの形になっている）。網羅的な分岐を書いて未知の値で壊れる
呼び出し側は、この契約に従っていない。

### 検査

`OCVU_ABI_VERSION` と C# の期待値が一致することは L3 が既に見ている
（`AbiContractTests.AbiVersion_MatchesTheVersionThisPackageWasBuiltAgainst`）。
status 表の同期は `StatusCodeSyncTests` が見ている。**この 2 つを消さないこと。**

---

## 3. API の allowlist（M2 で確定、M3.5 で追加）

M2 で公開する `ocvu_` 関数は次で全部とする。広さを追わないのが M2 の目的である。
**M3.5 で 2 本足したので、現在の allowlist は §3.5 を含めて 11 本である。**

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

### まだ作らないもの

`Mat` の部分参照（ROI）、型変換、算術演算、チャンネル分離、**`imgcodecs` の
ファイルパス経路**。いずれも契約が固まってから足す。
**メモリ上の byte 列の encode / decode は M3.5 で足した（§3.5）。ファイルパスを
受けない判断の理由は §1.6 にある。**

**`WebCamTexture` 連携はここから外した。** M4 で `WebCamTextureConverter` を
足したが、**新しい C ABI 関数は 1 本も増えていない** —— `CvMat.Create` と
`copy_from_buffer` の上に立つ C# だけである。したがって allowlist の対象外で、
公開 API としての説明は `docs/api-reference.md` §2.6 にある。

---

## 参照

- `CLAUDE.md` — 「アーキテクチャの中核」の不変条件。この文書はその具体化である
- `docs/roadmap.md` — M2 の目的・ゴール・完了条件（上記 §1 の食い違いに従って更新済み）
- `docs/api-reference.md` — この文書が決めた契約の、利用者向けの現れ方（C ABI 11 本と C# 公開 API）。**手書きである**
- `docs/api-map.md` — いま境界に在るものの機械的な一覧（M5 の生成物）。**手で編集しない**
- `bindings/spec/*.json` — 宣言の機械可読な正本（M5）。C ヘッダ・C# の P/Invoke・到達性テスト・上の対応表はここから出る
- `.claude/skills/add-abi-function/SKILL.md` — 関数を 1 本足すときの TDD 順序
