# Phase 2 — imgproc の実用関数 実装計画

> **この計画より優先する文書がある。**
> 実装前に 12 観点 x 2 段で前提を実測し、**この計画の記述が 11 箇所で覆った** ——
> 決定は [実測で覆った前提と、その決定](./2026-09-05-api-expansion-corrections.md)
> にある。**食い違う箇所はあちらが正しい。**


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 二値化・エッジ・形態素・射影変換・テンプレート照合・線分検出・角点精緻化・輪郭検出を C ABI に出す。

**Architecture:** 9 本のうち 8 本は `imgproc` module、**1 本（`ocvu_get_perspective_transform`）だけが `geometry` module** である（下記）。実装は `native/src/ocvu_imgproc_ops.cpp`（画素を作る 5 本）と `native/src/ocvu_imgproc_shape.cpp`（形を返す 3 本）に分け、`ocvu_get_perspective_transform` だけ既存の `native/src/ocvu_geometry.cpp` に足す。**どちらの module も既にリンク済みなので、OpenCV の再ビルドは起きない。**

**Tech Stack:** C++17 / OpenCV 5.0.0（`imgproc` / `geometry`）/ C# netstandard2.1 / GoogleTest（L1）/ xUnit（L3）

**Spec:** [API 拡張（A〜F）— 全体設計と分割](./2026-09-05-api-surface-expansion.md)

## Global Constraints

**spec の §5 から、そのまま効くものを写す。**

- **`tools/opencv-config.psd1` の `Modules` も `cmake/FindOpenCvUnityDeps.cmake` の `COMPONENTS` も変えない**
- **新しい status code も新しい struct も足さない**
- **宣言を手で書かない。** `bindings/spec/<module>.json` に 1 エントリ足して `./tools/dev.ps1 generate`
- **`bool` を境界に出さない。** `int32_t` の 0 / 非 0 で受ける（`l2_gradient` がこれ）
- **`*_length` はバイト数、`*_capacity` は要素数。** 両方 `summary` に明記する
- **積は `static_cast<int64_t>` を先に当ててから作る**
- **可変長出力は「容量 + `BUFFER_TOO_SMALL` + `out_count`」の 1 形だけを使う**（2 回呼びにしない）
- **`out_count` は NULL 判定の直後に 0 を書き、以降のすべての早期 return がその後ろに来る**
- **公開 ABI 関数は `OCVU_TRY_BEGIN` / `OCVU_TRY_END` で囲む。** `cv::Exception` はその手前で個別に受けて `OCVU_STATUS_OPENCV_ERROR` にする
- **`extern "C" ocvu_status ocvu_名前(` までを 1 物理行に置く**
- **in-place（`src == dst`）を許すかどうかを関数ごとに決め、`summary` に書く**
- **`Runtime/Core` は `UnityEngine` を参照しない**
- **`git add -A` / `git add .` は hook が拒否する**

## 先に知っておくこと: `getPerspectiveTransform` は `imgproc` に無い

**実測（2026-09-05）**: `cv::getPerspectiveTransform` の宣言は
`third_party/opencv/<hash>/include/opencv2/geometry/2d.hpp:909` に在り、
**`imgproc.hpp` には無い**（`imgproc.hpp` に現れる 1 件は doc コメントの中の
参照である）。**OpenCV 5 が `calib3d` を割ったときに一緒に動いている。**

**したがって `ocvu_get_perspective_transform` は `bindings/spec/geometry.json` に書く。**
`imgproc.json` に書くと、生成される `docs/api-map.md` の module 列が実物と食い違う。

**`cv::warpPerspective` のほうは `imgproc.hpp:2161` に在る。**
**同じ用途の 2 本が別 module に居る** —— これは `ocvu_calibration.cpp` が
3 module にまたがっているのと同じ形である。

## ファイル構成

**新規**

| ファイル | 責務 |
| --- | --- |
| `native/src/ocvu_imgproc_ops.cpp` | 画素を作る 5 本（threshold / canny / morphology_ex / match_template / warp_perspective） |
| `native/src/ocvu_imgproc_shape.cpp` | 形を返す 3 本（hough_lines_p / corner_sub_pix / find_contours） |
| `native/tests/test_imgproc_ops.cpp` | 上 5 本と `ocvu_get_perspective_transform` の L1 |
| `native/tests/test_imgproc_shape.cpp` | 形を返す 3 本の L1 |
| `tests/Managed/CvUnity.Tests.Managed/ImgprocOpsTests.cs` | L3 |

**変更**

| ファイル | 何を |
| --- | --- |
| `native/include/opencv_unity_native.h` | `OCVU_THRESH_*`(6) / `OCVU_MORPH_*`(7) / `OCVU_MORPH_SHAPE_*`(3) / `OCVU_TM_*`(6) / `OCVU_RETR_*`(4) / `OCVU_CHAIN_APPROX_*`(2) / `OCVU_BORDER_*`(5) / `OCVU_CORNER_MAX_POINTS` |
| `bindings/spec/imgproc.json` | 8 エントリ |
| `bindings/spec/geometry.json` | 1 エントリ |
| `native/src/ocvu_geometry.cpp` | `ocvu_get_perspective_transform` |
| `native/CMakeLists.txt` / `native/tests/CMakeLists.txt` | ソース一覧 |
| `Packages/.../Runtime/Core/CvOps.cs` | 9 本ぶんの入口と `CvLine` / `CvContour` |
| `docs/abi-ownership-and-versioning.md` / `docs/api-reference.md` / `CLAUDE.md` | 文書 |

---

## Task 1: `ocvu_threshold` と `ocvu_canny`

**2 本まとめる。** どちらも「1 枚入れて 1 枚出す」だけで、レビューの粒度として分ける意味が無い。

**Files:**
- Create: `native/tests/test_imgproc_ops.cpp`、`native/src/ocvu_imgproc_ops.cpp`
- Modify: `native/include/opencv_unity_native.h`、`bindings/spec/imgproc.json`、`native/CMakeLists.txt`、`native/tests/CMakeLists.txt`

**Interfaces:**
- Produces:
  - `ocvu_status ocvu_threshold(ocvu_mat_handle src, ocvu_mat_handle dst, double threshold_value, double max_value, int32_t type, double* out_computed_threshold)`
  - `ocvu_status ocvu_canny(ocvu_mat_handle src, ocvu_mat_handle dst, double threshold1, double threshold2, int32_t aperture_size, int32_t l2_gradient)`

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_imgproc_ops.cpp` を新規作成する。

```cpp
// imgproc のうち「画素を作る」5 本と、geometry の ocvu_get_perspective_transform の
// 契約テスト。**期待値は手で決められる入力だけを使う。**

#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <array>
#include <vector>

namespace {

// 左半分が 10、右半分が 200 の 4x4 グレー画像を作る。
ocvu_mat_handle MakeSplitImage() {
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(4, 4, OCVU_MAT_TYPE_8UC1, &handle), OCVU_STATUS_OK);

    std::array<uint8_t, 16> pixels{};
    for (int r = 0; r < 4; ++r) {
        for (int c = 0; c < 4; ++c) {
            pixels[static_cast<size_t>(r) * 4 + c] = (c < 2) ? 10 : 200;
        }
    }
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(), 16, 4), OCVU_STATUS_OK);
    return handle;
}

std::vector<uint8_t> ReadPixels(ocvu_mat_handle handle) {
    ocvu_mat_info info{};
    EXPECT_EQ(ocvu_mat_get_info(handle, &info), OCVU_STATUS_OK);
    std::vector<uint8_t> pixels(static_cast<size_t>(info.rows) * info.cols * info.channels);
    EXPECT_EQ(ocvu_mat_copy_to_buffer(handle, pixels.data(),
                                      static_cast<int64_t>(pixels.size()),
                                      static_cast<int64_t>(info.cols) * info.channels),
              OCVU_STATUS_OK);
    return pixels;
}

}  // namespace

TEST(ImgprocOps, ThresholdSplitsAtTheGivenValue) {
    const ocvu_mat_handle src = MakeSplitImage();
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    double computed = -1.0;
    ASSERT_EQ(ocvu_threshold(src, dst, 100.0, 255.0, OCVU_THRESH_BINARY, &computed),
              OCVU_STATUS_OK);

    // しきい値を明示したので、そのまま返る。
    EXPECT_DOUBLE_EQ(computed, 100.0);

    const std::vector<uint8_t> pixels = ReadPixels(dst);
    ASSERT_EQ(pixels.size(), 16u);
    for (int r = 0; r < 4; ++r) {
        EXPECT_EQ(pixels[static_cast<size_t>(r) * 4 + 0], 0);
        EXPECT_EQ(pixels[static_cast<size_t>(r) * 4 + 1], 0);
        EXPECT_EQ(pixels[static_cast<size_t>(r) * 4 + 2], 255);
        EXPECT_EQ(pixels[static_cast<size_t>(r) * 4 + 3], 255);
    }

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(ImgprocOps, ThresholdReportsTheValueOtsuChose) {
    // **Otsu はしきい値を自分で選ぶ。** 呼ぶ側はそれを知りたいので返す。
    const ocvu_mat_handle src = MakeSplitImage();
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    double computed = -1.0;
    ASSERT_EQ(ocvu_threshold(src, dst, 0.0, 255.0,
                             OCVU_THRESH_BINARY | OCVU_THRESH_OTSU, &computed),
              OCVU_STATUS_OK);

    // 10 と 200 の 2 山なので、その間のどこかが選ばれる。
    EXPECT_GT(computed, 10.0);
    EXPECT_LT(computed, 200.0);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(ImgprocOps, ThresholdRejectsBadArgumentsAndDoesNotWriteTheComputedValue) {
    const ocvu_mat_handle src = MakeSplitImage();
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    // **0 ではない値で汚してから呼ぶ。**
    double computed = 12345.0;

    EXPECT_EQ(ocvu_threshold(OCVU_MAT_HANDLE_NONE, dst, 100.0, 255.0,
                             OCVU_THRESH_BINARY, &computed),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_DOUBLE_EQ(computed, 0.0) << "失敗時は out_computed_threshold に 0 を書くこと";

    computed = 12345.0;
    EXPECT_EQ(ocvu_threshold(src, OCVU_MAT_HANDLE_NONE, 100.0, 255.0,
                             OCVU_THRESH_BINARY, &computed),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_DOUBLE_EQ(computed, 0.0);

    // 知らない type を素通しにしない。
    computed = 12345.0;
    EXPECT_EQ(ocvu_threshold(src, dst, 100.0, 255.0, 99, &computed),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_DOUBLE_EQ(computed, 0.0);

    // out_computed_threshold は必須ではない —— NULL を許す。
    EXPECT_EQ(ocvu_threshold(src, dst, 100.0, 255.0, OCVU_THRESH_BINARY, nullptr),
              OCVU_STATUS_OK);

    // **src と dst が同じ handle でもよい。** 結果を一時に求めてから入れるので
    // 曖昧さが無い（cvtColor / resize と違って禁じない）。
    EXPECT_EQ(ocvu_threshold(src, src, 100.0, 255.0, OCVU_THRESH_BINARY, nullptr),
              OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(ImgprocOps, CannyFindsTheEdgeBetweenTheHalves) {
    const ocvu_mat_handle src = MakeSplitImage();
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    ASSERT_EQ(ocvu_canny(src, dst, 50.0, 150.0, 3, 0), OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 4);
    EXPECT_EQ(info.cols, 4);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_8UC1);

    // 段差があるので、どこかは 255 になる。**位置は OpenCV が決めるので数えない。**
    const std::vector<uint8_t> pixels = ReadPixels(dst);
    bool any_edge = false;
    for (uint8_t p : pixels) if (p == 255) any_edge = true;
    EXPECT_TRUE(any_edge) << "段差があるのにエッジが 1 画素も無い";

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(ImgprocOps, CannyRejectsBadArguments) {
    const ocvu_mat_handle src = MakeSplitImage();
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_canny(OCVU_MAT_HANDLE_NONE, dst, 50.0, 150.0, 3, 0),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_canny(src, OCVU_MAT_HANDLE_NONE, 50.0, 150.0, 3, 0),
              OCVU_STATUS_INVALID_HANDLE);

    // aperture_size は 3 / 5 / 7 のいずれかでなければならない。
    EXPECT_EQ(ocvu_canny(src, dst, 50.0, 150.0, 4, 0), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_canny(src, dst, 50.0, 150.0, 9, 0), OCVU_STATUS_INVALID_ARGUMENT);

    // しきい値が負なのは誤りである。
    EXPECT_EQ(ocvu_canny(src, dst, -1.0, 150.0, 3, 0), OCVU_STATUS_INVALID_ARGUMENT);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}
```

`native/tests/CMakeLists.txt` の一覧に `test_imgproc_ops.cpp` を足す。

- [ ] **Step 2: RED を目で確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: **コンパイルエラー**（`ocvu_threshold` も `OCVU_THRESH_BINARY` も無い）。

- [ ] **Step 3: 定数をヘッダに足す**

`native/include/opencv_unity_native.h` の `OCVU_IMREAD_*` の直後に足す。

```c
/* threshold の種類。cv::ThresholdTypes の値をそのまま使う
 * （実装 .cpp の static_assert が写し間違いをコンパイル時に落とす）。
 *
 * OCVU_THRESH_OTSU は上の 5 つのいずれかと **or して**渡す ——
 * しきい値を画像から自動で選ばせる指定である（渡した threshold_value は無視され、
 * 実際に選ばれた値が out_computed_threshold に入る）。 */
#define OCVU_THRESH_BINARY     0
#define OCVU_THRESH_BINARY_INV 1
#define OCVU_THRESH_TRUNC      2
#define OCVU_THRESH_TOZERO     3
#define OCVU_THRESH_TOZERO_INV 4
#define OCVU_THRESH_OTSU       8

/* 形態素演算の種類。cv::MorphTypes の値をそのまま使う。 */
#define OCVU_MORPH_ERODE    0
#define OCVU_MORPH_DILATE   1
#define OCVU_MORPH_OPEN     2
#define OCVU_MORPH_CLOSE    3
#define OCVU_MORPH_GRADIENT 4
#define OCVU_MORPH_TOPHAT   5
#define OCVU_MORPH_BLACKHAT 6

/* 形態素演算の構造要素の形。cv::MorphShapes の値をそのまま使う。 */
#define OCVU_MORPH_SHAPE_RECT    0
#define OCVU_MORPH_SHAPE_CROSS   1
#define OCVU_MORPH_SHAPE_ELLIPSE 2

/* テンプレート照合の方法。cv::TemplateMatchModes の値をそのまま使う。
 * SQDIFF 系は**小さいほど似ている**、他は大きいほど似ている。 */
#define OCVU_TM_SQDIFF        0
#define OCVU_TM_SQDIFF_NORMED 1
#define OCVU_TM_CCORR         2
#define OCVU_TM_CCORR_NORMED  3
#define OCVU_TM_CCOEFF        4
#define OCVU_TM_CCOEFF_NORMED 5

/* 輪郭の取り出し方。cv::RetrievalModes の値をそのまま使う。
 * **RETR_FLOODFILL は出していない** —— 32 bit 1 channel の入力を要求するので、
 * この ABI が扱う 8 bit の画像では使えない。 */
#define OCVU_RETR_EXTERNAL 0
#define OCVU_RETR_LIST     1
#define OCVU_RETR_CCOMP    2
#define OCVU_RETR_TREE     3

/* 輪郭の点の間引き方。cv::ContourApproximationModes の値をそのまま使う。 */
#define OCVU_CHAIN_APPROX_NONE   1
#define OCVU_CHAIN_APPROX_SIMPLE 2

/* 画像の外側をどう埋めるか。cv::BorderTypes の値をそのまま使う。 */
#define OCVU_BORDER_CONSTANT    0
#define OCVU_BORDER_REPLICATE   1
#define OCVU_BORDER_REFLECT     2
#define OCVU_BORDER_WRAP        3
#define OCVU_BORDER_REFLECT_101 4

/* ocvu_corner_sub_pix が受け取る点数の上限。
 * OCVU_PNP_MAX_POINTS と同じ理由 —— 点数から配列の必要バイト数を作るときに
 * int32_t の乗算が符号付きオーバーフローを起こさないための歯止めである。 */
#define OCVU_CORNER_MAX_POINTS 10000
```

- [ ] **Step 4: spec に 2 エントリ足して生成する**

`bindings/spec/imgproc.json` に足す。

```json
{
  "name": "ocvu_threshold",
  "summary": "src を二値化して dst に入れる。dst は結果に応じて丸ごと置き換わり、src と同じ形状・型になる。type は OCVU_THRESH_BINARY から OCVU_THRESH_TOZERO_INV までのいずれかで、OCVU_THRESH_OTSU を or して渡すとしきい値を画像から自動で選ぶ（そのとき threshold_value は無視される）。それ以外のビットが立っていれば OCVU_STATUS_INVALID_ARGUMENT を返す。out_computed_threshold には実際に使われたしきい値が入る —— Otsu を指定したときにそれを知る唯一の手段である。out_computed_threshold は NULL でもよく、その場合は書かない。NULL でない場合はどの失敗経路でも 0 を書く。src と dst に同じ handle を渡してもよい（結果を求めてから入れ替えるので in-place 呼び出しを禁じていない）。handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、失敗したときは dst を書き換えない。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "dst", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "threshold_value", "cType": "double", "csType": "double", "direction": "in" },
    { "name": "max_value", "cType": "double", "csType": "double", "direction": "in" },
    { "name": "type", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "out_computed_threshold", "cType": "double*", "csType": "double[]", "direction": "out-buffer" }
  ]
},
{
  "name": "ocvu_canny",
  "summary": "src に Canny のエッジ検出を掛けて dst に入れる。dst は結果に応じて丸ごと置き換わり、src と同じ大きさの 8 bit 1 channel になる（エッジが 255、それ以外が 0）。threshold1 と threshold2 はどちらも 0 以上でなければならず、負なら OCVU_STATUS_INVALID_ARGUMENT を返す。小さいほうが弱いエッジをつなぐ下限、大きいほうが強いエッジの下限として使われる。aperture_size は Sobel の窓の大きさで 3 / 5 / 7 のいずれかでなければならない。l2_gradient は 0 以外で真として扱い、勾配の大きさを L2 ノルムで測る（0 なら L1 で速いが粗い）。src と dst に同じ handle を渡してもよい。handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、失敗したときは dst を書き換えない。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "dst", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "threshold1", "cType": "double", "csType": "double", "direction": "in" },
    { "name": "threshold2", "cType": "double", "csType": "double", "direction": "in" },
    { "name": "aperture_size", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "l2_gradient", "cType": "int32_t", "csType": "int", "direction": "in" }
  ]
}
```

```
pwsh tools/dev.ps1 generate
```

- [ ] **Step 5: 実装する**

`native/src/ocvu_imgproc_ops.cpp` を新規作成する。

```cpp
// imgproc のうち「画素を作る」もの。
//
// **ocvu_imgproc.cpp に足していない。** あちらは M2 の 3 本（cvtColor / resize /
// GaussianBlur）で、そこへ 5 本足すと 1 ファイルが持つ責務が広くなりすぎる。

#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>

#include <cstdint>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

// 境界に出す値は OpenCV のものをそのまま使う。
static_assert(OCVU_THRESH_BINARY == cv::THRESH_BINARY, "THRESH_BINARY がずれている");
static_assert(OCVU_THRESH_BINARY_INV == cv::THRESH_BINARY_INV, "THRESH_BINARY_INV がずれている");
static_assert(OCVU_THRESH_TRUNC == cv::THRESH_TRUNC, "THRESH_TRUNC がずれている");
static_assert(OCVU_THRESH_TOZERO == cv::THRESH_TOZERO, "THRESH_TOZERO がずれている");
static_assert(OCVU_THRESH_TOZERO_INV == cv::THRESH_TOZERO_INV, "THRESH_TOZERO_INV がずれている");
static_assert(OCVU_THRESH_OTSU == cv::THRESH_OTSU, "THRESH_OTSU がずれている");
static_assert(OCVU_MORPH_ERODE == cv::MORPH_ERODE, "MORPH_ERODE がずれている");
static_assert(OCVU_MORPH_DILATE == cv::MORPH_DILATE, "MORPH_DILATE がずれている");
static_assert(OCVU_MORPH_OPEN == cv::MORPH_OPEN, "MORPH_OPEN がずれている");
static_assert(OCVU_MORPH_CLOSE == cv::MORPH_CLOSE, "MORPH_CLOSE がずれている");
static_assert(OCVU_MORPH_GRADIENT == cv::MORPH_GRADIENT, "MORPH_GRADIENT がずれている");
static_assert(OCVU_MORPH_TOPHAT == cv::MORPH_TOPHAT, "MORPH_TOPHAT がずれている");
static_assert(OCVU_MORPH_BLACKHAT == cv::MORPH_BLACKHAT, "MORPH_BLACKHAT がずれている");
static_assert(OCVU_MORPH_SHAPE_RECT == cv::MORPH_RECT, "MORPH_RECT がずれている");
static_assert(OCVU_MORPH_SHAPE_CROSS == cv::MORPH_CROSS, "MORPH_CROSS がずれている");
static_assert(OCVU_MORPH_SHAPE_ELLIPSE == cv::MORPH_ELLIPSE, "MORPH_ELLIPSE がずれている");
static_assert(OCVU_TM_SQDIFF == cv::TM_SQDIFF, "TM_SQDIFF がずれている");
static_assert(OCVU_TM_SQDIFF_NORMED == cv::TM_SQDIFF_NORMED, "TM_SQDIFF_NORMED がずれている");
static_assert(OCVU_TM_CCORR == cv::TM_CCORR, "TM_CCORR がずれている");
static_assert(OCVU_TM_CCORR_NORMED == cv::TM_CCORR_NORMED, "TM_CCORR_NORMED がずれている");
static_assert(OCVU_TM_CCOEFF == cv::TM_CCOEFF, "TM_CCOEFF がずれている");
static_assert(OCVU_TM_CCOEFF_NORMED == cv::TM_CCOEFF_NORMED, "TM_CCOEFF_NORMED がずれている");
static_assert(OCVU_BORDER_CONSTANT == cv::BORDER_CONSTANT, "BORDER_CONSTANT がずれている");
static_assert(OCVU_BORDER_REPLICATE == cv::BORDER_REPLICATE, "BORDER_REPLICATE がずれている");
static_assert(OCVU_BORDER_REFLECT == cv::BORDER_REFLECT, "BORDER_REFLECT がずれている");
static_assert(OCVU_BORDER_WRAP == cv::BORDER_WRAP, "BORDER_WRAP がずれている");
static_assert(OCVU_BORDER_REFLECT_101 == cv::BORDER_REFLECT_101, "BORDER_REFLECT_101 がずれている");

namespace ocvu_imgproc_ops_detail {

bool IsKnownThresholdType(int32_t type) {
    // OTSU は or して渡す。それを外した残りが 0..4 の範囲に収まっていること。
    const int32_t base = type & ~OCVU_THRESH_OTSU;
    return base >= OCVU_THRESH_BINARY && base <= OCVU_THRESH_TOZERO_INV;
}

bool IsKnownBorderMode(int32_t mode) {
    return mode >= OCVU_BORDER_CONSTANT && mode <= OCVU_BORDER_REFLECT_101;
}

bool IsKnownInterpolation(int32_t interpolation) {
    return interpolation == OCVU_INTER_NEAREST || interpolation == OCVU_INTER_LINEAR;
}

}  // namespace ocvu_imgproc_ops_detail

extern "C" ocvu_status ocvu_threshold(ocvu_mat_handle src, ocvu_mat_handle dst, double threshold_value, double max_value, int32_t type, double* out_computed_threshold) {
    OCVU_TRY_BEGIN
    using namespace ocvu_imgproc_ops_detail;

    // **NULL でないなら、何よりも先に 0 を書く。** どの経路で返っても、
    // 呼ぶ側が読む値が前回のまま残らないようにする。
    if (out_computed_threshold != nullptr) {
        *out_computed_threshold = 0.0;
    }

    if (!IsKnownThresholdType(type)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_threshold: type is not one of OCVU_THRESH_* (optionally or-ed with OCVU_THRESH_OTSU)");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_threshold: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_threshold: dst handle is invalid");
    }

    // **求めてから入れる。** src == dst でも壊れない形にしてある。
    cv::Mat result;
    double used = 0.0;
    try {
        used = cv::threshold(*src_mat, result, threshold_value, max_value, type);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    if (out_computed_threshold != nullptr) {
        *out_computed_threshold = used;
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_canny(ocvu_mat_handle src, ocvu_mat_handle dst, double threshold1, double threshold2, int32_t aperture_size, int32_t l2_gradient) {
    OCVU_TRY_BEGIN
    if (threshold1 < 0.0 || threshold2 < 0.0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_canny: thresholds must not be negative");
    }
    // OpenCV が受けるのは 3 / 5 / 7 だけである。落とすと例外になるのでここで断る。
    if (aperture_size != 3 && aperture_size != 5 && aperture_size != 7) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_canny: aperture_size must be 3, 5 or 7");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_canny: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_canny: dst handle is invalid");
    }

    cv::Mat result;
    try {
        cv::Canny(*src_mat, result, threshold1, threshold2, aperture_size, l2_gradient != 0);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

`native/CMakeLists.txt` の `OCVU_SOURCES` に `src/ocvu_imgproc_ops.cpp` を足す。

- [ ] **Step 6: L1 を緑にする**

```
pwsh tools/dev.ps1 test-native
```

期待: `ImgprocOps.Threshold*` 3 件と `ImgprocOps.Canny*` 2 件が pass、exit 0。

- [ ] **Step 7: 検査が働くことを確かめる**

1. `ocvu_threshold` の冒頭の `*out_computed_threshold = 0.0;` を消す
2. `pwsh tools/dev.ps1 test-native` → **`ThresholdRejectsBadArgumentsAndDoesNotWriteTheComputedValue`
   が落ちること**を目で見る
3. 戻して緑に戻ることを確認する

- [ ] **Step 8: コミット**

```bash
git add native/tests/test_imgproc_ops.cpp native/tests/CMakeLists.txt \
        native/src/ocvu_imgproc_ops.cpp native/CMakeLists.txt \
        native/include/opencv_unity_native.h bindings/spec/imgproc.json \
        native/include/ocvu/imgproc.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Imgproc.g.cs \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(imgproc): 二値化とエッジ検出の 2 本を出す"
```

---

## Task 2: `ocvu_morphology_ex` と `ocvu_match_template`

**Files:**
- Modify: `native/tests/test_imgproc_ops.cpp`、`native/src/ocvu_imgproc_ops.cpp`、`bindings/spec/imgproc.json`

**Interfaces:**
- Consumes: `MakeSplitImage` / `ReadPixels`（Task 1 のテストヘルパ）、`ocvu_imgproc_ops_detail::IsKnownBorderMode`
- Produces:
  - `ocvu_status ocvu_morphology_ex(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t op, int32_t kernel_shape, int32_t kernel_width, int32_t kernel_height, int32_t iterations)`
  - `ocvu_status ocvu_match_template(ocvu_mat_handle image, ocvu_mat_handle templ, ocvu_mat_handle dst, int32_t method)`

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_imgproc_ops.cpp` の末尾に足す。

```cpp
namespace {

// 中央 1 画素だけが 255 の 5x5 画像。
ocvu_mat_handle MakeSingleDot() {
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(5, 5, OCVU_MAT_TYPE_8UC1, &handle), OCVU_STATUS_OK);
    std::array<uint8_t, 25> pixels{};
    pixels[2 * 5 + 2] = 255;
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(), 25, 5), OCVU_STATUS_OK);
    return handle;
}

}  // namespace

TEST(ImgprocOps, DilateGrowsTheDot) {
    // 3x3 の矩形で膨張させると、1 画素の点が 3x3 に広がる。**手で数えられる。**
    const ocvu_mat_handle src = MakeSingleDot();
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    ASSERT_EQ(ocvu_morphology_ex(src, dst, OCVU_MORPH_DILATE, OCVU_MORPH_SHAPE_RECT, 3, 3, 1),
              OCVU_STATUS_OK);

    const std::vector<uint8_t> pixels = ReadPixels(dst);
    ASSERT_EQ(pixels.size(), 25u);
    int lit = 0;
    for (uint8_t p : pixels) if (p == 255) ++lit;
    EXPECT_EQ(lit, 9) << "3x3 の矩形で膨張したら 9 画素になる";

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(ImgprocOps, ErodeRemovesTheDot) {
    const ocvu_mat_handle src = MakeSingleDot();
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    ASSERT_EQ(ocvu_morphology_ex(src, dst, OCVU_MORPH_ERODE, OCVU_MORPH_SHAPE_RECT, 3, 3, 1),
              OCVU_STATUS_OK);

    const std::vector<uint8_t> pixels = ReadPixels(dst);
    for (uint8_t p : pixels) EXPECT_EQ(p, 0) << "1 画素の点は 3x3 の収縮で消える";

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(ImgprocOps, MorphologyRejectsBadArguments) {
    const ocvu_mat_handle src = MakeSingleDot();
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_morphology_ex(src, dst, 99, OCVU_MORPH_SHAPE_RECT, 3, 3, 1),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_morphology_ex(src, dst, OCVU_MORPH_DILATE, 99, 3, 3, 1),
              OCVU_STATUS_INVALID_ARGUMENT);
    // 構造要素の大きさは 1 以上でなければならない。
    EXPECT_EQ(ocvu_morphology_ex(src, dst, OCVU_MORPH_DILATE, OCVU_MORPH_SHAPE_RECT, 0, 3, 1),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_morphology_ex(src, dst, OCVU_MORPH_DILATE, OCVU_MORPH_SHAPE_RECT, 3, 0, 1),
              OCVU_STATUS_INVALID_ARGUMENT);
    // 繰り返しは 1 以上。
    EXPECT_EQ(ocvu_morphology_ex(src, dst, OCVU_MORPH_DILATE, OCVU_MORPH_SHAPE_RECT, 3, 3, 0),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_morphology_ex(OCVU_MAT_HANDLE_NONE, dst, OCVU_MORPH_DILATE,
                                 OCVU_MORPH_SHAPE_RECT, 3, 3, 1),
              OCVU_STATUS_INVALID_HANDLE);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(ImgprocOps, MatchTemplateProducesTheExpectedResultSize) {
    // 5x5 の画像に 3x3 のテンプレートを当てると、応答は 3x3 になる
    // （5 - 3 + 1 = 3）。**これは手で決まる。**
    const ocvu_mat_handle image = MakeSingleDot();
    ocvu_mat_handle templ = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(3, 3, OCVU_MAT_TYPE_8UC1, &templ), OCVU_STATUS_OK);
    std::array<uint8_t, 9> tpixels{};
    tpixels[4] = 255;
    ASSERT_EQ(ocvu_mat_copy_from_buffer(templ, tpixels.data(), 9, 3), OCVU_STATUS_OK);

    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    ASSERT_EQ(ocvu_match_template(image, templ, dst, OCVU_TM_CCOEFF_NORMED), OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 3);
    EXPECT_EQ(info.cols, 3);

    EXPECT_EQ(ocvu_mat_release(image), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(templ), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(ImgprocOps, MatchTemplateRejectsBadArguments) {
    const ocvu_mat_handle image = MakeSingleDot();
    ocvu_mat_handle templ = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(3, 3, OCVU_MAT_TYPE_8UC1, &templ), OCVU_STATUS_OK);
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_match_template(image, templ, dst, 99), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_match_template(OCVU_MAT_HANDLE_NONE, templ, dst, OCVU_TM_SQDIFF),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_match_template(image, OCVU_MAT_HANDLE_NONE, dst, OCVU_TM_SQDIFF),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_match_template(image, templ, OCVU_MAT_HANDLE_NONE, OCVU_TM_SQDIFF),
              OCVU_STATUS_INVALID_HANDLE);

    // **テンプレートが画像より大きいのは呼ぶ側の誤りである。** OpenCV に落とすと
    // 例外になるので、OPENCV_ERROR として報告する（原因不明にはしない）。
    ocvu_mat_handle big = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(9, 9, OCVU_MAT_TYPE_8UC1, &big), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_match_template(image, big, dst, OCVU_TM_SQDIFF), OCVU_STATUS_OPENCV_ERROR);

    EXPECT_EQ(ocvu_mat_release(image), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(templ), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(big), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}
```

- [ ] **Step 2: RED を目で確認する**

```
pwsh tools/dev.ps1 test-native
```

- [ ] **Step 3: spec に 2 エントリ足して生成する**

```json
{
  "name": "ocvu_morphology_ex",
  "summary": "src に形態素演算（収縮・膨張・開・閉・勾配・トップハット・ブラックハット）を掛けて dst に入れる。dst は結果に応じて丸ごと置き換わり、src と同じ形状・型になる。op は OCVU_MORPH_* のいずれか、kernel_shape は OCVU_MORPH_SHAPE_* のいずれかで、それ以外は OCVU_STATUS_INVALID_ARGUMENT を返す。kernel_width と kernel_height はどちらも 1 以上、iterations は 1 以上でなければならない。src と dst に同じ handle を渡してもよい。handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、失敗したときは dst を書き換えない。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "dst", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "op", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "kernel_shape", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "kernel_width", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "kernel_height", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "iterations", "cType": "int32_t", "csType": "int", "direction": "in" }
  ]
},
{
  "name": "ocvu_match_template",
  "summary": "image の中で templ に似ている場所の応答画像を作って dst に入れる。dst は結果に応じて丸ごと置き換わり、(image の幅 - templ の幅 + 1) x (image の高さ - templ の高さ + 1) の 32 bit 浮動小数 1 channel になる。method は OCVU_TM_* のいずれかで、それ以外は OCVU_STATUS_INVALID_ARGUMENT を返す。**OCVU_TM_SQDIFF と OCVU_TM_SQDIFF_NORMED は値が小さいほど似ており、他の 4 つは大きいほど似ている** —— 最も似た位置を探すときにどちらを取るかが逆になる。templ が image より大きい場合は OpenCV が例外を投げるので OCVU_STATUS_OPENCV_ERROR を返す。handle が無効なら OCVU_STATUS_INVALID_HANDLE。失敗したときは dst を書き換えない。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "image", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "templ", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "dst", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "method", "cType": "int32_t", "csType": "int", "direction": "in" }
  ]
}
```

```
pwsh tools/dev.ps1 generate
```

- [ ] **Step 4: 実装する**

`native/src/ocvu_imgproc_ops.cpp` に足す。まず detail 名前空間へ 2 つの述語を追加する。

```cpp
bool IsKnownMorphOp(int32_t op) {
    return op >= OCVU_MORPH_ERODE && op <= OCVU_MORPH_BLACKHAT;
}

bool IsKnownMorphShape(int32_t shape) {
    return shape >= OCVU_MORPH_SHAPE_RECT && shape <= OCVU_MORPH_SHAPE_ELLIPSE;
}

bool IsKnownTemplateMatchMethod(int32_t method) {
    return method >= OCVU_TM_SQDIFF && method <= OCVU_TM_CCOEFF_NORMED;
}
```

続けてファイル末尾に実装を足す。

```cpp
extern "C" ocvu_status ocvu_morphology_ex(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t op, int32_t kernel_shape, int32_t kernel_width, int32_t kernel_height, int32_t iterations) {
    OCVU_TRY_BEGIN
    using namespace ocvu_imgproc_ops_detail;

    if (!IsKnownMorphOp(op)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_morphology_ex: op is not one of OCVU_MORPH_*");
    }
    if (!IsKnownMorphShape(kernel_shape)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_morphology_ex: kernel_shape is not one of OCVU_MORPH_SHAPE_*");
    }
    if (kernel_width < 1 || kernel_height < 1) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_morphology_ex: kernel_width and kernel_height must be at least 1");
    }
    if (iterations < 1) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_morphology_ex: iterations must be at least 1");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_morphology_ex: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_morphology_ex: dst handle is invalid");
    }

    cv::Mat result;
    try {
        const cv::Mat kernel = cv::getStructuringElement(
            kernel_shape, cv::Size(kernel_width, kernel_height));
        cv::morphologyEx(*src_mat, result, op, kernel, cv::Point(-1, -1), iterations);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_match_template(ocvu_mat_handle image, ocvu_mat_handle templ, ocvu_mat_handle dst, int32_t method) {
    OCVU_TRY_BEGIN
    using namespace ocvu_imgproc_ops_detail;

    if (!IsKnownTemplateMatchMethod(method)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_match_template: method is not one of OCVU_TM_*");
    }

    const cv::Mat* image_mat = ::ocvu::mat_table_get(image);
    if (image_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_match_template: image handle is invalid");
    }
    const cv::Mat* templ_mat = ::ocvu::mat_table_get(templ);
    if (templ_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_match_template: templ handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_match_template: dst handle is invalid");
    }

    cv::Mat result;
    try {
        cv::matchTemplate(*image_mat, *templ_mat, result, method);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

- [ ] **Step 5: L1 を緑にする**

```
pwsh tools/dev.ps1 test-native
```

期待: `ImgprocOps.*` が 10 件 pass、exit 0。

- [ ] **Step 6: コミット**

```bash
git add native/tests/test_imgproc_ops.cpp native/src/ocvu_imgproc_ops.cpp \
        bindings/spec/imgproc.json native/include/ocvu/imgproc.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Imgproc.g.cs \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(imgproc): 形態素演算とテンプレート照合の 2 本を出す"
```

---

## Task 3: `ocvu_get_perspective_transform`（geometry）と `ocvu_warp_perspective`（imgproc）

**2 本まとめる。** 求めた変換で実際に変形して初めて正しさが言えるので、
**閉じた輪でテストする。**

**Files:**
- Modify: `native/tests/test_imgproc_ops.cpp`、`native/src/ocvu_geometry.cpp`、`native/src/ocvu_imgproc_ops.cpp`、`bindings/spec/geometry.json`、`bindings/spec/imgproc.json`

**Interfaces:**
- Produces:
  - `ocvu_status ocvu_get_perspective_transform(const float* src_points, int64_t src_length, const float* dst_points, int64_t dst_length, ocvu_mat_handle dst)`
  - `ocvu_status ocvu_warp_perspective(ocvu_mat_handle src, ocvu_mat_handle dst, ocvu_mat_handle transform, int32_t width, int32_t height, int32_t interpolation, int32_t border_mode)`

**設計の決定**: `ocvu_warp_perspective` の変換行列は **`ocvu_mat_handle` で受ける**
（`double[9]` ではない）。`ocvu_get_perspective_transform` も
`ocvu_find_homography` も `ocvu_mat_handle` に結果を入れるので、
**その出力をそのまま渡せる形にする。** 行列を C# へ読み出して詰め替える往復を
呼ぶ側に強いない。

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_imgproc_ops.cpp` の末尾に足す。

```cpp
TEST(ImgprocOps, PerspectiveTransformAndWarpRoundTrip) {
    // 4x4 の画像を、恒等ではない変換で 8x8 へ引き伸ばす。
    // **対応は「4 隅 -> 8x8 の 4 隅」なので、期待値は手で決まる。**
    const std::array<float, 8> from{0.0f, 0.0f, 3.0f, 0.0f, 3.0f, 3.0f, 0.0f, 3.0f};
    const std::array<float, 8> to{0.0f, 0.0f, 7.0f, 0.0f, 7.0f, 7.0f, 0.0f, 7.0f};

    ocvu_mat_handle transform = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &transform), OCVU_STATUS_OK);
    ASSERT_EQ(ocvu_get_perspective_transform(from.data(), static_cast<int64_t>(sizeof(from)),
                                             to.data(), static_cast<int64_t>(sizeof(to)),
                                             transform),
              OCVU_STATUS_OK);

    // 変換は 64 bit 1 channel の 3x3 である。
    ocvu_mat_info tinfo{};
    ASSERT_EQ(ocvu_mat_get_info(transform, &tinfo), OCVU_STATUS_OK);
    EXPECT_EQ(tinfo.rows, 3);
    EXPECT_EQ(tinfo.cols, 3);
    EXPECT_EQ(tinfo.channels, 1);

    const ocvu_mat_handle src = MakeSplitImage();
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    ASSERT_EQ(ocvu_warp_perspective(src, dst, transform, 8, 8,
                                    OCVU_INTER_NEAREST, OCVU_BORDER_CONSTANT),
              OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 8);
    EXPECT_EQ(info.cols, 8);

    // 左半分が暗く、右半分が明るいという性質は保たれる。
    const std::vector<uint8_t> pixels = ReadPixels(dst);
    EXPECT_LT(pixels[4 * 8 + 1], 100) << "左が明るくなっている";
    EXPECT_GT(pixels[4 * 8 + 6], 100) << "右が暗くなっている";

    EXPECT_EQ(ocvu_mat_release(transform), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(ImgprocOps, PerspectiveTransformRejectsBadArguments) {
    const std::array<float, 8> quad{0.0f, 0.0f, 3.0f, 0.0f, 3.0f, 3.0f, 0.0f, 3.0f};
    ocvu_mat_handle transform = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &transform), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_get_perspective_transform(nullptr, static_cast<int64_t>(sizeof(quad)),
                                             quad.data(), static_cast<int64_t>(sizeof(quad)),
                                             transform),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_get_perspective_transform(quad.data(), static_cast<int64_t>(sizeof(quad)),
                                             nullptr, static_cast<int64_t>(sizeof(quad)),
                                             transform),
              OCVU_STATUS_NULL_POINTER);

    // **ちょうど 4 点ぶん（32 バイト）が要る。** 1 バイト足りなければ何も読まない。
    EXPECT_EQ(ocvu_get_perspective_transform(quad.data(), static_cast<int64_t>(sizeof(quad)) - 1,
                                             quad.data(), static_cast<int64_t>(sizeof(quad)),
                                             transform),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_get_perspective_transform(quad.data(), static_cast<int64_t>(sizeof(quad)),
                                             quad.data(), static_cast<int64_t>(sizeof(quad)) - 1,
                                             transform),
              OCVU_STATUS_INVALID_ARGUMENT);

    EXPECT_EQ(ocvu_get_perspective_transform(quad.data(), static_cast<int64_t>(sizeof(quad)),
                                             quad.data(), static_cast<int64_t>(sizeof(quad)),
                                             OCVU_MAT_HANDLE_NONE),
              OCVU_STATUS_INVALID_HANDLE);

    EXPECT_EQ(ocvu_mat_release(transform), OCVU_STATUS_OK);
}

TEST(ImgprocOps, WarpPerspectiveRejectsBadArguments) {
    const std::array<float, 8> from{0.0f, 0.0f, 3.0f, 0.0f, 3.0f, 3.0f, 0.0f, 3.0f};
    ocvu_mat_handle transform = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &transform), OCVU_STATUS_OK);
    ASSERT_EQ(ocvu_get_perspective_transform(from.data(), static_cast<int64_t>(sizeof(from)),
                                             from.data(), static_cast<int64_t>(sizeof(from)),
                                             transform),
              OCVU_STATUS_OK);

    const ocvu_mat_handle src = MakeSplitImage();
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_warp_perspective(src, dst, transform, 0, 8,
                                    OCVU_INTER_NEAREST, OCVU_BORDER_CONSTANT),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_warp_perspective(src, dst, transform, 8, 0,
                                    OCVU_INTER_NEAREST, OCVU_BORDER_CONSTANT),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_warp_perspective(src, dst, transform, 8, 8, 99, OCVU_BORDER_CONSTANT),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_warp_perspective(src, dst, transform, 8, 8, OCVU_INTER_NEAREST, 99),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_warp_perspective(src, dst, OCVU_MAT_HANDLE_NONE, 8, 8,
                                    OCVU_INTER_NEAREST, OCVU_BORDER_CONSTANT),
              OCVU_STATUS_INVALID_HANDLE);

    // **変換が 3x3 でないのは呼ぶ側の誤りである。** src（4x4）を渡して確かめる。
    EXPECT_EQ(ocvu_warp_perspective(src, dst, src, 8, 8,
                                    OCVU_INTER_NEAREST, OCVU_BORDER_CONSTANT),
              OCVU_STATUS_INVALID_ARGUMENT);

    EXPECT_EQ(ocvu_mat_release(transform), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}
```

- [ ] **Step 2: RED を目で確認する**

```
pwsh tools/dev.ps1 test-native
```

- [ ] **Step 3: spec に 2 エントリ足して生成する**

**`ocvu_get_perspective_transform` は `bindings/spec/geometry.json` に書く**
（`cv::getPerspectiveTransform` が `geometry` に在るため。この計画の冒頭を参照）。

```json
{
  "name": "ocvu_get_perspective_transform",
  "summary": "ちょうど 4 点の対応から射影変換（3x3）を厳密に求めて dst に入れる。dst は結果に応じて丸ごと置き換わり、64 bit 1 channel の 3x3 になる。src_points と dst_points はどちらも x と y が交互に並ぶ float 8 個で、src_length と dst_length はその配列の**バイト数**である（要素数でも点数でもない）。**呼ぶ側を信用せず、4 点ぶん（float 8 個）に満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。** ocvu_find_homography との違いは、こちらが**ちょうど 4 点を厳密に通す**のに対し、あちらは 4 点以上から当てはめる点である —— 外れ値がありうる対応には ocvu_find_homography を使うこと。dst の handle が無効なら OCVU_STATUS_INVALID_HANDLE。点が退化していて解が求まらない場合は OpenCV が例外を投げるので OCVU_STATUS_OPENCV_ERROR を返す。失敗したときは dst を書き換えない。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "src_points", "cType": "const float*", "csType": "float[]", "direction": "in-buffer" },
    { "name": "src_length", "cType": "int64_t", "csType": "long", "direction": "in" },
    { "name": "dst_points", "cType": "const float*", "csType": "float[]", "direction": "in-buffer" },
    { "name": "dst_length", "cType": "int64_t", "csType": "long", "direction": "in" },
    { "name": "dst", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" }
  ]
}
```

`bindings/spec/imgproc.json` に足す。

```json
{
  "name": "ocvu_warp_perspective",
  "summary": "src を射影変換で変形して dst に入れる。dst は結果に応じて丸ごと置き換わり、height x width で src と同じ型になる。transform は 3x3 の変換行列を持つ Mat の handle である（ocvu_get_perspective_transform や ocvu_find_homography の出力をそのまま渡せる）—— 3 行 3 列でなければ OCVU_STATUS_INVALID_ARGUMENT を返す。width と height はどちらも 1 以上でなければならない。interpolation は OCVU_INTER_* のいずれか、border_mode は OCVU_BORDER_* のいずれかで、それ以外は拒否する。**src と dst に同じ handle を渡してはならない場合がある**が、この実装は結果を一時に求めてから入れるので許している。handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、失敗したときは dst を書き換えない。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "dst", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "transform", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "width", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "height", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "interpolation", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "border_mode", "cType": "int32_t", "csType": "int", "direction": "in" }
  ]
}
```

```
pwsh tools/dev.ps1 generate
```

- [ ] **Step 4: 実装する**

`native/src/ocvu_geometry.cpp` の末尾に足す（`#include <opencv2/geometry.hpp>` は既にある）。

```cpp
extern "C" ocvu_status ocvu_get_perspective_transform(const float* src_points, int64_t src_length, const float* dst_points, int64_t dst_length, ocvu_mat_handle dst) {
    OCVU_TRY_BEGIN
    if (src_points == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_get_perspective_transform: src_points is NULL");
    }
    if (dst_points == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_get_perspective_transform: dst_points is NULL");
    }

    // **ちょうど 4 点である。** 射影変換はそれで一意に決まる。
    constexpr int64_t kNeeded = 4 * 2 * static_cast<int64_t>(sizeof(float));
    if (src_length < kNeeded) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_get_perspective_transform: src_length (bytes) is too small for 4 points");
    }
    if (dst_length < kNeeded) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_get_perspective_transform: dst_length (bytes) is too small for 4 points");
    }

    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_get_perspective_transform: dst handle is invalid");
    }

    const cv::Mat src_view(4, 2, CV_32F, const_cast<float*>(src_points));
    const cv::Mat dst_view(4, 2, CV_32F, const_cast<float*>(dst_points));

    cv::Mat transform;
    try {
        transform = cv::getPerspectiveTransform(src_view, dst_view);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }
    if (transform.empty()) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_OPENCV_ERROR,
            "ocvu_get_perspective_transform: OpenCV returned an empty transform");
    }

    *dst_mat = transform;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

`native/src/ocvu_imgproc_ops.cpp` の末尾に足す。

```cpp
extern "C" ocvu_status ocvu_warp_perspective(ocvu_mat_handle src, ocvu_mat_handle dst, ocvu_mat_handle transform, int32_t width, int32_t height, int32_t interpolation, int32_t border_mode) {
    OCVU_TRY_BEGIN
    using namespace ocvu_imgproc_ops_detail;

    if (width < 1 || height < 1) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_warp_perspective: width and height must be at least 1");
    }
    if (!IsKnownInterpolation(interpolation)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_warp_perspective: interpolation is not one of OCVU_INTER_*");
    }
    if (!IsKnownBorderMode(border_mode)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_warp_perspective: border_mode is not one of OCVU_BORDER_*");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_warp_perspective: src handle is invalid");
    }
    const cv::Mat* transform_mat = ::ocvu::mat_table_get(transform);
    if (transform_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_warp_perspective: transform handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_warp_perspective: dst handle is invalid");
    }

    // **形を自分で確かめる。** OpenCV に落とすと例外になるが、呼ぶ側が直せる
    // 誤りなので INVALID_ARGUMENT で返す。
    if (transform_mat->rows != 3 || transform_mat->cols != 3) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_warp_perspective: transform must be a 3x3 matrix");
    }

    cv::Mat result;
    try {
        cv::warpPerspective(*src_mat, result, *transform_mat, cv::Size(width, height),
                            interpolation, border_mode);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

- [ ] **Step 5: L1 を緑にする**

```
pwsh tools/dev.ps1 test-native
```

期待: `ImgprocOps.*` が 13 件 pass、exit 0。

- [ ] **Step 6: コミット**

```bash
git add native/tests/test_imgproc_ops.cpp native/src/ocvu_geometry.cpp \
        native/src/ocvu_imgproc_ops.cpp \
        bindings/spec/geometry.json bindings/spec/imgproc.json \
        native/include/ocvu/geometry.h native/include/ocvu/imgproc.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Geometry.g.cs \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Imgproc.g.cs \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(geometry,imgproc): 4 点から射影変換を求めて画像を変形する 2 本を出す"
```

---

## Task 4: `ocvu_hough_lines_p` と `ocvu_corner_sub_pix`

**Files:**
- Create: `native/tests/test_imgproc_shape.cpp`、`native/src/ocvu_imgproc_shape.cpp`
- Modify: `bindings/spec/imgproc.json`、`native/CMakeLists.txt`、`native/tests/CMakeLists.txt`

**Interfaces:**
- Produces:
  - `ocvu_status ocvu_hough_lines_p(ocvu_mat_handle src, double rho, double theta, int32_t threshold, double min_line_length, double max_line_gap, float* out_lines, int32_t capacity, int32_t* out_count)`
  - `ocvu_status ocvu_corner_sub_pix(ocvu_mat_handle src, float* points, int64_t points_length, int32_t point_count, int32_t win_size, int32_t zero_zone, int32_t max_iterations, double epsilon)`

**設計の決定**: `ocvu_corner_sub_pix` の `points` は **入出力兼用**である
（`direction` は `out-buffer`）。**この ABI で初めての形**なので `summary` に明記する ——
既存の buffer 引数は入力か出力のどちらかだった。

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_imgproc_shape.cpp` を新規作成する。

```cpp
// imgproc のうち「形を返す」3 本の契約テスト。
//
// **入力は自分で描いた図形にする。** 外部の画像に依存しない。

#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <array>
#include <cmath>
#include <vector>

namespace {

// 幅 side の黒い画像に、指定した行だけ白い横線を引いたもの。
ocvu_mat_handle MakeHorizontalLine(int32_t side, int32_t row) {
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(side, side, OCVU_MAT_TYPE_8UC1, &handle), OCVU_STATUS_OK);
    std::vector<uint8_t> pixels(static_cast<size_t>(side) * side, 0);
    for (int32_t c = 0; c < side; ++c) {
        pixels[static_cast<size_t>(row) * side + c] = 255;
    }
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(),
                                        static_cast<int64_t>(pixels.size()), side),
              OCVU_STATUS_OK);
    return handle;
}

// 左上が黒、右下が白の 2 値の市松（角点が中央にできる）。
ocvu_mat_handle MakeCheckerCorner(int32_t side) {
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(side, side, OCVU_MAT_TYPE_8UC1, &handle), OCVU_STATUS_OK);
    std::vector<uint8_t> pixels(static_cast<size_t>(side) * side, 0);
    const int32_t half = side / 2;
    for (int32_t r = 0; r < side; ++r) {
        for (int32_t c = 0; c < side; ++c) {
            const bool white = (r < half) == (c < half);
            pixels[static_cast<size_t>(r) * side + c] = white ? 255 : 0;
        }
    }
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(),
                                        static_cast<int64_t>(pixels.size()), side),
              OCVU_STATUS_OK);
    return handle;
}

}  // namespace

TEST(ImgprocShape, HoughFindsTheHorizontalLine) {
    const ocvu_mat_handle src = MakeHorizontalLine(64, 32);

    std::array<float, 64> lines{};
    int32_t count = -1;
    const double theta = std::acos(-1.0) / 180.0;  // 1 度

    ASSERT_EQ(ocvu_hough_lines_p(src, 1.0, theta, 30, 20.0, 5.0,
                                 lines.data(), 64, &count),
              OCVU_STATUS_OK);
    ASSERT_GE(count, 1) << "1 本の横線があるのに何も見つからない";

    // 1 本目は y がほぼ 32 の横線である（4 要素で x1, y1, x2, y2）。
    EXPECT_NEAR(lines[1], 32.0f, 2.0f);
    EXPECT_NEAR(lines[3], 32.0f, 2.0f);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
}

TEST(ImgprocShape, HoughReturnsZeroOnABlankImage) {
    // **見つからないのは誤りではない。**
    ocvu_mat_handle blank = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(64, 64, OCVU_MAT_TYPE_8UC1, &blank), OCVU_STATUS_OK);

    std::array<float, 64> lines{};
    int32_t count = -1;
    const double theta = std::acos(-1.0) / 180.0;

    EXPECT_EQ(ocvu_hough_lines_p(blank, 1.0, theta, 30, 20.0, 5.0,
                                 lines.data(), 64, &count),
              OCVU_STATUS_OK);
    EXPECT_EQ(count, 0);

    EXPECT_EQ(ocvu_mat_release(blank), OCVU_STATUS_OK);
}

TEST(ImgprocShape, HoughRejectsBadArgumentsAndZeroesTheCount) {
    const ocvu_mat_handle src = MakeHorizontalLine(64, 32);
    std::array<float, 64> lines{};
    const double theta = std::acos(-1.0) / 180.0;

    EXPECT_EQ(ocvu_hough_lines_p(src, 1.0, theta, 30, 20.0, 5.0, lines.data(), 64, nullptr),
              OCVU_STATUS_NULL_POINTER);

    // **0 ではない値で汚してから呼ぶ。**
    int32_t count = 12345;
    EXPECT_EQ(ocvu_hough_lines_p(src, 0.0, theta, 30, 20.0, 5.0, lines.data(), 64, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0) << "失敗時は out_count に 0 を書くこと";

    count = 12345;
    EXPECT_EQ(ocvu_hough_lines_p(src, 1.0, 0.0, 30, 20.0, 5.0, lines.data(), 64, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_hough_lines_p(src, 1.0, theta, 0, 20.0, 5.0, lines.data(), 64, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_hough_lines_p(src, 1.0, theta, 30, 20.0, 5.0, nullptr, 64, &count),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_hough_lines_p(OCVU_MAT_HANDLE_NONE, 1.0, theta, 30, 20.0, 5.0,
                                 lines.data(), 64, &count),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(count, 0);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
}

TEST(ImgprocShape, HoughReportsTheNeededCountWhenTheBufferIsTooSmall) {
    const ocvu_mat_handle src = MakeHorizontalLine(64, 32);
    std::array<float, 64> lines{};
    lines.fill(-7.0f);
    int32_t count = -1;
    const double theta = std::acos(-1.0) / 180.0;

    // 容量 0 では 1 本も入らない。
    EXPECT_EQ(ocvu_hough_lines_p(src, 1.0, theta, 30, 20.0, 5.0, lines.data(), 0, &count),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_GE(count, 1) << "溢れたときは実際に見つかった数を返すこと";
    for (float v : lines) EXPECT_FLOAT_EQ(v, -7.0f) << "断ったのに書いている";

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
}

TEST(ImgprocShape, CornerSubPixMovesThePointTowardTheCorner) {
    // 32x32 の市松の角は (16, 16) にある。**そこから 2 画素ずらして渡す。**
    const ocvu_mat_handle src = MakeCheckerCorner(32);
    std::array<float, 2> points{14.0f, 14.0f};

    ASSERT_EQ(ocvu_corner_sub_pix(src, points.data(), static_cast<int64_t>(sizeof(points)),
                                  1, 5, -1, 30, 0.01),
              OCVU_STATUS_OK);

    // **精緻化なので、元の位置より角に近づいていればよい。**
    EXPECT_NEAR(points[0], 16.0f, 1.5f);
    EXPECT_NEAR(points[1], 16.0f, 1.5f);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
}

TEST(ImgprocShape, CornerSubPixRejectsBadArgumentsWithoutTouchingThePoints) {
    const ocvu_mat_handle src = MakeCheckerCorner(32);
    std::array<float, 2> points{14.0f, 14.0f};

    EXPECT_EQ(ocvu_corner_sub_pix(src, nullptr, static_cast<int64_t>(sizeof(points)),
                                  1, 5, -1, 30, 0.01),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_corner_sub_pix(src, points.data(), static_cast<int64_t>(sizeof(points)),
                                  0, 5, -1, 30, 0.01),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_corner_sub_pix(src, points.data(), static_cast<int64_t>(sizeof(points)),
                                  OCVU_CORNER_MAX_POINTS + 1, 5, -1, 30, 0.01),
              OCVU_STATUS_INVALID_ARGUMENT);
    // **長さはバイト数である。** 1 バイト足りなければ何も読まない。
    EXPECT_EQ(ocvu_corner_sub_pix(src, points.data(), static_cast<int64_t>(sizeof(points)) - 1,
                                  1, 5, -1, 30, 0.01),
              OCVU_STATUS_INVALID_ARGUMENT);
    // 窓は 1 以上、繰り返しは 1 以上。
    EXPECT_EQ(ocvu_corner_sub_pix(src, points.data(), static_cast<int64_t>(sizeof(points)),
                                  1, 0, -1, 30, 0.01),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_corner_sub_pix(src, points.data(), static_cast<int64_t>(sizeof(points)),
                                  1, 5, -1, 0, 0.01),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_corner_sub_pix(OCVU_MAT_HANDLE_NONE, points.data(),
                                  static_cast<int64_t>(sizeof(points)), 1, 5, -1, 30, 0.01),
              OCVU_STATUS_INVALID_HANDLE);

    // **断ったのだから、渡した点は 1 つも動いていない。**
    EXPECT_FLOAT_EQ(points[0], 14.0f);
    EXPECT_FLOAT_EQ(points[1], 14.0f);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
}
```

`native/tests/CMakeLists.txt` の一覧に `test_imgproc_shape.cpp` を足す。

- [ ] **Step 2: RED を目で確認する**

```
pwsh tools/dev.ps1 test-native
```

- [ ] **Step 3: spec に 2 エントリ足して生成する**

```json
{
  "name": "ocvu_hough_lines_p",
  "summary": "確率的 Hough 変換で src から線分を検出し、out_lines へ書いて本数を out_count に返す。src は 8 bit 1 channel の 2 値画像でなければならない（ocvu_canny の出力をそのまま渡せる）。rho は距離の刻み（画素）で 0 より大きく、theta は角度の刻み（ラジアン）で 0 より大きく、threshold は投票数の下限で 1 以上でなければならない。min_line_length より短い線分は捨て、max_line_gap 以下の切れ目はつなぐ。capacity は out_lines の**要素数**である（バイト数でも本数でもない）—— 1 本につき 4 要素（x1, y1, x2, y2）要るので、n 本を受けるには capacity が n * 4 以上でなければならない。足りないときは**何も書かずに** OCVU_STATUS_BUFFER_TOO_SMALL を返し、out_count に**実際に見つかった本数**を入れる。**1 本も見つからないのは誤りではない** —— OCVU_STATUS_OK を返して out_count に 0 を入れる。out_count が NULL なら他の何より先に OCVU_STATUS_NULL_POINTER を返し、通ったあとはどの失敗経路でも out_count に 0 を書く。handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返す。buffer の所有権は最初から最後まで呼ぶ側にある。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "rho", "cType": "double", "csType": "double", "direction": "in" },
    { "name": "theta", "cType": "double", "csType": "double", "direction": "in" },
    { "name": "threshold", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "min_line_length", "cType": "double", "csType": "double", "direction": "in" },
    { "name": "max_line_gap", "cType": "double", "csType": "double", "direction": "in" },
    { "name": "out_lines", "cType": "float*", "csType": "float[]", "direction": "out-buffer" },
    { "name": "capacity", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "out_count", "cType": "int32_t*", "csType": "out int", "direction": "out" }
  ]
},
{
  "name": "ocvu_corner_sub_pix",
  "summary": "既に見つけてある角点の位置を副画素精度へ精緻化する。**points は入出力兼用である** —— 渡した位置を読み、精緻化した位置でその場を上書きする（この ABI で唯一この形をしている）。x と y が交互に並ぶ float の配列で、points_length はその**バイト数**である（要素数でも点数でもない）。point_count は 1 以上 OCVU_CORNER_MAX_POINTS 以下でなければならず、長さが point_count * 2 * sizeof(float) に満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。win_size は探索窓の半径（画素）で 1 以上、zero_zone は窓の中央で無視する領域の半径で -1 なら無視しない、max_iterations は 1 以上、epsilon は移動量がこれを下回ったら打ち切る値である。src は 8 bit 1 channel でなければならない。**断った場合は points を 1 バイトも書き換えない。** handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、そのときも points は書き換えない。buffer の所有権は最初から最後まで呼ぶ側にある。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "points", "cType": "float*", "csType": "float[]", "direction": "out-buffer" },
    { "name": "points_length", "cType": "int64_t", "csType": "long", "direction": "in" },
    { "name": "point_count", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "win_size", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "zero_zone", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "max_iterations", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "epsilon", "cType": "double", "csType": "double", "direction": "in" }
  ]
}
```

```
pwsh tools/dev.ps1 generate
```

- [ ] **Step 4: 実装する**

`native/src/ocvu_imgproc_shape.cpp` を新規作成する。

```cpp
// imgproc のうち「形を返す」もの。座標や点列を境界に出すので、
// 画素を作るだけの ocvu_imgproc_ops.cpp とは扱いが違う。

#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>

#include <cstdint>
#include <vector>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

extern "C" ocvu_status ocvu_hough_lines_p(ocvu_mat_handle src, double rho, double theta, int32_t threshold, double min_line_length, double max_line_gap, float* out_lines, int32_t capacity, int32_t* out_count) {
    OCVU_TRY_BEGIN
    // **out_count を最初に見る。** 無いと呼ぶ側は溢れたときの必要量を決められない。
    if (out_count == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_hough_lines_p: out_count is NULL");
    }
    *out_count = 0;

    if (rho <= 0.0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_hough_lines_p: rho must be greater than 0");
    }
    if (theta <= 0.0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_hough_lines_p: theta must be greater than 0");
    }
    if (threshold < 1) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_hough_lines_p: threshold must be at least 1");
    }
    if (out_lines == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_hough_lines_p: out_lines is NULL");
    }
    if (capacity < 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_hough_lines_p: capacity must not be negative");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_hough_lines_p: src handle is invalid");
    }

    std::vector<cv::Vec4i> lines;
    try {
        cv::HoughLinesP(*src_mat, lines, rho, theta, threshold, min_line_length, max_line_gap);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    const int64_t found = static_cast<int64_t>(lines.size());
    const int64_t needed = found * 4;
    if (needed > static_cast<int64_t>(capacity)) {
        *out_count = static_cast<int32_t>(found);
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_hough_lines_p: capacity (elements) must be at least 4 times the line count");
    }

    for (int64_t i = 0; i < found; ++i) {
        const cv::Vec4i& line = lines[static_cast<size_t>(i)];
        out_lines[i * 4] = static_cast<float>(line[0]);
        out_lines[i * 4 + 1] = static_cast<float>(line[1]);
        out_lines[i * 4 + 2] = static_cast<float>(line[2]);
        out_lines[i * 4 + 3] = static_cast<float>(line[3]);
    }

    *out_count = static_cast<int32_t>(found);
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_corner_sub_pix(ocvu_mat_handle src, float* points, int64_t points_length, int32_t point_count, int32_t win_size, int32_t zero_zone, int32_t max_iterations, double epsilon) {
    OCVU_TRY_BEGIN
    if (points == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_corner_sub_pix: points is NULL");
    }
    if (point_count < 1 || point_count > OCVU_CORNER_MAX_POINTS) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_corner_sub_pix: point_count must be between 1 and OCVU_CORNER_MAX_POINTS");
    }
    const int64_t needed =
        static_cast<int64_t>(point_count) * 2 * static_cast<int64_t>(sizeof(float));
    if (points_length < needed) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_corner_sub_pix: points_length (bytes) is too small for point_count");
    }
    if (win_size < 1) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_corner_sub_pix: win_size must be at least 1");
    }
    if (max_iterations < 1) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_corner_sub_pix: max_iterations must be at least 1");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_corner_sub_pix: src handle is invalid");
    }

    // **呼ぶ側の buffer を直接 OpenCV に渡さない。** 途中で例外になったときに
    // points が書きかけで残ることを避けるため、写してから戻す。
    std::vector<cv::Point2f> corners(static_cast<size_t>(point_count));
    for (int32_t i = 0; i < point_count; ++i) {
        corners[static_cast<size_t>(i)] = cv::Point2f(points[i * 2], points[i * 2 + 1]);
    }

    try {
        cv::cornerSubPix(
            *src_mat, corners, cv::Size(win_size, win_size), cv::Size(zero_zone, zero_zone),
            cv::TermCriteria(cv::TermCriteria::EPS + cv::TermCriteria::MAX_ITER,
                             max_iterations, epsilon));
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    for (int32_t i = 0; i < point_count; ++i) {
        points[i * 2] = corners[static_cast<size_t>(i)].x;
        points[i * 2 + 1] = corners[static_cast<size_t>(i)].y;
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

`native/CMakeLists.txt` の `OCVU_SOURCES` に `src/ocvu_imgproc_shape.cpp` を足す。

- [ ] **Step 5: L1 を緑にする**

```
pwsh tools/dev.ps1 test-native
```

期待: `ImgprocShape.*` が 6 件 pass、exit 0。

- [ ] **Step 6: コミット**

```bash
git add native/tests/test_imgproc_shape.cpp native/tests/CMakeLists.txt \
        native/src/ocvu_imgproc_shape.cpp native/CMakeLists.txt \
        bindings/spec/imgproc.json native/include/ocvu/imgproc.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Imgproc.g.cs \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(imgproc): 線分検出と角点の副画素精緻化の 2 本を出す"
```

---

## Task 5: `ocvu_find_contours`

**Files:**
- Modify: `native/tests/test_imgproc_shape.cpp`、`native/src/ocvu_imgproc_shape.cpp`、`bindings/spec/imgproc.json`

**Interfaces:**
- Produces: `ocvu_status ocvu_find_contours(ocvu_mat_handle src, int32_t mode, int32_t method, float* out_points, int32_t points_capacity, int32_t* out_counts, int32_t counts_capacity, int32_t* out_contour_count, int32_t* out_total_points)`

**設計の決定**: **輪郭は「入れ子の可変長」なので、平らな 2 本の配列で表す。**
`out_points` に全輪郭の点を順に並べ、`out_counts` に輪郭ごとの点数を並べる。
呼ぶ側は `out_counts` を前から足していけば各輪郭の範囲が決まる。
**階層（hierarchy）は出さない** —— 親子関係を表す 4 本目の配列が要り、
このマイルストーンの範囲を超える。

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_imgproc_shape.cpp` の末尾に足す。

```cpp
namespace {

// 32x32 の黒い画像の中央に、10x10 の白い正方形を 1 つ置く。
ocvu_mat_handle MakeSingleSquare() {
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(32, 32, OCVU_MAT_TYPE_8UC1, &handle), OCVU_STATUS_OK);
    std::vector<uint8_t> pixels(32 * 32, 0);
    for (int r = 11; r < 21; ++r) {
        for (int c = 11; c < 21; ++c) {
            pixels[static_cast<size_t>(r) * 32 + c] = 255;
        }
    }
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(),
                                        static_cast<int64_t>(pixels.size()), 32),
              OCVU_STATUS_OK);
    return handle;
}

}  // namespace

TEST(ImgprocShape, FindContoursFindsTheSquare) {
    const ocvu_mat_handle src = MakeSingleSquare();

    std::array<float, 256> points{};
    std::array<int32_t, 16> counts{};
    int32_t contour_count = -1;
    int32_t total_points = -1;

    ASSERT_EQ(ocvu_find_contours(src, OCVU_RETR_EXTERNAL, OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), 256, counts.data(), 16,
                                 &contour_count, &total_points),
              OCVU_STATUS_OK);

    // 白い塊が 1 つなので輪郭も 1 本である。
    EXPECT_EQ(contour_count, 1);
    // CHAIN_APPROX_SIMPLE は正方形を 4 隅に間引く。
    EXPECT_EQ(counts[0], 4);
    EXPECT_EQ(total_points, 4);

    // 4 隅は 11..20 の範囲に収まる。
    for (int i = 0; i < 8; ++i) {
        EXPECT_GE(points[i], 11.0f);
        EXPECT_LE(points[i], 20.0f);
    }

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
}

TEST(ImgprocShape, FindContoursReturnsZeroOnABlankImage) {
    ocvu_mat_handle blank = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(32, 32, OCVU_MAT_TYPE_8UC1, &blank), OCVU_STATUS_OK);

    std::array<float, 256> points{};
    std::array<int32_t, 16> counts{};
    int32_t contour_count = -1;
    int32_t total_points = -1;

    EXPECT_EQ(ocvu_find_contours(blank, OCVU_RETR_EXTERNAL, OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), 256, counts.data(), 16,
                                 &contour_count, &total_points),
              OCVU_STATUS_OK);
    EXPECT_EQ(contour_count, 0);
    EXPECT_EQ(total_points, 0);

    EXPECT_EQ(ocvu_mat_release(blank), OCVU_STATUS_OK);
}

TEST(ImgprocShape, FindContoursReportsWhatItNeedsWhenTheBuffersAreTooSmall) {
    const ocvu_mat_handle src = MakeSingleSquare();

    std::array<float, 256> points{};
    std::array<int32_t, 16> counts{};
    points.fill(-7.0f);
    counts.fill(-7);
    int32_t contour_count = -1;
    int32_t total_points = -1;

    // 点の容量が足りない（4 点 = 8 要素が要る）。
    EXPECT_EQ(ocvu_find_contours(src, OCVU_RETR_EXTERNAL, OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), 7, counts.data(), 16,
                                 &contour_count, &total_points),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(contour_count, 1) << "溢れたときは必要な輪郭の本数を返すこと";
    EXPECT_EQ(total_points, 4) << "溢れたときは必要な点の総数を返すこと";

    // 輪郭数の容量が足りない。
    contour_count = -1;
    total_points = -1;
    EXPECT_EQ(ocvu_find_contours(src, OCVU_RETR_EXTERNAL, OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), 256, counts.data(), 0,
                                 &contour_count, &total_points),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(contour_count, 1);
    EXPECT_EQ(total_points, 4);

    for (float v : points) EXPECT_FLOAT_EQ(v, -7.0f) << "断ったのに points を書いている";
    for (int32_t v : counts) EXPECT_EQ(v, -7) << "断ったのに counts を書いている";

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
}

TEST(ImgprocShape, FindContoursRejectsBadArgumentsAndZeroesBothCounts) {
    const ocvu_mat_handle src = MakeSingleSquare();
    std::array<float, 256> points{};
    std::array<int32_t, 16> counts{};

    EXPECT_EQ(ocvu_find_contours(src, OCVU_RETR_EXTERNAL, OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), 256, counts.data(), 16, nullptr, nullptr),
              OCVU_STATUS_NULL_POINTER);

    // **0 ではない値で汚してから呼ぶ。**
    int32_t contour_count = 12345;
    int32_t total_points = 12345;

    EXPECT_EQ(ocvu_find_contours(src, 99, OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), 256, counts.data(), 16,
                                 &contour_count, &total_points),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(contour_count, 0) << "失敗時は 0 を書くこと";
    EXPECT_EQ(total_points, 0) << "失敗時は 0 を書くこと";

    contour_count = 12345;
    total_points = 12345;
    EXPECT_EQ(ocvu_find_contours(src, OCVU_RETR_EXTERNAL, 99,
                                 points.data(), 256, counts.data(), 16,
                                 &contour_count, &total_points),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(contour_count, 0);
    EXPECT_EQ(total_points, 0);

    contour_count = 12345;
    total_points = 12345;
    EXPECT_EQ(ocvu_find_contours(OCVU_MAT_HANDLE_NONE, OCVU_RETR_EXTERNAL,
                                 OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), 256, counts.data(), 16,
                                 &contour_count, &total_points),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(contour_count, 0);
    EXPECT_EQ(total_points, 0);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
}
```

- [ ] **Step 2: RED を目で確認する**

```
pwsh tools/dev.ps1 test-native
```

- [ ] **Step 3: spec に 1 エントリ足して生成する**

```json
{
  "name": "ocvu_find_contours",
  "summary": "src から輪郭を検出し、全輪郭の点を out_points へ、輪郭ごとの点数を out_counts へ書く。**入れ子の可変長を、平らな 2 本の配列で表している** —— 呼ぶ側は out_counts を前から足していけば、out_points の中の各輪郭の範囲が決まる。src は 8 bit 1 channel の 2 値画像でなければならない。mode は OCVU_RETR_* のいずれか（OCVU_RETR_FLOODFILL は出していない）、method は OCVU_CHAIN_APPROX_NONE か OCVU_CHAIN_APPROX_SIMPLE で、それ以外は OCVU_STATUS_INVALID_ARGUMENT を返す。points_capacity と counts_capacity はどちらも**配列の要素数**である（バイト数でも点数でもない）—— 点は 1 個につき 2 要素（x と y）要る。どちらかが足りないときは**どちらの配列にも 1 バイトも書かずに** OCVU_STATUS_BUFFER_TOO_SMALL を返し、out_contour_count に必要な輪郭の本数を、out_total_points に必要な点の総数を入れる（呼ぶ側はそれで確保し直して呼び直せる）。**1 本も見つからないのは誤りではない** —— OCVU_STATUS_OK を返して両方に 0 を入れる。out_contour_count か out_total_points が NULL なら他の何より先に OCVU_STATUS_NULL_POINTER を返し、通ったあとはどの失敗経路でも両方に 0 を書く。**階層（どの輪郭がどの輪郭の内側にあるか）は返さない。** handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返す。buffer の所有権は最初から最後まで呼ぶ側にある。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "mode", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "method", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "out_points", "cType": "float*", "csType": "float[]", "direction": "out-buffer" },
    { "name": "points_capacity", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "out_counts", "cType": "int32_t*", "csType": "int[]", "direction": "out-buffer" },
    { "name": "counts_capacity", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "out_contour_count", "cType": "int32_t*", "csType": "out int", "direction": "out" },
    { "name": "out_total_points", "cType": "int32_t*", "csType": "out int", "direction": "out" }
  ]
}
```

```
pwsh tools/dev.ps1 generate
```

- [ ] **Step 4: 実装する**

`native/src/ocvu_imgproc_shape.cpp` の先頭付近に static_assert と述語を足す。

```cpp
static_assert(OCVU_RETR_EXTERNAL == cv::RETR_EXTERNAL, "RETR_EXTERNAL がずれている");
static_assert(OCVU_RETR_LIST == cv::RETR_LIST, "RETR_LIST がずれている");
static_assert(OCVU_RETR_CCOMP == cv::RETR_CCOMP, "RETR_CCOMP がずれている");
static_assert(OCVU_RETR_TREE == cv::RETR_TREE, "RETR_TREE がずれている");
static_assert(OCVU_CHAIN_APPROX_NONE == cv::CHAIN_APPROX_NONE, "CHAIN_APPROX_NONE がずれている");
static_assert(OCVU_CHAIN_APPROX_SIMPLE == cv::CHAIN_APPROX_SIMPLE, "CHAIN_APPROX_SIMPLE がずれている");

namespace ocvu_imgproc_shape_detail {

bool IsKnownRetrievalMode(int32_t mode) {
    // **RETR_FLOODFILL は含めない。** 32 bit 1 channel の入力を要求するので、
    // この ABI が扱う 8 bit の 2 値画像では使えない。
    return mode >= OCVU_RETR_EXTERNAL && mode <= OCVU_RETR_TREE;
}

bool IsKnownApproximationMethod(int32_t method) {
    return method == OCVU_CHAIN_APPROX_NONE || method == OCVU_CHAIN_APPROX_SIMPLE;
}

}  // namespace ocvu_imgproc_shape_detail
```

ファイル末尾に実装を足す。

```cpp
extern "C" ocvu_status ocvu_find_contours(ocvu_mat_handle src, int32_t mode, int32_t method, float* out_points, int32_t points_capacity, int32_t* out_counts, int32_t counts_capacity, int32_t* out_contour_count, int32_t* out_total_points) {
    OCVU_TRY_BEGIN
    using namespace ocvu_imgproc_shape_detail;

    // **2 つの out を最初に見る。** どちらも溢れたときの必要量を伝える器である。
    if (out_contour_count == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_find_contours: out_contour_count is NULL");
    }
    if (out_total_points == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_find_contours: out_total_points is NULL");
    }
    *out_contour_count = 0;
    *out_total_points = 0;

    if (!IsKnownRetrievalMode(mode)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_find_contours: mode is not one of OCVU_RETR_*");
    }
    if (!IsKnownApproximationMethod(method)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_find_contours: method is not one of OCVU_CHAIN_APPROX_*");
    }
    if (out_points == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_find_contours: out_points is NULL");
    }
    if (out_counts == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_find_contours: out_counts is NULL");
    }
    if (points_capacity < 0 || counts_capacity < 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_find_contours: capacities must not be negative");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_find_contours: src handle is invalid");
    }

    std::vector<std::vector<cv::Point>> contours;
    try {
        cv::findContours(*src_mat, contours, mode, method);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    // **積も和も int64_t で作る。** 輪郭の数も点の数も OpenCV 由来なので
    // 上限を仮定しない。
    const int64_t contour_count = static_cast<int64_t>(contours.size());
    int64_t total_points = 0;
    for (const std::vector<cv::Point>& contour : contours) {
        total_points += static_cast<int64_t>(contour.size());
    }

    // int32_t に入らない大きさは ABI で表現できないので、切り詰めずに断る。
    if (contour_count > INT32_MAX || total_points > INT32_MAX / 2) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_find_contours: the result is too large to describe through this ABI");
    }

    if (contour_count > static_cast<int64_t>(counts_capacity) ||
        total_points * 2 > static_cast<int64_t>(points_capacity)) {
        *out_contour_count = static_cast<int32_t>(contour_count);
        *out_total_points = static_cast<int32_t>(total_points);
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_find_contours: points_capacity or counts_capacity is too small");
    }

    int64_t written = 0;
    for (int64_t i = 0; i < contour_count; ++i) {
        const std::vector<cv::Point>& contour = contours[static_cast<size_t>(i)];
        out_counts[i] = static_cast<int32_t>(contour.size());
        for (const cv::Point& p : contour) {
            out_points[written * 2] = static_cast<float>(p.x);
            out_points[written * 2 + 1] = static_cast<float>(p.y);
            ++written;
        }
    }

    *out_contour_count = static_cast<int32_t>(contour_count);
    *out_total_points = static_cast<int32_t>(total_points);
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

**`INT32_MAX` を使うので `#include <cstdint>` の隣に `#include <climits>` は要らない**
（`<cstdint>` が `INT32_MAX` を出す）。

- [ ] **Step 5: L1 を緑にする**

```
pwsh tools/dev.ps1 test-native
```

期待: `ImgprocShape.*` が 10 件 pass、exit 0。

- [ ] **Step 6: 検査が働くことを確かめる**

1. `ocvu_find_contours` の溢れ判定 `total_points * 2 > ...` を `false` に書き換える
2. `pwsh tools/dev.ps1 test-native` → **`FindContoursReportsWhatItNeedsWhenTheBuffersAreTooSmall`
   が落ちること**を目で見る（**buffer を踏み越えるので ASan なら即死する** ——
   それも検査が働いた証拠である）
3. 戻して緑に戻ることを確認する

- [ ] **Step 7: ASan を回す**

```
pwsh tools/dev.ps1 test-asan
```

期待: exit 0。**この Phase は buffer を大量に触るので必ず回す。**

- [ ] **Step 8: コミット**

```bash
git add native/tests/test_imgproc_shape.cpp native/src/ocvu_imgproc_shape.cpp \
        bindings/spec/imgproc.json native/include/ocvu/imgproc.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Imgproc.g.cs \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(imgproc): 輪郭を検出する ocvu_find_contours を出す"
```

---

## Task 6: C# の公開 API と L3

**Files:**
- Modify: `Packages/.../Runtime/Core/CvOps.cs`
- Create: `tests/Managed/CvUnity.Tests.Managed/ImgprocOpsTests.cs`

**Interfaces:**
- Produces（すべて `CvOps` の静的メソッド。`ocvu_get_perspective_transform` は
  `geometry` の関数だが、**用途が imgproc の変形と一体なので `CvOps` に置く** ——
  `CvGeometry` に置くと呼ぶ側が 2 つのクラスを行き来する）:
  - `CvOps.Threshold(CvMat src, CvMat dst, double threshold, double maxValue, CvThresholdType type)` → `double`
  - `CvOps.Canny(CvMat src, CvMat dst, double threshold1, double threshold2, int apertureSize, bool l2Gradient)`
  - `CvOps.MorphologyEx(CvMat src, CvMat dst, CvMorphOp op, CvMorphShape shape, int kernelWidth, int kernelHeight, int iterations)`
  - `CvOps.MatchTemplate(CvMat image, CvMat templ, CvMat dst, CvTemplateMatchMethod method)`
  - `CvOps.GetPerspectiveTransform(CvPoint2[] src, CvPoint2[] dst, CvMat transform)`
  - `CvOps.WarpPerspective(CvMat src, CvMat dst, CvMat transform, int width, int height, CvInterpolation interpolation, CvBorderMode borderMode)`
  - `CvOps.HoughLinesP(CvMat src, double rho, double theta, int threshold, double minLineLength, double maxLineGap, int maxLines)` → `CvLine[]`
  - `CvOps.CornerSubPix(CvMat src, CvPoint2[] points, int winSize, int zeroZone, int maxIterations, double epsilon)` → `CvPoint2[]`
  - `CvOps.FindContours(CvMat src, CvRetrievalMode mode, CvChainApproxMethod method)` → `CvPoint2[][]`

- [ ] **Step 1: `CvOps` に enum と 9 本を足す**

**enum は 6 つ足す**（`CvThresholdType` / `CvMorphOp` / `CvMorphShape` /
`CvTemplateMatchMethod` / `CvRetrievalMode` / `CvChainApproxMethod` /
`CvBorderMode`）。**値は C の `#define` の写し**なので、
`CvHomographyMethod` と同じ形の `<remarks>` を書き、
L3 が両側を native に問うことで同期を守る。

**`CvThresholdType` は `[Flags]` にする** —— `Otsu` を or して渡すためである。

**`CvLine` を新設する**（`Runtime/Core/CvOps.cs` の中に置く。`CvPoint2` と同じ場所）。

```csharp
    /// <summary>
    /// 検出された線分 1 本。両端の点を持つ読み取り専用の値。
    /// </summary>
    public readonly struct CvLine
    {
        /// <summary>一方の端点。</summary>
        public CvPoint2 Start { get; }

        /// <summary>もう一方の端点。</summary>
        public CvPoint2 End { get; }

        /// <summary>2 つの端点から線分を作る。</summary>
        public CvLine(CvPoint2 start, CvPoint2 end)
        {
            Start = start;
            End = end;
        }
    }
```

**`FindContours` は溢れる経路を隠す** —— 1 回目で必要量を受け取り、
足りなければその量で確保して 1 度だけ呼び直す。**`CvAruco.DetectMarkers` と
同じ形にする**（Phase 1 で確立済み）。

```csharp
        /// <summary>
        /// 2 値画像から輪郭を検出する。
        /// </summary>
        /// <returns>輪郭ごとの点列。1 本も無ければ空の配列（**これは誤りではない**）。</returns>
        public static CvPoint2[][] FindContours(
            CvMat src, CvRetrievalMode mode, CvChainApproxMethod method)
        {
            if (src == null) throw new ArgumentNullException(nameof(src));

            // 1 回目は小さめの buffer で試す。**溢れたら native が必要量を返す。**
            var result = TryFindContours(src, mode, method, 64, 1024,
                                         out int contourCount, out int totalPoints);
            if (result != null) return result;

            result = TryFindContours(src, mode, method, contourCount, totalPoints * 2,
                                     out _, out _);
            if (result == null)
                throw new CvNativeException(
                    CvStatus.BufferTooSmall,
                    "輪郭の検出が 2 度続けて溢れました。検出結果が呼び出しの間に変わっています。");
            return result;
        }

        private static CvPoint2[][] TryFindContours(
            CvMat src, CvRetrievalMode mode, CvChainApproxMethod method,
            int countsCapacity, int pointsCapacity,
            out int contourCount, out int totalPoints)
        {
            var counts = new int[Math.Max(countsCapacity, 1)];
            var points = new float[Math.Max(pointsCapacity, 1)];

            var status = (CvStatus)NativeMethods.ocvu_find_contours(
                src.Handle, (int)mode, (int)method,
                points, pointsCapacity, counts, countsCapacity,
                out contourCount, out totalPoints);

            if (status == CvStatus.BufferTooSmall) return null;
            CvNative.ThrowIfFailed(status);

            var contours = new CvPoint2[contourCount][];
            int read = 0;
            for (int i = 0; i < contourCount; i++)
            {
                var contour = new CvPoint2[counts[i]];
                for (int p = 0; p < contour.Length; p++)
                {
                    contour[p] = new CvPoint2(points[read * 2], points[read * 2 + 1]);
                    read++;
                }
                contours[i] = contour;
            }
            return contours;
        }
```

**残り 8 本も同じ作法で書く** —— 引数を検証して native を呼び、
`CvNative.ThrowIfFailed` に status を渡す。`HoughLinesP` は
`maxLines` を受け取って `CvLine[]` を返し、溢れたら native が返した本数で
1 度だけ確保し直す。`CornerSubPix` は**入力の配列を書き換えず、
写しを渡して結果を新しい配列で返す**（C# 側では in-place を見せない ——
呼ぶ側が渡した配列が黙って変わるのは驚きが大きい）。

- [ ] **Step 2: L3 テストを書いて走らせる**

`tests/Managed/CvUnity.Tests.Managed/ImgprocOpsTests.cs` に、L1 と同じ検証を
C# から行うテストを書く。**最低限これを含める**:

- `ThresholdReturnsTheValueOtsuChose` — 10 と 200 の 2 山画像で、返り値が
  10 より大きく 200 より小さいこと
- `CannyFindsAnEdge` — 段差のある画像で 255 の画素が 1 つ以上あること
- `DilateGrowsTheDot` — 1 画素の点が 3x3 で 9 画素になること
- `PerspectiveTransformAndWarpRoundTrip` — 4 隅の対応から変換を求め、
  8x8 に引き伸ばし、左が暗く右が明るいこと
- `HoughFindsTheHorizontalLine` — 1 本の横線が 1 本以上の `CvLine` になること
- `FindContoursFindsTheSquare` — 白い正方形が 1 本の輪郭・4 点になること
- `FindContoursGrowsTheBufferWhenTheFirstCallOverflows` — **溢れる経路を通す**。
  多数の小さな塊（16x16 の格子状に 1 画素ずつ）を置いて 64 本を超えさせ、
  正しい本数が返ること
- `TheManagedEnumValuesMatchWhatNativeAccepts` — 6 つの enum それぞれについて、
  **定義されている値は native に拒否されず、定義に無い値（99）は
  `CvStatus.InvalidArgument` で拒否される**こと

```
pwsh tools/dev.ps1 test-managed
```

- [ ] **Step 3: 全レーンを回す**

```
pwsh tools/dev.ps1 test
pwsh tools/dev.ps1 test-asan
```

両方 exit 0。

- [ ] **Step 4: コミット**

```bash
git add Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvOps.cs \
        tests/Managed/CvUnity.Tests.Managed/ImgprocOpsTests.cs
git commit -m "feat(csharp): imgproc の 9 本の公開 API を CvOps に足す"
```

---

## Task 7: 文書とレビュー

- [ ] **Step 1: allowlist に §3.11 を足す**

`docs/abi-ownership-and-versioning.md` に **§3.11 imgproc の実用関数**を足す。
**`ocvu_get_perspective_transform` が `geometry` module であることを明記する**
（`cv::getPerspectiveTransform` が OpenCV 5 で `geometry` へ移ったため）。

**§3 の冒頭が数えている本数を直す。**

- [ ] **Step 2: API リファレンスに足し、「まだ無い」から消す**

`docs/api-reference.md` の §1 と §2 に足し、**§3「この allowlist に含まれないもの」から
`cornerSubPix` を消す**（`.github/release-notes.md` の「出していないもの」にも
載っているので、次の版のノートを書くときに一緒に直す）。

- [ ] **Step 3: `CLAUDE.md` を直す**

- 「公開 ABI の内訳」の段落
- 「ファイル配置」の表の `native/src/` の行に `ocvu_imgproc_ops.cpp` と
  `ocvu_imgproc_shape.cpp`
- `docs/api-reference.md` の行の C# クラス一覧（`CvLine` が増えた）

- [ ] **Step 4: 大きさを測る**

```
pwsh tools/dev.ps1 build
ls -l Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/x86_64/opencv_unity_native.dll
```

前回からの差を記録する。**`imgproc` は既に大量にリンクされているので、
Phase 1 より増分は小さいはずである** —— そうでなければ理由を調べる。

- [ ] **Step 5: AI レビュー**

**この差分を書いていない別のエージェント**に、ブランチ全体の差分と
この計画と[全体設計](./2026-09-05-api-surface-expansion.md)を渡してレビューさせる。
指摘を直したら、スコープを絞った再レビュー。

- [ ] **Step 6: コミットして push、PR を作る**

PR 本文に書くもの:
- 何を成立させたか（9 本、OpenCV の再ビルドなし）
- **`getPerspectiveTransform` が `imgproc` ではなく `geometry` に在ったこと**（実測）
- 実測値（L1 / L3 の件数、ライブラリの大きさの差）
- **意図的に見送ったもの**（`connectedComponents`、`remap`、`equalizeHist`、
  `calcHist`、輪郭の階層、`adaptiveThreshold`、描画関数）
- ステップ 5 のレビュー結果

**merge しない。** CI が緑になったら報告して指示を待つ。

---

## Self-Review

**1. spec coverage** — [全体設計](./2026-09-05-api-surface-expansion.md) §4 の Phase 2 に挙げた 9 本が Task 1〜5 に在る。§5 の決定は Global Constraints に写した。§9 の完了条件は Task 7 が満たす。

**2. placeholder scan** — Task 6 Step 1 の「残り 8 本も同じ作法で書く」と Step 2 のテスト一覧は、**関数名・引数・検証内容を名指ししてある**ので「Task N と同様」ではない。ただし**この 2 箇所だけはコードブロックを省いている** —— C# の薄いラッパは native の契約が決まれば機械的で、9 本ぶんを写すと計画が読めなくなるためである。**実装者はここで判断を求められる** ので、その旨を明記した。

**3. type consistency** — `ocvu_imgproc_ops_detail` は Task 1 で定義し Task 2 / 3 で使う（Interfaces に明記）。`ocvu_imgproc_shape_detail` は Task 5 で定義する。`MakeSplitImage` / `ReadPixels` は Task 1、`MakeSingleDot` は Task 2、`MakeHorizontalLine` / `MakeCheckerCorner` は Task 4、`MakeSingleSquare` は Task 5 で定義する。`OCVU_INTER_*` は既存（`native/include/opencv_unity_native.h` に在ることを実測で確認済み）。
