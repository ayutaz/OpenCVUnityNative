# API 拡張（A〜F）— 全体設計と分割

> **この計画より優先する文書がある。**
> 実装前に 12 観点 x 2 段で前提を実測し、**この計画の記述が 11 箇所で覆った** ——
> 決定は [実測で覆った前提と、その決定](./2026-09-05-api-expansion-corrections.md)
> にある。**食い違う箇所はあちらが正しい。**


> **これは計画ではなく、4 つの計画が共有する spec である。** 各計画はここから
> 引数を取る。実装に入る前にこの文書を通しで読むこと。

**目的**: 既にリンク済みの OpenCV module の中から、Unity 利用者が実際に必要とする
関数を C ABI に出す。**OpenCV の再ビルドは 1 度も起こさない。**

**成果**: 公開 C ABI が **27 本から 53 本**になる（+26 本）。**この数はここでは数えない
—— 正本は `docs/api-map.md` の冒頭である。** ここに書いてあるのは「この作業で 26 本
足す」という計画の内容であって、現在の本数ではない。

---

## 1. これはマイルストーンではない

`docs/roadmap.md` の M0〜M7 のどれでもない。**M6 が終わり M7 に入る前に挟む
API 拡張である** —— 配布（v0.1.0 / v0.1.1 / v0.2.0 / v0.3.0）が
マイルストーンの間に挟まってきたのと同じ位置づけで、roadmap の依存図にも
その形で足す（Task 0）。

**根拠は `docs/roadmap.md` の「差別化の穴」にある** ——

> 本案が公開している API は `core` / `imgproc` / `imgcodecs` / `objdetect` /
> `features` / `geometry` / `calib` に留まる —— **土台が 5 系なのは本案だけだが、
> 使える機能の量では競合に遠く及ばない。**

**この作業はその差を埋めにいく。** ただし「OpenCV 全対応」を目指すのではない
（`docs/api-map.md` の冒頭がその表現を禁じている）。**出したものと出していないものを
両方書く**のがこの拡張の作法である。

---

## 2. 費用の前提（実測、2026-09-05）

**この計画が成立するのは、次の 3 つを実測で確かめたからである。**

| 事実 | 実測 |
| --- | --- |
| 復元済みの OpenCV ツリーに在るライブラリは **9 つ** | `third_party/opencv/09fcbe260d87/x64/vc17/staticlib/` に `opencv_{calib,core,features,flann,geometry,imgcodecs,imgproc,objdetect,stereo}500.lib` |
| `stereo` は **`Modules` に無いのにビルドされている** | 同上。`calib` が推移的に引く（`tools/verify-opencv-artifact.ps1` の `$AcceptedTransitiveModules` に既に載っている） |
| `Modules` を触らなければ**構成ハッシュは変わらない** | `Get-OpenCvConfigHash` が読むのは `tools/opencv-config.psd1` だけである（`add-abi-function` skill が明記） |

**帰結: この計画は `tools/opencv-config.psd1` の `Modules` を 1 文字も変えない。**
したがって 6 platform 分の OpenCV 再ビルド（`calib` のときは
`4785d98e9aad` → `09fcbe260d87` で全 platform が動いた）は起きない。

**唯一の例外が `stereo` である** —— `cmake/FindOpenCvUnityDeps.cmake` の
`COMPONENTS` に足す。**これはハッシュを変えない**が、リンク行は変える。
だから `geometry` / `calib` と同じく、**足す前に `cv::StereoBM` を参照する
L1 テストを書いて RED を見る**（Phase 4 Task 1）。

---

## 3. 対象外（実測して「できない」と分かったもの）

**足せなかったのではなく、この構成では足せない。次の人が調べ直さずに済むよう
根拠ごと書く。**

| 出さないもの | 根拠（2026-09-05 に実測） |
| --- | --- |
| `CascadeClassifier`（Haar 顔検出） | `objdetect.hpp` と `objdetect/` に **0 件**。OpenCV 5 で contrib へ移った |
| `HOGDescriptor` | 同上、**0 件** |
| `AKAZE` | `features.hpp` に **0 件** |
| `FaceDetectorYN` | 宣言は在るが `dnn` 前提。`dnn` は `Modules` に無い |
| `mcc`（カラーチェッカー） | `objdetect/mcc_checker_detector.hpp` が `#ifdef HAVE_OPENCV_DNN` で囲われている |
| 動画入出力（`videoio`） | FFmpeg / GStreamer を引き込むため、ライセンス方針で除外してある（`tools/tests/OpenCvConfig.Tests.ps1` が `videoio` の不在を検査している） |
| `BarcodeDetector` | 在るが、超解像に `dnn` を optional で使う。**無い構成での挙動を確かめていない**ので今回は出さない |
| `stereoCalibrate` / `fisheye` / `calibrateHandEye` | `calib.hpp` に在るが、今回の範囲外（単眼の輪は M5 で閉じてある） |
| `findEssentialMat` / `recoverPose` | `geometry/3d.hpp` に在るが、今回の範囲外 |
| `connectedComponents` / `remap` / `equalizeHist` | `imgproc.hpp` に在るが、今回の範囲外（**在るのに出さないと決めた** —— 次に足すならここから） |

---

## 4. 足す 26 本（完全な一覧）

**本数を数えるのはこの表ではない。** ここは「何を足すか」を決める場所で、
足し終わったあとの本数は `docs/api-map.md` が数える。

### Phase 1 — 姿勢と ArUco（6 本）

| # | 関数 | module | 何をするか |
| --- | --- | --- | --- |
| 1 | `ocvu_solve_pnp` | `geometry` | 既知の 3D 点と、その画像上の対応点、カメラの内部パラメータから、1 枚ぶんの姿勢（回転ベクトルと並進ベクトル）を求める |
| 2 | `ocvu_rodrigues_to_matrix` | `geometry` | 回転ベクトル（3 要素）を回転行列（3x3）に直す |
| 3 | `ocvu_rodrigues_to_vector` | `geometry` | 回転行列（3x3）を回転ベクトル（3 要素）に直す |
| 4 | `ocvu_project_points` | `geometry` | 3D 点を、与えた姿勢とカメラで画像平面へ投影する |
| 5 | `ocvu_aruco_generate_marker` | `objdetect` | 辞書と ID からマーカー画像を生成して Mat に入れる |
| 6 | `ocvu_aruco_detect_markers` | `objdetect` | 画像から ArUco マーカーを検出し、ID と 4 隅の座標を返す |

### Phase 2 — imgproc の実用関数（9 本）

| # | 関数 | 何をするか |
| --- | --- | --- |
| 7 | `ocvu_threshold` | 二値化する。Otsu を使ったときに実際に選ばれたしきい値も返す |
| 8 | `ocvu_canny` | Canny のエッジ検出 |
| 9 | `ocvu_morphology_ex` | 収縮・膨張・開閉などの形態素演算 |
| 10 | `ocvu_warp_perspective` | 射影変換で画像を変形する |
| 11 | `ocvu_get_perspective_transform` | 4 点の対応から射影変換（3x3）を厳密に求める |
| 12 | `ocvu_match_template` | テンプレートマッチングの応答画像を作る |
| 13 | `ocvu_hough_lines_p` | 確率的 Hough 変換で線分を検出する |
| 14 | `ocvu_corner_sub_pix` | 既に見つけた角点を副画素精度へ精緻化する（入出力兼用のバッファ） |
| 15 | `ocvu_find_contours` | 輪郭を検出し、点列と輪郭ごとの点数を返す |

### Phase 3 — core の基本演算（8 本）

| # | 関数 | 何をするか |
| --- | --- | --- |
| 16 | `ocvu_extract_channel` | 1 channel を取り出す |
| 17 | `ocvu_insert_channel` | 1 channel を差し込む |
| 18 | `ocvu_min_max_loc` | 最小値・最大値と、その位置を返す |
| 19 | `ocvu_in_range` | 下限と上限の間にある画素を 255、それ以外を 0 にする |
| 20 | `ocvu_normalize` | 値域を正規化する |
| 21 | `ocvu_bitwise` | AND / OR / XOR / NOT をひとつの入口で行う |
| 22 | `ocvu_lut` | ルックアップテーブルで画素値を置き換える |
| 23 | `ocvu_copy_make_border` | 周囲に余白を足す |

### Phase 4 — 特徴点マッチングとステレオ（3 本）

| # | 関数 | module | 何をするか |
| --- | --- | --- | --- |
| 24 | `ocvu_detect_and_compute` | `features` | 特徴点の検出と記述子の計算を 1 回で行う。記述子は呼ぶ側が用意した Mat に入る |
| 25 | `ocvu_match_descriptors` | `features` | 2 つの記述子集合を総当たりで対応づける |
| 26 | `ocvu_compute_disparity` | **`stereo`（新設）** | 左右の画像から視差画像を作る |

---

## 5. 設計の決定（4 計画すべてに効く）

### 5.1 新しい status code は 1 つも足さない

**実測で確かめた**: 26 本のどの失敗経路も、既にある 9 つで表現できる。

| 起きること | status |
| --- | --- |
| `solvePnP` が `false` を返す | `OCVU_STATUS_NOT_FOUND`（`ocvu_find_homography` と同じ扱い。**解が無いのは誤りではない**） |
| ArUco が 0 個検出した | `OCVU_STATUS_OK` で `out_count = 0`（**検出できないのは誤りではない**） |
| 出力バッファが足りない | `OCVU_STATUS_BUFFER_TOO_SMALL` + 必要量 |
| OpenCV が投げた | `OCVU_STATUS_OPENCV_ERROR` |

**帰結: `native/include/opencv_unity_native.h` の `OCVU_STATUS_LIST` と
`Runtime/Core/CvStatus.cs` は 1 行も変わらない。** `StatusCodeSyncTests` は
このブランチで緑のままである。

### 5.2 新しい struct は 1 つだけ（`ocvu_dmatch`）

Phase 4 の `ocvu_match_descriptors` が返す対応 1 つぶん。**struct を境界に出すのは
`ocvu_mat_info` / `ocvu_keypoint` に続いて 3 例目**で、同じ作法に従う ——
**layout の正本は native のヘッダに置き、C# 側は手で写して L3 が
`Marshal.SizeOf` と `Marshal.OffsetOf` で突き合わせる。**

```c
typedef struct ocvu_dmatch {
    int32_t query_index;
    int32_t train_index;
    int32_t image_index;
    float   distance;
} ocvu_dmatch;
```

**`Marshal.SizeOf` だけでは足りない。** M5 で「合計だけを固定した検査は中身の
入れ替えを通す」を実測している（`sizeof == 28` は同じ型のフィールドを入れ替えても
通る）。**`Marshal.OffsetOf` を 4 つとも並べて閉じる。**

### 5.3 `bool` を境界に出さない

C++ の `bool` は幅が platform で保証されず、C# の `bool` は既定の marshalling が
4 バイトの `BOOL` になる。**`int32_t` の 0 / 非 0 で受ける。**
`l2_gradient` / `cross_check` がこれに当たる。

### 5.4 可変長出力は「呼ぶ側が容量を渡す」1 形だけを使う

**2 種類の作法が既にある。混ぜない。**

| 既存の形 | いつ使うか | 例 |
| --- | --- | --- |
| **2 回呼び**（`buffer = NULL` で必要量を聞く） | **1 回目が安い**とき | `ocvu_imencode`（符号化は 1 回目に走るが、それが本体である） |
| **容量 + `BUFFER_TOO_SMALL` + `out_count`** | **検出をやり直すのが高い**とき | `ocvu_orb_detect`、`ocvu_find_chessboard_corners` |

**この計画が足す可変長出力は、すべて後者にする** ——
`ocvu_aruco_detect_markers` / `ocvu_hough_lines_p` / `ocvu_find_contours` /
`ocvu_detect_and_compute` / `ocvu_match_descriptors` の 5 本。
理由は**どれも検出そのものが本体だから**である。溢れたときは
`out_count` に**実際に見つかった数**を入れて `BUFFER_TOO_SMALL` を返し、
**バッファには 1 バイトも書かない。**

**`out_count` を書く規則は `ocvu_imencode` の `out_required_size` と同じである** ——
**NULL 判定の直後に 0 を書き、以降のすべての早期 return がその後ろに来る。**
これを守らないと、呼ぶ側が同じ変数を使い回したときに「失敗したのに前回の数が残る」。

**L1 でこれを確かめるときは、0 ではない値でわざと汚してから呼ぶ。**
0 で初期化していると「書いていない」と「0 を書いた」が区別できない
（M3.5 で実測。代入を消しても 16 件が緑のまま通った）。

### 5.5 `length` はすべてバイト数

`ocvu_find_homography` / `ocvu_calibrate_camera` が既にそうしている。
**要素数にすると、既存に慣れた呼び手が違う単位の値を渡して検査を通過する方向に倒れる。**

**ただし `capacity` は要素数である**（`ocvu_calibrate_camera` の
`out_camera_matrix` 等がそう）。**この非対称は既にある** ——
`*_length` = バイト数、`*_capacity` = 要素数。**新しい関数もこれに従い、
`summary` に毎回明記する。**

### 5.6 積は必ず `int64_t` に上げてから作り、上限で縛る

`point_count * 2 * sizeof(float)` のような積は、`int32_t` のまま計算すると
符号付きオーバーフロー（未定義動作）になる。**`static_cast<int64_t>` を先に当てる。**

加えて、**上限定数を置くのは「その値から native 側が何かを作る」ときだけにする**
（`OCVU_CHESSBOARD_MAX_CORNERS` / `OCVU_CALIB_MAX_POINTS` の前例は、どちらも
**入力**の点数から必要バイト数を作っている）。

**出力の `capacity` には上限を置かない。** あれは呼ぶ側が確保済みの buffer の
大きさであって、native は何も作らない。`capacity * 8` のような比較は
`int64_t` に上げれば桁あふれしない。**発火しえない上限を置くと、
`prove-a-check-works` が言う「壊して落ちることを見られない検査」が 1 つ増える。**

したがって、この計画が足す上限は**次の 2 つだけ**である。

| 定数 | 値 | 何を縛るか | なぜ要るか |
| --- | --- | --- | --- |
| `OCVU_PNP_MAX_POINTS` | 10000 | `ocvu_solve_pnp` / `ocvu_project_points` の `point_count` | **入力**の点数から必要バイト数を作る |
| `OCVU_CORNER_MAX_POINTS` | 10000 | `ocvu_corner_sub_pix` の `point_count` | 同上 |

**加えて 1 つだけ、確保量を縛るものがある。**

| 定数 | 値 | 何を縛るか |
| --- | --- | --- |
| `OCVU_ARUCO_MAX_MARKER_PIXELS` | 4096 | `ocvu_aruco_generate_marker` の `side_pixels`（native が `side_pixels * side_pixels` を確保する） |

### 5.7 OpenCV の値をそのまま出す定数には `static_assert` を置く

`OCVU_IMREAD_*` / `OCVU_CVT_*` / `OCVU_HOMOGRAPHY_METHOD_*` が既にそうしている。
**写し間違いをコンパイル時に落とす。**

**逆に、OpenCV に対応する値が無い定数には置かない**（置きようがない）。
この計画では `OCVU_BITWISE_*` / `OCVU_FEATURE_DETECTOR_*` / `OCVU_STEREO_*` が
それに当たる。**その場合はコメントで「これはこちらが決めた値である」と明記する** ——
`static_assert` が無いことが手抜きに見えないようにするためである。

### 5.8 到達性テストは全部の関数を「全部 0 / NULL」で呼ぶ

`AbiReachabilityChecks.g.cs` は生成物で、**`ulong` → `0UL`、`int` → `0`、
`double` → `0.0`、配列 → `null`、`out` → `out _`** で 1 回ずつ呼ぶ
（`bindings/generator/Ocvu.Generator/ReachabilityEmitter.cs` を実測）。

**したがって 26 本すべてが、全部 0 / NULL で呼ばれても落ちずに status を返さねばならない。**
これは Editor だけでなく **IL2CPP Player とブラウザでも走る**。
検証の順序（NULL → handle → 値域）を守れば自動的に満たされるが、
**実装のたびに意識すること。**

### 5.9 in-place を許すかどうかを毎回決めて `summary` に書く

`ocvu_cvt_color` / `ocvu_resize` は `src == dst` を**拒否**し、
`ocvu_undistort` は**許す**。**OpenCV 側の in-place 対応は関数ごとに違うので、
曖昧さを ABI に持ち込まない。**

この計画の方針: **結果を一時の `cv::Mat` に求めてから `*dst_mat` へ代入する**
形にできる関数は許し、OpenCV に直接 `dst` を書かせる関数は拒否する。
**どちらにするかは関数ごとに `summary` に書く。**

### 5.10 C# の公開クラスは module の範囲で分ける

`CvOps` は imgproc、`CvCodecs` は imgcodecs、というのが既にある区切りである
（`add-abi-function` skill:「1 つのクラスに全モジュールを詰めると、この plugin が
どの OpenCV モジュールをリンクしているかが C# 側から読み取れなくなる」）。

| Phase | C# の入口 |
| --- | --- |
| 1 | `CvGeometry`（既存に足す）と **`CvAruco`（新設）** |
| 2 | `CvOps`（既存に足す） |
| 3 | **`CvCoreOps`（新設）** |
| 4 | `CvFeatures`（既存に足す）と **`CvStereo`（新設）** |

**`Runtime/Core` と `Runtime/Interop` は `UnityEngine` を参照してはならない。**
`CvPoint2` / `CvPoint3` が `Vector2` / `Vector3` を使っていないのと同じ理由で、
新しい値型も `UnityEngine` を使わない。

---

## 6. `stereo` を足すときに同時に動くもの（Phase 4 だけ）

**`COMPONENTS` を変えるのは `geometry`（M5）・`calib`（M5）に続いて 3 例目である。**
`add-abi-function` skill の「新しい OpenCV module を足すなら、先にリンクを実証する」に
従うが、**`Modules` は触らないので、あの節が挙げる 5 つのうち動くのは一部だけである。**

| 場所 | 動くか | 理由 |
| --- | --- | --- |
| `cmake/FindOpenCvUnityDeps.cmake` の `COMPONENTS` | **動く** | `stereo` を足す |
| `native/tests/test_module_linkage.cpp` | **動く** | `cv::StereoBM` を参照する `StereoIsLinked` を足す |
| `tools/tests/OpenCvConfig.Tests.ps1` の `$specModulesNotBuiltDirectly` | **動く** | いま `@('infra', 'geometry')`。**`stereo` を足さないと、spec に `stereo` module が現れた瞬間にこの検査が落ちる**（`Modules` に無いため） |
| `native/include/opencv_unity_native.h` の `#include` 一覧 | **動く** | `#include "ocvu/stereo.h"` を手で 1 行足す（**この 1 行だけは生成物ではない**） |
| `README.md` / `README.ja.md` の「リンクしている module」 | **動く** | 両方に同じ一覧がある。**片方だけ直すと 2 つが食い違う** |
| `docs/abi-ownership-and-versioning.md` §3 | **動く** | allowlist に新しい節が要る |
| `tools/opencv-config.psd1` の `Modules` | **動かない** | `stereo` は `calib` が推移的に引くので足さない |
| `tools/verify-opencv-artifact.ps1` の `$AcceptedTransitiveModules` | **動かない** | `stereo` は既に載っている（実測） |
| `THIRD_PARTY_NOTICES.md` | **動かない** | `stereo` は OpenCV 本体の module で、新しい bundled 依存を持ち込まない（`calib` を足したときに確認済み） |
| 構成ハッシュ / OpenCV の再ビルド | **動かない** | `Modules` を触らないため |

---

## 7. `OCVU_ABI_VERSION` は 1 のまま

`docs/abi-ownership-and-versioning.md` §2 の「bump しない変更」に
**「関数の追加」**が明記されている。26 本足しても既存の宣言は 1 つも変わらないので
**bump しない。**

**新しい struct（`ocvu_dmatch`）の追加も bump しない** —— 既存の struct の
layout を変えていないためである。

---

## 8. 4 つの計画と、その順序

**この順序には理由がある。**

| 順 | 計画 | なぜこの位置か |
| --- | --- | --- |
| 1 | [姿勢と ArUco](./2026-09-05-api-pose-and-aruco.md) | **最も価値が高いものを先に出す。** ArUco の姿勢推定は `ocvu_solve_pnp` の上に立つので、geometry が先に要る |
| 2 | [imgproc の実用関数](./2026-09-05-api-imgproc-ops.md) | 本数が最も多い。**Phase 1 で可変長出力の作法が固まってから**着手すると、`ocvu_find_contours` の設計判断が減る |
| 3 | [core の基本演算](./2026-09-05-api-core-ops.md) | すべて既存の形の反復。**新しい設計判断がゼロ**なので、いつ着手してもよい |
| 4 | [マッチングとステレオ](./2026-09-05-api-matching-and-stereo.md) | **`COMPONENTS` と新しい struct を触る唯一の計画。** 他が全部済んでからにすると、赤くなったときの原因がここに限定される |

**各計画は単独で PR にでき、単独で main に入れられる。** 途中で止めても、
そこまでの関数は完全に使える状態になる。

---

## 9. 各計画に共通する完了条件

**4 つの計画すべてが、最後のタスクで次を満たす。**

- [ ] `./tools/dev.ps1 test` が exit 0（tools の速いテスト + `verify-generated` + L1 + L3）
- [ ] `./tools/dev.ps1 test-asan` が exit 0（**メモリを触る関数を足すので必ず回す**）
- [ ] `docs/api-map.md` が生成し直され、足した関数が全部載っている
- [ ] `docs/abi-ownership-and-versioning.md` §3 に新しい節がある（allowlist の正本）
- [ ] `docs/api-reference.md` の C ABI 節と C# 節の両方に足してある
- [ ] **`docs/api-reference.md` の「この allowlist に含まれないもの」から、足したものが消えている**（M5 で「足した機能が『まだ無い』側に残る」を実際に踏んだ）
- [ ] `CLAUDE.md` の ABI 内訳の段落と、ファイル配置の表が現状と合っている
- [ ] 実装した関数を実際に呼ぶ L1 と L3 が両方ある（**到達性テストは「呼べた」しか見ない**）
- [ ] 配布ライブラリの大きさを測って記録した（`README.ja.md` に前例がある）
- [ ] **PR を出す前に、その差分を書いていない別のエージェントでレビューした**

---

## 10. リスクと、それに対して用意してあるもの

| リスク | 対処 |
| --- | --- |
| **26 本は多い。** 途中で息切れする | **4 つに割ってある。** どれも単独で完結し、単独で配れる |
| `summary` に嘘を書いても `verify-generated` は緑になる | **`CLAUDE.md` の「CI が保証していないこと」に明記済みの穴である。** 各関数について、`summary` が約束した status を実際に返す L1 を書く（M5 の module 追加で 2 回踏んだ） |
| 生成物を手で編集してしまう | `check-generated-file-edit.sh` がその場で指摘し、`check-staged-generated-file.sh` が commit を止める |
| 一時ファイル名の衝突でフレークが出る | `tools/tests/*.Tests.ps1` を触らないので、この計画では起きない。触るなら `check-shared-temp-paths.sh` が指摘する |
| **binary が大きくなる** | `calib` の 3 本で +274,432 バイトだった。26 本で 1〜3 MB 増える見込み。**上限（`pack-upm-tarball.ps1` の 512 MB）に対して 2 桁小さいが、測って記録する** |
| ArUco の検出が環境で揺れる | **テストは自分で生成したマーカーを検出する閉じた輪にする**（`generateImageMarker` → `detectMarkers`）。外部の画像資産に依存しない |

---

## 11. 参照

- `.claude/skills/add-abi-function/SKILL.md` — **ABI を 1 本足す手順の正本。各計画のタスクはこれに従う**
- `.claude/skills/prove-a-check-works/SKILL.md` — 検査を足したら壊して落ちることを見る
- `.claude/skills/milestone-complete/SKILL.md` — 完了の判定（**これはマイルストーンではないが、文書の陳腐化確認の節はそのまま効く**）
- `docs/abi-ownership-and-versioning.md` — 所有権・versioning・allowlist の正本
- `docs/api-map.md` — **本数を数える唯一の場所**（生成物）
- `bindings/spec/schema.json` — spec の形
