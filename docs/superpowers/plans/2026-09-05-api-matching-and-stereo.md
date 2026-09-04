# Phase 4 — 特徴点マッチングとステレオ 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 特徴点の記述子を計算して対応づけられるようにし、左右の画像から視差を求められるようにする。

**Architecture:** `features` module に 2 本（`ocvu_detect_and_compute` / `ocvu_match_descriptors`）、**新設する `stereo` module に 1 本**（`ocvu_compute_disparity`）。**`stereo` は `calib` が推移的に引くので既にビルド済みだが、リンクはされていない** —— `cmake/FindOpenCvUnityDeps.cmake` の `COMPONENTS` に 1 語足す。**`tools/opencv-config.psd1` の `Modules` は触らないので、構成ハッシュは変わらず OpenCV の再ビルドは起きない。**

**Tech Stack:** C++17 / OpenCV 5.0.0（`features` / `stereo`）/ C# netstandard2.1 / GoogleTest（L1）/ xUnit（L3）

**Spec:** [API 拡張（A〜F）— 全体設計と分割](./2026-09-05-api-surface-expansion.md)

## Global Constraints

- **`tools/opencv-config.psd1` の `Modules` を 1 文字も変えない**（構成ハッシュが変わり 6 platform 分の再ビルドになる）
- **`cmake/FindOpenCvUnityDeps.cmake` の `COMPONENTS` には `stereo` を 1 語だけ足す** —— **足す前にリンクが落ちることを見る**（Task 4）
- **新しい status code を足さない**
- **新しい struct は `ocvu_dmatch` 1 つだけ。** layout の正本は native のヘッダに置き、C# 側は手で写して L3 が `Marshal.SizeOf` **と** `Marshal.OffsetOf` の全フィールドで突き合わせる（**合計だけを固定した検査は中身の入れ替えを通す** —— M5 で実測）
- **宣言を手で書かない。** spec に 1 エントリ足して `./tools/dev.ps1 generate`
- **`bool` を境界に出さない。** `int32_t` の 0 / 非 0 で受ける（`cross_check` がこれ）
- **`*_length` はバイト数、`*_capacity` は要素数。** 両方 `summary` に明記する
- **積は `static_cast<int64_t>` を先に当ててから作る**
- **可変長出力は「容量 + `BUFFER_TOO_SMALL` + `out_count`」の 1 形だけを使う**
- **`out_count` は NULL 判定の直後に 0 を書き、以降のすべての早期 return がその後ろに来る**
- **公開 ABI 関数は `OCVU_TRY_BEGIN` / `OCVU_TRY_END` で囲む。** `cv::Exception` はその手前で個別に受ける
- **`extern "C" ocvu_status ocvu_名前(` までを 1 物理行に置く**
- **`Runtime/Core` は `UnityEngine` を参照しない**
- **`OCVU_ABI_VERSION` は 1 のまま**（新しい struct の追加も、既存の layout を変えないので bump しない）
- **`git add -A` / `git add .` は hook が拒否する**

## この Phase 固有の決定

### 記述子は `ocvu_mat_handle` で扱う

`ocvu_detect_and_compute` が返す記述子は、ORB なら 32 バイト × 特徴点数、
SIFT なら 128 float × 特徴点数である。**これを平らな配列で境界に出すと、
呼ぶ側が型と行の長さを自分で組み立てることになる。**

**代わりに `cv::Mat` のまま handle に入れる。** 呼ぶ側は
`ocvu_match_descriptors` にその handle をそのまま渡せばよく、
中身を C# へ写す必要が無い。**「毎フレームの細かな境界呼び出しを避ける」という
不変条件にも合っている。**

### 検出器は `int32_t` で選ぶ

ORB と SIFT の 2 つを出す。**`cv::Feature2D` の handle を境界に出さない** ——
新しい種類の handle を足すと、`docs/abi-ownership-and-versioning.md` §1 が
持つ所有権の形が 1 つ増える（`ocvu_imencode` で「blob の handle を作らない」と
決めたのと同じ判断である）。

**帰結: 検出器は毎回作り直される。** 連続して呼ぶと ORB の生成コストが
毎回かかる。**それでよい** —— この ABI の粒度は「1 枚を処理する」であって
「検出器を保持する」ではない。**そのことを `summary` に書く。**

### `ocvu_orb_detect` は残す

既に在る `ocvu_orb_detect`（記述子を計算しない）は**そのまま残す。**
記述子が要らない用途（角点だけ欲しい）で `ocvu_detect_and_compute` を呼ぶと、
使わない記述子の計算とその Mat の確保が無駄になる。

**`docs/api-map.md` に 2 本並ぶことになるので、両方の `summary` に
「どちらを使うか」を書く。**

### `stereo` module の spec を新設する

`bindings/spec/stereo.json` を作る。**そのとき 3 つが同時に動く**:

1. **`native/include/opencv_unity_native.h` に `#include "ocvu/stereo.h"` を手で 1 行足す**
   （**この 1 行だけは生成物ではない**）
2. **`tools/tests/OpenCvConfig.Tests.ps1` の `$specModulesNotBuiltDirectly` に
   `'stereo'` を足す** —— いまは `@('infra', 'geometry')` で、
   **spec に `stereo` module が現れた瞬間にこの検査が落ちる**
   （`tools/opencv-config.psd1` の `Modules` に無いため）
3. **`cmake/FindOpenCvUnityDeps.cmake` の `COMPONENTS` に `stereo` を足す**

**2 を忘れると `dev.ps1 test` が落ちる。** これは検査が意図どおり働いた形である。

## ファイル構成

**新規**

| ファイル | 責務 |
| --- | --- |
| `bindings/spec/stereo.json` | `stereo` module の spec（新設） |
| `native/src/ocvu_matching.cpp` | `features` の 2 本 |
| `native/src/ocvu_stereo.cpp` | `stereo` の 1 本 |
| `native/tests/test_matching.cpp` | `features` の 2 本の L1 |
| `native/tests/test_stereo.cpp` | `stereo` の 1 本の L1 |
| `Packages/.../Runtime/Core/CvStereo.cs`（+ `.meta`） | C# の公開入口 |
| `tests/Managed/CvUnity.Tests.Managed/MatchingTests.cs` | L3 |
| `tests/Managed/CvUnity.Tests.Managed/StereoTests.cs` | L3 |

**変更**

| ファイル | 何を |
| --- | --- |
| `native/include/opencv_unity_native.h` | `ocvu_dmatch` / `OCVU_FEATURE_*`(2) / `OCVU_STEREO_*`(2) / `OCVU_MATCH_MAX_COUNT` / `#include "ocvu/stereo.h"` |
| `bindings/spec/features.json` | 2 エントリ |
| `cmake/FindOpenCvUnityDeps.cmake` | `COMPONENTS` に `stereo` |
| `native/tests/test_module_linkage.cpp` | `StereoIsLinked` |
| `tools/tests/OpenCvConfig.Tests.ps1` | `$specModulesNotBuiltDirectly` に `'stereo'` |
| `Packages/.../Runtime/Interop/NativeMethods.cs` | `OcvuDMatch` struct（**spec が表現しない型**） |
| `Packages/.../Runtime/Core/CvFeatures.cs` | 2 本 |
| `README.md` / `README.ja.md` | リンクしている module の一覧（**両方直す。片方だけだと食い違う**） |
| `docs/abi-ownership-and-versioning.md` / `docs/api-reference.md` / `CLAUDE.md` | 文書 |

---

## Task 1: `ocvu_detect_and_compute`

**Files:**
- Create: `native/tests/test_matching.cpp`、`native/src/ocvu_matching.cpp`
- Modify: `native/include/opencv_unity_native.h`、`bindings/spec/features.json`、`native/CMakeLists.txt`、`native/tests/CMakeLists.txt`

**Interfaces:**
- Produces: `ocvu_status ocvu_detect_and_compute(ocvu_mat_handle src, int32_t detector, int32_t max_features, ocvu_keypoint* out_keypoints, int32_t capacity, ocvu_mat_handle out_descriptors, int32_t* out_count)`

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_matching.cpp` を新規作成する。

```cpp
// features module の記述子まわり 2 本の契約テスト。
//
// **入力は自分で描いた模様にする。** 外部の画像に依存しない。

#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <array>
#include <vector>

namespace {

// 64x64 のグレー画像に、乱数ではない決まった模様（市松＋点）を描く。
// **同じ入力なら同じ特徴点が出る**ので、テストが揺れない。
ocvu_mat_handle MakeTexturedImage(int32_t offset_x) {
    constexpr int32_t kSide = 64;
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(kSide, kSide, OCVU_MAT_TYPE_8UC1, &handle), OCVU_STATUS_OK);

    std::vector<uint8_t> pixels(static_cast<size_t>(kSide) * kSide, 40);
    // 8 画素ごとの市松。offset_x だけ横にずらす。
    for (int32_t r = 0; r < kSide; ++r) {
        for (int32_t c = 0; c < kSide; ++c) {
            const int32_t sc = c + offset_x;
            if (sc < 0 || sc >= kSide) continue;
            const bool light = ((r / 8) + (sc / 8)) % 2 == 0;
            pixels[static_cast<size_t>(r) * kSide + c] = light ? 220 : 40;
        }
    }
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(),
                                        static_cast<int64_t>(pixels.size()), kSide),
              OCVU_STATUS_OK);
    return handle;
}

}  // namespace

TEST(Matching, DetectAndComputeProducesKeypointsAndDescriptors) {
    const ocvu_mat_handle src = MakeTexturedImage(0);
    ocvu_mat_handle descriptors = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &descriptors), OCVU_STATUS_OK);

    std::array<ocvu_keypoint, 200> keypoints{};
    int32_t count = -1;

    ASSERT_EQ(ocvu_detect_and_compute(src, OCVU_FEATURE_ORB, 200,
                                      keypoints.data(), 200, descriptors, &count),
              OCVU_STATUS_OK);
    ASSERT_GT(count, 0) << "市松模様なのに特徴点が 1 つも出ない";

    // **記述子の行数は特徴点の数と一致する。** ORB の記述子は 32 バイトである。
    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(descriptors, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, count);
    EXPECT_EQ(info.cols, 32);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(descriptors), OCVU_STATUS_OK);
}

TEST(Matching, DetectAndComputeSupportsSift) {
    const ocvu_mat_handle src = MakeTexturedImage(0);
    ocvu_mat_handle descriptors = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &descriptors), OCVU_STATUS_OK);

    std::array<ocvu_keypoint, 200> keypoints{};
    int32_t count = -1;

    ASSERT_EQ(ocvu_detect_and_compute(src, OCVU_FEATURE_SIFT, 200,
                                      keypoints.data(), 200, descriptors, &count),
              OCVU_STATUS_OK);
    ASSERT_GT(count, 0);

    // SIFT の記述子は 128 次元の float である。**ORB とは型も幅も違う。**
    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(descriptors, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, count);
    EXPECT_EQ(info.cols, 128);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(descriptors), OCVU_STATUS_OK);
}

TEST(Matching, DetectAndComputeReportsTheCountWhenTheBufferIsTooSmall) {
    const ocvu_mat_handle src = MakeTexturedImage(0);
    ocvu_mat_handle descriptors = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &descriptors), OCVU_STATUS_OK);

    std::array<ocvu_keypoint, 200> keypoints{};
    // **0 ではない値で汚す。**
    for (ocvu_keypoint& kp : keypoints) kp.x = -7.0f;
    int32_t count = -1;

    EXPECT_EQ(ocvu_detect_and_compute(src, OCVU_FEATURE_ORB, 200,
                                      keypoints.data(), 0, descriptors, &count),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_GT(count, 0) << "溢れたときは実際に見つかった数を返すこと";

    for (const ocvu_keypoint& kp : keypoints) {
        EXPECT_FLOAT_EQ(kp.x, -7.0f) << "断ったのに keypoints を書いている";
    }

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(descriptors), OCVU_STATUS_OK);
}

TEST(Matching, DetectAndComputeRejectsBadArgumentsAndZeroesTheCount) {
    const ocvu_mat_handle src = MakeTexturedImage(0);
    ocvu_mat_handle descriptors = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &descriptors), OCVU_STATUS_OK);
    std::array<ocvu_keypoint, 200> keypoints{};

    // **out_count が NULL なら他の何より先に断る。**
    EXPECT_EQ(ocvu_detect_and_compute(src, OCVU_FEATURE_ORB, 200,
                                      keypoints.data(), 200, descriptors, nullptr),
              OCVU_STATUS_NULL_POINTER);

    int32_t count = 12345;
    EXPECT_EQ(ocvu_detect_and_compute(src, 99, 200, keypoints.data(), 200,
                                      descriptors, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0) << "失敗時は out_count に 0 を書くこと";

    count = 12345;
    EXPECT_EQ(ocvu_detect_and_compute(src, OCVU_FEATURE_ORB, 0, keypoints.data(), 200,
                                      descriptors, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_detect_and_compute(src, OCVU_FEATURE_ORB,
                                      OCVU_ORB_MAX_FEATURES + 1, keypoints.data(), 200,
                                      descriptors, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_detect_and_compute(src, OCVU_FEATURE_ORB, 200, nullptr, 200,
                                      descriptors, &count),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_detect_and_compute(OCVU_MAT_HANDLE_NONE, OCVU_FEATURE_ORB, 200,
                                      keypoints.data(), 200, descriptors, &count),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_detect_and_compute(src, OCVU_FEATURE_ORB, 200, keypoints.data(), 200,
                                      OCVU_MAT_HANDLE_NONE, &count),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(count, 0);

    // **src と out_descriptors が同じ handle なのは誤りである** ——
    // 入力を読みながら同じ Mat を置き換えることになる。
    count = 12345;
    EXPECT_EQ(ocvu_detect_and_compute(src, OCVU_FEATURE_ORB, 200, keypoints.data(), 200,
                                      src, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(descriptors), OCVU_STATUS_OK);
}
```

`native/tests/CMakeLists.txt` の一覧に `test_matching.cpp` を足す。

- [ ] **Step 2: RED を目で確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: **コンパイルエラー**（`ocvu_detect_and_compute` も `OCVU_FEATURE_ORB` も無い）。

- [ ] **Step 3: 定数をヘッダに足す**

`native/include/opencv_unity_native.h` の `OCVU_ORB_MAX_FEATURES` の直後に足す。

```c
/* ocvu_detect_and_compute が使う検出器。
 *
 * **これは OpenCV の定数の写しではない。** cv::ORB / cv::SIFT はクラスであって
 * 定数ではないので、対応する値が上流に存在しない。**この 2 つはこちらが決めた値**
 * であり、したがって static_assert で固定することもできない（固定する相手が無い）。
 *
 * ORB は速く、記述子が 32 バイトの 2 値である（ハミング距離で比べる）。
 * SIFT は遅いが回転と拡大縮小に強く、記述子が 128 次元の float である
 * （L2 距離で比べる）。**距離の選び方が変わる**ので、
 * ocvu_match_descriptors の norm_type を検出器に合わせること。 */
#define OCVU_FEATURE_ORB  0
#define OCVU_FEATURE_SIFT 1
```

- [ ] **Step 4: spec に 1 エントリ足して生成する**

`bindings/spec/features.json` に足す。

```json
{
  "name": "ocvu_detect_and_compute",
  "summary": "src から特徴点を検出し、同時にその記述子を計算する。特徴点は out_keypoints へ書き、記述子は out_descriptors の Mat へ入れる（Mat は結果に応じて丸ごと置き換わり、行が特徴点 1 つ、列が記述子の次元になる —— ORB は 32 列の 8 bit、SIFT は 128 列の 32 bit 浮動小数である）。**記述子を平らな配列で返さないのは、型も幅も検出器によって違うためである** —— handle のまま ocvu_match_descriptors へ渡せる。detector は OCVU_FEATURE_* のいずれかで、それ以外は OCVU_STATUS_INVALID_ARGUMENT を返す。max_features は 1 以上 OCVU_ORB_MAX_FEATURES 以下でなければならない。capacity は out_keypoints の**要素数**である（バイト数ではない）—— 見つかった数に満たなければ**何も書かずに** OCVU_STATUS_BUFFER_TOO_SMALL を返し、out_count に**実際に見つかった数**を入れる。**1 つも見つからないのは誤りではない** —— OCVU_STATUS_OK を返して out_count に 0 を入れる。out_count が NULL なら他の何より先に OCVU_STATUS_NULL_POINTER を返し、通ったあとはどの失敗経路でも out_count に 0 を書く。src と out_descriptors に同じ handle を渡してはならない。**検出器は呼び出しのたびに作り直される** —— この ABI の粒度は 1 枚を処理することであって、検出器を保持することではない。**記述子が要らないなら ocvu_orb_detect を使うこと**（記述子の計算と Mat の確保が省ける）。handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返す。buffer の所有権は最初から最後まで呼ぶ側にある。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "detector", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "max_features", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "out_keypoints", "cType": "ocvu_keypoint*", "csType": "OcvuKeyPoint[]", "direction": "out-buffer" },
    { "name": "capacity", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "out_descriptors", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "out_count", "cType": "int32_t*", "csType": "out int", "direction": "out" }
  ]
}
```

**既存の `ocvu_orb_detect` の `summary` にも 1 文足す**:
「記述子も要るなら ocvu_detect_and_compute を使うこと。」
**spec を書き換えたので `generate` が `NativeMethods.Features.g.cs` と
`docs/api-map.md` を更新する。**

```
pwsh tools/dev.ps1 generate
```

- [ ] **Step 5: 実装する**

`native/src/ocvu_matching.cpp` を新規作成する。

```cpp
// features module のうち「記述子」に関わるもの。
//
// **ocvu_features.cpp に足していない。** あちらは記述子を計算しない
// ocvu_orb_detect 1 本で、こちらは記述子を Mat に入れて対応づける。

#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/features.hpp>

#include <cstdint>
#include <vector>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

namespace ocvu_matching_detail {

bool IsKnownDetector(int32_t detector) {
    return detector == OCVU_FEATURE_ORB || detector == OCVU_FEATURE_SIFT;
}

}  // namespace ocvu_matching_detail

extern "C" ocvu_status ocvu_detect_and_compute(ocvu_mat_handle src, int32_t detector, int32_t max_features, ocvu_keypoint* out_keypoints, int32_t capacity, ocvu_mat_handle out_descriptors, int32_t* out_count) {
    OCVU_TRY_BEGIN
    using namespace ocvu_matching_detail;

    // **out_count を最初に見る。** 無いと呼ぶ側は溢れたときの必要量を決められない。
    if (out_count == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_detect_and_compute: out_count is NULL");
    }
    *out_count = 0;

    if (!IsKnownDetector(detector)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_detect_and_compute: detector is not one of OCVU_FEATURE_*");
    }
    if (max_features < 1 || max_features > OCVU_ORB_MAX_FEATURES) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_detect_and_compute: max_features must be between 1 and OCVU_ORB_MAX_FEATURES");
    }
    if (out_keypoints == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_detect_and_compute: out_keypoints is NULL");
    }
    if (capacity < 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_detect_and_compute: capacity must not be negative");
    }
    // **入力を読みながら同じ Mat を置き換えることになる。** 先に断る。
    if (src == out_descriptors) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_detect_and_compute: src and out_descriptors must be different handles");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_detect_and_compute: src handle is invalid");
    }
    cv::Mat* descriptors_mat = ::ocvu::mat_table_get(out_descriptors);
    if (descriptors_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_detect_and_compute: out_descriptors handle is invalid");
    }

    std::vector<cv::KeyPoint> keypoints;
    cv::Mat descriptors;
    try {
        // **検出器は毎回作り直す。** handle を境界に出さない判断の帰結である
        // （docs/abi-ownership-and-versioning.md §1 の所有権の形を増やさない）。
        cv::Ptr<cv::Feature2D> feature;
        if (detector == OCVU_FEATURE_ORB) {
            feature = cv::ORB::create(max_features);
        } else {
            feature = cv::SIFT::create(max_features);
        }
        feature->detectAndCompute(*src_mat, cv::noArray(), keypoints, descriptors);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    const int64_t found = static_cast<int64_t>(keypoints.size());
    if (found > static_cast<int64_t>(capacity)) {
        *out_count = static_cast<int32_t>(found);
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_detect_and_compute: capacity (elements) is smaller than the number found");
    }

    for (int64_t i = 0; i < found; ++i) {
        const cv::KeyPoint& kp = keypoints[static_cast<size_t>(i)];
        out_keypoints[i].x = kp.pt.x;
        out_keypoints[i].y = kp.pt.y;
        out_keypoints[i].size = kp.size;
        out_keypoints[i].angle = kp.angle;
        out_keypoints[i].response = kp.response;
        out_keypoints[i].octave = kp.octave;
        out_keypoints[i].class_id = kp.class_id;
    }

    *descriptors_mat = descriptors;
    *out_count = static_cast<int32_t>(found);
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

`native/CMakeLists.txt` の `OCVU_SOURCES` に `src/ocvu_matching.cpp` を足す。

- [ ] **Step 6: L1 を緑にする**

```
pwsh tools/dev.ps1 test-native
```

期待: `Matching.DetectAndCompute*` が 4 件 pass、exit 0。

- [ ] **Step 7: コミット**

```bash
git add native/tests/test_matching.cpp native/tests/CMakeLists.txt \
        native/src/ocvu_matching.cpp native/CMakeLists.txt \
        native/include/opencv_unity_native.h bindings/spec/features.json \
        native/include/ocvu/features.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Features.g.cs \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(features): 特徴点と記述子を同時に求める ocvu_detect_and_compute を出す"
```

---

## Task 2: `ocvu_dmatch` と `ocvu_match_descriptors`

**Files:**
- Modify: `native/include/opencv_unity_native.h`（`ocvu_dmatch` と `OCVU_MATCH_MAX_COUNT`）、`native/tests/test_matching.cpp`、`native/src/ocvu_matching.cpp`、`bindings/spec/features.json`、`Packages/.../Runtime/Interop/NativeMethods.cs`

**Interfaces:**
- Consumes: `ocvu_detect_and_compute`（Task 1）、`MakeTexturedImage`（Task 1 のテストヘルパ）
- Produces: `ocvu_status ocvu_match_descriptors(ocvu_mat_handle query, ocvu_mat_handle train, int32_t norm_type, int32_t cross_check, ocvu_dmatch* out_matches, int32_t capacity, int32_t* out_count)`

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_matching.cpp` の末尾に足す。

```cpp
namespace {

// 画像から ORB の記述子を作る。失敗したら handle は無効のまま返る。
ocvu_mat_handle ComputeOrbDescriptors(ocvu_mat_handle src, int32_t* out_count) {
    ocvu_mat_handle descriptors = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &descriptors), OCVU_STATUS_OK);
    std::array<ocvu_keypoint, 500> keypoints{};
    EXPECT_EQ(ocvu_detect_and_compute(src, OCVU_FEATURE_ORB, 500,
                                      keypoints.data(), 500, descriptors, out_count),
              OCVU_STATUS_OK);
    return descriptors;
}

}  // namespace

TEST(Matching, TheDmatchStructHasTheExpectedLayout) {
    // **native 側の正本を固定する。** C# 側は L3 が Marshal.OffsetOf で
    // 全フィールドを突き合わせる（合計だけを見る検査は入れ替えを通す）。
    EXPECT_EQ(sizeof(ocvu_dmatch), 16u);
    EXPECT_EQ(offsetof(ocvu_dmatch, query_index), 0u);
    EXPECT_EQ(offsetof(ocvu_dmatch, train_index), 4u);
    EXPECT_EQ(offsetof(ocvu_dmatch, image_index), 8u);
    EXPECT_EQ(offsetof(ocvu_dmatch, distance), 12u);
}

TEST(Matching, MatchDescriptorsFindsCorrespondences) {
    // **同じ画像どうしなので、対応は必ず見つかる。**
    const ocvu_mat_handle image = MakeTexturedImage(0);
    int32_t count = 0;
    const ocvu_mat_handle a = ComputeOrbDescriptors(image, &count);
    const ocvu_mat_handle b = ComputeOrbDescriptors(image, &count);
    ASSERT_GT(count, 0);

    std::vector<ocvu_dmatch> matches(static_cast<size_t>(count));
    int32_t match_count = -1;

    ASSERT_EQ(ocvu_match_descriptors(a, b, OCVU_NORM_HAMMING, 0,
                                     matches.data(), count, &match_count),
              OCVU_STATUS_OK);
    ASSERT_GT(match_count, 0);

    // 同じ記述子どうしなので、距離 0 の対応が並ぶ。**索引も一致する。**
    for (int32_t i = 0; i < match_count; ++i) {
        EXPECT_FLOAT_EQ(matches[static_cast<size_t>(i)].distance, 0.0f);
        EXPECT_EQ(matches[static_cast<size_t>(i)].query_index,
                  matches[static_cast<size_t>(i)].train_index);
    }

    EXPECT_EQ(ocvu_mat_release(image), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(a), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(b), OCVU_STATUS_OK);
}

TEST(Matching, MatchDescriptorsReportsTheCountWhenTheBufferIsTooSmall) {
    const ocvu_mat_handle image = MakeTexturedImage(0);
    int32_t count = 0;
    const ocvu_mat_handle a = ComputeOrbDescriptors(image, &count);
    const ocvu_mat_handle b = ComputeOrbDescriptors(image, &count);

    std::vector<ocvu_dmatch> matches(static_cast<size_t>(count));
    for (ocvu_dmatch& m : matches) m.distance = -7.0f;
    int32_t match_count = -1;

    EXPECT_EQ(ocvu_match_descriptors(a, b, OCVU_NORM_HAMMING, 0,
                                     matches.data(), 0, &match_count),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_GT(match_count, 0) << "溢れたときは実際の対応数を返すこと";
    for (const ocvu_dmatch& m : matches) {
        EXPECT_FLOAT_EQ(m.distance, -7.0f) << "断ったのに matches を書いている";
    }

    EXPECT_EQ(ocvu_mat_release(image), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(a), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(b), OCVU_STATUS_OK);
}

TEST(Matching, MatchDescriptorsRejectsBadArgumentsAndZeroesTheCount) {
    const ocvu_mat_handle image = MakeTexturedImage(0);
    int32_t count = 0;
    const ocvu_mat_handle a = ComputeOrbDescriptors(image, &count);
    const ocvu_mat_handle b = ComputeOrbDescriptors(image, &count);
    std::vector<ocvu_dmatch> matches(static_cast<size_t>(count));

    EXPECT_EQ(ocvu_match_descriptors(a, b, OCVU_NORM_HAMMING, 0,
                                     matches.data(), count, nullptr),
              OCVU_STATUS_NULL_POINTER);

    int32_t match_count = 12345;
    EXPECT_EQ(ocvu_match_descriptors(a, b, 99, 0, matches.data(), count, &match_count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(match_count, 0) << "失敗時は out_count に 0 を書くこと";

    match_count = 12345;
    EXPECT_EQ(ocvu_match_descriptors(a, b, OCVU_NORM_HAMMING, 0, nullptr, count, &match_count),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(match_count, 0);

    match_count = 12345;
    EXPECT_EQ(ocvu_match_descriptors(OCVU_MAT_HANDLE_NONE, b, OCVU_NORM_HAMMING, 0,
                                     matches.data(), count, &match_count),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(match_count, 0);

    match_count = 12345;
    EXPECT_EQ(ocvu_match_descriptors(a, OCVU_MAT_HANDLE_NONE, OCVU_NORM_HAMMING, 0,
                                     matches.data(), count, &match_count),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(match_count, 0);

    EXPECT_EQ(ocvu_mat_release(image), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(a), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(b), OCVU_STATUS_OK);
}
```

**`offsetof` を使うので `#include <cstddef>` を足す。**

- [ ] **Step 2: RED を目で確認する**

```
pwsh tools/dev.ps1 test-native
```

- [ ] **Step 3: struct と定数をヘッダに足す**

`native/include/opencv_unity_native.h` の `ocvu_keypoint` の定義の直後に足す。

```c
/*
 * 記述子どうしの対応 1 つ。境界に出るので固定サイズ型だけで構成する。
 *
 * cv::DMatch をそのまま出すことはできない（C++ のクラスで、layout の
 * 保証も無い）。**この struct の layout がこちら側の正本である。**
 * 実装 .cpp に static_assert を置いて大きさを固定してあり、
 * C# 側の OcvuDMatch とは L3 が Marshal.SizeOf と Marshal.OffsetOf の
 * 両方で突き合わせる（**合計だけを固定した検査は中身の入れ替えを通す** ——
 * M5 で ocvu_keypoint について実測した）。
 *
 * query_index は問い合わせ側の記述子の索引、train_index は照合先の索引、
 * image_index は照合先が複数の画像から来るときにその識別に使うもの
 * （この ABI は 1 対 1 の照合しか出していないので常に 0 である）、
 * distance は 2 つの記述子の距離で **小さいほど似ている。**
 */
typedef struct ocvu_dmatch {
    int32_t query_index;
    int32_t train_index;
    int32_t image_index;
    float   distance;
} ocvu_dmatch;

/* ocvu_match_descriptors の距離の測り方。cv::NormTypes の値をそのまま出す
 * （実装 .cpp の static_assert が写し間違いをコンパイル時に落とす）。
 *
 * **検出器に合わせること。** ORB の記述子は 2 値なので HAMMING、
 * SIFT の記述子は float なので L2 を使う。合っていないと結果が無意味になるが、
 * OpenCV は型が合っていれば受け付けるので**誰も止めない。** */
#define OCVU_NORM_HAMMING 6

/* ocvu_match_descriptors の capacity の上限。
 * 呼ぶ側が過大な値を渡したときに native 側で確保しないための歯止めである。 */
#define OCVU_MATCH_MAX_COUNT 100000
```

**`OCVU_NORM_L2` は Phase 3 が足す。** この Phase が先なら、
Phase 3 の Task 3 Step 3 に載っている `OCVU_NORM_*` の 4 行をここで足すこと
（**両方が足すと衝突する**）。

- [ ] **Step 4: spec に 1 エントリ足して生成する**

```json
{
  "name": "ocvu_match_descriptors",
  "summary": "query の各記述子に対して train の中で最も近いものを 1 つ探し、その対応を out_matches へ書いて個数を out_count に返す。query と train は ocvu_detect_and_compute が作った記述子の Mat である。norm_type は OCVU_NORM_HAMMING か OCVU_NORM_L2 で、それ以外は OCVU_STATUS_INVALID_ARGUMENT を返す —— **検出器に合わせること**（ORB の 2 値記述子には HAMMING、SIFT の float 記述子には L2）。**合っていなくても OpenCV は型が合っていれば受け付けるので、結果が無意味になっても誰も止めない。** cross_check は 0 以外で真として扱い、互いに最近傍である対応だけを残す（誤対応が減るが、対応の数も減る）。capacity は out_matches の**要素数**である（バイト数ではない）—— 見つかった対応の数に満たなければ**何も書かずに** OCVU_STATUS_BUFFER_TOO_SMALL を返し、out_count に**実際の対応数**を入れる。capacity は OCVU_MATCH_MAX_COUNT 以下でなければならない。**1 つも見つからないのは誤りではない** —— OCVU_STATUS_OK を返して out_count に 0 を入れる。out_count が NULL なら他の何より先に OCVU_STATUS_NULL_POINTER を返し、通ったあとはどの失敗経路でも out_count に 0 を書く。距離は小さいほど似ている。handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返す。buffer の所有権は最初から最後まで呼ぶ側にある。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "query", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "train", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "norm_type", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "cross_check", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "out_matches", "cType": "ocvu_dmatch*", "csType": "OcvuDMatch[]", "direction": "out-buffer" },
    { "name": "capacity", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "out_count", "cType": "int32_t*", "csType": "out int", "direction": "out" }
  ]
}
```

```
pwsh tools/dev.ps1 generate
```

- [ ] **Step 5: C# の struct を手で足す**

`Packages/.../Runtime/Interop/NativeMethods.cs` の `OcvuKeyPoint` の直後に足す
（**spec が表現しない型なので、これは生成物ではない**）。

```csharp
    /// <summary>
    /// 記述子どうしの対応 1 つ。native の ocvu_dmatch と layout を合わせる。
    /// </summary>
    /// <remarks>
    /// struct の layout は正本を native のヘッダ側に置いてある。
    /// **大きさが合っていてもフィールドの並びが違えば marshalling だけが壊れる**
    /// ので、L3 の MatchingTests が Marshal.SizeOf と Marshal.OffsetOf の
    /// 両方で突き合わせる。
    /// </remarks>
    [StructLayout(LayoutKind.Sequential)]
    internal struct OcvuDMatch
    {
        internal int QueryIndex;
        internal int TrainIndex;
        internal int ImageIndex;
        internal float Distance;
    }
```

- [ ] **Step 6: 実装する**

`native/src/ocvu_matching.cpp` の先頭に static_assert を足す。

```cpp
#include <cstddef>

// **境界に出る struct の大きさと並びを固定する。**
// C# 側とは L3 が Marshal.SizeOf と Marshal.OffsetOf で突き合わせる。
static_assert(sizeof(ocvu_dmatch) == 16, "ocvu_dmatch の大きさが変わった");
static_assert(offsetof(ocvu_dmatch, query_index) == 0, "query_index の位置が変わった");
static_assert(offsetof(ocvu_dmatch, train_index) == 4, "train_index の位置が変わった");
static_assert(offsetof(ocvu_dmatch, image_index) == 8, "image_index の位置が変わった");
static_assert(offsetof(ocvu_dmatch, distance) == 12, "distance の位置が変わった");

static_assert(OCVU_NORM_HAMMING == cv::NORM_HAMMING, "NORM_HAMMING がずれている");
static_assert(OCVU_NORM_L2 == cv::NORM_L2, "NORM_L2 がずれている");
```

detail 名前空間に述語を足す。

```cpp
bool IsKnownMatchNorm(int32_t norm_type) {
    return norm_type == OCVU_NORM_HAMMING || norm_type == OCVU_NORM_L2;
}
```

ファイル末尾に実装を足す。

```cpp
extern "C" ocvu_status ocvu_match_descriptors(ocvu_mat_handle query, ocvu_mat_handle train, int32_t norm_type, int32_t cross_check, ocvu_dmatch* out_matches, int32_t capacity, int32_t* out_count) {
    OCVU_TRY_BEGIN
    using namespace ocvu_matching_detail;

    if (out_count == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_match_descriptors: out_count is NULL");
    }
    *out_count = 0;

    if (!IsKnownMatchNorm(norm_type)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_match_descriptors: norm_type must be OCVU_NORM_HAMMING or OCVU_NORM_L2");
    }
    if (out_matches == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_match_descriptors: out_matches is NULL");
    }
    if (capacity < 0 || capacity > OCVU_MATCH_MAX_COUNT) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_match_descriptors: capacity must be between 0 and OCVU_MATCH_MAX_COUNT");
    }

    const cv::Mat* query_mat = ::ocvu::mat_table_get(query);
    if (query_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_match_descriptors: query handle is invalid");
    }
    const cv::Mat* train_mat = ::ocvu::mat_table_get(train);
    if (train_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_match_descriptors: train handle is invalid");
    }

    std::vector<cv::DMatch> matches;
    try {
        const cv::Ptr<cv::BFMatcher> matcher =
            cv::BFMatcher::create(norm_type, cross_check != 0);
        matcher->match(*query_mat, *train_mat, matches);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    const int64_t found = static_cast<int64_t>(matches.size());
    if (found > static_cast<int64_t>(capacity)) {
        // **INT32_MAX を超えるなら、切り詰めずに断る。**
        if (found > INT32_MAX) {
            return ::ocvu::set_last_error(
                OCVU_STATUS_INVALID_ARGUMENT,
                "ocvu_match_descriptors: the result is too large to describe through this ABI");
        }
        *out_count = static_cast<int32_t>(found);
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_match_descriptors: capacity (elements) is smaller than the number of matches");
    }

    for (int64_t i = 0; i < found; ++i) {
        const cv::DMatch& m = matches[static_cast<size_t>(i)];
        out_matches[i].query_index = m.queryIdx;
        out_matches[i].train_index = m.trainIdx;
        out_matches[i].image_index = m.imgIdx;
        out_matches[i].distance = m.distance;
    }

    *out_count = static_cast<int32_t>(found);
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

- [ ] **Step 7: L1 を緑にする**

```
pwsh tools/dev.ps1 test-native
```

期待: `Matching.*` が 8 件 pass、exit 0。

- [ ] **Step 8: コミット**

```bash
git add native/tests/test_matching.cpp native/src/ocvu_matching.cpp \
        native/include/opencv_unity_native.h bindings/spec/features.json \
        native/include/ocvu/features.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.cs \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Features.g.cs \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(features): 記述子を対応づける ocvu_match_descriptors と ocvu_dmatch を出す"
```

---

## Task 3: `stereo` のリンクを先に実証する

**このタスクは関数を 1 本も足さない。** `COMPONENTS` に `stereo` を足すことが
**実際にリンク行を変える**ことを、`add-abi-function` skill の手順どおりに証明する。

**`geometry` は落ちなかったが `calib` は落ちた**（M5 で実測）。
**`stereo` がどちらかは推測できないので、実際に走らせる。**

**Files:**
- Modify: `native/tests/test_module_linkage.cpp`、`cmake/FindOpenCvUnityDeps.cmake`

- [ ] **Step 1: `cv::StereoBM` を参照するテストを書く**

`native/tests/test_module_linkage.cpp` の末尾に足す。

```cpp
TEST(ModuleLinkage, StereoIsLinked) {
    // **stereo は Modules に無いが、ビルドされている。** calib が推移的に引くためで、
    // 復元済みのツリーに libopencv_stereo が実在する（2026-09-05 に実測）。
    // **ただしそれは「リンクできる」ことの証拠ではない** ——
    // COMPONENTS に足して、実際にシンボルを参照して初めて分かる。
    //
    // **calib と同じか geometry と同じかは、走らせるまで分からない** ——
    // geometry は features / objdetect の依存として既に引かれていたので
    // COMPONENTS に足す前から通ったが、calib は LNK2019 で落ちた。
    const cv::Ptr<cv::StereoBM> matcher = cv::StereoBM::create(16, 21);
    ASSERT_FALSE(matcher.empty());
    EXPECT_EQ(matcher->getNumDisparities(), 16);
    EXPECT_EQ(matcher->getBlockSize(), 21);
}
```

`#include <opencv2/stereo.hpp>` をファイル冒頭の include 群に足す。

- [ ] **Step 2: `COMPONENTS` を触らずにビルドし、結果を記録する**

```
pwsh tools/dev.ps1 test-native
```

**2 つのどちらかになる。両方とも正しい結果である:**

| 結果 | 意味 | 次にすること |
| --- | --- | --- |
| **`LNK2019` / undefined reference で落ちる** | `stereo` はどの module からも推移的に引かれていない。**`calib` と同じ形** | Step 3 へ進む。**この 1 語が実際にリンク行を変える** |
| **通る** | `stereo` は既に推移的に引かれている。**`geometry` と同じ形** | Step 3 へ進む。**`COMPONENTS` への追加は意図の宣言であって no-op である** —— そのことを PR 本文と allowlist に**明記する**（`geometry` の前例がある） |

**どちらだったかを PR 本文に実測として書く。** 「落ちた」と「通った」で
`COMPONENTS` の 1 語の意味が変わるので、**推測で書かない。**

- [ ] **Step 3: `COMPONENTS` に `stereo` を足す**

`cmake/FindOpenCvUnityDeps.cmake` の該当行を変える。

```cmake
    COMPONENTS core imgproc imgcodecs objdetect features geometry calib stereo
```

**その行の近くのコメントに、Step 2 で実測した結果を書く** ——
`geometry` と `calib` について既に書いてある形に揃える。

- [ ] **Step 4: 通ることを確かめる**

```
pwsh tools/dev.ps1 test-native
```

期待: `ModuleLinkage.StereoIsLinked` が pass、exit 0。

- [ ] **Step 5: コミット**

```bash
git add native/tests/test_module_linkage.cpp cmake/FindOpenCvUnityDeps.cmake
git commit -m "build: stereo module をリンクし、シンボルが解決することを L1 で実証する"
```

---

## Task 4: `ocvu_compute_disparity`

**Files:**
- Create: `bindings/spec/stereo.json`、`native/src/ocvu_stereo.cpp`、`native/tests/test_stereo.cpp`
- Modify: `native/include/opencv_unity_native.h`（`OCVU_STEREO_*` と `#include`）、`native/CMakeLists.txt`、`native/tests/CMakeLists.txt`、`tools/tests/OpenCvConfig.Tests.ps1`

**Interfaces:**
- Produces: `ocvu_status ocvu_compute_disparity(ocvu_mat_handle left, ocvu_mat_handle right, ocvu_mat_handle dst, int32_t algorithm, int32_t num_disparities, int32_t block_size)`

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_stereo.cpp` を新規作成する。

```cpp
// stereo module の契約テスト。
//
// **視差の値そのものは検証しない。** アルゴリズムの出力は実装の詳細に
// 左右されるので、ここで見るのは「呼べて、正しい形の結果が返る」ことである。

#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <vector>

namespace {

// 縦縞のグレー画像。offset_x だけ横にずらす（= 視差のある左右の対を作れる）。
ocvu_mat_handle MakeStripes(int32_t width, int32_t height, int32_t offset_x) {
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(height, width, OCVU_MAT_TYPE_8UC1, &handle), OCVU_STATUS_OK);
    std::vector<uint8_t> pixels(static_cast<size_t>(width) * height, 0);
    for (int32_t r = 0; r < height; ++r) {
        for (int32_t c = 0; c < width; ++c) {
            const int32_t sc = c + offset_x;
            pixels[static_cast<size_t>(r) * width + c] =
                ((sc / 5) % 2 == 0) ? 220 : 30;
        }
    }
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(),
                                        static_cast<int64_t>(pixels.size()), width),
              OCVU_STATUS_OK);
    return handle;
}

}  // namespace

TEST(Stereo, ComputeDisparityProducesAnImageOfTheExpectedShape) {
    const ocvu_mat_handle left = MakeStripes(128, 64, 0);
    const ocvu_mat_handle right = MakeStripes(128, 64, 4);
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    ASSERT_EQ(ocvu_compute_disparity(left, right, dst, OCVU_STEREO_BM, 16, 21),
              OCVU_STATUS_OK);

    // **視差画像は入力と同じ大きさの 16 bit 符号つき 1 channel である。**
    // この ABI の OCVU_MAT_TYPE_* には無い型なので、type ではなく形だけを見る。
    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 64);
    EXPECT_EQ(info.cols, 128);
    EXPECT_EQ(info.channels, 1);

    EXPECT_EQ(ocvu_mat_release(left), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(right), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(Stereo, ComputeDisparitySupportsSgbm) {
    const ocvu_mat_handle left = MakeStripes(128, 64, 0);
    const ocvu_mat_handle right = MakeStripes(128, 64, 4);
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    // SGBM は block_size に奇数を要求する（BM も同様）。
    ASSERT_EQ(ocvu_compute_disparity(left, right, dst, OCVU_STEREO_SGBM, 16, 5),
              OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 64);
    EXPECT_EQ(info.cols, 128);

    EXPECT_EQ(ocvu_mat_release(left), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(right), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(Stereo, ComputeDisparityRejectsBadArguments) {
    const ocvu_mat_handle left = MakeStripes(128, 64, 0);
    const ocvu_mat_handle right = MakeStripes(128, 64, 4);
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_compute_disparity(left, right, dst, 99, 16, 21),
              OCVU_STATUS_INVALID_ARGUMENT);

    // **num_disparities は 16 の倍数で、正でなければならない。**
    // OpenCV に落とすと例外になるので、呼ぶ側が直せる誤りとしてここで断る。
    EXPECT_EQ(ocvu_compute_disparity(left, right, dst, OCVU_STEREO_BM, 0, 21),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_compute_disparity(left, right, dst, OCVU_STEREO_BM, 17, 21),
              OCVU_STATUS_INVALID_ARGUMENT);

    // **block_size は 5 以上の奇数でなければならない。**
    EXPECT_EQ(ocvu_compute_disparity(left, right, dst, OCVU_STEREO_BM, 16, 20),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_compute_disparity(left, right, dst, OCVU_STEREO_BM, 16, 3),
              OCVU_STATUS_INVALID_ARGUMENT);

    EXPECT_EQ(ocvu_compute_disparity(OCVU_MAT_HANDLE_NONE, right, dst,
                                     OCVU_STEREO_BM, 16, 21),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_compute_disparity(left, OCVU_MAT_HANDLE_NONE, dst,
                                     OCVU_STEREO_BM, 16, 21),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_compute_disparity(left, right, OCVU_MAT_HANDLE_NONE,
                                     OCVU_STEREO_BM, 16, 21),
              OCVU_STATUS_INVALID_HANDLE);

    EXPECT_EQ(ocvu_mat_release(left), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(right), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(Stereo, ComputeDisparityReportsMismatchedSizesAsAnOpenCvError) {
    // **左右の大きさが違うのは呼ぶ側の誤りである。** OpenCV が投げるので
    // OPENCV_ERROR として報告する（「原因不明」にはしない）。
    const ocvu_mat_handle left = MakeStripes(128, 64, 0);
    const ocvu_mat_handle right = MakeStripes(64, 64, 4);
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    const ocvu_status status =
        ocvu_compute_disparity(left, right, dst, OCVU_STEREO_BM, 16, 21);
    EXPECT_EQ(status, OCVU_STATUS_OPENCV_ERROR);
    EXPECT_NE(status, OCVU_STATUS_UNKNOWN_ERROR);

    EXPECT_EQ(ocvu_mat_release(left), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(right), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}
```

`native/tests/CMakeLists.txt` の一覧に `test_stereo.cpp` を足す。

- [ ] **Step 2: RED を目で確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: **コンパイルエラー**（`ocvu_compute_disparity` も `OCVU_STEREO_BM` も無い）。

- [ ] **Step 3: 定数と include をヘッダに足す**

`native/include/opencv_unity_native.h` に足す。

```c
/* ocvu_compute_disparity のアルゴリズム。
 *
 * **これは OpenCV の定数の写しではない。** cv::StereoBM / cv::StereoSGBM は
 * クラスであって定数ではないので、対応する値が上流に存在しない。
 * **この 2 つはこちらが決めた値**であり、static_assert で固定する相手が無い。
 *
 * BM は速いが粗く、SGBM は遅いが滑らかである。 */
#define OCVU_STEREO_BM   0
#define OCVU_STEREO_SGBM 1
```

**`#include` の一覧に 1 行足す**（`ocvu/calib.h` の次）。

```c
#include "ocvu/stereo.h"
```

**この 1 行だけは生成物ではない** —— ヘッダの末尾のコメントがそう説明している。

- [ ] **Step 4: `stereo` の spec を新設して生成する**

`bindings/spec/stereo.json` を新規作成する。

```json
{
  "module": "stereo",
  "functions": [
    {
      "name": "ocvu_compute_disparity",
      "summary": "平行に並べた左右の画像から視差の画像を作って dst に入れる。dst は結果に応じて丸ごと置き換わり、入力と同じ大きさの 16 bit 符号つき 1 channel になる（**この ABI の OCVU_MAT_TYPE_* には無い型なので、ocvu_mat_copy_to_buffer で読み出すときは 1 画素 2 バイトとして扱うこと**）。値は実際の視差の 16 倍である（OpenCV がそう返す）。left と right は同じ大きさ・同じ型の 8 bit 1 channel で、**あらかじめ平行化されていなければならない**（この package は平行化を持っていない）。algorithm は OCVU_STEREO_BM か OCVU_STEREO_SGBM で、それ以外は OCVU_STATUS_INVALID_ARGUMENT を返す —— BM は速いが粗く、SGBM は遅いが滑らかである。num_disparities は探索する視差の幅で、正の 16 の倍数でなければならない。block_size は照合する窓の 1 辺で、5 以上の奇数でなければならない。左右の大きさが違う場合は OpenCV が例外を投げるので OCVU_STATUS_OPENCV_ERROR を返す。handle が無効なら OCVU_STATUS_INVALID_HANDLE。失敗したときは dst を書き換えない。",
      "returns": "ocvu_status",
      "csReturns": "int",
      "wrapInTryBarrier": true,
      "params": [
        { "name": "left", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
        { "name": "right", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
        { "name": "dst", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
        { "name": "algorithm", "cType": "int32_t", "csType": "int", "direction": "in" },
        { "name": "num_disparities", "cType": "int32_t", "csType": "int", "direction": "in" },
        { "name": "block_size", "cType": "int32_t", "csType": "int", "direction": "in" }
      ]
    }
  ]
}
```

```
pwsh tools/dev.ps1 generate
```

期待: **生成物が 2 つ増える**（`native/include/ocvu/stereo.h` と
`Packages/.../Runtime/Interop/NativeMethods.Stereo.g.cs`）。

**`NativeMethods.Stereo.g.cs.meta` を手で作る。**
既存のもの（`NativeMethods.Calib.g.cs.meta`）と同じ形にする ——
**60 バイト、1 行目のみ CRLF、末尾改行なし**（実測）で、
**guid はリポジトリ内で一意にする**（`git grep <guid>` が 1 件も返さないこと）。

- [ ] **Step 5: `OpenCvConfig.Tests.ps1` の一覧に `stereo` を足す**

**この 1 行を忘れると `dev.ps1 test` が落ちる。**
`tools/tests/OpenCvConfig.Tests.ps1` の該当行を変える。

```powershell
#   - stereo は Modules に書いていないが、calib の依存として引かれる
#     （COMPONENTS には意図の宣言として明示してある）
$specModulesNotBuiltDirectly = @('infra', 'geometry', 'stereo')
```

**変える前に一度 `pwsh tools/dev.ps1 test-tools` を走らせて、
実際に落ちることを見ること** —— `prove-a-check-works` の
「壊して、落ちることを見る」がここでは無料で手に入る。

- [ ] **Step 6: 実装する**

`native/src/ocvu_stereo.cpp` を新規作成する。

```cpp
// stereo module。**この plugin がこの module を使う唯一の場所である。**

#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/stereo.hpp>

#include <cstdint>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

extern "C" ocvu_status ocvu_compute_disparity(ocvu_mat_handle left, ocvu_mat_handle right, ocvu_mat_handle dst, int32_t algorithm, int32_t num_disparities, int32_t block_size) {
    OCVU_TRY_BEGIN
    if (algorithm != OCVU_STEREO_BM && algorithm != OCVU_STEREO_SGBM) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_compute_disparity: algorithm must be OCVU_STEREO_BM or OCVU_STEREO_SGBM");
    }
    // **OpenCV の要求を自分で見る。** 落とすと例外になるが、呼ぶ側が直せる誤りである。
    if (num_disparities <= 0 || num_disparities % 16 != 0) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_compute_disparity: num_disparities must be a positive multiple of 16");
    }
    if (block_size < 5 || block_size % 2 == 0) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_compute_disparity: block_size must be an odd number of at least 5");
    }

    const cv::Mat* left_mat = ::ocvu::mat_table_get(left);
    if (left_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_compute_disparity: left handle is invalid");
    }
    const cv::Mat* right_mat = ::ocvu::mat_table_get(right);
    if (right_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_compute_disparity: right handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_compute_disparity: dst handle is invalid");
    }

    cv::Mat result;
    try {
        cv::Ptr<cv::StereoMatcher> matcher;
        if (algorithm == OCVU_STEREO_BM) {
            matcher = cv::StereoBM::create(num_disparities, block_size);
        } else {
            matcher = cv::StereoSGBM::create(0, num_disparities, block_size);
        }
        matcher->compute(*left_mat, *right_mat, result);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

`native/CMakeLists.txt` の `OCVU_SOURCES` に `src/ocvu_stereo.cpp` を足す。

- [ ] **Step 7: L1 を緑にする**

```
pwsh tools/dev.ps1 test-native
```

期待: `Stereo.*` が 4 件 pass、exit 0。

- [ ] **Step 8: 全レーンと ASan を回す**

```
pwsh tools/dev.ps1 test
pwsh tools/dev.ps1 test-asan
```

両方 exit 0。**`test` に `verify-generated` と `test-tools` が入っている**ので、
Step 5 の一覧の追加が効いているかもここで分かる。

- [ ] **Step 9: コミット**

```bash
git add bindings/spec/stereo.json native/src/ocvu_stereo.cpp native/CMakeLists.txt \
        native/tests/test_stereo.cpp native/tests/CMakeLists.txt \
        native/include/opencv_unity_native.h native/include/ocvu/stereo.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Stereo.g.cs \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Stereo.g.cs.meta \
        tools/tests/OpenCvConfig.Tests.ps1 \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(stereo): 左右の画像から視差を求める ocvu_compute_disparity を出す"
```

---

## Task 5: C# の公開 API と L3

**Files:**
- Create: `Packages/.../Runtime/Core/CvStereo.cs`（+ `.meta`）、`tests/Managed/CvUnity.Tests.Managed/MatchingTests.cs`、`tests/Managed/CvUnity.Tests.Managed/StereoTests.cs`
- Modify: `Packages/.../Runtime/Core/CvFeatures.cs`

**Interfaces:**
- Produces:
  - `CvFeatures.DetectAndCompute(CvMat src, CvFeatureDetector detector, int maxFeatures, CvMat descriptors)` → `CvKeyPoint[]`
  - `CvFeatures.MatchDescriptors(CvMat query, CvMat train, CvDescriptorNorm norm, bool crossCheck, int maxMatches)` → `CvMatch[]`
  - `CvStereo.ComputeDisparity(CvMat left, CvMat right, CvMat dst, CvStereoAlgorithm algorithm, int numDisparities, int blockSize)`

- [ ] **Step 1: `CvFeatures` に 2 本と型を足す**

**新しい値型 `CvMatch` と enum 2 つ**（`CvFeatureDetector` / `CvDescriptorNorm`）を
`Runtime/Core/CvFeatures.cs` に足す。

```csharp
    /// <summary>
    /// 記述子どうしの対応 1 つ。native の ocvu_dmatch に対応する読み取り専用の値。
    /// </summary>
    public readonly struct CvMatch
    {
        /// <summary>問い合わせ側の記述子の索引。</summary>
        public int QueryIndex { get; }

        /// <summary>照合先の記述子の索引。</summary>
        public int TrainIndex { get; }

        /// <summary>2 つの記述子の距離。**小さいほど似ている。**</summary>
        public float Distance { get; }

        /// <summary>3 つの値から対応を作る。</summary>
        public CvMatch(int queryIndex, int trainIndex, float distance)
        {
            QueryIndex = queryIndex;
            TrainIndex = trainIndex;
            Distance = distance;
        }
    }

    /// <summary>特徴点の検出器。</summary>
    /// <remarks>
    /// 値は C の <c>OCVU_FEATURE_*</c> の写しである。**これは OpenCV の定数では
    /// なく、この package が決めた値である。** <c>MatchingTests</c> の
    /// <c>TheManagedDetectorValuesMatchWhatNativeAccepts</c> が両側を native に
    /// 問うことで同期を守っている。
    /// </remarks>
    public enum CvFeatureDetector
    {
        /// <summary>速い。記述子は 32 バイトの 2 値で、<see cref="CvDescriptorNorm.Hamming"/> で比べる。</summary>
        Orb = 0,

        /// <summary>遅いが回転と拡大縮小に強い。記述子は 128 次元の float で、<see cref="CvDescriptorNorm.L2"/> で比べる。</summary>
        Sift = 1,
    }

    /// <summary>記述子どうしの距離の測り方。</summary>
    /// <remarks>
    /// **検出器に合わせること。** 合っていなくても native は型が合っていれば
    /// 受け付けるので、結果が無意味になっても例外にならない。
    /// </remarks>
    public enum CvDescriptorNorm
    {
        /// <summary>2 値の記述子（ORB）用。</summary>
        Hamming = 6,

        /// <summary>float の記述子（SIFT）用。</summary>
        L2 = 4,
    }
```

**`DetectAndCompute` は溢れる経路を隠す** —— 1 回目で必要量を受け取り、
足りなければその量で確保して 1 度だけ呼び直す（`CvAruco.DetectMarkers` と同じ形）。
**`MatchDescriptors` も同じ。**

**`CvMat descriptors` を引数で受け取る**のは、記述子の所有権を呼ぶ側に置くためである
（native が Mat を作って返す形にすると、解放し忘れという壊れ方が増える）。
**そのことを `<remarks>` に書く。**

- [ ] **Step 2: `CvStereo` を新規作成する**

`Packages/.../Runtime/Core/CvStereo.cs`。`CvStereoAlgorithm` enum と
`ComputeDisparity` の 1 本だけを持つ。

**`<remarks>` に 2 つ書く**:
- **視差画像は 16 bit 符号つきで、`CvMatType` には無い型である** ——
  `CopyTo` で読むときは 1 画素 2 バイトとして扱うこと
- **左右の画像は平行化されていなければならない** ——
  この package は平行化を持っていない

`.meta` を手で作る（**guid は一意にする**）。

- [ ] **Step 3: L3 テストを書いて走らせる**

`tests/Managed/CvUnity.Tests.Managed/MatchingTests.cs` に**必ず含めるもの**:

```csharp
        [Fact]
        public void TheDMatchStructMatchesTheNativeLayout()
        {
            // **合計だけでは足りない。** 同じ型のフィールドを入れ替えても
            // sizeof は変わらないので、offset を全部並べて閉じる
            // （M5 で ocvu_keypoint について実測した）。
            Assert.Equal(16, Marshal.SizeOf<OcvuDMatch>());
            Assert.Equal(0, Marshal.OffsetOf<OcvuDMatch>(nameof(OcvuDMatch.QueryIndex)).ToInt32());
            Assert.Equal(4, Marshal.OffsetOf<OcvuDMatch>(nameof(OcvuDMatch.TrainIndex)).ToInt32());
            Assert.Equal(8, Marshal.OffsetOf<OcvuDMatch>(nameof(OcvuDMatch.ImageIndex)).ToInt32());
            Assert.Equal(12, Marshal.OffsetOf<OcvuDMatch>(nameof(OcvuDMatch.Distance)).ToInt32());
        }
```

**加えてこれらを含める**:
- `DetectAndComputeProducesKeypointsAndDescriptors` — ORB で記述子が 32 列になること
- `DetectAndComputeSupportsSift` — SIFT で 128 列になること
- `DetectAndComputeGrowsTheBufferWhenTheFirstCallOverflows` — `maxFeatures` を
  小さくして溢れさせ、正しい数が返ること
- `MatchDescriptorsFindsIdenticalDescriptors` — 同じ画像どうしで距離 0 の対応が並ぶこと
- `TheManagedDetectorValuesMatchWhatNativeAccepts` — 定義された値が拒否されず、
  99 が `CvStatus.InvalidArgument` で拒否されること

`tests/Managed/CvUnity.Tests.Managed/StereoTests.cs`:
- `ComputeDisparityProducesAnImageOfTheExpectedShape`
- `ComputeDisparityRejectsAnEvenBlockSize` — `CvStatus.InvalidArgument`
- `ComputeDisparityRejectsANonMultipleOf16` — 同上
- `TheManagedAlgorithmValuesMatchWhatNativeAccepts`

```
pwsh tools/dev.ps1 test-managed
```

- [ ] **Step 4: 全レーンを回す**

```
pwsh tools/dev.ps1 test
pwsh tools/dev.ps1 test-asan
```

- [ ] **Step 5: コミット**

```bash
git add Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvFeatures.cs \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvStereo.cs \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvStereo.cs.meta \
        tests/Managed/CvUnity.Tests.Managed/MatchingTests.cs \
        tests/Managed/CvUnity.Tests.Managed/StereoTests.cs
git commit -m "feat(csharp): マッチングとステレオの公開 API を出す"
```

---

## Task 6: 文書とレビュー

**この Phase は `COMPONENTS` を変えるので、直す場所が他の 3 つより多い。**

- [ ] **Step 1: `README.md` と `README.ja.md` の module 一覧を直す**

**両方に同じ一覧がある。片方だけ直すと 2 つが食い違う。**

- `README.md:358` 付近の「`imgproc`, `imgcodecs`, `objdetect`, `features`,
  `geometry` and `calib`」に `stereo` を足す
- `README.ja.md:227` 付近の「`core` / `imgproc` / `imgcodecs` / `objdetect` /
  `features` / `geometry` / `calib` をリンクしています」に足す

**`README.ja.md` の「書くことが引き込みます」の段落には大きさの実測も書いてある。**
Step 5 で測った値をそこに足す。

- [ ] **Step 2: allowlist に §3.13 を足す**

`docs/abi-ownership-and-versioning.md` に **§3.13 マッチングとステレオ**を足す。
**§3 の冒頭が数えている本数を直す。**

**次の 3 つを明記する:**
1. **`ocvu_dmatch` は境界に出る 3 つ目の struct である**（`ocvu_mat_info` /
   `ocvu_keypoint` に続く）。layout の正本は native のヘッダ
2. **`OCVU_FEATURE_*` と `OCVU_STEREO_*` は OpenCV の写しではない** ——
   こちらが決めた値なので `static_assert` が無い
3. **`stereo` を `COMPONENTS` に足した結果**（Task 3 Step 2 で実測したもの。
   リンクが落ちたのか、既に引かれていたのか）

- [ ] **Step 3: API リファレンスに足し、「まだ無い」から消す**

`docs/api-reference.md` の §1 と §2 に足す。
**§3「この allowlist に含まれないもの」から「記述子を伴う特徴点マッチング」を消す**
（`.github/release-notes.md` の「出していないもの」にも載っているので、
次の版のノートを書くときに一緒に直す）。

- [ ] **Step 4: `CLAUDE.md` を直す**

**5 箇所ある:**
1. 「公開 ABI の内訳」の段落（`stereo` module が加わったことも書く）
2. 「ファイル配置」の表の `native/src/` の行に `ocvu_matching.cpp` と `ocvu_stereo.cpp`
3. **`bindings/spec/*.json` の行の module 一覧**（`stereo` を足す）
4. **`native/include/ocvu/{...}.h` の行の module 一覧**（同上）
5. **`cmake/FindOpenCvUnityDeps.cmake` の行**（`COMPONENTS` の現在値を書いてある）
6. `docs/api-reference.md` の行の C# クラス一覧に `CvStereo`

**`tools/opencv-config.psd1` の行は変えない** —— `Modules` は触っていない。

- [ ] **Step 5: 大きさを測る**

```
pwsh tools/dev.ps1 build
ls -l Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/x86_64/opencv_unity_native.dll
```

**この Phase は SIFT と SGBM を引き込むので、4 つの中で増分が最も大きいはずである。**
前回からの差を記録し、`README.ja.md` に書く。

- [ ] **Step 6: AI レビュー**

**この差分を書いていない別のエージェント**に、ブランチ全体の差分と
この計画と[全体設計](./2026-09-05-api-surface-expansion.md)を渡す。
**特に見てもらうべきもの**（ただし**指摘してほしくないことは伝えない**）:
- `COMPONENTS` を変えたときに動く場所を全部直したか
- `ocvu_dmatch` の layout 検査が両側で閉じているか

指摘を直したら、スコープを絞った再レビュー。

- [ ] **Step 7: コミットして push、PR を作る**

PR 本文に書くもの:
- 何を成立させたか（3 本 + 新しい struct 1 つ + `stereo` module のリンク）
- **`COMPONENTS` に `stereo` を足した結果の実測**（`geometry` と同じだったか、
  `calib` と同じだったか）
- **構成ハッシュが変わっていないこと**（`Modules` を触っていないので
  OpenCV の再ビルドは起きていない）
- 実測値（L1 / L3 の件数、ライブラリの大きさの差）
- **意図的に見送ったもの**（`knnMatch` / `radiusMatch`、FLANN ベースの照合、
  `AKAZE`（**OpenCV 5 の `features` に無い**）、ステレオの平行化
  （`stereoRectify`）、視差から 3D への復元（`reprojectImageTo3D`）、
  記述子を保持する検出器の handle）
- ステップ 6 のレビュー結果

**merge しない。** CI が緑になったら報告して指示を待つ。

---

## Self-Review

**1. spec coverage** — [全体設計](./2026-09-05-api-surface-expansion.md) §4 の Phase 4 に挙げた 3 本が Task 1 / 2 / 4 に在る。§5.2 の `ocvu_dmatch` は Task 2、§6 の「`stereo` を足すときに動くもの」は Task 3 / 4 / 6 に割ってある。§9 の完了条件は Task 6 が満たす。

**2. placeholder scan** — Task 5 は C# のコードブロックを一部省いているが、**`CvMatch` と 2 つの enum は貼ってあり、`TheDMatchStructMatchesTheNativeLayout` も全文が在る**（この Phase で最も壊れやすい検査なので省かない）。残りはメソッド名・引数・テスト名をすべて名指ししてある。

**3. type consistency** — `ocvu_matching_detail` は Task 1 で定義し Task 2 で使う。`MakeTexturedImage` は Task 1、`ComputeOrbDescriptors` は Task 2、`MakeStripes` は Task 4 で定義する。`OCVU_NORM_L2` は **Phase 3 と共有する** ので、先に着手したほうが足すことを明記した。`OcvuDMatch` は Task 2 Step 5 で手書きし、Task 5 の L3 が突き合わせる。

**4. 確認できていないもの** — **`cv::SIFT::create(max_features)` の第 1 引数が `nfeatures` であること**は実測済み（`features.hpp:380`）だが、**SIFT が `max_features` を上限として厳密に守るかは確かめていない**。Task 1 のテストは `ASSERT_GT(count, 0)` と `EXPECT_EQ(info.rows, count)` しか見ていないので、守らなくても落ちない。**そこは意図的である** —— 上限の扱いは検出器の実装の詳細で、この ABI が約束するものではない。
