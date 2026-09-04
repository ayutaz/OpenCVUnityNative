# Phase 3 — core の基本演算 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** channel の出し入れ・最小最大・範囲抽出・正規化・論理演算・ルックアップ変換・余白付けを C ABI に出す。

**Architecture:** `core` module に 8 本を足す。実装は `native/src/ocvu_core_ops.cpp` の 1 ファイル。**`core` は最初からリンクされているので、OpenCV の再ビルドも `COMPONENTS` の変更も起きない。** 8 本すべてが既存の形（handle を取り、handle に書く）の反復で、**新しい設計判断がゼロ**である。

**Tech Stack:** C++17 / OpenCV 5.0.0（`core`）/ C# netstandard2.1 / GoogleTest（L1）/ xUnit（L3）

**Spec:** [API 拡張（A〜F）— 全体設計と分割](./2026-09-05-api-surface-expansion.md)

## Global Constraints

- **`tools/opencv-config.psd1` の `Modules` も `cmake/FindOpenCvUnityDeps.cmake` の `COMPONENTS` も変えない**
- **新しい status code も新しい struct も足さない**
- **宣言を手で書かない。** `bindings/spec/core.json` に 1 エントリ足して `./tools/dev.ps1 generate`
- **`*_length` はバイト数、`*_capacity` は要素数。** 両方 `summary` に明記する
- **積は `static_cast<int64_t>` を先に当ててから作る**
- **公開 ABI 関数は `OCVU_TRY_BEGIN` / `OCVU_TRY_END` で囲む。** `cv::Exception` はその手前で個別に受けて `OCVU_STATUS_OPENCV_ERROR` にする
- **`extern "C" ocvu_status ocvu_名前(` までを 1 物理行に置く**
- **in-place（`src == dst`）を許すかどうかを関数ごとに決め、`summary` に書く**
- **`Runtime/Core` は `UnityEngine` を参照しない**
- **`git add -A` / `git add .` は hook が拒否する**

## この Phase 固有の決定

### `ocvu_bitwise` は 4 つの演算を 1 本にまとめる

`cv::bitwise_and` / `_or` / `_xor` / `_not` は**同じ形をしている**（NOT だけ第 2 引数が無い）。
4 本に分けると spec も実装も L1 も 4 倍になるが、区別しているのは演算子だけである。

**`op` 引数で 1 本にする。** NOT のときは `src2` を無視し、**それを `summary` に明記する**
（黙って無視すると、渡した引数が効いていないことに呼ぶ側が気づけない）。

**`OCVU_BITWISE_*` の値は OpenCV に対応するものが無い。** `cv::bitwise_and` は
関数であって定数ではないので、**これはこちらが決めた値である** ——
`static_assert` を置きようがないので、そのことをヘッダのコメントに書く。

### `ocvu_min_max_loc` は 4 つの出力を持つ

最小値・最大値・最小の位置・最大の位置。**位置は `int32_t` 2 個（x, y）で返す** ——
`ocvu_mat_info` のように struct を足すほどの必要が無く、`ocvu_dmatch` を
Phase 4 で足すのに加えてここでも足すと、境界の struct が一度に 2 つ増える。

**4 つとも NULL を許す。** 呼ぶ側が最大値だけ欲しいことは普通にある。
**ただし全部 NULL なら誤りである**（何も受け取らずに計算だけさせる意味が無い）。

### `ocvu_normalize` の `dtype` は出さない

`cv::normalize` は出力の型を変えられるが、この ABI が扱う型は
`OCVU_MAT_TYPE_*` の 3 つだけである。**型変換を持ち込むと、
「8UC1 を 32F に正規化する」という、この ABI が表現できない出力が作れてしまう。**
`dtype = -1`（src と同じ型）に固定し、そのことを `summary` に書く。

## ファイル構成

**新規**

| ファイル | 責務 |
| --- | --- |
| `native/src/ocvu_core_ops.cpp` | 8 本すべて |
| `native/tests/test_core_ops.cpp` | 8 本の L1 |
| `tests/Managed/CvUnity.Tests.Managed/CoreOpsTests.cs` | L3 |
| `Packages/.../Runtime/Core/CvCoreOps.cs`（+ `.meta`） | C# の公開入口 |

**変更**

| ファイル | 何を |
| --- | --- |
| `native/include/opencv_unity_native.h` | `OCVU_BITWISE_*`(4) / `OCVU_NORM_*`(4) |
| `bindings/spec/core.json` | 8 エントリ |
| `native/CMakeLists.txt` / `native/tests/CMakeLists.txt` | ソース一覧 |
| `docs/abi-ownership-and-versioning.md` / `docs/api-reference.md` / `CLAUDE.md` | 文書 |

**`OCVU_BORDER_*` は Phase 2 が足す。** この Phase が先に着手される場合は
`ocvu_copy_make_border` のためにこちらで足すこと（**両方が足すと衝突する** ——
先に着手したほうが足し、後から来たほうは既に在ることを確かめて使う）。

---

## Task 1: `ocvu_extract_channel` と `ocvu_insert_channel`

**Files:**
- Create: `native/tests/test_core_ops.cpp`、`native/src/ocvu_core_ops.cpp`
- Modify: `bindings/spec/core.json`、`native/CMakeLists.txt`、`native/tests/CMakeLists.txt`

**Interfaces:**
- Produces:
  - `ocvu_status ocvu_extract_channel(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t channel_index)`
  - `ocvu_status ocvu_insert_channel(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t channel_index)`

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_core_ops.cpp` を新規作成する。

```cpp
// core module の基本演算 8 本の契約テスト。
//
// **期待値はすべて手で決められる。** 画素の値を自分で置いた小さい画像だけを使う。

#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <array>
#include <vector>

namespace {

// 2x2 の 4 channel 画像。画素 i の channel c に (i * 10 + c) を入れる。
ocvu_mat_handle MakeFourChannel() {
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(2, 2, OCVU_MAT_TYPE_8UC4, &handle), OCVU_STATUS_OK);
    std::array<uint8_t, 16> pixels{};
    for (int i = 0; i < 4; ++i) {
        for (int c = 0; c < 4; ++c) {
            pixels[static_cast<size_t>(i) * 4 + c] = static_cast<uint8_t>(i * 10 + c);
        }
    }
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(), 16, 8), OCVU_STATUS_OK);
    return handle;
}

// 全画素が同じ値の 1 channel 画像。
ocvu_mat_handle MakeUniform(int32_t rows, int32_t cols, uint8_t value) {
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(rows, cols, OCVU_MAT_TYPE_8UC1, &handle), OCVU_STATUS_OK);
    std::vector<uint8_t> pixels(static_cast<size_t>(rows) * cols, value);
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(),
                                        static_cast<int64_t>(pixels.size()), cols),
              OCVU_STATUS_OK);
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

TEST(CoreOps, ExtractChannelTakesTheRequestedChannel) {
    const ocvu_mat_handle src = MakeFourChannel();
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    ASSERT_EQ(ocvu_extract_channel(src, dst, 2), OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 2);
    EXPECT_EQ(info.cols, 2);
    EXPECT_EQ(info.channels, 1);

    // channel 2 なので、画素 i の値は i * 10 + 2 である。**手で数えられる。**
    const std::vector<uint8_t> pixels = ReadPixels(dst);
    ASSERT_EQ(pixels.size(), 4u);
    for (int i = 0; i < 4; ++i) {
        EXPECT_EQ(pixels[static_cast<size_t>(i)], i * 10 + 2) << "画素 " << i;
    }

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(CoreOps, InsertChannelReplacesTheRequestedChannel) {
    ocvu_mat_handle target = MakeFourChannel();
    const ocvu_mat_handle replacement = MakeUniform(2, 2, 99);

    ASSERT_EQ(ocvu_insert_channel(replacement, target, 1), OCVU_STATUS_OK);

    // channel 1 だけが 99 になり、他は元のままである。
    const std::vector<uint8_t> pixels = ReadPixels(target);
    ASSERT_EQ(pixels.size(), 16u);
    for (int i = 0; i < 4; ++i) {
        EXPECT_EQ(pixels[static_cast<size_t>(i) * 4 + 0], i * 10 + 0);
        EXPECT_EQ(pixels[static_cast<size_t>(i) * 4 + 1], 99) << "画素 " << i;
        EXPECT_EQ(pixels[static_cast<size_t>(i) * 4 + 2], i * 10 + 2);
        EXPECT_EQ(pixels[static_cast<size_t>(i) * 4 + 3], i * 10 + 3);
    }

    EXPECT_EQ(ocvu_mat_release(target), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(replacement), OCVU_STATUS_OK);
}

TEST(CoreOps, ChannelFunctionsRejectBadArguments) {
    const ocvu_mat_handle src = MakeFourChannel();
    const ocvu_mat_handle single = MakeUniform(2, 2, 5);
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    // channel の索引が範囲外。**4 channel なので 0..3 だけが有効である。**
    EXPECT_EQ(ocvu_extract_channel(src, dst, -1), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_extract_channel(src, dst, 4), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_insert_channel(single, src, -1), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_insert_channel(single, src, 4), OCVU_STATUS_INVALID_ARGUMENT);

    EXPECT_EQ(ocvu_extract_channel(OCVU_MAT_HANDLE_NONE, dst, 0), OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_extract_channel(src, OCVU_MAT_HANDLE_NONE, 0), OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_insert_channel(OCVU_MAT_HANDLE_NONE, src, 0), OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_insert_channel(single, OCVU_MAT_HANDLE_NONE, 0), OCVU_STATUS_INVALID_HANDLE);

    // **src と dst が同じ handle なのは誤りである** —— channel を自分自身から
    // 取り出したり差し込んだりする意味が無く、OpenCV の挙動も保証されない。
    EXPECT_EQ(ocvu_extract_channel(src, src, 0), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_insert_channel(src, src, 0), OCVU_STATUS_INVALID_ARGUMENT);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(single), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}
```

`native/tests/CMakeLists.txt` の一覧に `test_core_ops.cpp` を足す。

- [ ] **Step 2: RED を目で確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: **コンパイルエラー**（`ocvu_extract_channel` が未定義）。

- [ ] **Step 3: spec に 2 エントリ足して生成する**

`bindings/spec/core.json` の `functions` に足す。

```json
{
  "name": "ocvu_extract_channel",
  "summary": "src の 1 つの channel を取り出して dst に入れる。dst は結果に応じて丸ごと置き換わり、src と同じ大きさの 1 channel になる。channel_index は 0 以上かつ src の channel 数未満でなければならず、範囲外なら OCVU_STATUS_INVALID_ARGUMENT を返す。**src と dst に同じ handle を渡してはならない** —— 自分自身から channel を取り出す意味が無く、OCVU_STATUS_INVALID_ARGUMENT を返す。handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、失敗したときは dst を書き換えない。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "dst", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "channel_index", "cType": "int32_t", "csType": "int", "direction": "in" }
  ]
},
{
  "name": "ocvu_insert_channel",
  "summary": "src（1 channel）を dst の 1 つの channel へ差し込む。**dst は置き換わるのではなく、その channel だけが書き換わる** —— 他の channel と大きさは元のままである（ocvu_extract_channel と対になる唯一の非置換の関数である）。src は 1 channel で、dst と同じ大きさ・同じ要素型でなければならない。channel_index は 0 以上かつ dst の channel 数未満でなければならず、範囲外なら OCVU_STATUS_INVALID_ARGUMENT を返す。**src と dst に同じ handle を渡してはならない。** handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返す。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "dst", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "channel_index", "cType": "int32_t", "csType": "int", "direction": "in" }
  ]
}
```

```
pwsh tools/dev.ps1 generate
```

- [ ] **Step 4: 実装する**

`native/src/ocvu_core_ops.cpp` を新規作成する。

```cpp
// core module の基本演算。
//
// **ocvu_mat.cpp にも ocvu_mat_buffer.cpp にも足していない。** あちらは
// Mat のライフサイクルと buffer の受け渡しで、こちらは画素に対する演算である。

#include <opencv_unity_native.h>

#include <opencv2/core.hpp>

#include <cstdint>
#include <vector>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

extern "C" ocvu_status ocvu_extract_channel(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t channel_index) {
    OCVU_TRY_BEGIN
    // **同じ handle を先に断る。** table から 2 回引く前に分かる誤りである。
    if (src == dst) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_extract_channel: src and dst must be different handles");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_extract_channel: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_extract_channel: dst handle is invalid");
    }

    // **範囲は自分で見る。** OpenCV に落とすと例外になるが、呼ぶ側が直せる
    // 誤りなので INVALID_ARGUMENT で返す。
    if (channel_index < 0 || channel_index >= src_mat->channels()) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_extract_channel: channel_index is out of range for src");
    }

    cv::Mat result;
    try {
        cv::extractChannel(*src_mat, result, channel_index);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_insert_channel(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t channel_index) {
    OCVU_TRY_BEGIN
    if (src == dst) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_insert_channel: src and dst must be different handles");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_insert_channel: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_insert_channel: dst handle is invalid");
    }

    if (channel_index < 0 || channel_index >= dst_mat->channels()) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_insert_channel: channel_index is out of range for dst");
    }

    // **この 1 本だけは dst を置き換えず、その場を書き換える。**
    // 失敗したときに dst が途中まで変わりうるので、写しに対して行ってから戻す。
    cv::Mat working = dst_mat->clone();
    try {
        cv::insertChannel(*src_mat, working, channel_index);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = working;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

`native/CMakeLists.txt` の `OCVU_SOURCES` に `src/ocvu_core_ops.cpp` を足す。

- [ ] **Step 5: L1 を緑にする**

```
pwsh tools/dev.ps1 test-native
```

期待: `CoreOps.*` が 3 件 pass、exit 0。

- [ ] **Step 6: コミット**

```bash
git add native/tests/test_core_ops.cpp native/tests/CMakeLists.txt \
        native/src/ocvu_core_ops.cpp native/CMakeLists.txt \
        bindings/spec/core.json native/include/ocvu/core.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Core.g.cs \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(core): channel を取り出す・差し込む 2 本を出す"
```

---

## Task 2: `ocvu_min_max_loc` と `ocvu_in_range`

**Files:**
- Modify: `native/tests/test_core_ops.cpp`、`native/src/ocvu_core_ops.cpp`、`bindings/spec/core.json`

**Interfaces:**
- Consumes: `MakeUniform` / `ReadPixels`（Task 1）
- Produces:
  - `ocvu_status ocvu_min_max_loc(ocvu_mat_handle src, double* out_min_value, double* out_max_value, int32_t* out_min_location, int32_t* out_max_location)`
  - `ocvu_status ocvu_in_range(ocvu_mat_handle src, ocvu_mat_handle dst, const double* lower, int64_t lower_length, const double* upper, int64_t upper_length)`

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_core_ops.cpp` の末尾に足す。

```cpp
namespace {

// 3x3 の 1 channel 画像。中央に 200、左上に 5、他は 100。
ocvu_mat_handle MakeExtremes() {
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(3, 3, OCVU_MAT_TYPE_8UC1, &handle), OCVU_STATUS_OK);
    std::array<uint8_t, 9> pixels{};
    for (uint8_t& p : pixels) p = 100;
    pixels[0] = 5;          // (x=0, y=0)
    pixels[1 * 3 + 1] = 200;  // (x=1, y=1)
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(), 9, 3), OCVU_STATUS_OK);
    return handle;
}

}  // namespace

TEST(CoreOps, MinMaxLocFindsBothExtremesAndTheirPositions) {
    const ocvu_mat_handle src = MakeExtremes();

    double min_value = -1.0;
    double max_value = -1.0;
    std::array<int32_t, 2> min_loc{-1, -1};
    std::array<int32_t, 2> max_loc{-1, -1};

    ASSERT_EQ(ocvu_min_max_loc(src, &min_value, &max_value, min_loc.data(), max_loc.data()),
              OCVU_STATUS_OK);

    EXPECT_DOUBLE_EQ(min_value, 5.0);
    EXPECT_DOUBLE_EQ(max_value, 200.0);
    // **位置は x, y の順である。**
    EXPECT_EQ(min_loc[0], 0);
    EXPECT_EQ(min_loc[1], 0);
    EXPECT_EQ(max_loc[0], 1);
    EXPECT_EQ(max_loc[1], 1);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
}

TEST(CoreOps, MinMaxLocAllowsAskingForOnlySomeOutputs) {
    const ocvu_mat_handle src = MakeExtremes();

    // 最大値だけ欲しいのは普通のことなので、他は NULL でよい。
    double max_value = -1.0;
    EXPECT_EQ(ocvu_min_max_loc(src, nullptr, &max_value, nullptr, nullptr), OCVU_STATUS_OK);
    EXPECT_DOUBLE_EQ(max_value, 200.0);

    // **全部 NULL は誤りである** —— 何も受け取らずに計算だけさせる意味が無い。
    EXPECT_EQ(ocvu_min_max_loc(src, nullptr, nullptr, nullptr, nullptr),
              OCVU_STATUS_NULL_POINTER);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
}

TEST(CoreOps, MinMaxLocZeroesTheOutputsOnFailure) {
    // **0 ではない値で汚してから呼ぶ。**
    double min_value = 12345.0;
    double max_value = 12345.0;
    std::array<int32_t, 2> min_loc{12345, 12345};
    std::array<int32_t, 2> max_loc{12345, 12345};

    EXPECT_EQ(ocvu_min_max_loc(OCVU_MAT_HANDLE_NONE, &min_value, &max_value,
                               min_loc.data(), max_loc.data()),
              OCVU_STATUS_INVALID_HANDLE);

    EXPECT_DOUBLE_EQ(min_value, 0.0) << "失敗時は 0 を書くこと";
    EXPECT_DOUBLE_EQ(max_value, 0.0);
    EXPECT_EQ(min_loc[0], 0);
    EXPECT_EQ(min_loc[1], 0);
    EXPECT_EQ(max_loc[0], 0);
    EXPECT_EQ(max_loc[1], 0);
}

TEST(CoreOps, InRangeMarksThePixelsInsideTheBounds) {
    const ocvu_mat_handle src = MakeExtremes();
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    // 50..150 の間だけ 255 にする。5 と 200 は外れ、100 が 7 個残る。
    const std::array<double, 1> lower{50.0};
    const std::array<double, 1> upper{150.0};

    ASSERT_EQ(ocvu_in_range(src, dst,
                            lower.data(), static_cast<int64_t>(sizeof(lower)),
                            upper.data(), static_cast<int64_t>(sizeof(upper))),
              OCVU_STATUS_OK);

    const std::vector<uint8_t> pixels = ReadPixels(dst);
    ASSERT_EQ(pixels.size(), 9u);
    int lit = 0;
    for (uint8_t p : pixels) if (p == 255) ++lit;
    EXPECT_EQ(lit, 7) << "100 の画素が 7 個あるはずである";
    EXPECT_EQ(pixels[0], 0) << "5 は範囲外である";
    EXPECT_EQ(pixels[1 * 3 + 1], 0) << "200 は範囲外である";

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(CoreOps, InRangeRejectsBadArguments) {
    const ocvu_mat_handle src = MakeExtremes();
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);
    const std::array<double, 1> bound{50.0};
    const int64_t bytes = static_cast<int64_t>(sizeof(bound));

    EXPECT_EQ(ocvu_in_range(src, dst, nullptr, bytes, bound.data(), bytes),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_in_range(src, dst, bound.data(), bytes, nullptr, bytes),
              OCVU_STATUS_NULL_POINTER);

    // **長さはバイト数である。** src の channel 数ぶんの double が要る（ここでは 1 個）。
    EXPECT_EQ(ocvu_in_range(src, dst, bound.data(), bytes - 1, bound.data(), bytes),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_in_range(src, dst, bound.data(), bytes, bound.data(), bytes - 1),
              OCVU_STATUS_INVALID_ARGUMENT);

    EXPECT_EQ(ocvu_in_range(OCVU_MAT_HANDLE_NONE, dst, bound.data(), bytes, bound.data(), bytes),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_in_range(src, OCVU_MAT_HANDLE_NONE, bound.data(), bytes, bound.data(), bytes),
              OCVU_STATUS_INVALID_HANDLE);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
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
  "name": "ocvu_min_max_loc",
  "summary": "src の最小値・最大値と、それぞれが最初に現れる位置を返す。**4 つの出力はどれも NULL でよい**（最大値だけ欲しいことは普通にある）が、**4 つとも NULL なら OCVU_STATUS_NULL_POINTER を返す** —— 何も受け取らずに計算だけさせる意味が無いためである。out_min_location と out_max_location は int32_t 2 個ぶんの領域で、**x が先、y が後**の順に書く（呼ぶ側が 2 要素を確保すること。1 要素しか無い領域を渡すと踏み越えるが、native からは長さが分からない）。**どの失敗経路でも、NULL でないすべての出力に 0 を書く。** src は 1 channel でなければならない（複数 channel では最小最大が一意に決まらないので OpenCV が例外を投げ、OCVU_STATUS_OPENCV_ERROR になる）。handle が無効なら OCVU_STATUS_INVALID_HANDLE。出力の所有権は最初から最後まで呼ぶ側にある。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "out_min_value", "cType": "double*", "csType": "double[]", "direction": "out-buffer" },
    { "name": "out_max_value", "cType": "double*", "csType": "double[]", "direction": "out-buffer" },
    { "name": "out_min_location", "cType": "int32_t*", "csType": "int[]", "direction": "out-buffer" },
    { "name": "out_max_location", "cType": "int32_t*", "csType": "int[]", "direction": "out-buffer" }
  ]
},
{
  "name": "ocvu_in_range",
  "summary": "src の各画素が lower と upper の間（両端を含む）にあるかを調べ、入っていれば 255、外れていれば 0 を dst に書く。dst は結果に応じて丸ごと置き換わり、src と同じ大きさの 8 bit 1 channel になる。lower と upper は src の channel 数ぶんの double を並べた配列で、lower_length と upper_length はその**バイト数**である（要素数でも channel 数でもない）。**呼ぶ側を信用せず、src の channel 数ぶんに満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。** 複数 channel の場合は**すべての channel が範囲に入っている画素だけ**が 255 になる。src と dst に同じ handle を渡してもよい。handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、失敗したときは dst を書き換えない。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "dst", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "lower", "cType": "const double*", "csType": "double[]", "direction": "in-buffer" },
    { "name": "lower_length", "cType": "int64_t", "csType": "long", "direction": "in" },
    { "name": "upper", "cType": "const double*", "csType": "double[]", "direction": "in-buffer" },
    { "name": "upper_length", "cType": "int64_t", "csType": "long", "direction": "in" }
  ]
}
```

```
pwsh tools/dev.ps1 generate
```

- [ ] **Step 4: 実装する**

`native/src/ocvu_core_ops.cpp` の末尾に足す。

```cpp
extern "C" ocvu_status ocvu_min_max_loc(ocvu_mat_handle src, double* out_min_value, double* out_max_value, int32_t* out_min_location, int32_t* out_max_location) {
    OCVU_TRY_BEGIN
    // **NULL でないものには、何よりも先に 0 を書く。** どの経路で返っても、
    // 呼ぶ側が読む値が前回のまま残らないようにする。
    if (out_min_value != nullptr) *out_min_value = 0.0;
    if (out_max_value != nullptr) *out_max_value = 0.0;
    if (out_min_location != nullptr) { out_min_location[0] = 0; out_min_location[1] = 0; }
    if (out_max_location != nullptr) { out_max_location[0] = 0; out_max_location[1] = 0; }

    // **全部 NULL は誤りである。** 何も受け取らずに計算だけさせる意味が無い。
    if (out_min_value == nullptr && out_max_value == nullptr &&
        out_min_location == nullptr && out_max_location == nullptr) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_NULL_POINTER,
            "ocvu_min_max_loc: at least one output must not be NULL");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_min_max_loc: src handle is invalid");
    }

    // **求めてから書く。** 例外になったときに一部だけ書かれた状態にしない。
    double min_value = 0.0;
    double max_value = 0.0;
    cv::Point min_point;
    cv::Point max_point;
    try {
        cv::minMaxLoc(*src_mat, &min_value, &max_value, &min_point, &max_point);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    if (out_min_value != nullptr) *out_min_value = min_value;
    if (out_max_value != nullptr) *out_max_value = max_value;
    if (out_min_location != nullptr) {
        out_min_location[0] = min_point.x;
        out_min_location[1] = min_point.y;
    }
    if (out_max_location != nullptr) {
        out_max_location[0] = max_point.x;
        out_max_location[1] = max_point.y;
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_in_range(ocvu_mat_handle src, ocvu_mat_handle dst, const double* lower, int64_t lower_length, const double* upper, int64_t upper_length) {
    OCVU_TRY_BEGIN
    if (lower == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_in_range: lower is NULL");
    }
    if (upper == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_in_range: upper is NULL");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_in_range: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_in_range: dst handle is invalid");
    }

    // **必要量は src の channel 数で決まる。** handle を引いてからでないと分からない。
    const int64_t needed =
        static_cast<int64_t>(src_mat->channels()) * static_cast<int64_t>(sizeof(double));
    if (lower_length < needed) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_in_range: lower_length (bytes) is too small for the channel count of src");
    }
    if (upper_length < needed) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_in_range: upper_length (bytes) is too small for the channel count of src");
    }

    // cv::Scalar は 4 要素固定。channel 数ぶんだけ写し、残りは 0 のままにする。
    cv::Scalar lower_scalar;
    cv::Scalar upper_scalar;
    const int channels = src_mat->channels();
    for (int i = 0; i < channels && i < 4; ++i) {
        lower_scalar[i] = lower[i];
        upper_scalar[i] = upper[i];
    }

    cv::Mat result;
    try {
        cv::inRange(*src_mat, lower_scalar, upper_scalar, result);
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

期待: `CoreOps.*` が 8 件 pass、exit 0。

- [ ] **Step 6: 検査が働くことを確かめる**

1. `ocvu_min_max_loc` の冒頭の 4 行の 0 埋めを消す
2. `pwsh tools/dev.ps1 test-native` → **`MinMaxLocZeroesTheOutputsOnFailure` が
   落ちること**を目で見る
3. 戻して緑に戻ることを確認する

- [ ] **Step 7: コミット**

```bash
git add native/tests/test_core_ops.cpp native/src/ocvu_core_ops.cpp \
        bindings/spec/core.json native/include/ocvu/core.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Core.g.cs \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(core): 最小最大の探索と範囲抽出の 2 本を出す"
```

---

## Task 3: `ocvu_bitwise` と `ocvu_lut`

**Files:**
- Modify: `native/tests/test_core_ops.cpp`、`native/src/ocvu_core_ops.cpp`、`bindings/spec/core.json`、`native/include/opencv_unity_native.h`

**Interfaces:**
- Produces:
  - `ocvu_status ocvu_bitwise(ocvu_mat_handle src1, ocvu_mat_handle src2, ocvu_mat_handle dst, int32_t op)`
  - `ocvu_status ocvu_lut(ocvu_mat_handle src, ocvu_mat_handle dst, const uint8_t* table, int64_t table_length)`

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_core_ops.cpp` の末尾に足す。

```cpp
TEST(CoreOps, BitwiseAndOrXorProduceTheExpectedValues) {
    // 0b1100 と 0b1010 の組み合わせ。**手で計算できる。**
    const ocvu_mat_handle a = MakeUniform(2, 2, 0b1100);
    const ocvu_mat_handle b = MakeUniform(2, 2, 0b1010);
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    ASSERT_EQ(ocvu_bitwise(a, b, dst, OCVU_BITWISE_AND), OCVU_STATUS_OK);
    for (uint8_t p : ReadPixels(dst)) EXPECT_EQ(p, 0b1000);

    ASSERT_EQ(ocvu_bitwise(a, b, dst, OCVU_BITWISE_OR), OCVU_STATUS_OK);
    for (uint8_t p : ReadPixels(dst)) EXPECT_EQ(p, 0b1110);

    ASSERT_EQ(ocvu_bitwise(a, b, dst, OCVU_BITWISE_XOR), OCVU_STATUS_OK);
    for (uint8_t p : ReadPixels(dst)) EXPECT_EQ(p, 0b0110);

    EXPECT_EQ(ocvu_mat_release(a), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(b), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(CoreOps, BitwiseNotIgnoresTheSecondSource) {
    const ocvu_mat_handle a = MakeUniform(2, 2, 0b00001111);
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    // **NOT は src2 を見ない。** 無効な handle を渡しても通ることで、
    // 「無視する」という契約を実証する。
    ASSERT_EQ(ocvu_bitwise(a, OCVU_MAT_HANDLE_NONE, dst, OCVU_BITWISE_NOT), OCVU_STATUS_OK);
    for (uint8_t p : ReadPixels(dst)) EXPECT_EQ(p, 0b11110000);

    EXPECT_EQ(ocvu_mat_release(a), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(CoreOps, BitwiseRejectsBadArguments) {
    const ocvu_mat_handle a = MakeUniform(2, 2, 1);
    const ocvu_mat_handle b = MakeUniform(2, 2, 2);
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_bitwise(a, b, dst, 99), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_bitwise(OCVU_MAT_HANDLE_NONE, b, dst, OCVU_BITWISE_AND),
              OCVU_STATUS_INVALID_HANDLE);
    // **AND では src2 が要る。** NOT と違ってここは無効を通さない。
    EXPECT_EQ(ocvu_bitwise(a, OCVU_MAT_HANDLE_NONE, dst, OCVU_BITWISE_AND),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_bitwise(a, b, OCVU_MAT_HANDLE_NONE, OCVU_BITWISE_AND),
              OCVU_STATUS_INVALID_HANDLE);

    EXPECT_EQ(ocvu_mat_release(a), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(b), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(CoreOps, LutReplacesEveryValueThroughTheTable) {
    const ocvu_mat_handle src = MakeUniform(2, 2, 3);
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    // 索引 i を 255 - i にする表。値 3 は 252 になる。
    std::array<uint8_t, 256> table{};
    for (int i = 0; i < 256; ++i) table[static_cast<size_t>(i)] = static_cast<uint8_t>(255 - i);

    ASSERT_EQ(ocvu_lut(src, dst, table.data(), 256), OCVU_STATUS_OK);
    for (uint8_t p : ReadPixels(dst)) EXPECT_EQ(p, 252);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(CoreOps, LutRejectsBadArguments) {
    const ocvu_mat_handle src = MakeUniform(2, 2, 3);
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);
    std::array<uint8_t, 256> table{};

    EXPECT_EQ(ocvu_lut(src, dst, nullptr, 256), OCVU_STATUS_NULL_POINTER);
    // **表はちょうど 256 バイト要る。** 8 bit の値域を全部覆う必要がある。
    EXPECT_EQ(ocvu_lut(src, dst, table.data(), 255), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_lut(OCVU_MAT_HANDLE_NONE, dst, table.data(), 256), OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_lut(src, OCVU_MAT_HANDLE_NONE, table.data(), 256), OCVU_STATUS_INVALID_HANDLE);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}
```

- [ ] **Step 2: RED を目で確認する**

```
pwsh tools/dev.ps1 test-native
```

- [ ] **Step 3: 定数をヘッダに足す**

`native/include/opencv_unity_native.h` に足す。

```c
/* ocvu_bitwise の演算。
 *
 * **これは OpenCV の定数の写しではない。** cv::bitwise_and などは関数であって
 * 定数ではないので、対応する値が上流に存在しない。**この 4 つはこちらが決めた値**
 * であり、したがって static_assert で固定することもできない（固定する相手が無い）。
 *
 * OCVU_BITWISE_NOT のときだけ src2 を見ない。 */
#define OCVU_BITWISE_AND 0
#define OCVU_BITWISE_OR  1
#define OCVU_BITWISE_XOR 2
#define OCVU_BITWISE_NOT 3

/* ocvu_normalize の正規化の仕方。cv::NormTypes の値をそのまま使う
 * （実装 .cpp の static_assert が写し間違いをコンパイル時に落とす）。
 *
 * MINMAX は値域を [alpha, beta] へ線形に写す。**画像を見るために使うのは
 * ふつうこれである。** INF / L1 / L2 はノルムが alpha になるように割る。 */
#define OCVU_NORM_INF     1
#define OCVU_NORM_L1      2
#define OCVU_NORM_L2      4
#define OCVU_NORM_MINMAX 32
```

- [ ] **Step 4: spec に 2 エントリ足して生成する**

```json
{
  "name": "ocvu_bitwise",
  "summary": "src1 と src2 のビット演算（AND / OR / XOR）、または src1 のビット反転（NOT）を dst に入れる。dst は結果に応じて丸ごと置き換わり、src1 と同じ形状・型になる。op は OCVU_BITWISE_* のいずれかで、それ以外は OCVU_STATUS_INVALID_ARGUMENT を返す。**OCVU_BITWISE_NOT のときは src2 を一切見ない** —— 無効な handle を渡しても成功する（黙って無視するのではなく、そう決めてある）。他の 3 つでは src2 の handle が無効なら OCVU_STATUS_INVALID_HANDLE を返す。src1 と src2 は同じ形状・同じ型でなければならず、違えば OpenCV が例外を投げるので OCVU_STATUS_OPENCV_ERROR になる。src と dst に同じ handle を渡してもよい。失敗したときは dst を書き換えない。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "src1", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "src2", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "dst", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "op", "cType": "int32_t", "csType": "int", "direction": "in" }
  ]
},
{
  "name": "ocvu_lut",
  "summary": "src の各画素の値を表で引いた値に置き換えて dst に入れる。dst は結果に応じて丸ごと置き換わり、src と同じ形状・型になる。table は 8 bit の値域（0 から 255）を全部覆う 256 バイトでなければならず、table_length はその**バイト数**である（要素数ではない —— この型では同じ値になるが、この ABI の length はすべてバイト数で統一してある）。**256 に満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。** src は 8 bit でなければならず、そうでなければ OpenCV が例外を投げるので OCVU_STATUS_OPENCV_ERROR になる。複数 channel の src には同じ表がすべての channel に適用される。src と dst に同じ handle を渡してもよい。handle が無効なら OCVU_STATUS_INVALID_HANDLE。失敗したときは dst を書き換えない。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "dst", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "table", "cType": "const uint8_t*", "csType": "byte[]", "direction": "in-buffer" },
    { "name": "table_length", "cType": "int64_t", "csType": "long", "direction": "in" }
  ]
}
```

```
pwsh tools/dev.ps1 generate
```

- [ ] **Step 5: 実装する**

`native/src/ocvu_core_ops.cpp` の末尾に足す。

```cpp
extern "C" ocvu_status ocvu_bitwise(ocvu_mat_handle src1, ocvu_mat_handle src2, ocvu_mat_handle dst, int32_t op) {
    OCVU_TRY_BEGIN
    if (op != OCVU_BITWISE_AND && op != OCVU_BITWISE_OR &&
        op != OCVU_BITWISE_XOR && op != OCVU_BITWISE_NOT) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_bitwise: op is not one of OCVU_BITWISE_*");
    }

    const cv::Mat* src1_mat = ::ocvu::mat_table_get(src1);
    if (src1_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_bitwise: src1 handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_bitwise: dst handle is invalid");
    }

    // **NOT のときだけ src2 を見ない。** そう決めてあるので、無効でも通す。
    const cv::Mat* src2_mat = nullptr;
    if (op != OCVU_BITWISE_NOT) {
        src2_mat = ::ocvu::mat_table_get(src2);
        if (src2_mat == nullptr) {
            return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                          "ocvu_bitwise: src2 handle is invalid");
        }
    }

    cv::Mat result;
    try {
        switch (op) {
            case OCVU_BITWISE_AND: cv::bitwise_and(*src1_mat, *src2_mat, result); break;
            case OCVU_BITWISE_OR:  cv::bitwise_or(*src1_mat, *src2_mat, result); break;
            case OCVU_BITWISE_XOR: cv::bitwise_xor(*src1_mat, *src2_mat, result); break;
            default:               cv::bitwise_not(*src1_mat, result); break;
        }
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_lut(ocvu_mat_handle src, ocvu_mat_handle dst, const uint8_t* table, int64_t table_length) {
    OCVU_TRY_BEGIN
    if (table == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER, "ocvu_lut: table is NULL");
    }
    // **8 bit の値域を全部覆う必要がある。** 足りない表を渡されると
    // OpenCV が表の外を読む。
    if (table_length < 256) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_lut: table_length (bytes) must be at least 256");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_lut: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_lut: dst handle is invalid");
    }

    // 借用はこの呼び出しの内側で完結する。
    const cv::Mat table_view(1, 256, CV_8U, const_cast<uint8_t*>(table));

    cv::Mat result;
    try {
        cv::LUT(*src_mat, table_view, result);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

- [ ] **Step 6: L1 を緑にする**

```
pwsh tools/dev.ps1 test-native
```

期待: `CoreOps.*` が 13 件 pass、exit 0。

- [ ] **Step 7: コミット**

```bash
git add native/tests/test_core_ops.cpp native/src/ocvu_core_ops.cpp \
        native/include/opencv_unity_native.h bindings/spec/core.json \
        native/include/ocvu/core.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Core.g.cs \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(core): 論理演算とルックアップ変換の 2 本を出す"
```

---

## Task 4: `ocvu_normalize` と `ocvu_copy_make_border`

**Files:**
- Modify: `native/tests/test_core_ops.cpp`、`native/src/ocvu_core_ops.cpp`、`bindings/spec/core.json`

**Interfaces:**
- Produces:
  - `ocvu_status ocvu_normalize(ocvu_mat_handle src, ocvu_mat_handle dst, double alpha, double beta, int32_t norm_type)`
  - `ocvu_status ocvu_copy_make_border(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t top, int32_t bottom, int32_t left, int32_t right, int32_t border_type, double border_value)`

**`OCVU_BORDER_*` は Phase 2 が足す。** この Phase が先なら、
Phase 2 の Task 1 Step 3 に載っている 5 行をここで足すこと。

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_core_ops.cpp` の末尾に足す。

```cpp
TEST(CoreOps, NormalizeMinMaxStretchesToTheGivenRange) {
    // 5 と 200 を含む画像を 0..255 へ引き伸ばすと、最小が 0、最大が 255 になる。
    const ocvu_mat_handle src = MakeExtremes();
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    ASSERT_EQ(ocvu_normalize(src, dst, 0.0, 255.0, OCVU_NORM_MINMAX), OCVU_STATUS_OK);

    double min_value = -1.0;
    double max_value = -1.0;
    ASSERT_EQ(ocvu_min_max_loc(dst, &min_value, &max_value, nullptr, nullptr),
              OCVU_STATUS_OK);
    EXPECT_DOUBLE_EQ(min_value, 0.0);
    EXPECT_DOUBLE_EQ(max_value, 255.0);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(CoreOps, NormalizeRejectsBadArguments) {
    const ocvu_mat_handle src = MakeExtremes();
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_normalize(src, dst, 0.0, 255.0, 99), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_normalize(OCVU_MAT_HANDLE_NONE, dst, 0.0, 255.0, OCVU_NORM_MINMAX),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_normalize(src, OCVU_MAT_HANDLE_NONE, 0.0, 255.0, OCVU_NORM_MINMAX),
              OCVU_STATUS_INVALID_HANDLE);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(CoreOps, CopyMakeBorderGrowsTheImageByTheGivenAmounts) {
    // 2x2 に上 1 / 下 2 / 左 3 / 右 4 を足すと 5x9 になる。**手で数えられる。**
    const ocvu_mat_handle src = MakeUniform(2, 2, 128);
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    ASSERT_EQ(ocvu_copy_make_border(src, dst, 1, 2, 3, 4, OCVU_BORDER_CONSTANT, 7.0),
              OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 5);
    EXPECT_EQ(info.cols, 9);

    const std::vector<uint8_t> pixels = ReadPixels(dst);
    // 左上の隅は余白なので border_value が入る。
    EXPECT_EQ(pixels[0], 7);
    // 元の画像は (row 1, col 3) から始まる。
    EXPECT_EQ(pixels[static_cast<size_t>(1) * 9 + 3], 128);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(CoreOps, CopyMakeBorderRejectsBadArguments) {
    const ocvu_mat_handle src = MakeUniform(2, 2, 128);
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    // 負の余白は誤りである。
    EXPECT_EQ(ocvu_copy_make_border(src, dst, -1, 0, 0, 0, OCVU_BORDER_CONSTANT, 0.0),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_copy_make_border(src, dst, 0, -1, 0, 0, OCVU_BORDER_CONSTANT, 0.0),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_copy_make_border(src, dst, 0, 0, -1, 0, OCVU_BORDER_CONSTANT, 0.0),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_copy_make_border(src, dst, 0, 0, 0, -1, OCVU_BORDER_CONSTANT, 0.0),
              OCVU_STATUS_INVALID_ARGUMENT);

    EXPECT_EQ(ocvu_copy_make_border(src, dst, 1, 1, 1, 1, 99, 0.0),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_copy_make_border(OCVU_MAT_HANDLE_NONE, dst, 1, 1, 1, 1,
                                    OCVU_BORDER_CONSTANT, 0.0),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_copy_make_border(src, OCVU_MAT_HANDLE_NONE, 1, 1, 1, 1,
                                    OCVU_BORDER_CONSTANT, 0.0),
              OCVU_STATUS_INVALID_HANDLE);

    EXPECT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);
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
  "name": "ocvu_normalize",
  "summary": "src の値域を正規化して dst に入れる。dst は結果に応じて丸ごと置き換わり、**src と同じ型になる**（この ABI は型変換を持ち込まないので、出力の型を選ぶ引数を出していない）。norm_type は OCVU_NORM_* のいずれかで、それ以外は OCVU_STATUS_INVALID_ARGUMENT を返す。OCVU_NORM_MINMAX のときは値域を alpha と beta の間へ線形に写す（画像を見えるようにするのはふつうこれである）。他の 3 つのときは指定したノルムが alpha になるように割り、beta は使わない。src と dst に同じ handle を渡してもよい。handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、失敗したときは dst を書き換えない。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "dst", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "alpha", "cType": "double", "csType": "double", "direction": "in" },
    { "name": "beta", "cType": "double", "csType": "double", "direction": "in" },
    { "name": "norm_type", "cType": "int32_t", "csType": "int", "direction": "in" }
  ]
},
{
  "name": "ocvu_copy_make_border",
  "summary": "src の周囲に余白を足して dst に入れる。dst は結果に応じて丸ごと置き換わり、(src の高さ + top + bottom) x (src の幅 + left + right) で src と同じ型になる。top / bottom / left / right はいずれも 0 以上でなければならず、負なら OCVU_STATUS_INVALID_ARGUMENT を返す。border_type は OCVU_BORDER_* のいずれかで、それ以外は拒否する。border_value は OCVU_BORDER_CONSTANT のときにだけ使う埋め値で、**全 channel に同じ値が入る**（channel ごとに違う値を入れる経路は出していない）。src と dst に同じ handle を渡してもよい。handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、失敗したときは dst を書き換えない。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "dst", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "top", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "bottom", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "left", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "right", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "border_type", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "border_value", "cType": "double", "csType": "double", "direction": "in" }
  ]
}
```

```
pwsh tools/dev.ps1 generate
```

- [ ] **Step 4: 実装する**

`native/src/ocvu_core_ops.cpp` の先頭に static_assert を足す。

```cpp
static_assert(OCVU_NORM_INF == cv::NORM_INF, "NORM_INF がずれている");
static_assert(OCVU_NORM_L1 == cv::NORM_L1, "NORM_L1 がずれている");
static_assert(OCVU_NORM_L2 == cv::NORM_L2, "NORM_L2 がずれている");
static_assert(OCVU_NORM_MINMAX == cv::NORM_MINMAX, "NORM_MINMAX がずれている");
static_assert(OCVU_BORDER_CONSTANT == cv::BORDER_CONSTANT, "BORDER_CONSTANT がずれている");
static_assert(OCVU_BORDER_REPLICATE == cv::BORDER_REPLICATE, "BORDER_REPLICATE がずれている");
static_assert(OCVU_BORDER_REFLECT == cv::BORDER_REFLECT, "BORDER_REFLECT がずれている");
static_assert(OCVU_BORDER_WRAP == cv::BORDER_WRAP, "BORDER_WRAP がずれている");
static_assert(OCVU_BORDER_REFLECT_101 == cv::BORDER_REFLECT_101, "BORDER_REFLECT_101 がずれている");
```

ファイル末尾に実装を足す。

```cpp
extern "C" ocvu_status ocvu_normalize(ocvu_mat_handle src, ocvu_mat_handle dst, double alpha, double beta, int32_t norm_type) {
    OCVU_TRY_BEGIN
    if (norm_type != OCVU_NORM_INF && norm_type != OCVU_NORM_L1 &&
        norm_type != OCVU_NORM_L2 && norm_type != OCVU_NORM_MINMAX) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_normalize: norm_type is not one of OCVU_NORM_*");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_normalize: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_normalize: dst handle is invalid");
    }

    cv::Mat result;
    try {
        // **dtype は -1 に固定する。** この ABI が扱う型は OCVU_MAT_TYPE_* の
        // 3 つだけなので、型変換を持ち込むと表現できない出力が作れてしまう。
        cv::normalize(*src_mat, result, alpha, beta, norm_type, -1);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_copy_make_border(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t top, int32_t bottom, int32_t left, int32_t right, int32_t border_type, double border_value) {
    OCVU_TRY_BEGIN
    if (top < 0 || bottom < 0 || left < 0 || right < 0) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_copy_make_border: top, bottom, left and right must not be negative");
    }
    if (border_type < OCVU_BORDER_CONSTANT || border_type > OCVU_BORDER_REFLECT_101) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_copy_make_border: border_type is not one of OCVU_BORDER_*");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_copy_make_border: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_copy_make_border: dst handle is invalid");
    }

    cv::Mat result;
    try {
        cv::copyMakeBorder(*src_mat, result, top, bottom, left, right, border_type,
                           cv::Scalar::all(border_value));
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

期待: `CoreOps.*` が 17 件 pass、exit 0。

- [ ] **Step 6: ASan を回す**

```
pwsh tools/dev.ps1 test-asan
```

期待: exit 0。

- [ ] **Step 7: コミット**

```bash
git add native/tests/test_core_ops.cpp native/src/ocvu_core_ops.cpp \
        bindings/spec/core.json native/include/ocvu/core.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Core.g.cs \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(core): 正規化と余白付けの 2 本を出す"
```

---

## Task 5: C# の公開 API と L3

**Files:**
- Create: `Packages/.../Runtime/Core/CvCoreOps.cs`（+ `.meta`）、`tests/Managed/CvUnity.Tests.Managed/CoreOpsTests.cs`

**Interfaces:**
- Produces（すべて `CvCoreOps` の静的メソッド）:
  - `ExtractChannel(CvMat src, CvMat dst, int channelIndex)`
  - `InsertChannel(CvMat src, CvMat dst, int channelIndex)`
  - `MinMaxLoc(CvMat src)` → `CvMinMax`
  - `InRange(CvMat src, CvMat dst, double[] lower, double[] upper)`
  - `Normalize(CvMat src, CvMat dst, double alpha, double beta, CvNormType normType)`
  - `Bitwise(CvMat src1, CvMat src2, CvMat dst, CvBitwiseOp op)`
  - `BitwiseNot(CvMat src, CvMat dst)`
  - `Lut(CvMat src, CvMat dst, byte[] table)`
  - `CopyMakeBorder(CvMat src, CvMat dst, int top, int bottom, int left, int right, CvBorderMode borderType, double borderValue)`

- [ ] **Step 1: `CvCoreOps` を新規作成する**

**新しい値型 `CvMinMax` を作る。**

```csharp
    /// <summary>
    /// 最小値・最大値と、それぞれが最初に現れた位置。
    /// </summary>
    public readonly struct CvMinMax
    {
        /// <summary>最小値。</summary>
        public double MinValue { get; }

        /// <summary>最大値。</summary>
        public double MaxValue { get; }

        /// <summary>最小値が最初に現れた位置。</summary>
        public CvPoint2 MinLocation { get; }

        /// <summary>最大値が最初に現れた位置。</summary>
        public CvPoint2 MaxLocation { get; }

        /// <summary>4 つの値から結果を作る。</summary>
        public CvMinMax(double minValue, double maxValue,
                        CvPoint2 minLocation, CvPoint2 maxLocation)
        {
            MinValue = minValue;
            MaxValue = maxValue;
            MinLocation = minLocation;
            MaxLocation = maxLocation;
        }
    }
```

**enum を 3 つ足す**（`CvNormType` / `CvBitwiseOp`。`CvBorderMode` は
**Phase 2 が `CvOps.cs` に足す** ので、そちらが先なら再利用する ——
**2 つ作らないこと**。この Phase が先なら `CvCoreOps.cs` に置き、
Phase 2 はそれを使う）。

**`Bitwise` と `BitwiseNot` を分ける。** C の ABI は `op` で 1 本だが、
**C# では NOT だけ引数の数が違う**ほうが読みやすい ——
`Bitwise(a, null, dst, CvBitwiseOp.Not)` と書かせない。
`BitwiseNot` の中で `OCVU_MAT_HANDLE_NONE`（`0UL`）を渡す。

**`MinMaxLoc` は 4 つとも受け取る。** C 側は NULL を許すが、
**C# 側で部分的に受け取る形を出すと呼ぶ側の分岐が増える** ——
`CvMinMax` を 1 つ返すほうが単純である。

- [ ] **Step 2: L3 テストを書いて走らせる**

`tests/Managed/CvUnity.Tests.Managed/CoreOpsTests.cs` に、L1 と同じ検証を
C# から行うテストを書く。**最低限これを含める**:

- `ExtractChannelTakesTheRequestedChannel`
- `InsertChannelReplacesOnlyThatChannel`
- `MinMaxLocFindsBothExtremesAndTheirPositions`
- `InRangeMarksThePixelsInsideTheBounds`
- `NormalizeMinMaxStretchesToTheGivenRange`
- `BitwiseAndOrXorProduceTheExpectedValues`
- `BitwiseNotInvertsEveryBit`
- `LutReplacesEveryValueThroughTheTable`
- `LutRejectsAShortTable` — 255 バイトの表で `CvStatus.InvalidArgument`
- `CopyMakeBorderGrowsTheImageByTheGivenAmounts`
- `TheManagedEnumValuesMatchWhatNativeAccepts` — `CvNormType` と `CvBitwiseOp` の
  各値が native に拒否されず、定義に無い値（99）が
  `CvStatus.InvalidArgument` で拒否されること

```
pwsh tools/dev.ps1 test-managed
```

- [ ] **Step 3: 全レーンを回す**

```
pwsh tools/dev.ps1 test
pwsh tools/dev.ps1 test-asan
```

- [ ] **Step 4: コミット**

```bash
git add Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvCoreOps.cs \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvCoreOps.cs.meta \
        tests/Managed/CvUnity.Tests.Managed/CoreOpsTests.cs
git commit -m "feat(csharp): core の 8 本の公開 API を CvCoreOps として出す"
```

---

## Task 6: 文書とレビュー

- [ ] **Step 1: allowlist に §3.12 を足す**

`docs/abi-ownership-and-versioning.md` に **§3.12 core の基本演算**を足す。
**§3 の冒頭が数えている本数を直す。**

**`ocvu_insert_channel` が「dst を置き換えない唯一の関数」であることを明記する** ——
他はすべて `*dst_mat = result` で丸ごと置き換わるので、この 1 本だけ挙動が違う。

**`OCVU_BITWISE_*` が OpenCV の写しではないことも書く** ——
allowlist は「境界に出す値の正本」でもあるので、
どれが上流由来でどれがこちら由来かを区別できるようにする。

- [ ] **Step 2: API リファレンスに足す**

`docs/api-reference.md` の §1 と §2 に足す。
**§3「この allowlist に含まれないもの」に足したものが残っていないか確認する。**

- [ ] **Step 3: `CLAUDE.md` を直す**

- 「公開 ABI の内訳」の段落
- 「ファイル配置」の表の `native/src/` の行に `ocvu_core_ops.cpp`
- `docs/api-reference.md` の行の C# クラス一覧に `CvCoreOps`

- [ ] **Step 4: 大きさを測る**

```
pwsh tools/dev.ps1 build
ls -l Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/x86_64/opencv_unity_native.dll
```

**`core` は最初からリンクされているので、増分は最も小さいはずである** ——
そうでなければ理由を調べる。

- [ ] **Step 5: AI レビュー**

**この差分を書いていない別のエージェント**に、ブランチ全体の差分と
この計画と[全体設計](./2026-09-05-api-surface-expansion.md)を渡す。
指摘を直したら、スコープを絞った再レビュー。

- [ ] **Step 6: コミットして push、PR を作る**

PR 本文に書くもの:
- 何を成立させたか（8 本、OpenCV の再ビルドなし、`core` は元からリンク済み）
- 実測値（L1 / L3 の件数、ライブラリの大きさの差）
- **意図的に見送ったもの**（`split` / `merge`（`extractChannel` / `insertChannel` で
  代替できる）、算術演算（`add` / `subtract` / `multiply` / `divide`）、
  `compare`、`countNonZero`、`meanStdDev`、`transpose` / `flip`、
  `normalize` の型変換）
- ステップ 5 のレビュー結果

**merge しない。** CI が緑になったら報告して指示を待つ。

---

## Self-Review

**1. spec coverage** — [全体設計](./2026-09-05-api-surface-expansion.md) §4 の Phase 3 に挙げた 8 本が Task 1〜4 に在る。**ただし全体設計の一覧では `ocvu_bitwise` を 1 本と数えているが、そこには `split` / `merge` が無い** —— 全体設計 §4 の Phase 3 は `extract_channel` / `insert_channel` を挙げており、一致している。§9 の完了条件は Task 6 が満たす。

**2. placeholder scan** — Task 5 Step 1・2 は C# のコードブロックを省いているが、**メソッド名・引数・返り値・テスト名をすべて名指し**してあり、`CvMinMax` の実装は貼ってある。省いた理由（9 本の薄いラッパを写すと読めなくなる）を明記した。

**3. type consistency** — `MakeFourChannel` / `MakeUniform` / `ReadPixels` は Task 1、`MakeExtremes` は Task 2 で定義する。`ocvu_min_max_loc` は Task 2 で作り Task 4 のテストで使う。`OCVU_BORDER_*` と `CvBorderMode` は **Phase 2 と共有する** ので、先に着手したほうが足すことを明記した。
