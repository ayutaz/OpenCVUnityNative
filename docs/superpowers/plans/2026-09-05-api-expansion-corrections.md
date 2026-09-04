# API 拡張（A〜F）— 実測で覆った前提と、その決定

> **この文書は 5 つの計画に優先する。** 食い違う箇所はここが正しい。
> 計画本文は書き直していない —— **どこが実測で覆ったかを残すほうが、
> 直して消すより次に読む人の役に立つ**ためである。

**根拠**: 2026-09-05 に 12 観点 × 2 段（調査 → 反証）で計画の前提を実測した。
**ブロッカー 11 件・要修正 22 件・見落とし 53 件**が出た。
**反証段は前段の修正案そのものを 2 件否定している**（D4 と D12 がそれである）。

**PR は 1 つにまとめる。** したがって計画にある「Phase 2 と Phase 3 が
`OCVU_BORDER_*` を共有するので先に着手したほうが足す」といった調整は
**不要になった** —— 順に足すだけである。

---

## D1. 生成器の型表を先に広げる（**最初の作業**）

**計画の spec エントリは 5 つがそのままでは `dev.ps1 generate` に拒否される。**
`bindings/generator/Ocvu.Generator/SpecModel.cs:122-151` の `AllowedCsTypes` は
**閉じた表**で、知らない `cType` も、知っている `cType` に合わない `csType` も
`SpecFormatException` で止める。

| 計画が書いている組 | 現状 | 直し方 |
| --- | --- | --- |
| `int32_t*` + `int[]`（4 箇所） | `int32_t*` は `out int` **だけ** | 表に `"int[]"` を足す |
| `ocvu_dmatch*` + `OcvuDMatch[]` | **`ocvu_dmatch*` という key が無い** | `ocvu_keypoint*` と同じ形で足す |

**この拡張には前例がある。** `["double*"] = new[] { "double[]", "out double", "System.IntPtr" }`
が**既に配列とスカラーの二義を持って**おり、同ファイルの docstring が
「**1 つの cType が 2 つの意味を持つ** …どちらになるかは spec の direction と
csType が決める」と明記している。`int32_t*` に `int[]` を足すのは同じ形である。

**受け入れているコスト**（レビューが指摘したもの）: 足した瞬間に、
リポジトリ内の全 `int32_t*` param が `out int` と `int[]` のどちらでも通る。
現行 9 個 + 追加 6 個の計 15 個が「取り違えても表が通す」状態になる。
**`double*` で既に同じコストを払っているので、新しい種類の穴ではない。**

**`bindings/generator/Ocvu.Generator.Tests/SpecSchemaTests.cs` も同じ commit で直す** ——
表の中身を Theory で 1 組ずつ固定しており、**`dev.ps1 test` の速いレーンに入っている。**

---

## D2. `ocvu_min_max_loc` は位置を配列で返さない

**計画は `out_min_location` / `out_max_location` を `int32_t*`（2 要素）で返していた。**
2 つ直す。

1. **`out int` を 4 つにする** —— `out_min_x` / `out_min_y` / `out_max_x` / `out_max_y`。
   これで D1 の `int[]` 追加が**この関数のためには不要**になり、さらに
   「現在の out-buffer は 9 本すべてが直後に capacity / buffer_size を持つのに、
   この 2 本だけが相方を持たない」という不整合も消える。
2. **位置を要求しないときは OpenCV に位置を要求しない。** 実測で
   `cv::minMaxLoc` は**複数 channel でも値は返す**（8UC3 で min=1 max=3、例外なし）。
   投げるのは**位置を要求したときだけ**である（`minmax.dispatch.cpp:308` の
   `(cn == 1 && ...) || (cn > 1 && _mask.empty() && !minIdx && !maxIdx)`）。
   計画の実装は常に `&min_point` / `&max_point` を渡すので、
   **値だけを求めた呼び出しまで失敗する。** 4 つの出力の要求に応じて
   `nullptr` を渡し分けること。

**`int[]` の追加自体は残る 3 箇所（`out_ids` / `out_counts`）のために必要である。**

---

## D3. Mat の型を 3 つ増やす

**26 本のうち 3 本が、この ABI が名前を持たない型の Mat を作る。**

| 関数 | 出力の型 | 現状 |
| --- | --- | --- |
| `ocvu_get_perspective_transform` | CV_64FC1（実測） | `ocvu_mat_get_info` の `type` に **-1** が入り、それでも `OCVU_STATUS_OK` を返す |
| `ocvu_match_template` | CV_32FC1（実測 type=5） | 同上 |
| `ocvu_compute_disparity` | CV_16SC1 | 同上 |

`native/src/ocvu_mat.cpp:18-25` の `from_cv_type` は未知の型に `-1` を返し、
C# の `CvMatType` は `Gray8 / Bgr24 / Bgra32` の 3 値しか持たない。
**呼ぶ側は「型が -1 の Mat」を受け取り、何バイト読めばよいか分からない。**

**決定: 3 つの型を足す。**

```c
#define OCVU_MAT_TYPE_16SC1  3   /* CV_16SC1 */
#define OCVU_MAT_TYPE_32FC1  5   /* CV_32FC1 */
#define OCVU_MAT_TYPE_64FC1  6   /* CV_64FC1 */
```

同時に動くもの: `from_cv_type` / `to_cv_type`（`native/src/ocvu_mat.cpp`）、
C# の `CvMatType`、`docs/abi-ownership-and-versioning.md` の型の節。

**`ocvu_mat_create` でこれらの型を作れるようになる**のは副作用だが、望ましい
（`ocvu_match_template` の出力を受ける器を呼ぶ側が用意できる）。

**`static_assert` で OpenCV の値と固定すること** —— 既存の `OCVU_MAT_TYPE_*` に
`static_assert` が無いなら、この 3 つには付ける。

---

## D4. `max_features` は上限ではない（**反証段が修正案を否定した 1 件目**）

**実測**: `cv::ORB::create(nfeatures)` も `cv::SIFT::create(nfeatures)` も、
`nfeatures` を上限として守らない。

| 検出器 | 実測 |
| --- | --- |
| ORB | 200x200 で `create(5)` → **24**、`create(10)` → **36**、`create(20)` → **36** |
| SIFT | 160x160 で `create(200)` → **240**、200x200 で `create(50)` → **60** |

**帰結が 3 つある。**

1. **`capacity == max_features` は `OCVU_STATUS_OK` を保証しない。**
   計画の L1 は 4 箇所すべてでその形を取っており、**SIFT では落ちる。**
2. **調査段の修正案「`kSide` を 160 以上にする」は誤りだった** ——
   ORB は直るが、**今度は SIFT が 240 個返して capacity=200 を超える。**
   反証段が 11 サイズを実測してこれを示した。
3. **既存の `native/src/ocvu_features.cpp:69` のコメントが同じ誤解を持っている。**

**決定:**

- **`summary` に「`max_features` は OpenCV への希望であって上限ではない。
  超えた場合は `BUFFER_TOO_SMALL` と実際の個数が返る」と書く。**
- **L1 は `capacity` を `max_features` と別に、十分大きく取る。**
- **C# は 2 回呼びで伸ばす**（`CvAruco.DetectMarkers` と同じ形）。
- **`ocvu_features.cpp:69` の既存コメントも直す。**

**画像の大きさ**: ORB は `edgeThreshold=31` のため小さい画像で 0 個になる
（実測: 32→0、64→0、96→0、128→8、160→104、200→212、256→280）。
**L1 の入力は 200x200 以上にすること。**

---

## D5. `ocvu_match_template` は大きさを自分で見る

**実測**: `cv::matchTemplate` は templ が image より**両方向とも大きいとき、
例外を投げず image と templ を入れ替えて計算する**（5x5 の image に 9x9 の
templ を渡すと 5x5 が返る）。調査段が引いた `>=` の assertion は
`cv::matchTemplateMask` のもので、`matchTemplate` 自身は `<=` 版である。

**帰結**: 計画の否定テストが落ちるだけでなく、**`summary` が約束する出力の形
（`image - templ + 1`）が黙って破られる。**

**決定: 実装で `image.rows >= templ.rows && image.cols >= templ.cols` を検査し、
満たさなければ `OCVU_STATUS_INVALID_ARGUMENT` を返す。** L1 もそれに合わせる。

---

## D6. Otsu の期待値は実測に合わせる

**実測**: 4x4 の分割画像（左 10 / 右 200）に `THRESH_OTSU` を掛けると
返り値は**ちょうど 10.0**（8x8 に広げても同じ）。2 値ヒストグラムでは
10 以上 199 以下のどの分割も同じ分離になり、実装は最初に最大を取る `i` を返す。

**計画の `EXPECT_GT(computed, 10.0)` は落ちる。**

**決定: `EXPECT_GE(computed, 10.0)` かつ `EXPECT_LT(computed, 200.0)` にする。**
**「Otsu が値を選んで返す」ことを見るのが目的**なので、選ばれた値そのものを
狭く縛らない。

---

## D7. マッチングの索引一致は `cross_check=1` で見る

**実測**: 同じ記述子集合どうしでも `queryIdx == trainIdx` は成り立たない
（200x200 の市松で 212 件中 53 件のみ。距離はすべて 0）。繰り返す模様では
記述子が重複し、同点のとき BFMatcher は先に現れたほうを選ぶ。

**決定: `cross_check=1` を使う。** 実測で 176x176・ORB(200) は
`cross_check=0` が 88 件中 self 44 件なのに対し、**`cross_check=1` は 44 件
すべてが self** だった。**入力を作り替えるより差分が小さく、しかも
`cross_check` が実際に効いていることを同じテストが証明する。**

---

## D8. `docs/api-reference.md` は spec と同じ commit で直す

**`tools/tests/BindingGenerator.Tests.ps1:228-257` が、spec の全関数名が
`docs/api-reference.md` に識別子として現れることを要求する**（除外リスト無し、
大文字小文字を区別）。これは `$ToolsTestScriptsFast` に配線されており、
**`dev.ps1 test` は `Test-Tools` を最初に呼んで fail-fast する。**

**帰結: 「文書は最後の Task にまとめる」という計画の段取りは成立しない。**

**決定: spec に entry を足す commit で、`docs/api-reference.md` にも
その名前を足す。** 詳しい説明は後でよいが、**名前は同時に入れる。**

---

## D9. レーンは絶対に 2 つ同時に走らせない

5 つの計画は合計 **81 回以上**のレーン起動を指示しながら、
CLAUDE.md の不変条件「dev.ps1 のレーンは相互排他である」に一度も触れていない。

**結果を書くレーンは開始時に `Reset-Results` で `artifacts/test-results/` を
ディレクトリごと消す**（`tools/dev.ps1:131-136`）ので、後から始めたほうが
先行レーンの結果を消す。**壊れ方が悪い** —— 先行したレーンは赤くならず**無音で止まる。**

さらに `test-native` / `test-managed` / `test` / `build` は
**同じ CMake ビルド木 `build/windows-x64-debug/` と同じ `Packages/.../Runtime/Plugins/`**
を共有する。

**決定: この作業でコードを書くのは並列でよいが、`dev.ps1` を呼ぶのは常に 1 つだけ。**

**加えて**: `BindingGenerator.Tests.ps1:90-109` は生成物**全部**に行を追記して
`finally` で書き戻す。**プロセスが強制終了されると生成物が汚れたまま残る。**
中断したら `git status` を見て、汚れていれば `dev.ps1 generate` で戻すこと。

---

## D10. `.meta` は 4 つ作り、互いに突き合わせる

新設する `.cs` は 4 つ（`CvAruco.cs` / `CvCoreOps.cs` / `CvStereo.cs` /
`NativeMethods.Stereo.g.cs`）。**計画は 3 つ分しか作り方を書いていない**
（`CvCoreOps.cs.meta` が抜けている）。

**`.meta` の欠落は何も赤くしない** —— package の `.cs` に `.meta` が在ることを
見ている機械は 1 つも無い（`pack-upm-tarball.ps1` が要求するのは plugin の
binary とそのフォルダだけ）。**だから忘れると、Unity が import した時点で
新しい guid を振り、次に git が差分として拾う形で後から出る。**

**`git grep <guid>` では 4 つの相互衝突が見えない**（tracked な内容しか見ない）。
**4 つを互いに突き合わせること。**

**形式は実測で確かめてから作る**（既存の `.meta` を `od -c` で読む）。

---

## D11. `#include "ocvu/stereo.h"` の数は spec の module 数と一致必須

`tools/tests/BindingGenerator.Tests.ps1:189-202` が
(a) spec の全 module について `#include "ocvu/<module>.h"` の存在を要求し、
(b) **`#include` の数と spec module の数の一致（`-eq`）まで見る。**

**帰結: 足し忘れも、余分な include も、どちらも `dev.ps1 test` が赤くする。**
`native/include/opencv_unity_native.h` のこの 1 行は**生成物ではない**ので手で足す。

---

## D12. `stereo` の `COMPONENTS` 追加は RED を出さない見込み（**反証段が修正案を否定した 2 件目**）

**全体設計 §2 は「足す前に `cv::StereoBM` を参照する L1 テストを書いて RED を見る」
と断定しているが、実測はそれを支持しない。**

- 復元済みツリーに `opencv_stereo500.lib` が**既に在る**
- `OpenCVModules.cmake:135-139` が `opencv_calib` の `INTERFACE_LINK_LIBRARIES` に
  `opencv_stereo` を含めており、`COMPONENTS` には既に `calib` が在る

**つまり `geometry` とまったく同じ形で、そのときも RED は出なかった。**

**決定: Phase 4 Task 3 の「2 つのどちらか」という分岐はそのまま使う。**
**ただし「RED を見る」と断定した全体設計 §2 の記述は誤りなので、
実測の結果を PR 本文と allowlist に書くときに『予想外』と書かないこと** ——
`geometry` と同じ形になることは着手前から分かっていた。

**iOS と Web では話が違う**（レビューの指摘）: 静的ライブラリを束ねる分岐は
`foreach(_lib IN LISTS OpenCV_LIBS)` で列挙し、`OpenCV_LIBS` は**要求した
`COMPONENTS` だけ**から作られる。**desktop で no-op でも、iOS / Web では
`stereo` を足さないと束ねられない。** だから `COMPONENTS` への追加は必要である。

---

## D13. `OCVU_MATCH_MAX_COUNT` を作らない

全体設計 §5.6 は「**出力の `capacity` には上限を置かない**」と決め、
足してよい定数を 3 つに限定している。`OCVU_MATCH_MAX_COUNT` は 4 つ目であり、
しかも縛っているのが**出力の capacity** なので二重に反する。

**決定: 作らない。** `capacity` が負でないことだけを見る。

---

## D14. `CvInterpolation` を作らない

計画の Phase 2 は `CvOps.WarpPerspective(..., CvInterpolation interpolation, ...)`
と書いているが、**その型はリポジトリのどこにも存在せず、足す一覧にも入っていない。**

既存の `CvOps.Resize` は生の `int interpolation` を受け、
`CvOps.InterNearest` / `InterLinear` という `int` 定数が在る
（`Runtime/Core/CvOps.cs:11-12, 18`）。

**決定: 既存に合わせて `int` を受ける。** 新しい enum を作らない。

---

## D15. `HoughLinesP` には写しを渡す

OpenCV の doc は `imgproc.hpp:1863` で
`The image may be modified by the function.` と明記している。
**反証段の実測では書き換わった画素は 0 個だった**が、
同じファイルの `findContours` はわざわざ「3.2 以降は書き換えない」と
断っているので、**HoughLinesP 側の「may be modified」は書き忘れではなく契約である。**

**決定: 実装で `src_mat->clone()` を渡す。** 呼ぶ側の handle を守る。
**実測で書き換わらなかったことを根拠に省略しない** —— 上流が契約として
残している以上、次の版で変わりうる。

---

## D16. 型の制約を `summary` に正しく書く

**実測で分かった、計画の `summary` が間違えているもの:**

| 関数 | 計画の記述 | 実測 |
| --- | --- | --- |
| `ocvu_corner_sub_pix` | 「src は 8 bit 1 channel でなければならない」 | `cv::cornerSubPix` が縛るのは **channel だけ**。ただし CV_16UC1 は `getRectSubPix` 側で拒否される。**通るのは 8U と 32F** |
| `ocvu_threshold` | src の型に触れていない | **CV_32S は拒否される**。さらに **`THRESH_OTSU` は CV_8UC1 と CV_16UC1 でしか動かない**（8UC3 に or して渡すと落ちる） |
| `ocvu_match_descriptors` | 「合っていなくても OpenCV は受け付ける」 | **片方向は止める** —— `NORM_HAMMING` を SIFT の CV_32F 記述子に当てると例外。query と train の型が違う場合も例外 |
| `ocvu_compute_disparity` | 「num_disparities は 16 の倍数、block_size は 5 以上の奇数」を「OpenCV の要求」として書いている | **強制するのは BM だけ。** SGBM は blockSize を一切検査せず、num_disparities の 16 倍数性も見ない。**したがってこれは OpenCV の要求ではなく、この ABI が自分で決めた、より厳しい契約である** |

**決定: 4 つとも `summary` を実測に合わせる。**
**特に最後の 1 つは「OpenCV の要求」と書かない** —— 嘘になる。

---

## D17. `ocvu_project_points` の出力は `cv::Mat` で受ける

計画は `std::vector<cv::Point2f> projected;` を `OutputArray` として渡すが、
**`vector<Point2f>` から作った `_OutputArray` は型が固定される**ので、
関数側が別の depth を要求すると例外になる。計画の入力は
objectPoints が CV_32F、rvec / tvec / cameraMatrix が CV_64F で**混ざっている。**

**決定: `cv::Mat projected;` で受け、書き出すときに型を確かめる。**

---

## D18. 出力の型を確かめるのではなく変換する

`native/src/ocvu_calibration.cpp` が既にその作法を採っている ——
`:345` のコメントが「OpenCV は 64F の 3x3 と 1xN を返すが、**契約は自分でも
確かめる。**」と述べたうえで、`:346-351` は
`type() == CV_64F ? そのまま : convertTo(m, CV_64F)`、
`:405-408` は rvecs / tvecs を**無条件に** `convertTo` している。

**決定: 新しい実装も同じ形にする。** `at<double>` で読む前に、
型が違えば `convertTo` する。**弾かずに変換する。**

---

## D19. 溢れたときは出力 handle を触らない、と `summary` に書く

`ocvu_detect_and_compute` が `BUFFER_TOO_SMALL` で返る経路では
`out_descriptors` の Mat が**元のまま**である。呼ぶ側は `out_count` に
240 のような値を得るのに、descriptors は 1x1 8UC1 のままになる。

**それを `ocvu_match_descriptors` に渡しても例外にならず、対応が 1 件返る**（実測）。
**誤りが status ではなく「もっともらしい結果」として現れる** ——
このリポジトリが繰り返し記録している「ビルドは通るが動かない」と同じ形である。

**決定: `summary` に「溢れた場合 out_descriptors は書き換えない」と明記する。**

---

## D20. C# は netstandard2.1 / C# 9 / 警告をエラーとして扱う設定でビルドされる

`Runtime/Core` と `Runtime/Interop` の全 `.cs` は L3 レーンで shim に
丸ごと取り込まれ、**netstandard2.1 / LangVersion 9.0 /
TreatWarningsAsErrors=true** でビルドされる。

**決定: C# 10 以降の構文を使わない。** 警告も出さない
（未使用変数、XML doc の不備など）。

---

## D21. 触る文書の一覧（計画が挙げていなかったもの）

計画の §6 / §9 が挙げていないのに、この作業で古くなるもの:

| 場所 | 何が古くなるか |
| --- | --- |
| `docs/README.md:15` | allowlist を**関数名で列挙**している |
| `docs/roadmap.md:712` | 「本案が公開している API は core / imgproc / … に留まる」（module 一覧。`stereo` が 8 つ目になる） |
| `docs/roadmap.md:1607` | M5 判定セルが「`solvePnP` …も出していない」と現在形 |
| `docs/abi-ownership-and-versioning.md:580-586` | §3.9 末尾の「出していないもの」（`solvePnP` / `cornerSubPix`） |
| `docs/abi-ownership-and-versioning.md:588-591` | 「まだ作らないもの」（チャンネル分離 / 記述子を伴うマッチング / `aruco`） |
| `docs/abi-ownership-and-versioning.md:615` | 参照節の「C ABI 18 本」 |
| `docs/api-reference.md:9-13` | 冒頭の対象範囲段落（名指し + 本数） |
| `docs/api-reference.md:626-635` | **`## 3. 対象外（この文書に書かないもの）`** —— 計画が「§3『この allowlist に含まれないもの』」と呼んでいたのは**別の小節**（`:320`）である |
| `CLAUDE.md:43` / `:51` | 「`stereo` のシンボルを 1 つも参照しない」（`ocvu_compute_disparity` が偽にする） |
| `CLAUDE.md:68` | `dev.ps1 generate` の「**18 ファイル**」（`stereo` で 20 になる） |
| `CLAUDE.md:73` | `test-native` の「GoogleTest **104 件** + CTest **4 件**」 |
| `CLAUDE.md:74` | `test-managed` の「**76 件**」「**102 件**」 |
| `CLAUDE.md:347` | 確定事項表の allowlist 行（関数名を全部並べている） |
| `tools/verify-opencv-artifact.ps1` | `$AcceptedTransitiveModules` に `stereo` を載せた**根拠の散文**が失効する |
| `tools/tests/OpenCvConfig.Tests.ps1:25` | 「例外が **2 つ**ある」（`stereo` で 3 つになる） |
| `.github/release-notes.md:98-100` | 「出していないもの」に `solvePnP` / `aruco` / `cornerSubPix` / 記述子マッチング / ステレオ校正 |
| `docs/unity-opencv-integration-research-and-plan.md` | 競合比較表の module 一覧 |

**`add-abi-function` skill が「module 一覧を散文で持っている文書は grep できない。
目で探すしかない」と書いている 3 つ**（roadmap の M7 節、競合比較表、CLAUDE.md）
**が全部ここに入っている。**

---

## D22. Task 0 を作る

全体設計 §1 は「roadmap の依存図にもその形で足す（**Task 0**）」と書いているが、
**4 つの計画のどれにも Task 0 は無い。**

**この commit で既に済ませてある**（`2922582` が roadmap の依存図と
`docs/README.md` を直した）。**改めて作業は要らない。**

---

## 実行の順序（1 PR 版）

**計画の Task 番号は Phase ごとに閉じているので、1 本の列に直す。**

| 段 | 何を | なぜこの順か |
| --- | --- | --- |
| 0 | **D1**（生成器の型表）+ **D3**（Mat の型 3 つ） | **これが無いと `generate` が 1 度も通らない** |
| 1 | spec 26 entry + `docs/api-reference.md` に名前 + `generate` | **D8** により名前は同時に入れる |
| 2 | native 実装 7 ファイル + L1 | ここが本体 |
| 3 | `dev.ps1 test-native` を緑にする | **D9**: 1 つずつ |
| 4 | C# の公開 API + L3 | |
| 5 | `dev.ps1 test` / `test-asan` | |
| 6 | 文書（**D21** の一覧を全部） | |
| 7 | AI レビュー → PR | **merge しない** |

**段 2 と 4 は並列でよい**（ファイルが分かれる）。**段 3 と 5 は必ず 1 つずつ。**
