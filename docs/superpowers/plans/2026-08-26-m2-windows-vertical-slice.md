# M2 Windows vertical slice 実装計画

> **状態: 実施済みの計画である。Task 8 まで実施した。** 2026-08-27 に PR #5（`9ded0b9`）
> として main へ入った時点の判定は「8 件中 7 件達成、条件 7 は未達」で、残っていた条件 7
> （`ci-unity.yml` が CI 上で L4 / L5 を実行する）は 2026-08-29 に達成した（`8c68fff`）。
> **完了条件 8 件すべてを満たしている。判定は [docs/roadmap.md](../../roadmap.md) の
> M2 節にある** —— そこが正本である。実施中の進行記録は手元の `.superpowers/` 配下に
> あるが、**これは `.gitignore` で追跡外なのでクローンには入らない。** 別のマシンで
> この計画書を読む者には検証できないため、参照先として当てにしないこと。
>
> **本文のチェックボックス 62 個は 1 つも更新していない。** 実施当時に印を付けなかった
> だけで、未着手という意味ではない。**この計画書を進捗の記録として読まないこと。**

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Mat` のライフサイクルと 3 つの `imgproc` API が C# から動き、Unity Editor (Mono) と Windows IL2CPP Player で同一結果になる。

**Architecture:** `ocvu_mat_handle` は世代番号つきの handle table の索引であり、生ポインタではない。解放済み handle の再使用は未定義動作ではなく `OCVU_STATUS_INVALID_HANDLE` として検出される。Unity 側のメモリは handle にならず、`copy_from_buffer` / `copy_to_buffer` が長さと stride を検証したうえで 1 回の呼び出しの内側だけで読み書きする。UnityEngine に触れるコードは `Runtime/UnityIntegration/` の別 asmdef にのみ置き、`Runtime/Core` と `Runtime/Interop` は L3 が Unity 抜きで走れる状態を保つ。

**Tech Stack:** C++17 / MSVC、OpenCV 5.0.0（静的リンク、実行時ライブラリは共有）、GoogleTest + CTest（L1）、AddressSanitizer（L2）、xUnit + P/Invoke on net8.0（L3）、Unity 6000.x EditMode（L4）と Windows IL2CPP Player（L5）、netstandard2.1 / C# 9。

**Spec:** `docs/abi-ownership-and-versioning.md`（所有権・versioning・API allowlist の確定内容）

## Global Constraints

以下は全タスクの要件に含まれる。値は spec からそのまま写している。

- **`ocvu_mat_handle` が指すメモリは常に native が確保し native が解放する。Unity が所有するメモリを指す handle を返してはならない。** 借用は 1 回の ABI 呼び出しの内側で完結する。
- **buffer 引数は必ず検証する。** `rows * stride` が渡された長さを超えるなら、何も書かずに `OCVU_STATUS_INVALID_ARGUMENT` を返す。ポインタが NULL なら `OCVU_STATUS_NULL_POINTER`。呼ぶ側を信用しない。
- **`ocvu_status` を返す `extern "C"` 関数は `OCVU_TRY_BEGIN` / `OCVU_TRY_END` で本体を囲む。** 例外を ABI 境界の外へ出さない。除外は `ocvu_get_last_error_status` / `ocvu_get_last_error_message` のみ（hook が検査する）。
- **`OCVU_ABI_VERSION` は M2 で bump しない。** M2 が足すのは新しい関数と `OCVU_STATUS_LIST` 末尾への追加だけで、spec §2 の「bump しない変更」に該当する。
- **`Runtime/Interop` と `Runtime/Core` は `UnityEngine` を参照しない。** UnityEngine 依存は `Runtime/UnityIntegration/` の別 asmdef にのみ置く（hook と netstandard2.1 shim が検査する）。
- **C ABI に出るのは opaque handle と固定サイズ型のみ。** `cv::Mat*` や STL 型を境界の外へ出さない。
- 対象 Unity は **6000.x のみ**。C# は **netstandard2.1 / C# 9**。
- **ローカルループは秒単位を守る。** 重い検証は `test-tools-slow` か CI に置く。
- **検査を足したり変えたりしたら `prove-a-check-works` skill に従う。** 壊して落ちることを見るまで、その検査は動くと言えない。

---

### Task 1: Mat handle table とライフサイクル

**Files:**
- Create: `native/src/ocvu_mat_table.h`, `native/src/ocvu_mat_table.cpp`, `native/src/ocvu_mat.cpp`
- Modify: `native/include/opencv_unity_native.h`（`OCVU_STATUS_LIST` に 1 行追加、型と 4 関数の宣言）
- Modify: `native/CMakeLists.txt`（新しい .cpp を追加）
- Modify: `Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvStatus.cs`（新 status）
- Test: `native/tests/test_mat_lifecycle.cpp`, `tests/Managed/CvUnity.Tests.Managed/MatLifecycleTests.cs`

**Interfaces:**
- Consumes: `OCVU_TRY_BEGIN` / `OCVU_TRY_END` / `ocvu::set_last_error`（`native/src/ocvu_error.h`）
- Produces:
  - `typedef uint64_t ocvu_mat_handle;` と `#define OCVU_MAT_HANDLE_NONE 0`
  - `ocvu_status ocvu_mat_create(int32_t rows, int32_t cols, int32_t type, ocvu_mat_handle* out_handle)`
  - `ocvu_status ocvu_mat_release(ocvu_mat_handle handle)`
  - `ocvu_status ocvu_mat_clone(ocvu_mat_handle src, ocvu_mat_handle* out_handle)`
  - `ocvu_status ocvu_mat_get_info(ocvu_mat_handle handle, ocvu_mat_info* out_info)`
  - `struct ocvu_mat_info { int32_t rows; int32_t cols; int32_t type; int32_t channels; int64_t step; int64_t total_bytes; }`
  - `OCVU_STATUS_INVALID_HANDLE = 7`
  - C++ 内部用: `ocvu::mat_table_acquire(cv::Mat) -> ocvu_mat_handle`, `ocvu::mat_table_get(ocvu_mat_handle) -> cv::Mat*`（無効なら nullptr）, `ocvu::mat_table_release(ocvu_mat_handle) -> bool`

**設計の要点（実装前に読むこと）**

handle を生ポインタにしない。解放後の handle をもう一度渡されたとき、生ポインタなら
未定義動作になり、ASan が無い環境では黙って壊れる。**世代番号を持つ table にすると、
その誤りが `OCVU_STATUS_INVALID_HANDLE` という観測可能な結果になる。**

handle の 64 bit は上位 32 bit が世代、下位 32 bit が索引である。解放のたびに世代を
1 進めるので、古い handle は索引が生きていても世代が合わず弾かれる。`0` は
`OCVU_MAT_HANDLE_NONE` として常に無効にする（ゼロ初期化された変数を誤って渡した場合を
確実に捕まえるため）。

table は `std::mutex` で保護する。Unity のワーカースレッドから呼ばれ得るため。

- [ ] **Step 1: status を 1 つ足し、C# 側にも同じものを足す**

`native/include/opencv_unity_native.h` の `OCVU_STATUS_LIST` の**末尾**に追加する。
末尾であることが重要で、既存の値が動くと spec §2 の「bump する変更」になってしまう。

```c
#define OCVU_STATUS_LIST(X)               \
    X(OCVU_STATUS_OK,                  0) \
    X(OCVU_STATUS_INVALID_ARGUMENT,    1) \
    X(OCVU_STATUS_NULL_POINTER,        2) \
    X(OCVU_STATUS_OUT_OF_MEMORY,       3) \
    X(OCVU_STATUS_OPENCV_ERROR,        4) \
    X(OCVU_STATUS_UNKNOWN_ERROR,       5) \
    X(OCVU_STATUS_BUFFER_TOO_SMALL,    6) \
    X(OCVU_STATUS_INVALID_HANDLE,      7)
```

`Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvStatus.cs` の enum にも
`InvalidHandle = 7,` を足す。これを忘れると L3 の `StatusCodeSyncTests` が赤くなる。

- [ ] **Step 2: 同期テストが通ることを確認する（ここはまだ既存テストだけ）**

Run: `pwsh tools/dev.ps1 test-managed`
Expected: PASS（`StatusCodeSyncTests` が 7 個から 8 個になったことを認識する）

- [ ] **Step 3: L1 の失敗するテストを書く**

`native/tests/test_mat_lifecycle.cpp`:

```cpp
#include <gtest/gtest.h>

#include "opencv_unity_native.h"

TEST(MatLifecycle, CreateProducesAUsableHandle) {
    ocvu_mat_handle h = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(4, 6, OCVU_MAT_TYPE_8UC3, &h), OCVU_STATUS_OK);
    EXPECT_NE(h, OCVU_MAT_HANDLE_NONE);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(h, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 4);
    EXPECT_EQ(info.cols, 6);
    EXPECT_EQ(info.channels, 3);
    EXPECT_EQ(info.step, 6 * 3);
    EXPECT_EQ(info.total_bytes, 4 * 6 * 3);

    EXPECT_EQ(ocvu_mat_release(h), OCVU_STATUS_OK);
}

TEST(MatLifecycle, ReleasedHandleIsRejectedRatherThanCrashing) {
    ocvu_mat_handle h = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(2, 2, OCVU_MAT_TYPE_8UC1, &h), OCVU_STATUS_OK);
    ASSERT_EQ(ocvu_mat_release(h), OCVU_STATUS_OK);

    // 二重解放も、解放後の照会も、落ちずに status になる。
    EXPECT_EQ(ocvu_mat_release(h), OCVU_STATUS_INVALID_HANDLE);

    ocvu_mat_info info{};
    EXPECT_EQ(ocvu_mat_get_info(h, &info), OCVU_STATUS_INVALID_HANDLE);
}

TEST(MatLifecycle, ZeroHandleIsAlwaysInvalid) {
    ocvu_mat_info info{};
    EXPECT_EQ(ocvu_mat_get_info(OCVU_MAT_HANDLE_NONE, &info), OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_mat_release(OCVU_MAT_HANDLE_NONE), OCVU_STATUS_INVALID_HANDLE);
}

TEST(MatLifecycle, ReusedSlotDoesNotResurrectAnOldHandle) {
    // 解放した slot が再利用されても、古い handle は世代が合わず弾かれる。
    // これが世代番号を持つ理由そのものなので、明示的に固定する。
    ocvu_mat_handle first = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &first), OCVU_STATUS_OK);
    ASSERT_EQ(ocvu_mat_release(first), OCVU_STATUS_OK);

    ocvu_mat_handle second = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &second), OCVU_STATUS_OK);
    EXPECT_NE(first, second) << "a fresh handle must not equal a released one";

    ocvu_mat_info info{};
    EXPECT_EQ(ocvu_mat_get_info(first, &info), OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_mat_get_info(second, &info), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_mat_release(second), OCVU_STATUS_OK);
}

TEST(MatLifecycle, CloneCopiesContentIntoAnIndependentHandle) {
    ocvu_mat_handle src = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(3, 3, OCVU_MAT_TYPE_8UC1, &src), OCVU_STATUS_OK);

    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_clone(src, &dst), OCVU_STATUS_OK);
    EXPECT_NE(dst, src);

    // src を解放しても dst は生きている（別の記憶域である）。
    ASSERT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);

    ocvu_mat_info info{};
    EXPECT_EQ(ocvu_mat_get_info(dst, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 3);

    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(MatLifecycle, NullOutParametersAreRejected) {
    EXPECT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, nullptr), OCVU_STATUS_NULL_POINTER);

    ocvu_mat_handle h = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &h), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_get_info(h, nullptr), OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_mat_clone(h, nullptr), OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_mat_release(h), OCVU_STATUS_OK);
}

TEST(MatLifecycle, InvalidDimensionsAreRejected) {
    ocvu_mat_handle h = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(0, 4, OCVU_MAT_TYPE_8UC1, &h), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_mat_create(4, 0, OCVU_MAT_TYPE_8UC1, &h), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_mat_create(-1, 4, OCVU_MAT_TYPE_8UC1, &h), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(h, OCVU_MAT_HANDLE_NONE) << "out_handle must be left untouched on failure";
}
```

`native/tests/CMakeLists.txt` の source 一覧に `test_mat_lifecycle.cpp` を足す。

- [ ] **Step 4: テストが失敗することを確認する**

Run: `pwsh tools/dev.ps1 test-native`
Expected: コンパイルエラー。`ocvu_mat_create` などが宣言されていない。

- [ ] **Step 5: ヘッダに型と関数を宣言する**

`native/include/opencv_unity_native.h` の `ocvu_debug_throw` の宣言の**前**に足す。

```c
/*
 * Mat の不透明 handle。
 *
 * 生ポインタではない。上位 32 bit が世代、下位 32 bit が table の索引である。
 * 解放のたびに世代が進むので、解放済みの handle をもう一度渡しても
 * OCVU_STATUS_INVALID_HANDLE として弾かれる。生ポインタなら未定義動作になり、
 * sanitizer の無い環境（配布された Unity Player）では黙って壊れる。
 *
 * 0 は常に無効である。ゼロ初期化した変数を誤って渡した場合を確実に捕まえる。
 *
 * この handle が指すメモリは常に native が確保し native が解放する。
 * Unity が所有するメモリを指す handle は存在しない
 * （docs/abi-ownership-and-versioning.md §1）。
 */
typedef uint64_t ocvu_mat_handle;
#define OCVU_MAT_HANDLE_NONE ((ocvu_mat_handle)0)

/* OpenCV の CV_8UC1 等に対応する。ABI に cv:: の定数を露出させないための写し。 */
#define OCVU_MAT_TYPE_8UC1  0
#define OCVU_MAT_TYPE_8UC3 16
#define OCVU_MAT_TYPE_8UC4 24

/* ocvu_mat_get_info の出力。固定サイズ型のみで構成する。 */
typedef struct ocvu_mat_info {
    int32_t rows;
    int32_t cols;
    int32_t type;        /* OCVU_MAT_TYPE_* */
    int32_t channels;
    int64_t step;        /* 1 行のバイト数 */
    int64_t total_bytes; /* rows * step */
} ocvu_mat_info;

/*
 * rows x cols、指定 type の Mat を確保し、handle を out_handle に書く。
 * rows / cols が 1 未満、または type が未知なら OCVU_STATUS_INVALID_ARGUMENT を返し、
 * out_handle は変更しない。out_handle が NULL なら OCVU_STATUS_NULL_POINTER。
 */
OCVU_API ocvu_status ocvu_mat_create(int32_t rows, int32_t cols, int32_t type,
                                     ocvu_mat_handle* out_handle);

/*
 * handle を解放する。解放済み、または未知の handle なら
 * OCVU_STATUS_INVALID_HANDLE を返す（落とさない）。
 */
OCVU_API ocvu_status ocvu_mat_release(ocvu_mat_handle handle);

/* src の内容を複製した独立の handle を作る。src と dst は別の記憶域を持つ。 */
OCVU_API ocvu_status ocvu_mat_clone(ocvu_mat_handle src, ocvu_mat_handle* out_handle);

/* handle の形状を out_info に書く。out_info が NULL なら OCVU_STATUS_NULL_POINTER。 */
OCVU_API ocvu_status ocvu_mat_get_info(ocvu_mat_handle handle, ocvu_mat_info* out_info);
```

- [ ] **Step 6: handle table を実装する**

`native/src/ocvu_mat_table.h`:

```cpp
#ifndef OCVU_MAT_TABLE_H
#define OCVU_MAT_TABLE_H

#include <opencv2/core.hpp>

#include "opencv_unity_native.h"

namespace ocvu {

/*
 * Mat を table に入れて handle を返す。handle は世代 + 索引である。
 * 確保できない場合は OCVU_MAT_HANDLE_NONE を返す。
 */
ocvu_mat_handle mat_table_acquire(cv::Mat mat);

/*
 * handle に対応する Mat を返す。世代が合わない（解放済み）、索引が範囲外、
 * handle が 0 のいずれかなら nullptr を返す。
 *
 * 戻り値は table が所有する Mat への借用ポインタである。呼び出し側は
 * 保持してはならない — 同じスレッドで release されると無効になる。
 */
cv::Mat* mat_table_get(ocvu_mat_handle handle);

/* 解放する。handle が無効なら false を返す（二重解放の検出）。 */
bool mat_table_release(ocvu_mat_handle handle);

}  // namespace ocvu

#endif  /* OCVU_MAT_TABLE_H */
```

`native/src/ocvu_mat_table.cpp`:

```cpp
#include "ocvu_mat_table.h"

#include <cstdint>
#include <mutex>
#include <vector>

namespace ocvu {
namespace {

struct Slot {
    cv::Mat mat;
    uint32_t generation = 1;  // 1 から始める。世代 0 の handle は作らない
    bool occupied = false;
};

/*
 * table は関数内 static にする。DLL アンロード時の破棄順序に依存しないため。
 * mutex は Unity のワーカースレッドから同時に呼ばれ得るので必須である。
 */
struct Table {
    std::mutex mutex;
    std::vector<Slot> slots;
    std::vector<uint32_t> free_indices;
};

Table& table() {
    static Table instance;
    return instance;
}

constexpr ocvu_mat_handle make_handle(uint32_t index, uint32_t generation) {
    return (static_cast<ocvu_mat_handle>(generation) << 32) | static_cast<ocvu_mat_handle>(index);
}

constexpr uint32_t handle_index(ocvu_mat_handle h) { return static_cast<uint32_t>(h & 0xFFFFFFFFu); }
constexpr uint32_t handle_generation(ocvu_mat_handle h) { return static_cast<uint32_t>(h >> 32); }

}  // namespace

ocvu_mat_handle mat_table_acquire(cv::Mat mat) {
    Table& t = table();
    std::lock_guard<std::mutex> lock(t.mutex);

    uint32_t index;
    if (!t.free_indices.empty()) {
        index = t.free_indices.back();
        t.free_indices.pop_back();
    } else {
        t.slots.emplace_back();
        index = static_cast<uint32_t>(t.slots.size() - 1);
    }

    Slot& slot = t.slots[index];
    slot.mat = std::move(mat);
    slot.occupied = true;
    return make_handle(index, slot.generation);
}

cv::Mat* mat_table_get(ocvu_mat_handle handle) {
    if (handle == OCVU_MAT_HANDLE_NONE) { return nullptr; }

    Table& t = table();
    std::lock_guard<std::mutex> lock(t.mutex);

    const uint32_t index = handle_index(handle);
    if (index >= t.slots.size()) { return nullptr; }

    Slot& slot = t.slots[index];
    if (!slot.occupied || slot.generation != handle_generation(handle)) { return nullptr; }
    return &slot.mat;
}

bool mat_table_release(ocvu_mat_handle handle) {
    if (handle == OCVU_MAT_HANDLE_NONE) { return false; }

    Table& t = table();
    std::lock_guard<std::mutex> lock(t.mutex);

    const uint32_t index = handle_index(handle);
    if (index >= t.slots.size()) { return false; }

    Slot& slot = t.slots[index];
    if (!slot.occupied || slot.generation != handle_generation(handle)) { return false; }

    slot.mat.release();
    slot.occupied = false;
    // 世代を進めることで、この索引の古い handle は以後すべて無効になる。
    // 一周して衝突するのは 2^32 回の解放後であり、実用上到達しない。
    ++slot.generation;
    t.free_indices.push_back(index);
    return true;
}

}  // namespace ocvu
```

- [ ] **Step 7: ABI 関数を実装する**

`native/src/ocvu_mat.cpp`:

```cpp
#include <opencv2/core.hpp>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

namespace {

/* ABI に出す type 定数から OpenCV の型へ。未知なら false。 */
bool to_cv_type(int32_t abi_type, int* out_cv_type) {
    switch (abi_type) {
        case OCVU_MAT_TYPE_8UC1: *out_cv_type = CV_8UC1; return true;
        case OCVU_MAT_TYPE_8UC3: *out_cv_type = CV_8UC3; return true;
        case OCVU_MAT_TYPE_8UC4: *out_cv_type = CV_8UC4; return true;
        default: return false;
    }
}

int32_t from_cv_type(int cv_type) {
    switch (cv_type) {
        case CV_8UC1: return OCVU_MAT_TYPE_8UC1;
        case CV_8UC3: return OCVU_MAT_TYPE_8UC3;
        case CV_8UC4: return OCVU_MAT_TYPE_8UC4;
        default: return -1;
    }
}

}  // namespace

extern "C" ocvu_status ocvu_mat_create(int32_t rows, int32_t cols, int32_t type,
                                       ocvu_mat_handle* out_handle) {
    OCVU_TRY_BEGIN
    if (out_handle == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER, "out_handle is NULL");
    }
    if (rows < 1 || cols < 1) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "rows and cols must be >= 1");
    }
    int cv_type = 0;
    if (!to_cv_type(type, &cv_type)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT, "unknown mat type");
    }

    const ocvu_mat_handle handle = ::ocvu::mat_table_acquire(cv::Mat(rows, cols, cv_type));
    if (handle == OCVU_MAT_HANDLE_NONE) {
        return ::ocvu::set_last_error(OCVU_STATUS_OUT_OF_MEMORY, "mat table exhausted");
    }
    *out_handle = handle;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_mat_release(ocvu_mat_handle handle) {
    OCVU_TRY_BEGIN
    if (!::ocvu::mat_table_release(handle)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "handle is unknown or already released");
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_mat_clone(ocvu_mat_handle src, ocvu_mat_handle* out_handle) {
    OCVU_TRY_BEGIN
    if (out_handle == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER, "out_handle is NULL");
    }
    cv::Mat* mat = ::ocvu::mat_table_get(src);
    if (mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE, "src handle is invalid");
    }
    const ocvu_mat_handle handle = ::ocvu::mat_table_acquire(mat->clone());
    if (handle == OCVU_MAT_HANDLE_NONE) {
        return ::ocvu::set_last_error(OCVU_STATUS_OUT_OF_MEMORY, "mat table exhausted");
    }
    *out_handle = handle;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_mat_get_info(ocvu_mat_handle handle, ocvu_mat_info* out_info) {
    OCVU_TRY_BEGIN
    if (out_info == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER, "out_info is NULL");
    }
    cv::Mat* mat = ::ocvu::mat_table_get(handle);
    if (mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE, "handle is invalid");
    }
    out_info->rows = mat->rows;
    out_info->cols = mat->cols;
    out_info->type = from_cv_type(mat->type());
    out_info->channels = mat->channels();
    out_info->step = static_cast<int64_t>(mat->step);
    out_info->total_bytes = static_cast<int64_t>(mat->step) * mat->rows;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

`native/CMakeLists.txt` の source 一覧に `src/ocvu_mat_table.cpp` と `src/ocvu_mat.cpp` を足す。

- [ ] **Step 8: L1 が通ることを確認する**

Run: `pwsh tools/dev.ps1 test-native`
Expected: PASS。7 個の新しいテストがすべて緑。

- [ ] **Step 9: L3 の失敗するテストを書く**

`Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.cs` に宣言を足す。
`ocvu_mat_info` に対応する `[StructLayout(LayoutKind.Sequential)]` の struct も
同じファイルに置く（`Runtime/Interop` は UnityEngine を参照しないこと）。

`NativeMethods` と `OcvuMatInfo` は `internal` なので、テストからは見えない。
`Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/AssemblyInfo.cs` を**ここで**作る
（Task 5 の `CvMat` も同じものを必要とするが、先に要るのはこの Step である）:

```csharp
using System.Runtime.CompilerServices;

// Runtime/Interop の internal は、同じパッケージの Core 層と L3 のテストからだけ見える。
// public にはしない — P/Invoke 宣言は実装詳細であり、利用者向けの API ではない。
[assembly: InternalsVisibleTo("CvUnity.Core")]
[assembly: InternalsVisibleTo("CvUnity.Tests.Managed")]
[assembly: InternalsVisibleTo("CvUnity.Runtime")]
```

```csharp
[StructLayout(LayoutKind.Sequential)]
internal struct OcvuMatInfo
{
    internal int Rows;
    internal int Cols;
    internal int Type;
    internal int Channels;
    internal long Step;
    internal long TotalBytes;
}

[DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
internal static extern int ocvu_mat_create(int rows, int cols, int type, out ulong handle);

[DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
internal static extern int ocvu_mat_release(ulong handle);

[DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
internal static extern int ocvu_mat_clone(ulong src, out ulong handle);

[DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
internal static extern int ocvu_mat_get_info(ulong handle, out OcvuMatInfo info);
```

`tests/Managed/CvUnity.Tests.Managed/MatLifecycleTests.cs`:

```csharp
using CvUnity;
using CvUnity.Interop;
using Xunit;

namespace CvUnity.Tests.Managed
{
    public class MatLifecycleTests
    {
        [Fact]
        public void ReleasedHandle_IsRejectedAcrossThePInvokeBoundary()
        {
            // C ABI が落ちないことは L1 が見ている。ここで見たいのは、その status が
            // P/Invoke 越しにそのまま観測でき、managed 側が例外に変換できることである。
            ulong handle;
            Assert.Equal(0, NativeMethods.ocvu_mat_create(2, 2, 0, out handle));
            Assert.NotEqual(0UL, handle);

            Assert.Equal(0, NativeMethods.ocvu_mat_release(handle));

            var second = (CvStatus)NativeMethods.ocvu_mat_release(handle);
            Assert.Equal(CvStatus.InvalidHandle, second);
            Assert.True(CvNative.IsFailure(second));
        }

        [Fact]
        public void MatInfo_MarshalsWithTheSameLayoutAsNative()
        {
            // struct の layout がずれると値が黙って壊れる。native 側で計算できる
            // 関係（total_bytes == step * rows）を managed 側で照合して検出する。
            ulong handle;
            Assert.Equal(0, NativeMethods.ocvu_mat_create(4, 6, 16, out handle));

            OcvuMatInfo info;
            Assert.Equal(0, NativeMethods.ocvu_mat_get_info(handle, out info));

            Assert.Equal(4, info.Rows);
            Assert.Equal(6, info.Cols);
            Assert.Equal(3, info.Channels);
            Assert.Equal(18, info.Step);
            Assert.Equal(info.Step * info.Rows, info.TotalBytes);

            Assert.Equal(0, NativeMethods.ocvu_mat_release(handle));
        }

        [Fact]
        public void ZeroHandle_IsInvalidRatherThanCrashingTheRuntime()
        {
            // ゼロ初期化した変数をそのまま渡す誤りは managed 側で起きやすい。
            OcvuMatInfo info;
            Assert.Equal((int)CvStatus.InvalidHandle,
                NativeMethods.ocvu_mat_get_info(0UL, out info));
        }

        [Fact]
        public void FailedCreate_ReportsAMessageAndYieldsNoUsableHandle()
        {
            // 「out 引数が触られていないこと」はここでは検証できない。C# の out は
            // 呼び出し前の値を必ず破棄するので、native が書かなかったことと
            // marshaller が既定値を入れたことを managed 側から区別する手段が無い。
            // その検証は L1 の InvalidDimensionsAreRejected が持っている。
            //
            // ここで確かめられるのは、失敗が失敗として観測でき、理由が読め、
            // 返ってきた値が handle として通用しないことである。
            ulong handle;
            var status = (CvStatus)NativeMethods.ocvu_mat_create(0, 4, 0, out handle);

            Assert.Equal(CvStatus.InvalidArgument, status);
            Assert.Contains("rows and cols", CvNative.GetLastErrorMessage());

            OcvuMatInfo info;
            Assert.Equal((int)CvStatus.InvalidHandle,
                NativeMethods.ocvu_mat_get_info(handle, out info));
        }
    }
}
```

- [ ] **Step 10: L3 が通ることを確認する**

Run: `pwsh tools/dev.ps1 test-managed`
Expected: PASS。

- [ ] **Step 11: 全レーンと ASan を回す**

Run: `pwsh tools/dev.ps1 test` と `pwsh tools/dev.ps1 test-asan`
Expected: 両方 PASS。ASan は handle table の解放経路を通るので、ここで leak 以外の
メモリ誤りがあれば出る（Windows の ASan は leak 検出を持たない — M3 の Linux レーンの担当）。

- [ ] **Step 12: コミット**

```bash
git add native/include/opencv_unity_native.h native/src/ocvu_mat_table.h native/src/ocvu_mat_table.cpp native/src/ocvu_mat.cpp native/CMakeLists.txt native/tests/test_mat_lifecycle.cpp native/tests/CMakeLists.txt Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvStatus.cs Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.cs Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/AssemblyInfo.cs tests/Managed/CvUnity.Tests.Managed/MatLifecycleTests.cs
git commit -m "feat(mat): add generation-checked handles so use-after-release is a status, not UB"
```

---

### Task 2: buffer との受け渡しと引数検証

**Files:**
- Create: `native/src/ocvu_mat_buffer.cpp`
- Modify: `native/include/opencv_unity_native.h`（2 関数の宣言）
- Modify: `native/CMakeLists.txt`
- Modify: `Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.cs`
- Test: `native/tests/test_mat_buffer.cpp`, `tests/Managed/CvUnity.Tests.Managed/MatBufferTests.cs`

**Interfaces:**
- Consumes: Task 1 の `ocvu_mat_handle`, `ocvu::mat_table_get`, `ocvu_mat_info`
- Produces:
  - `ocvu_status ocvu_mat_copy_from_buffer(ocvu_mat_handle dst, const uint8_t* src, int64_t src_length, int64_t src_stride)`
  - `ocvu_status ocvu_mat_copy_to_buffer(ocvu_mat_handle src, uint8_t* dst, int64_t dst_length, int64_t dst_stride)`

**設計の要点**

**ここが M2 で最も危険な 2 関数である。** 呼ぶ側が渡す長さと stride を信じて書くと、
Unity のヒープを踏み越える。壊れ方は「即座に落ちず、後から無関係な場所が壊れる」形で、
Windows の ASan は Unity のアロケータを見られない。

したがって**書く前にすべて検証し、1 つでも合わなければ何も書かずに返す**。
検証は次の順で行う。

1. `dst` / `src` ポインタが NULL → `OCVU_STATUS_NULL_POINTER`
2. handle が無効 → `OCVU_STATUS_INVALID_HANDLE`
3. `stride` が Mat の 1 行のバイト数未満 → `OCVU_STATUS_INVALID_ARGUMENT`
4. `stride * rows` が `length` を超える → `OCVU_STATUS_INVALID_ARGUMENT`
5. `length` が負 → `OCVU_STATUS_INVALID_ARGUMENT`

**行ごとにコピーする。** Mat の `step` と外部 buffer の `stride` は一致しないことがある
（Unity のテクスチャは行が整列されている場合がある）。一括 `memcpy` は両者が等しいときしか
正しくない。

- [ ] **Step 1: L1 の失敗するテストを書く**

`native/tests/test_mat_buffer.cpp`:

```cpp
#include <gtest/gtest.h>

#include <cstdint>
#include <vector>

#include "opencv_unity_native.h"

namespace {

class MatBufferTest : public ::testing::Test {
protected:
    void SetUp() override {
        ASSERT_EQ(ocvu_mat_create(3, 4, OCVU_MAT_TYPE_8UC1, &handle_), OCVU_STATUS_OK);
    }
    void TearDown() override {
        if (handle_ != OCVU_MAT_HANDLE_NONE) { ocvu_mat_release(handle_); }
    }
    ocvu_mat_handle handle_ = OCVU_MAT_HANDLE_NONE;
};

}  // namespace

TEST_F(MatBufferTest, RoundTripsContentThroughAnExternalBuffer) {
    std::vector<uint8_t> in(3 * 4);
    for (size_t i = 0; i < in.size(); ++i) { in[i] = static_cast<uint8_t>(i + 1); }

    ASSERT_EQ(ocvu_mat_copy_from_buffer(handle_, in.data(),
                                        static_cast<int64_t>(in.size()), 4),
              OCVU_STATUS_OK);

    std::vector<uint8_t> out(in.size(), 0);
    ASSERT_EQ(ocvu_mat_copy_to_buffer(handle_, out.data(),
                                      static_cast<int64_t>(out.size()), 4),
              OCVU_STATUS_OK);
    EXPECT_EQ(in, out);
}

TEST_F(MatBufferTest, HonoursAStrideLargerThanTheRow) {
    // Unity のテクスチャは行が整列されていることがあり、stride > cols になる。
    // 一括 memcpy ではなく行ごとにコピーしていないとここで壊れる。
    const int64_t stride = 8;  // 1 行 4 バイトのデータを 8 バイト間隔で置く
    std::vector<uint8_t> padded(static_cast<size_t>(stride * 3), 0xEE);
    for (int row = 0; row < 3; ++row) {
        for (int col = 0; col < 4; ++col) {
            padded[static_cast<size_t>(row * stride + col)] =
                static_cast<uint8_t>(row * 10 + col);
        }
    }

    ASSERT_EQ(ocvu_mat_copy_from_buffer(handle_, padded.data(),
                                        static_cast<int64_t>(padded.size()), stride),
              OCVU_STATUS_OK);

    std::vector<uint8_t> tight(3 * 4, 0);
    ASSERT_EQ(ocvu_mat_copy_to_buffer(handle_, tight.data(),
                                      static_cast<int64_t>(tight.size()), 4),
              OCVU_STATUS_OK);

    for (int row = 0; row < 3; ++row) {
        for (int col = 0; col < 4; ++col) {
            EXPECT_EQ(tight[static_cast<size_t>(row * 4 + col)],
                      static_cast<uint8_t>(row * 10 + col))
                << "row " << row << " col " << col;
        }
    }
}

TEST_F(MatBufferTest, RejectsABufferShorterThanStrideTimesRows) {
    std::vector<uint8_t> tooSmall(3 * 4 - 1);
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle_, tooSmall.data(),
                                        static_cast<int64_t>(tooSmall.size()), 4),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_mat_copy_to_buffer(handle_, tooSmall.data(),
                                      static_cast<int64_t>(tooSmall.size()), 4),
              OCVU_STATUS_INVALID_ARGUMENT);
}

TEST_F(MatBufferTest, RejectsAStrideSmallerThanOneRow) {
    std::vector<uint8_t> buffer(3 * 4);
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle_, buffer.data(),
                                        static_cast<int64_t>(buffer.size()), 3),
              OCVU_STATUS_INVALID_ARGUMENT);
}

TEST_F(MatBufferTest, RejectsNegativeLengthAndStride) {
    std::vector<uint8_t> buffer(3 * 4);
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle_, buffer.data(), -1, 4),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle_, buffer.data(),
                                        static_cast<int64_t>(buffer.size()), -4),
              OCVU_STATUS_INVALID_ARGUMENT);
}

TEST_F(MatBufferTest, RejectsNullPointers) {
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle_, nullptr, 12, 4), OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_mat_copy_to_buffer(handle_, nullptr, 12, 4), OCVU_STATUS_NULL_POINTER);
}

TEST_F(MatBufferTest, RejectsAReleasedHandleWithoutTouchingTheBuffer) {
    std::vector<uint8_t> buffer(3 * 4, 0x5A);
    ocvu_mat_handle dead = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(3, 4, OCVU_MAT_TYPE_8UC1, &dead), OCVU_STATUS_OK);
    ASSERT_EQ(ocvu_mat_release(dead), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_mat_copy_to_buffer(dead, buffer.data(),
                                      static_cast<int64_t>(buffer.size()), 4),
              OCVU_STATUS_INVALID_HANDLE);
    for (uint8_t b : buffer) {
        EXPECT_EQ(b, 0x5A) << "the buffer must not be written when validation fails";
    }
}
```

`native/tests/CMakeLists.txt` に `test_mat_buffer.cpp` を足す。

- [ ] **Step 2: テストが失敗することを確認する**

Run: `pwsh tools/dev.ps1 test-native`
Expected: コンパイルエラー。`ocvu_mat_copy_from_buffer` が宣言されていない。

- [ ] **Step 3: ヘッダに宣言する**

```c
/*
 * 外部 buffer から Mat へコピーする。
 *
 * src は呼び出しの内側でだけ読む借用である。この関数が戻った後、native 側は
 * src を一切保持しない（docs/abi-ownership-and-versioning.md §1）。
 *
 * 書く前にすべて検証する。1 つでも合わなければ何も書かずに返す:
 *   src が NULL              -> OCVU_STATUS_NULL_POINTER
 *   handle が無効            -> OCVU_STATUS_INVALID_HANDLE
 *   src_length / src_stride が負          -> OCVU_STATUS_INVALID_ARGUMENT
 *   src_stride が Mat の 1 行より小さい    -> OCVU_STATUS_INVALID_ARGUMENT
 *   src_stride * rows が src_length を超える -> OCVU_STATUS_INVALID_ARGUMENT
 *
 * src_stride は Mat の step と異なってよい（Unity のテクスチャは行が整列されて
 * いることがある）。行ごとにコピーする。
 */
OCVU_API ocvu_status ocvu_mat_copy_from_buffer(ocvu_mat_handle dst,
                                               const uint8_t* src,
                                               int64_t src_length,
                                               int64_t src_stride);

/* Mat から外部 buffer へコピーする。検証規則は copy_from_buffer と同じ。 */
OCVU_API ocvu_status ocvu_mat_copy_to_buffer(ocvu_mat_handle src,
                                             uint8_t* dst,
                                             int64_t dst_length,
                                             int64_t dst_stride);
```

- [ ] **Step 4: 実装する**

`native/src/ocvu_mat_buffer.cpp`:

```cpp
#include <cstring>

#include <opencv2/core.hpp>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

namespace {

/*
 * 外部 buffer と Mat の整合を検証する。合格したときだけ true を返し、
 * row_bytes に 1 行の実バイト数を書く。
 *
 * 呼ぶ側を信用しないための関門であり、この関数を通らない書き込み経路を
 * 作らないこと（docs/abi-ownership-and-versioning.md §3）。
 */
bool validate(const cv::Mat& mat, int64_t length, int64_t stride,
              int64_t* out_row_bytes, ocvu_status* out_status) {
    if (length < 0 || stride < 0) {
        *out_status = ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                             "length and stride must not be negative");
        return false;
    }

    const int64_t row_bytes = static_cast<int64_t>(mat.cols) * mat.elemSize();
    if (stride < row_bytes) {
        *out_status = ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                             "stride is smaller than one row of the mat");
        return false;
    }
    if (stride * mat.rows > length) {
        *out_status = ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                             "buffer is shorter than stride * rows");
        return false;
    }

    *out_row_bytes = row_bytes;
    return true;
}

}  // namespace

extern "C" ocvu_status ocvu_mat_copy_from_buffer(ocvu_mat_handle dst,
                                                 const uint8_t* src,
                                                 int64_t src_length,
                                                 int64_t src_stride) {
    OCVU_TRY_BEGIN
    if (src == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER, "src is NULL");
    }
    cv::Mat* mat = ::ocvu::mat_table_get(dst);
    if (mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE, "dst handle is invalid");
    }

    int64_t row_bytes = 0;
    ocvu_status failure = OCVU_STATUS_OK;
    if (!validate(*mat, src_length, src_stride, &row_bytes, &failure)) {
        return failure;
    }

    for (int row = 0; row < mat->rows; ++row) {
        std::memcpy(mat->ptr(row), src + static_cast<size_t>(row * src_stride),
                    static_cast<size_t>(row_bytes));
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_mat_copy_to_buffer(ocvu_mat_handle src,
                                               uint8_t* dst,
                                               int64_t dst_length,
                                               int64_t dst_stride) {
    OCVU_TRY_BEGIN
    if (dst == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER, "dst is NULL");
    }
    cv::Mat* mat = ::ocvu::mat_table_get(src);
    if (mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE, "src handle is invalid");
    }

    int64_t row_bytes = 0;
    ocvu_status failure = OCVU_STATUS_OK;
    if (!validate(*mat, dst_length, dst_stride, &row_bytes, &failure)) {
        return failure;
    }

    for (int row = 0; row < mat->rows; ++row) {
        std::memcpy(dst + static_cast<size_t>(row * dst_stride), mat->ptr(row),
                    static_cast<size_t>(row_bytes));
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

`native/CMakeLists.txt` に `src/ocvu_mat_buffer.cpp` を足す。

- [ ] **Step 5: L1 が通ることを確認する**

Run: `pwsh tools/dev.ps1 test-native`
Expected: PASS。

- [ ] **Step 6: L3 のテストを書く**

`NativeMethods.cs` に宣言を足す（`byte[]` で受ける。marshaller が固定してくれる）:

```csharp
[DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
internal static extern int ocvu_mat_copy_from_buffer(
    ulong dst, byte[] src, long srcLength, long srcStride);

[DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
internal static extern int ocvu_mat_copy_to_buffer(
    ulong src, byte[] dst, long dstLength, long dstStride);
```

`tests/Managed/CvUnity.Tests.Managed/MatBufferTests.cs`:

```csharp
using CvUnity;
using CvUnity.Interop;
using Xunit;

namespace CvUnity.Tests.Managed
{
    public class MatBufferTests
    {
        [Fact]
        public void RoundTrip_PreservesEveryByteAcrossThePInvokeBoundary()
        {
            ulong handle;
            Assert.Equal(0, NativeMethods.ocvu_mat_create(3, 4, 0, out handle));

            var input = new byte[12];
            for (int i = 0; i < input.Length; i++) { input[i] = (byte)(i + 1); }

            Assert.Equal(0, NativeMethods.ocvu_mat_copy_from_buffer(
                handle, input, input.Length, 4));

            var output = new byte[12];
            Assert.Equal(0, NativeMethods.ocvu_mat_copy_to_buffer(
                handle, output, output.Length, 4));

            Assert.Equal(input, output);
            Assert.Equal(0, NativeMethods.ocvu_mat_release(handle));
        }

        [Fact]
        public void OversizedStride_IsRejectedRatherThanWritingPastTheArray()
        {
            // managed の配列を踏み越えると CLR のヒープが壊れる。native 側の検証が
            // P/Invoke 越しにも効いていることを確認する。落ちたらこのテストは
            // 失敗ではなくプロセスごと死ぬので、緑であること自体が結果である。
            ulong handle;
            Assert.Equal(0, NativeMethods.ocvu_mat_create(3, 4, 0, out handle));

            var small = new byte[12];
            var status = (CvStatus)NativeMethods.ocvu_mat_copy_to_buffer(
                handle, small, small.Length, 64);

            Assert.Equal(CvStatus.InvalidArgument, status);
            Assert.Equal(0, NativeMethods.ocvu_mat_release(handle));
        }

        [Fact]
        public void ShortBuffer_IsRejectedAndLeavesTheArrayUnchanged()
        {
            ulong handle;
            Assert.Equal(0, NativeMethods.ocvu_mat_create(3, 4, 0, out handle));

            var tooSmall = new byte[11];
            for (int i = 0; i < tooSmall.Length; i++) { tooSmall[i] = 0x5A; }

            var status = (CvStatus)NativeMethods.ocvu_mat_copy_to_buffer(
                handle, tooSmall, tooSmall.Length, 4);

            Assert.Equal(CvStatus.InvalidArgument, status);
            Assert.All(tooSmall, b => Assert.Equal(0x5A, b));
            Assert.Equal(0, NativeMethods.ocvu_mat_release(handle));
        }
    }
}
```

- [ ] **Step 7: L3 と ASan を回す**

Run: `pwsh tools/dev.ps1 test` と `pwsh tools/dev.ps1 test-asan`
Expected: 両方 PASS。

- [ ] **Step 8: 検証が本当に効いているか変異で確かめる**

`prove-a-check-works` skill の手順である。`validate` の `stride * mat.rows > length` を
`false` に置き換えてビルドし、`RejectsABufferShorterThanStrideTimesRows` が赤くなることを
確認してから戻す。**赤くならないなら、その検査は何も見ていない。**

Run: `pwsh tools/dev.ps1 test-native`（変異時）
Expected: FAIL。戻した後は PASS。

- [ ] **Step 9: コミット**

```bash
git add native/include/opencv_unity_native.h native/src/ocvu_mat_buffer.cpp native/CMakeLists.txt native/tests/test_mat_buffer.cpp native/tests/CMakeLists.txt Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.cs tests/Managed/CvUnity.Tests.Managed/MatBufferTests.cs
git commit -m "feat(mat): validate every buffer argument before writing a single byte"
```

---

### Task 3: imgproc の 3 関数

**Files:**
- Create: `native/src/ocvu_imgproc.cpp`
- Modify: `native/include/opencv_unity_native.h`, `native/CMakeLists.txt`, `NativeMethods.cs`
- Test: `native/tests/test_imgproc.cpp`, `tests/Managed/CvUnity.Tests.Managed/ImgprocTests.cs`

**Interfaces:**
- Consumes: Task 1 の handle と table、Task 2 の buffer 転送（テストで結果を取り出すのに使う）
- Produces:
  - `ocvu_status ocvu_cvt_color(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t code)`
  - `ocvu_status ocvu_resize(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t width, int32_t height, int32_t interpolation)`
  - `ocvu_status ocvu_gaussian_blur(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t ksize_width, int32_t ksize_height, double sigma_x, double sigma_y)`
  - `OCVU_CVT_BGR2GRAY = 6`, `OCVU_CVT_BGRA2BGR = 1`, `OCVU_CVT_RGBA2BGRA = 5`
  - `OCVU_INTER_NEAREST = 0`, `OCVU_INTER_LINEAR = 1`

**設計の要点**

`cv::cvtColor` などは失敗時に `cv::Exception` を投げる。`OCVU_TRY_END` の
`catch (const std::exception&)` が受けるが、それだと `OCVU_STATUS_UNKNOWN_ERROR` になる。
**OpenCV 由来の失敗は `OCVU_STATUS_OPENCV_ERROR` として区別できるべき**なので、
各関数で `catch (const cv::Exception& e)` を先に置く。

`dst` は呼び出し側が作った handle である。中身は関数側が上書きするので、
形状が合っていなくてもよい（OpenCV が必要に応じて再確保する）。ただし
`src` と `dst` が同じ handle の場合、OpenCV の in-place 対応は関数によって異なるので、
**同一 handle を拒否する**。曖昧な挙動を ABI に持ち込まない。

- [ ] **Step 1: L1 の失敗するテストを書く**

`native/tests/test_imgproc.cpp`:

```cpp
#include <gtest/gtest.h>

#include <cstdint>
#include <vector>

#include "opencv_unity_native.h"

namespace {

ocvu_mat_handle MakeMat(int rows, int cols, int32_t type) {
    ocvu_mat_handle h = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(rows, cols, type, &h), OCVU_STATUS_OK);
    return h;
}

}  // namespace

TEST(Imgproc, CvtColorBgrToGrayProducesOneChannel) {
    ocvu_mat_handle src = MakeMat(2, 2, OCVU_MAT_TYPE_8UC3);
    ocvu_mat_handle dst = MakeMat(1, 1, OCVU_MAT_TYPE_8UC1);

    // BGR = (255, 255, 255) を 4 画素。灰色化すると 255 になる。
    std::vector<uint8_t> white(2 * 2 * 3, 255);
    ASSERT_EQ(ocvu_mat_copy_from_buffer(src, white.data(),
                                        static_cast<int64_t>(white.size()), 2 * 3),
              OCVU_STATUS_OK);

    ASSERT_EQ(ocvu_cvt_color(src, dst, OCVU_CVT_BGR2GRAY), OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.channels, 1);
    EXPECT_EQ(info.rows, 2);
    EXPECT_EQ(info.cols, 2);

    std::vector<uint8_t> gray(4, 0);
    ASSERT_EQ(ocvu_mat_copy_to_buffer(dst, gray.data(), 4, 2), OCVU_STATUS_OK);
    for (uint8_t v : gray) { EXPECT_EQ(v, 255); }

    ocvu_mat_release(src);
    ocvu_mat_release(dst);
}

TEST(Imgproc, ResizeChangesTheReportedShape) {
    ocvu_mat_handle src = MakeMat(4, 4, OCVU_MAT_TYPE_8UC1);
    ocvu_mat_handle dst = MakeMat(1, 1, OCVU_MAT_TYPE_8UC1);

    ASSERT_EQ(ocvu_resize(src, dst, 2, 8, OCVU_INTER_LINEAR), OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.cols, 2) << "width maps to cols";
    EXPECT_EQ(info.rows, 8) << "height maps to rows";

    ocvu_mat_release(src);
    ocvu_mat_release(dst);
}

TEST(Imgproc, GaussianBlurSpreadsASinglePixel) {
    ocvu_mat_handle src = MakeMat(5, 5, OCVU_MAT_TYPE_8UC1);
    ocvu_mat_handle dst = MakeMat(1, 1, OCVU_MAT_TYPE_8UC1);

    std::vector<uint8_t> dot(25, 0);
    dot[2 * 5 + 2] = 255;  // 中央だけ白
    ASSERT_EQ(ocvu_mat_copy_from_buffer(src, dot.data(), 25, 5), OCVU_STATUS_OK);

    ASSERT_EQ(ocvu_gaussian_blur(src, dst, 3, 3, 0.0, 0.0), OCVU_STATUS_OK);

    std::vector<uint8_t> blurred(25, 0);
    ASSERT_EQ(ocvu_mat_copy_to_buffer(dst, blurred.data(), 25, 5), OCVU_STATUS_OK);

    EXPECT_LT(blurred[2 * 5 + 2], 255) << "the centre must lose intensity";
    EXPECT_GT(blurred[2 * 5 + 1], 0) << "a neighbour must gain intensity";

    ocvu_mat_release(src);
    ocvu_mat_release(dst);
}

TEST(Imgproc, SameHandleForSourceAndDestinationIsRejected) {
    ocvu_mat_handle h = MakeMat(2, 2, OCVU_MAT_TYPE_8UC3);
    EXPECT_EQ(ocvu_cvt_color(h, h, OCVU_CVT_BGR2GRAY), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_resize(h, h, 4, 4, OCVU_INTER_LINEAR), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_gaussian_blur(h, h, 3, 3, 0.0, 0.0), OCVU_STATUS_INVALID_ARGUMENT);
    ocvu_mat_release(h);
}

TEST(Imgproc, InvalidHandlesAreRejected) {
    ocvu_mat_handle valid = MakeMat(2, 2, OCVU_MAT_TYPE_8UC3);
    EXPECT_EQ(ocvu_cvt_color(OCVU_MAT_HANDLE_NONE, valid, OCVU_CVT_BGR2GRAY),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_cvt_color(valid, OCVU_MAT_HANDLE_NONE, OCVU_CVT_BGR2GRAY),
              OCVU_STATUS_INVALID_HANDLE);
    ocvu_mat_release(valid);
}

TEST(Imgproc, OpenCvFailureBecomesOpenCvErrorNotUnknownError) {
    // 1 チャンネルの Mat に BGR2GRAY を掛けると OpenCV が例外を投げる。
    // 例外が ABI を越えないだけでなく、由来が分かる status になること。
    ocvu_mat_handle src = MakeMat(2, 2, OCVU_MAT_TYPE_8UC1);
    ocvu_mat_handle dst = MakeMat(1, 1, OCVU_MAT_TYPE_8UC1);

    EXPECT_EQ(ocvu_cvt_color(src, dst, OCVU_CVT_BGR2GRAY), OCVU_STATUS_OPENCV_ERROR);
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_OPENCV_ERROR);

    ocvu_mat_release(src);
    ocvu_mat_release(dst);
}

TEST(Imgproc, InvalidKernelSizeIsRejected) {
    ocvu_mat_handle src = MakeMat(4, 4, OCVU_MAT_TYPE_8UC1);
    ocvu_mat_handle dst = MakeMat(1, 1, OCVU_MAT_TYPE_8UC1);

    // GaussianBlur の kernel は正の奇数でなければならない。
    EXPECT_EQ(ocvu_gaussian_blur(src, dst, 2, 3, 0.0, 0.0), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_gaussian_blur(src, dst, 0, 3, 0.0, 0.0), OCVU_STATUS_INVALID_ARGUMENT);

    ocvu_mat_release(src);
    ocvu_mat_release(dst);
}

TEST(Imgproc, NonPositiveResizeTargetIsRejected) {
    ocvu_mat_handle src = MakeMat(4, 4, OCVU_MAT_TYPE_8UC1);
    ocvu_mat_handle dst = MakeMat(1, 1, OCVU_MAT_TYPE_8UC1);

    EXPECT_EQ(ocvu_resize(src, dst, 0, 4, OCVU_INTER_LINEAR), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_resize(src, dst, 4, -1, OCVU_INTER_LINEAR), OCVU_STATUS_INVALID_ARGUMENT);

    ocvu_mat_release(src);
    ocvu_mat_release(dst);
}
```

`native/tests/CMakeLists.txt` に `test_imgproc.cpp` を足す。

- [ ] **Step 2: テストが失敗することを確認する**

Run: `pwsh tools/dev.ps1 test-native`
Expected: コンパイルエラー。

- [ ] **Step 3: ヘッダに宣言する**

```c
/* cvtColor の変換コード。cv::COLOR_* の値をそのまま使う（写し間違いを避けるため
 * 実装側で static_assert する）。M2 で必要な 3 つだけを公開する。 */
#define OCVU_CVT_BGRA2BGR   1
#define OCVU_CVT_RGBA2BGRA  5
#define OCVU_CVT_BGR2GRAY   6

/* resize の補間方法。 */
#define OCVU_INTER_NEAREST  0
#define OCVU_INTER_LINEAR   1

/*
 * 色空間を変換する。dst の形状と型は結果に応じて上書きされる。
 * src と dst が同じ handle の場合は OCVU_STATUS_INVALID_ARGUMENT を返す
 * （OpenCV の in-place 対応は関数ごとに異なり、曖昧さを ABI に持ち込まない）。
 * OpenCV 由来の失敗は OCVU_STATUS_OPENCV_ERROR になる。
 */
OCVU_API ocvu_status ocvu_cvt_color(ocvu_mat_handle src, ocvu_mat_handle dst,
                                    int32_t code);

/*
 * width x height に拡大縮小する。width / height が 1 未満なら
 * OCVU_STATUS_INVALID_ARGUMENT。src と dst の同一 handle も同様に拒否する。
 */
OCVU_API ocvu_status ocvu_resize(ocvu_mat_handle src, ocvu_mat_handle dst,
                                 int32_t width, int32_t height,
                                 int32_t interpolation);

/*
 * Gaussian ぼかしを掛ける。ksize は正の奇数でなければならず、
 * そうでなければ OCVU_STATUS_INVALID_ARGUMENT。
 * sigma に 0 を渡すと OpenCV が ksize から算出する。
 */
OCVU_API ocvu_status ocvu_gaussian_blur(ocvu_mat_handle src, ocvu_mat_handle dst,
                                        int32_t ksize_width, int32_t ksize_height,
                                        double sigma_x, double sigma_y);
```

- [ ] **Step 4: 実装する**

`native/src/ocvu_imgproc.cpp`:

```cpp
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

/*
 * ABI に出す定数が OpenCV の値と一致していることを、写し間違いではなく
 * コンパイル時に固定する。OpenCV 側が値を変えたらビルドが落ちる。
 */
static_assert(OCVU_CVT_BGRA2BGR == cv::COLOR_BGRA2BGR, "cvt code drift");
static_assert(OCVU_CVT_RGBA2BGRA == cv::COLOR_RGBA2BGRA, "cvt code drift");
static_assert(OCVU_CVT_BGR2GRAY == cv::COLOR_BGR2GRAY, "cvt code drift");
static_assert(OCVU_INTER_NEAREST == cv::INTER_NEAREST, "interpolation drift");
static_assert(OCVU_INTER_LINEAR == cv::INTER_LINEAR, "interpolation drift");

namespace {

/*
 * src / dst handle を解決する。同一 handle は拒否する。
 * 失敗した場合は *out_status に理由を入れて false を返す。
 */
bool resolve_pair(ocvu_mat_handle src, ocvu_mat_handle dst,
                  cv::Mat** out_src, cv::Mat** out_dst, ocvu_status* out_status) {
    if (src == dst) {
        *out_status = ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "src and dst must be different handles (in-place is not supported)");
        return false;
    }
    cv::Mat* s = ::ocvu::mat_table_get(src);
    if (s == nullptr) {
        *out_status = ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                             "src handle is invalid");
        return false;
    }
    cv::Mat* d = ::ocvu::mat_table_get(dst);
    if (d == nullptr) {
        *out_status = ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                             "dst handle is invalid");
        return false;
    }
    *out_src = s;
    *out_dst = d;
    return true;
}

}  // namespace

extern "C" ocvu_status ocvu_cvt_color(ocvu_mat_handle src, ocvu_mat_handle dst,
                                      int32_t code) {
    OCVU_TRY_BEGIN
    cv::Mat* s = nullptr;
    cv::Mat* d = nullptr;
    ocvu_status failure = OCVU_STATUS_OK;
    if (!resolve_pair(src, dst, &s, &d, &failure)) { return failure; }

    try {
        cv::cvtColor(*s, *d, code);
    } catch (const cv::Exception& e) {
        // OCVU_TRY_END でも捕まるが、そこでは UNKNOWN_ERROR になってしまう。
        // OpenCV 由来だと分かる status を返すためにここで先に受ける。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_resize(ocvu_mat_handle src, ocvu_mat_handle dst,
                                   int32_t width, int32_t height,
                                   int32_t interpolation) {
    OCVU_TRY_BEGIN
    if (width < 1 || height < 1) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "width and height must be >= 1");
    }
    cv::Mat* s = nullptr;
    cv::Mat* d = nullptr;
    ocvu_status failure = OCVU_STATUS_OK;
    if (!resolve_pair(src, dst, &s, &d, &failure)) { return failure; }

    try {
        cv::resize(*s, *d, cv::Size(width, height), 0.0, 0.0, interpolation);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_gaussian_blur(ocvu_mat_handle src, ocvu_mat_handle dst,
                                          int32_t ksize_width, int32_t ksize_height,
                                          double sigma_x, double sigma_y) {
    OCVU_TRY_BEGIN
    if (ksize_width < 1 || ksize_height < 1 ||
        (ksize_width % 2) == 0 || (ksize_height % 2) == 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "kernel size must be a positive odd number");
    }
    cv::Mat* s = nullptr;
    cv::Mat* d = nullptr;
    ocvu_status failure = OCVU_STATUS_OK;
    if (!resolve_pair(src, dst, &s, &d, &failure)) { return failure; }

    try {
        cv::GaussianBlur(*s, *d, cv::Size(ksize_width, ksize_height), sigma_x, sigma_y);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

`native/CMakeLists.txt` に `src/ocvu_imgproc.cpp` を足す。

- [ ] **Step 5: L1 が通ることを確認する**

Run: `pwsh tools/dev.ps1 test-native`
Expected: PASS。

- [ ] **Step 6: L3 のテストを書く**

`NativeMethods.cs`:

```csharp
[DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
internal static extern int ocvu_cvt_color(ulong src, ulong dst, int code);

[DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
internal static extern int ocvu_resize(
    ulong src, ulong dst, int width, int height, int interpolation);

[DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
internal static extern int ocvu_gaussian_blur(
    ulong src, ulong dst, int ksizeWidth, int ksizeHeight, double sigmaX, double sigmaY);
```

`tests/Managed/CvUnity.Tests.Managed/ImgprocTests.cs`:

```csharp
using CvUnity;
using CvUnity.Interop;
using Xunit;

namespace CvUnity.Tests.Managed
{
    public class ImgprocTests
    {
        [Fact]
        public void CvtColor_BgrToGray_ProducesTheExpectedBytes()
        {
            ulong src, dst;
            Assert.Equal(0, NativeMethods.ocvu_mat_create(2, 2, 16, out src));
            Assert.Equal(0, NativeMethods.ocvu_mat_create(1, 1, 0, out dst));

            var white = new byte[2 * 2 * 3];
            for (int i = 0; i < white.Length; i++) { white[i] = 255; }
            Assert.Equal(0, NativeMethods.ocvu_mat_copy_from_buffer(
                src, white, white.Length, 6));

            Assert.Equal(0, NativeMethods.ocvu_cvt_color(src, dst, 6));

            var gray = new byte[4];
            Assert.Equal(0, NativeMethods.ocvu_mat_copy_to_buffer(dst, gray, 4, 2));
            Assert.All(gray, b => Assert.Equal(255, b));

            NativeMethods.ocvu_mat_release(src);
            NativeMethods.ocvu_mat_release(dst);
        }

        [Fact]
        public void OpenCvFailure_SurfacesAsOpenCvErrorWithAMessage()
        {
            // 例外が P/Invoke フレームへ unwind すると CLR ごと落ちる。緑であること
            // 自体が「例外が境界を越えていない」ことの結果である。
            ulong src, dst;
            Assert.Equal(0, NativeMethods.ocvu_mat_create(2, 2, 0, out src));
            Assert.Equal(0, NativeMethods.ocvu_mat_create(1, 1, 0, out dst));

            var status = (CvStatus)NativeMethods.ocvu_cvt_color(src, dst, 6);

            Assert.Equal(CvStatus.OpenCvError, status);
            Assert.NotEmpty(CvNative.GetLastErrorMessage());

            NativeMethods.ocvu_mat_release(src);
            NativeMethods.ocvu_mat_release(dst);
        }

        [Fact]
        public void Resize_MapsWidthToColsAndHeightToRows()
        {
            // 幅と高さの取り違えは、正方形の画像でテストすると永久に気づけない。
            // 非正方形で固定する。
            ulong src, dst;
            Assert.Equal(0, NativeMethods.ocvu_mat_create(4, 4, 0, out src));
            Assert.Equal(0, NativeMethods.ocvu_mat_create(1, 1, 0, out dst));

            Assert.Equal(0, NativeMethods.ocvu_resize(src, dst, 2, 8, 1));

            OcvuMatInfo info;
            Assert.Equal(0, NativeMethods.ocvu_mat_get_info(dst, out info));
            Assert.Equal(2, info.Cols);
            Assert.Equal(8, info.Rows);

            NativeMethods.ocvu_mat_release(src);
            NativeMethods.ocvu_mat_release(dst);
        }
    }
}
```

- [ ] **Step 7: 全レーンと ASan を回す**

Run: `pwsh tools/dev.ps1 test` と `pwsh tools/dev.ps1 test-asan`
Expected: 両方 PASS。

- [ ] **Step 8: コミット**

```bash
git add native/include/opencv_unity_native.h native/src/ocvu_imgproc.cpp native/CMakeLists.txt native/tests/test_imgproc.cpp native/tests/CMakeLists.txt Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.cs tests/Managed/CvUnity.Tests.Managed/ImgprocTests.cs
git commit -m "feat(imgproc): add cvtColor, resize and GaussianBlur with OpenCV errors kept distinct"
```

---

### Task 4: L3 のクラッシュ・ハング耐性を証明する

**Files:**
- Create: `tests/Managed/CvUnity.Tests.Managed/HarnessProbeTests.cs`, `tools/run-managed-probe.ps1`
- Modify: `native/include/opencv_unity_native.h`（`ocvu_debug_crash` の宣言）, `native/src/ocvu_debug.cpp`
- Modify: `tools/dev.ps1`（`test-managed-probe` サブコマンド）
- Modify: `.github/workflows/ci-native.yml`

**Interfaces:**
- Consumes: 既存の `ocvu_debug_throw`
- Produces: `ocvu_status ocvu_debug_crash(int32_t kind)`（0 = segfault、1 = 無限ループ）、`dev.ps1 test-managed-probe`

**なぜこのタスクがあるか**

`CLAUDE.md` が明示している未証明の前提である。

> **L3 のクラッシュ・ハング耐性はまだ証明されていない。** L1 / L2 には意図的に
> クラッシュ・ハングする `native/tests/ocvu_probe.cpp` があり…L3 には同等のプローブが
> 無い。…managed 側からネイティブがクラッシュ／デッドロックしたときに本当に有限時間で
> 赤くなるかは未検証である。

M2 は所有権の誤りを status に変える設計を入れる。**その設計が破れたときに L3 が赤くなる
ことを、先に確かめておく必要がある。** 確かめずに進むと、L3 の緑が何を意味するのか
分からないまま Task 1〜3 の結果を信じることになる。

- [ ] **Step 1: native 側に意図的なクラッシュ経路を足す**

`native/include/opencv_unity_native.h`（`ocvu_debug_throw` の隣）:

```c
/*
 * conformance test 用に、意図的にプロセスを壊す。
 * kind: 0 = 不正アクセスで即死、1 = 戻ってこない（無限ループ）
 *
 * ocvu_debug_throw と違い、これは status を返さない — 戻ってこないからである。
 * L3 のハーネスが、managed 側からネイティブが死んだときに有限時間で赤くなるかを
 * 確かめるためだけに存在する。通常の経路からは決して呼ばれない。
 */
OCVU_API void ocvu_debug_crash(int32_t kind);
```

`native/src/ocvu_debug.cpp` に追加:

```cpp
extern "C" void ocvu_debug_crash(int32_t kind) {
    // OCVU_TRY_BEGIN で囲まない。囲む対象は「例外を status に変える」関数であり、
    // これは意図的に落とすための関数で、status を返さない（hook の検査対象外）。
    if (kind == 0) {
        volatile int* p = nullptr;
        *p = 1;  // 意図的な不正アクセス
    } else {
        for (;;) {
            // 意図的に戻らない。ハング検出の対象。
        }
    }
}
```

- [ ] **Step 2: プローブを走らせる仕組みを書く（まず失敗する状態で）**

`tests/Managed/CvUnity.Tests.Managed/HarnessProbeTests.cs`:

```csharp
using System.Runtime.InteropServices;
using Xunit;

namespace CvUnity.Tests.Managed
{
    /// <summary>
    /// このクラスは「意図的に落ちる」ためのものであり、通常の test 実行には
    /// 含めない（含めると常に赤くなる）。tools/run-managed-probe.ps1 が
    /// フィルタで名指しして起動し、落ちることそのものを確認する。
    /// </summary>
    public class HarnessProbeTests
    {
        [DllImport("opencv_unity_native", CallingConvention = CallingConvention.Cdecl)]
        private static extern void ocvu_debug_crash(int kind);

        [Fact]
        [Trait("Category", "Probe")]
        public void Probe_NativeSegfault()
        {
            ocvu_debug_crash(0);
        }

        [Fact]
        [Trait("Category", "Probe")]
        public void Probe_NativeHang()
        {
            ocvu_debug_crash(1);
        }
    }
}
```

既定の `dotnet test` からは除外する。`tests/Managed/CvUnity.Tests.Managed/` の
実行時フィルタで `Category!=Probe` を指定する形にし、`dev.ps1` の `Test-Managed` に
`--filter "Category!=Probe"` を足す。

- [ ] **Step 3: プローブが「赤くなること」を検査するスクリプトを書く**

`tools/run-managed-probe.ps1`:

```powershell
#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    L3 のクラッシュ・ハング耐性を実証する。

    通常のテストと逆で、**成功したら失敗**である。ネイティブが落ちた／固まったときに
    dotnet test が有限時間で非ゼロ終了することを確かめるのが目的なので、
    非ゼロ終了こそが期待する結果になる。

    cmake/run_expect_failure.cmake が L1 / L2 でやっていることの L3 版である。
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $repoRoot 'tests/Managed/CvUnity.Tests.Managed/CvUnity.Tests.Managed.csproj'
$failures = @()

function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

function Invoke-Probe([string]$testName, [int]$timeoutSeconds) {
    $start = Get-Date
    # --blame-hang がハングを有限時間で殺す。この上限が効いていることが検査対象。
    & dotnet test $project `
        --filter "FullyQualifiedName~$testName" `
        --blame-hang --blame-hang-timeout "${timeoutSeconds}s" `
        --nologo 2>&1 | Out-Null
    $exit = $LASTEXITCODE
    $elapsed = (Get-Date) - $start
    return [pscustomobject]@{ ExitCode = $exit; Seconds = $elapsed.TotalSeconds }
}

Write-Host '== L3 probe: native segfault must turn the run red ==' -ForegroundColor Cyan
$seg = Invoke-Probe 'Probe_NativeSegfault' 60
Assert-That ($seg.ExitCode -ne 0) 'a native segfault makes dotnet test exit non-zero'
Assert-That ($seg.Seconds -lt 120) "the segfault run finished in bounded time ($([int]$seg.Seconds)s)"

Write-Host '== L3 probe: native hang must be killed and turn the run red ==' -ForegroundColor Cyan
$hang = Invoke-Probe 'Probe_NativeHang' 30
Assert-That ($hang.ExitCode -ne 0) 'a native hang makes dotnet test exit non-zero'
Assert-That ($hang.Seconds -lt 180) "the hang was killed rather than running forever ($([int]$hang.Seconds)s)"

if ($failures.Count -gt 0) {
    [Console]::Error.WriteLine("`n$($failures.Count) assertion(s) failed")
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
```

- [ ] **Step 4: プローブを実行して、実際に赤くなるか見る**

Run: `pwsh tools/run-managed-probe.ps1`
Expected: 4 つの assertion がすべて PASS。**ここが PASS しないなら、L3 の緑は
「ネイティブが壊れていない」ことを意味していなかったということであり、それ自体が
M2 の重要な発見である。** その場合は結果をそのまま報告し、勝手に回避しないこと。

- [ ] **Step 5: `dev.ps1` に配線する**

`test-managed-probe` サブコマンドを足し、`ValidateSet` にも追加する。
所要時間が数分になるので `test` には**含めない**。`test-tools-slow` と同じ扱いで
CI に置く。`ci-native.yml` の「Run the slow tools tests」の次に step を足す。

```yaml
      - name: Run the L3 crash and hang probes
        shell: pwsh
        run: ./tools/dev.ps1 test-managed-probe
```

- [ ] **Step 6: CLAUDE.md の未証明の記述を更新する**

「L3 のクラッシュ・ハング耐性はまだ証明されていない」の段落を、実測に基づいた記述に
置き換える。**証明できたなら証明できたと書き、できなかったならできなかったと書く。**

- [ ] **Step 7: コミット**

```bash
git add native/include/opencv_unity_native.h native/src/ocvu_debug.cpp tests/Managed/CvUnity.Tests.Managed/HarnessProbeTests.cs tools/run-managed-probe.ps1 tools/dev.ps1 .github/workflows/ci-native.yml CLAUDE.md
git commit -m "test(l3): prove a native crash and hang actually turn the managed lane red"
```

---

### Task 5: Unity 統合層と最小 UPM パッケージ

**Files:**
- Create: `Packages/com.ayutaz.opencv-unity-native/Runtime/UnityIntegration/CvUnity.UnityIntegration.asmdef`
- Create: `Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvMat.cs`（UnityEngine 非依存。UnityIntegration ではない — L3 が触れるのは Core だけである）
- Create: `Packages/com.ayutaz.opencv-unity-native/Runtime/UnityIntegration/TextureConverter.cs`
- Create: `Packages/com.ayutaz.opencv-unity-native/package.json`
- Modify: `Packages/com.ayutaz.opencv-unity-native/Runtime/Core/` と `Runtime/Interop/` の asmdef（無ければ作る）
- Delete: `Packages/com.ayutaz.opencv-unity-native/Runtime/CvUnity.Runtime.asmdef` — 分割前に Core と Interop を 1 つの assembly にまとめていたもの。3 分割後はコンパイル対象が空になり、しかも shim の AssemblyName と同名（無関係な別物）で紛らわしいので消す

**Interfaces:**
- Consumes: Task 1〜3 の全 ABI
- Produces: `CvUnity.CvMat`（`IDisposable`）、`CvUnity.Unity.TextureConverter.ToMat(Texture2D)` / `ToTexture(CvMat, Texture2D)`

**設計の要点**

`CvMat` は `Runtime/Core` に置く（UnityEngine 非依存）。`IDisposable` で handle を
包み、`Dispose` 済みの再利用を managed 側で `ObjectDisposedException` にする。
native 側の `INVALID_HANDLE` は最後の砦であって、通常はここで捕まえる。

`TextureConverter` は `Runtime/UnityIntegration` に置く。**ここだけが UnityEngine を
参照してよい。** `Texture2D.GetRawTextureData<byte>()` が返す `NativeArray` から
ポインタを取り、`ocvu_mat_copy_from_buffer` に渡す。**そのポインタを保持しない** —
呼び出しが戻ったら忘れる。

`Runtime/Core` と `Runtime/Interop` に asmdef が無いと、Unity は既定 assembly に
入れてしまい UnityEngine 参照が通ってしまう。**asmdef で機械的に切る。**

- [ ] **Step 1: asmdef を 3 つ作る**

`Runtime/Interop/CvUnity.Interop.asmdef`:

```json
{
    "name": "CvUnity.Interop",
    "rootNamespace": "CvUnity.Interop",
    "references": [],
    "includePlatforms": [],
    "excludePlatforms": [],
    "allowUnsafeCode": true,
    "noEngineReferences": true
}
```

`noEngineReferences: true` が要点である。UnityEngine を参照しようとするとビルドが
落ちる。これが L3 を Unity 抜きで走らせ続けるための機械的な保証になる。

`Runtime/Core/CvUnity.Core.asmdef` も同じ形で、`references` に `CvUnity.Interop` を入れる。

`Runtime/UnityIntegration/CvUnity.UnityIntegration.asmdef` は
`noEngineReferences` を**書かない**（既定の false = UnityEngine を参照できる）。
`references` に `CvUnity.Core` と `CvUnity.Interop` を入れる。

- [ ] **Step 2: `CvMat` の L3 テストを書く**

`tests/Managed/CvUnity.Tests.Managed/CvMatTests.cs`:

```csharp
using System;
using CvUnity;
using Xunit;

namespace CvUnity.Tests.Managed
{
    public class CvMatTests
    {
        [Fact]
        public void Dispose_ReleasesTheHandleAndASecondDisposeIsHarmless()
        {
            var mat = CvMat.Create(2, 3, CvMatType.Gray8);
            Assert.Equal(2, mat.Rows);
            Assert.Equal(3, mat.Cols);

            mat.Dispose();
            mat.Dispose();  // 二重 Dispose は例外にならない（IDisposable の規約）
        }

        [Fact]
        public void UsingAfterDispose_ThrowsObjectDisposedRatherThanReachingNative()
        {
            var mat = CvMat.Create(2, 2, CvMatType.Gray8);
            mat.Dispose();

            Assert.Throws<ObjectDisposedException>(() => { var _ = mat.Rows; });
            Assert.Throws<ObjectDisposedException>(() => mat.CopyTo(new byte[4], 2));
        }

        [Fact]
        public void CopyFromAndCopyTo_RoundTrip()
        {
            using var mat = CvMat.Create(2, 2, CvMatType.Gray8);
            var input = new byte[] { 1, 2, 3, 4 };
            mat.CopyFrom(input, 2);

            var output = new byte[4];
            mat.CopyTo(output, 2);
            Assert.Equal(input, output);
        }

        [Fact]
        public void CreateWithInvalidSize_ThrowsWithTheNativeMessage()
        {
            var ex = Assert.Throws<CvNativeException>(
                () => CvMat.Create(0, 2, CvMatType.Gray8));
            Assert.Equal(CvStatus.InvalidArgument, ex.Status);
        }
    }
}
```

- [ ] **Step 3: テストが失敗することを確認する**

Run: `pwsh tools/dev.ps1 test-managed`
Expected: コンパイルエラー。`CvMat` が存在しない。

- [ ] **Step 4: `CvMat` を実装する**

`Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvMat.cs`:

```csharp
using System;
using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>ABI に出す Mat の型。native の OCVU_MAT_TYPE_* と対応する。</summary>
    public enum CvMatType
    {
        Gray8 = 0,
        Bgr24 = 16,
        Bgra32 = 24,
    }

    /// <summary>
    /// native が所有する Mat への handle を包む。
    ///
    /// この型が指すメモリは常に native 側のものである。Unity が所有する
    /// メモリを指す CvMat は存在しない（docs/abi-ownership-and-versioning.md §1）。
    /// </summary>
    public sealed class CvMat : IDisposable
    {
        private ulong _handle;

        private CvMat(ulong handle) { _handle = handle; }

        public static CvMat Create(int rows, int cols, CvMatType type)
        {
            ulong handle;
            var status = (CvStatus)NativeMethods.ocvu_mat_create(
                rows, cols, (int)type, out handle);
            CvNative.ThrowIfFailed(status);
            return new CvMat(handle);
        }

        internal ulong Handle
        {
            get
            {
                ThrowIfDisposed();
                return _handle;
            }
        }

        public int Rows => GetInfo().Rows;
        public int Cols => GetInfo().Cols;
        public int Channels => GetInfo().Channels;
        public long Step => GetInfo().Step;

        public CvMat Clone()
        {
            ulong handle;
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_mat_clone(Handle, out handle));
            return new CvMat(handle);
        }

        public void CopyFrom(byte[] source, long stride)
        {
            if (source == null) { throw new ArgumentNullException(nameof(source)); }
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_mat_copy_from_buffer(
                Handle, source, source.LongLength, stride));
        }

        public void CopyTo(byte[] destination, long stride)
        {
            if (destination == null) { throw new ArgumentNullException(nameof(destination)); }
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_mat_copy_to_buffer(
                Handle, destination, destination.LongLength, stride));
        }

        public void Dispose()
        {
            if (_handle == 0) { return; }
            NativeMethods.ocvu_mat_release(_handle);
            _handle = 0;
        }

        private OcvuMatInfo GetInfo()
        {
            OcvuMatInfo info;
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_mat_get_info(Handle, out info));
            return info;
        }

        private void ThrowIfDisposed()
        {
            if (_handle == 0) { throw new ObjectDisposedException(nameof(CvMat)); }
        }
    }
}
```

`OcvuMatInfo` と `NativeMethods` は `internal` のままにする。`public` にしない —
P/Invoke 宣言は実装詳細であり、利用者に見せる API ではない。`CvUnity.Core` から
見えるのは Task 1 Step 9 で作った `Runtime/Interop/AssemblyInfo.cs` の
`InternalsVisibleTo` による。`CvMat.GetInfo` を private にしてあるので、
`OcvuMatInfo` が公開 API の signature に現れることもない。

- [ ] **Step 5: L3 が通ることを確認する**

Run: `pwsh tools/dev.ps1 test-managed`
Expected: PASS。

- [ ] **Step 6: `TextureConverter` を書く（Unity 側。L4 で検証する）**

`Runtime/UnityIntegration/TextureConverter.cs`:

```csharp
using System;
using Unity.Collections;
using Unity.Collections.LowLevel.Unsafe;
using UnityEngine;

namespace CvUnity.Unity
{
    /// <summary>Texture2D と CvMat の相互変換。</summary>
    public static class TextureConverter
    {
        /// <summary>
        /// Texture2D の内容を新しい CvMat に写す。
        ///
        /// テクスチャのメモリを借りたまま保持しない。GetRawTextureData が返す
        /// NativeArray はテクスチャの更新や破棄で無効になり、それを跨いで
        /// 保持すると存在しないメモリを触ることになる。ここでは 1 回の
        /// コピーで native 側へ移し、呼び出しが戻った時点で借用を終える
        /// （docs/abi-ownership-and-versioning.md §1）。
        /// </summary>
        public static CvMat ToMat(Texture2D texture)
        {
            if (texture == null) { throw new ArgumentNullException(nameof(texture)); }
            if (texture.format != TextureFormat.RGBA32)
            {
                throw new NotSupportedException(
                    "M2 supports RGBA32 only; got " + texture.format);
            }

            var raw = texture.GetRawTextureData<byte>();
            var mat = CvMat.Create(texture.height, texture.width, CvMatType.Bgra32);
            try
            {
                var managed = raw.ToArray();
                mat.CopyFrom(managed, texture.width * 4);
                return mat;
            }
            catch
            {
                mat.Dispose();
                throw;
            }
        }

        /// <summary>CvMat の内容を既存の Texture2D に書き戻し、Apply する。</summary>
        public static void ToTexture(CvMat mat, Texture2D texture)
        {
            if (mat == null) { throw new ArgumentNullException(nameof(mat)); }
            if (texture == null) { throw new ArgumentNullException(nameof(texture)); }
            if (mat.Cols != texture.width || mat.Rows != texture.height)
            {
                throw new ArgumentException(
                    $"size mismatch: mat is {mat.Cols}x{mat.Rows}, texture is {texture.width}x{texture.height}");
            }

            var bytes = new byte[mat.Rows * mat.Cols * mat.Channels];
            mat.CopyTo(bytes, mat.Cols * mat.Channels);
            texture.LoadRawTextureData(bytes);
            texture.Apply();
        }
    }
}
```

- [ ] **Step 7: `package.json` の version を上げる**

`package.json` は既に存在する（`0.0.1`、`keywords` つき、`author` なし）。**全置換しない** —
下の内容は初期案であって、既存の `keywords` を理由なく落とすことになる。変えるのは
`version` を `0.1.0` にする 1 行だけでよい。M2 で初めて実機能が入るためである。

```json
{
  "name": "com.ayutaz.opencv-unity-native",
  "version": "0.1.0",
  "displayName": "OpenCV Unity Native",
  "description": "OpenCV 5 for Unity through a project-owned C ABI.",
  "unity": "6000.0",
  "license": "Apache-2.0",
  "author": { "name": "ayutaz" }
}
```

- [ ] **Step 8: UnityEngine が漏れていないことを確認する**

Run: `pwsh tools/dev.ps1 test`
Expected: PASS。netstandard2.1 の shim がビルドできることが、`Runtime/Core` と
`Runtime/Interop` に UnityEngine が入っていないことの機械的な証拠である。

- [ ] **Step 9: コミット**

```bash
git add Packages/com.ayutaz.opencv-unity-native tests/Managed/CvUnity.Tests.Managed/CvMatTests.cs
git commit -m "feat(unity): add CvMat and the Texture2D bridge, with asmdef keeping UnityEngine out of Core"
```

---

### Task 6: Unity プロジェクトと EditMode テスト（L4）

**Files:**
- Create: `tests/UnityProject/` 一式（`Packages/manifest.json`、`ProjectSettings/`、`Assets/Tests/`）
- Create: `tests/UnityProject/Assets/Tests/EditMode/VerticalSliceTests.cs`
- Modify: `tools/dev.ps1`（`test-unity-editmode` サブコマンド）

**Interfaces:**
- Consumes: Task 5 の `CvMat` と `TextureConverter`
- Produces: `dev.ps1 test-unity-editmode`

**設計の要点**

Unity プロジェクトは `Packages/manifest.json` の `file:` 参照で UPM パッケージを
取り込む。これが「ローカル参照可能な最小 UPM パッケージとして動作する」という
完了条件そのものの検証になる。

native の DLL は `Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/x86_64/` に
置く必要がある。`dev.ps1` のビルド後にコピーする step を足す。

- [ ] **Step 1: Unity プロジェクトの雛形を作る**

`tests/UnityProject/Packages/manifest.json`:

```json
{
  "dependencies": {
    "com.ayutaz.opencv-unity-native": "file:../../../Packages/com.ayutaz.opencv-unity-native",
    "com.unity.test-framework": "1.4.5"
  },
  "testables": [
    "com.ayutaz.opencv-unity-native"
  ]
}
```

`ProjectSettings/ProjectVersion.txt` に対象の Unity 6000.x を書く。
`uloop-launch` skill で実際のバージョンを確認して合わせること。

- [ ] **Step 2: EditMode テストを書く**

`tests/UnityProject/Assets/Tests/EditMode/VerticalSliceTests.cs`:

```csharp
using System;
using CvUnity;
using CvUnity.Unity;
using NUnit.Framework;
using UnityEngine;

public class VerticalSliceTests
{
    [Test]
    public void NativeLibraryLoadsAndReportsItsVersions()
    {
        Assert.AreEqual(1, CvNative.AbiVersion);
        Assert.AreEqual("5.0.0", CvNative.OpenCvVersion);
    }

    [Test]
    public void Texture2D_RoundTripsThroughOpenCvUnchanged()
    {
        var texture = new Texture2D(4, 2, TextureFormat.RGBA32, false);
        var pixels = new Color32[8];
        for (int i = 0; i < pixels.Length; i++)
        {
            pixels[i] = new Color32((byte)(i * 10), (byte)(i * 5), (byte)i, 255);
        }
        texture.SetPixels32(pixels);
        texture.Apply();

        using var mat = TextureConverter.ToMat(texture);
        Assert.AreEqual(4, mat.Cols);
        Assert.AreEqual(2, mat.Rows);
        Assert.AreEqual(4, mat.Channels);

        var result = new Texture2D(4, 2, TextureFormat.RGBA32, false);
        TextureConverter.ToTexture(mat, result);

        var original = texture.GetRawTextureData<byte>().ToArray();
        var roundTripped = result.GetRawTextureData<byte>().ToArray();
        CollectionAssert.AreEqual(original, roundTripped);
    }

    [Test]
    public void Blur_ChangesPixelsAndKeepsTheShape()
    {
        var texture = new Texture2D(8, 8, TextureFormat.RGBA32, false);
        var pixels = new Color32[64];
        for (int i = 0; i < pixels.Length; i++) { pixels[i] = new Color32(0, 0, 0, 255); }
        pixels[8 * 4 + 4] = new Color32(255, 255, 255, 255);
        texture.SetPixels32(pixels);
        texture.Apply();

        using var src = TextureConverter.ToMat(texture);
        using var dst = CvMat.Create(1, 1, CvMatType.Bgra32);

        CvOps.GaussianBlur(src, dst, 3, 3, 0.0, 0.0);

        Assert.AreEqual(8, dst.Cols);
        Assert.AreEqual(8, dst.Rows);

        var before = new byte[8 * 8 * 4];
        var after = new byte[8 * 8 * 4];
        src.CopyTo(before, 8 * 4);
        dst.CopyTo(after, 8 * 4);
        CollectionAssert.AreNotEqual(before, after, "the blur must actually change pixels");
    }

    [Test]
    public void DisposedMat_ThrowsInsteadOfCorruptingMemory()
    {
        var mat = CvMat.Create(2, 2, CvMatType.Gray8);
        mat.Dispose();
        Assert.Throws<ObjectDisposedException>(() => { var _ = mat.Rows; });
    }
}
```

`CvOps` は Task 3 の 3 関数の managed wrapper である。`Runtime/Core/CvOps.cs` に
次を作る（Task 5 で作り忘れていた場合はここで足す）:

```csharp
using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>imgproc の薄い wrapper。status を例外に変換する。</summary>
    public static class CvOps
    {
        public const int Bgra2Bgr = 1;
        public const int Rgba2Bgra = 5;
        public const int Bgr2Gray = 6;
        public const int InterNearest = 0;
        public const int InterLinear = 1;

        public static void CvtColor(CvMat src, CvMat dst, int code) =>
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_cvt_color(
                src.Handle, dst.Handle, code));

        public static void Resize(CvMat src, CvMat dst, int width, int height, int interpolation) =>
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_resize(
                src.Handle, dst.Handle, width, height, interpolation));

        public static void GaussianBlur(CvMat src, CvMat dst,
                                        int ksizeWidth, int ksizeHeight,
                                        double sigmaX, double sigmaY) =>
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_gaussian_blur(
                src.Handle, dst.Handle, ksizeWidth, ksizeHeight, sigmaX, sigmaY));
    }
}
```

`CvMat.Handle` は `internal` なので、`CvOps` が同じ assembly（`CvUnity.Core`）に
あれば見える。

- [ ] **Step 3: DLL を配置する仕組みを `dev.ps1` に足す**

Unity はパッケージ内の `Runtime/Plugins/x86_64/` に置かれた DLL を native plugin と
して読む。ビルド成果物をそこへ写す。**成果物はコミットしない**ので `.gitignore` にも足す。

`tools/dev.ps1` に足す:

```powershell
# Unity は Packages/<id>/Runtime/Plugins/x86_64/ に置かれた DLL を native plugin
# として読み込む。ビルドのたびにここへ写す。
# 写し忘れると Unity 側は「古い DLL のまま緑」という最も紛らわしい状態になるので、
# native をビルドする経路に必ずぶら下げる。
function Copy-NativePluginForUnity {
    $source = Join-Path $RepoRoot 'build/windows-x64-debug/native/Debug/opencv_unity_native.dll'
    if (-not (Test-Path -LiteralPath $source)) {
        Write-DevFailure "native plugin が見つかりません: $source`n先に './tools/dev.ps1 build' を実行してください。"
    }
    $destDir = Join-Path $RepoRoot 'Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/x86_64'
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    Copy-Item -LiteralPath $source -Destination $destDir -Force
    Write-Host "==> copied native plugin to $destDir" -ForegroundColor Cyan
}

function Test-UnityEditMode {
    Build-Native
    Copy-NativePluginForUnity

    $unity = Get-UnityEditorPath
    $project = Join-Path $RepoRoot 'tests/UnityProject'
    $results = Join-Path $RepoRoot 'artifacts/test-results/unity-editmode.xml'
    $log     = Join-Path $RepoRoot 'artifacts/test-results/unity-editmode.log'

    # -batchmode -nographics は CI とローカルで同じ条件にするため常に付ける。
    #
    # -quit は付けない。-runTests は Test Runner がテスト完了後に自分で Unity を
    # 終了させる仕組みで、-quit を併用すると Unity がプロジェクトを開いた直後に
    # 終了し、テストを 1 つも走らせないまま結果 XML も出さずに戻る（実測）。
    #
    # 呼び出しは & ではなく Start-Process -Wait にする。この環境では & が
    # Unity.exe の終了を待たず 17 ms で戻り、$LASTEXITCODE が未設定のまま次へ
    # 進んだ（実測）。待たずに結果 XML を読むと「まだ書かれていない」か
    # 「前回の実行の残骸」を読むことになり、どちらも静かに緑を返す。
    #
    # Unity は失敗時も 0 で終わることがあるので、終了コードと結果 XML の両方を見る。
    $unityArgs = @(
        '-projectPath', $project, '-runTests', '-testPlatform', 'EditMode',
        '-testResults', $results, '-logFile', $log, '-batchmode', '-nographics'
    )
    $proc = Start-Process -FilePath $unity -ArgumentList $unityArgs -Wait -PassThru -NoNewWindow
    $exit = $proc.ExitCode

    if (-not (Test-Path -LiteralPath $results)) {
        Write-DevFailure "Unity が結果 XML を出しませんでした: $results`nログ: $log"
    }
    [xml]$xml = Get-Content -LiteralPath $results
    $failed = [int]$xml.'test-run'.failed
    if ($exit -ne 0 -or $failed -ne 0) {
        Write-DevFailure "Unity EditMode テストが失敗しました（exit $exit、failed $failed）。`nログ: $log"
    }
    Write-Host "==> Unity EditMode: $($xml.'test-run'.passed) passed" -ForegroundColor Green
}
```

`Get-UnityEditorPath` は `tests/UnityProject/ProjectSettings/ProjectVersion.txt` の
バージョンから Unity Hub の既定の配置を組み立てる。実際のパスは `uloop-launch` skill
で確認して合わせること。

`.gitignore` に足す:

```
Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/
```

- [ ] **Step 4: EditMode テストを走らせる**

Run: `pwsh tools/dev.ps1 test-unity-editmode`
Expected: 4 テストすべて PASS。**Unity の起動に 1〜3 分かかるので、これは `test` に
含めない。** `ValidateSet` への追加を忘れないこと（M1 で 1 度これを落とした）。

**`-quit` を付けても Unity は失敗時に 0 で終わることがある。** 上の実装が終了コードと
結果 XML の両方を見ているのはそのためで、片方だけでは「落ちているのに緑」になり得る。
実装したら、テストをわざと 1 つ失敗させて赤くなることを確かめること
（`prove-a-check-works` skill）。

- [ ] **Step 5: コミット**

```bash
git add tests/UnityProject Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvOps.cs tools/dev.ps1 .gitignore
git commit -m "test(unity): add the EditMode vertical slice over a file: UPM reference"
```

---

### Task 7: IL2CPP Player テスト（L5）と `ci-unity.yml`

**Files:**
- Create: `tests/UnityProject/Assets/Tests/PlayMode/PlayerSmokeTests.cs`
- Create: `tests/UnityProject/Assets/Editor/BuildPlayer.cs`
- Create: `.github/workflows/ci-unity.yml`
- Modify: `tools/dev.ps1`（`test-unity-player`）
- Modify: `Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/LinkXml`（stripping 対策）

**Interfaces:**
- Consumes: Task 5・6 の全部
- Produces: `dev.ps1 test-unity-player`、`ci-unity.yml`

**設計の要点**

**IL2CPP の stripping が P/Invoke 宣言を消す**のが最大の危険である。`link.xml` で
`CvUnity.Interop` assembly を保護する。保護が効いているかは、**実際に Player を
ビルドして走らせる以外に確かめる方法が無い**。EditMode (Mono) では再現しない。

Unity ライセンスは GitHub Secrets に登録が必要である。**これは資格情報なので
エージェントが行ってはならない。** 未登録の場合、この Task は「登録待ち」として
止め、勝手に回避策を作らないこと。

- [ ] **Step 1: `link.xml` を書く**

`Packages/com.ayutaz.opencv-unity-native/link.xml`:

```xml
<linker>
  <!--
    IL2CPP の managed code stripping は、参照が静的に辿れない型を削る。
    P/Invoke 宣言は native 側からしか呼ばれないように見えることがあり、
    削られると実行時に EntryPointNotFoundException になる。
    Editor (Mono) では再現しないので、Player で走らせるまで気づけない。
  -->
  <assembly fullname="CvUnity.Interop" preserve="all" />
  <assembly fullname="CvUnity.Core" preserve="all" />
</linker>
```

- [ ] **Step 2: PlayMode テストを書く**

`tests/UnityProject/Assets/Tests/PlayMode/PlayerSmokeTests.cs` は Task 6 の
`VerticalSliceTests` と**同じ 4 つの検証**を行う。EditMode と Player で同一結果に
なることが完了条件なので、内容を変えない。ファイル冒頭にその理由を書くこと。

```csharp
using System.Collections;
using CvUnity;
using CvUnity.Unity;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

/// <summary>
/// EditMode の VerticalSliceTests と同じ検証を Player で行う。
///
/// 内容を変えないこと。M2 の完了条件は「Unity Editor (Mono) と Windows IL2CPP
/// Player の両方で同じ smoke test が通る」であり、違う検証をしたら
/// 「同じ結果になる」ことを確かめたことにならない。
///
/// Player でしか出ない失敗が本命である: IL2CPP の stripping が P/Invoke 宣言を
/// 削ると、ここで EntryPointNotFoundException になる。Mono では再現しない。
/// </summary>
public class PlayerSmokeTests
{
    [UnityTest]
    public IEnumerator NativeLibraryLoadsUnderIl2cpp()
    {
        Assert.AreEqual(1, CvNative.AbiVersion);
        Assert.AreEqual("5.0.0", CvNative.OpenCvVersion);
        yield return null;
    }

    [UnityTest]
    public IEnumerator Texture2D_RoundTripsThroughOpenCvUnchanged()
    {
        var texture = new Texture2D(4, 2, TextureFormat.RGBA32, false);
        var pixels = new Color32[8];
        for (int i = 0; i < pixels.Length; i++)
        {
            pixels[i] = new Color32((byte)(i * 10), (byte)(i * 5), (byte)i, 255);
        }
        texture.SetPixels32(pixels);
        texture.Apply();

        using (var mat = TextureConverter.ToMat(texture))
        {
            var result = new Texture2D(4, 2, TextureFormat.RGBA32, false);
            TextureConverter.ToTexture(mat, result);

            var original = texture.GetRawTextureData<byte>().ToArray();
            var roundTripped = result.GetRawTextureData<byte>().ToArray();
            CollectionAssert.AreEqual(original, roundTripped);
        }
        yield return null;
    }

    [UnityTest]
    public IEnumerator Blur_ChangesPixelsAndKeepsTheShape()
    {
        var texture = new Texture2D(8, 8, TextureFormat.RGBA32, false);
        var pixels = new Color32[64];
        for (int i = 0; i < pixels.Length; i++) { pixels[i] = new Color32(0, 0, 0, 255); }
        pixels[8 * 4 + 4] = new Color32(255, 255, 255, 255);
        texture.SetPixels32(pixels);
        texture.Apply();

        using (var src = TextureConverter.ToMat(texture))
        using (var dst = CvMat.Create(1, 1, CvMatType.Bgra32))
        {
            CvOps.GaussianBlur(src, dst, 3, 3, 0.0, 0.0);
            Assert.AreEqual(8, dst.Cols);
            Assert.AreEqual(8, dst.Rows);
        }
        yield return null;
    }

    [UnityTest]
    public IEnumerator DisposedMat_ThrowsInsteadOfCorruptingMemory()
    {
        var mat = CvMat.Create(2, 2, CvMatType.Gray8);
        mat.Dispose();
        Assert.Throws<System.ObjectDisposedException>(() => { var _ = mat.Rows; });
        yield return null;
    }
}
```

- [ ] **Step 3: Player ビルドとテスト実行を `dev.ps1` に足す**

Scripting backend を IL2CPP にするのは `Assets/Editor/BuildPlayer.cs` で行う。
`ProjectSettings.asset` に書くとファイル形式に依存するので、コードで明示する。

```csharp
using UnityEditor;
using UnityEditor.Build;

/// <summary>
/// batchmode から呼ばれ、Player テストを IL2CPP で走らせるための設定を入れる。
///
/// Mono のまま走らせると M2 の完了条件を満たさない。EditMode との違いは
/// backend そのものであり、stripping が P/Invoke 宣言を消す問題は IL2CPP で
/// しか再現しないからである。
/// </summary>
public static class BuildPlayer
{
    public static void ConfigureIl2cpp()
    {
        var target = NamedBuildTarget.Standalone;
        PlayerSettings.SetScriptingBackend(target, ScriptingImplementation.IL2CPP);
        // stripping を有効にしたまま走らせる。無効にすると link.xml が効いているか
        // 確かめられず、配布時の構成と違うものをテストすることになる。
        PlayerSettings.SetManagedStrippingLevel(target, ManagedStrippingLevel.Medium);
        AssetDatabase.SaveAssets();
    }
}
```

`tools/dev.ps1`:

```powershell
function Test-UnityPlayer {
    Build-Native
    Copy-NativePluginForUnity

    $unity = Get-UnityEditorPath
    $project = Join-Path $RepoRoot 'tests/UnityProject'
    $results = Join-Path $RepoRoot 'artifacts/test-results/unity-player.xml'
    $log     = Join-Path $RepoRoot 'artifacts/test-results/unity-player.log'

    # 先に backend を IL2CPP に固定する。Mono のまま走らせると、
    # M2 が確かめたい stripping の問題が再現しない。
    #
    # 呼び出し規約は Test-UnityEditMode と同じ（Task 6 の注記を参照）:
    # -executeMethod のときは -quit が必要だが、-runTests のときは付けない。
    # どちらも & ではなく Start-Process -Wait で待つ。
    $configureArgs = @(
        '-projectPath', $project, '-batchmode', '-nographics', '-quit',
        '-executeMethod', 'BuildPlayer.ConfigureIl2cpp', '-logFile', "$log.configure"
    )
    $configure = Start-Process -FilePath $unity -ArgumentList $configureArgs -Wait -PassThru -NoNewWindow
    if ($configure.ExitCode -ne 0) {
        Write-DevFailure "IL2CPP の設定に失敗しました。ログ: $log.configure"
    }

    $unityArgs = @(
        '-projectPath', $project, '-runTests', '-testPlatform', 'StandaloneWindows64',
        '-testResults', $results, '-logFile', $log, '-batchmode', '-nographics'
    )
    $proc = Start-Process -FilePath $unity -ArgumentList $unityArgs -Wait -PassThru -NoNewWindow
    $exit = $proc.ExitCode

    if (-not (Test-Path -LiteralPath $results)) {
        Write-DevFailure "Unity が結果 XML を出しませんでした: $results`nログ: $log"
    }
    [xml]$xml = Get-Content -LiteralPath $results
    $failed = [int]$xml.'test-run'.failed
    if ($exit -ne 0 -or $failed -ne 0) {
        Write-DevFailure "Unity Player テストが失敗しました（exit $exit、failed $failed）。`nログ: $log"
    }
    Write-Host "==> Unity Player (IL2CPP): $($xml.'test-run'.passed) passed" -ForegroundColor Green
}
```

`ValidateSet` と `switch` の両方に `test-unity-player` を足す。

- [ ] **Step 4: ローカルで Player テストを走らせる**

Run: `pwsh tools/dev.ps1 test-unity-player`
Expected: 4 テスト PASS。**IL2CPP のビルドは 5〜20 分かかる。**

`EntryPointNotFoundException` が出たら `link.xml` が効いていない。**その場合、
テストを緩めるのではなく stripping 設定を直すこと。** この失敗を再現できたことは
価値があるので、報告に残す。

- [ ] **Step 5: `ci-unity.yml` を書く**

```yaml
name: ci-unity

on:
  push:
    branches: ['**']
  pull_request:

permissions:
  contents: read
  actions: read

jobs:
  editmode:
    name: Unity EditMode (Mono)
    runs-on: windows-2022
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4
      # OpenCV artifact の restore と native ビルドは ci-native.yml と同じ手順を使う
      # （CI 専用の手順を作らない）。
      - name: Restore OpenCV
        shell: pwsh
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: ./tools/opencv.ps1 restore
      - name: Build native
        shell: pwsh
        run: ./tools/dev.ps1 build
      - name: Run EditMode tests
        shell: pwsh
        env:
          UNITY_LICENSE: ${{ secrets.UNITY_LICENSE }}
          UNITY_EMAIL: ${{ secrets.UNITY_EMAIL }}
          UNITY_PASSWORD: ${{ secrets.UNITY_PASSWORD }}
        run: ./tools/dev.ps1 test-unity-editmode

  player:
    name: Unity IL2CPP Player
    runs-on: windows-2022
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@v4
      - name: Restore OpenCV
        shell: pwsh
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: ./tools/opencv.ps1 restore
      - name: Build native
        shell: pwsh
        run: ./tools/dev.ps1 build
      - name: Run Player tests
        shell: pwsh
        env:
          UNITY_LICENSE: ${{ secrets.UNITY_LICENSE }}
          UNITY_EMAIL: ${{ secrets.UNITY_EMAIL }}
          UNITY_PASSWORD: ${{ secrets.UNITY_PASSWORD }}
        run: ./tools/dev.ps1 test-unity-player
```

**Secrets が未登録なら、この時点で止めて報告すること。** 資格情報の登録は
エージェントの作業ではない。

- [ ] **Step 6: コミット**

```bash
git add tests/UnityProject Packages/com.ayutaz.opencv-unity-native/link.xml .github/workflows/ci-unity.yml tools/dev.ps1
git commit -m "test(unity): run the same smoke test on the IL2CPP player as in the editor"
```

---

### Task 8: 文書の真実化と完了判定

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `docs/roadmap.md`, `docs/README.md`
- Modify: `.claude/skills/add-abi-function/SKILL.md`（handle 規約が増えたので反映）

**Interfaces:**
- Consumes: Task 1〜7 の全成果
- Produces: なし（判定と記録のみ）

- [ ] **Step 1: `milestone-complete` skill の手順を実行する**

roadmap の M2 完了条件を 1 件ずつ、実測で照合する。**終了コードを見る。出力の
PASS 行を数えない。** 満たしていない条件があれば満たしていないと書く。

- [ ] **Step 2: `CLAUDE.md` を現状に合わせる**

- 「マイルストーン（現在地: ...）」を M2 完了 / 次は M3 に
- 開発コマンドの表に `test-unity-editmode` / `test-unity-player` / `test-managed-probe` を足し、**実測値**を書く
- ファイル配置の表に `tests/UnityProject/` と `Runtime/UnityIntegration/` を足す
- 「L3 のクラッシュ・ハング耐性はまだ証明されていない」を Task 4 の結果に置き換える
- 「まだ無い」と書いてある `tests/UnityProject/`（M2）の記述を更新

- [ ] **Step 3: `README.md` の status を更新する**

対応範囲を過大に書かないこと。M2 が成立させたのは Windows x64 の vertical slice
だけである。

- [ ] **Step 4: `add-abi-function` skill に handle の規約を足す**

新しい ABI 関数が handle を取る場合の規約（`mat_table_get` で解決し、nullptr なら
`OCVU_STATUS_INVALID_HANDLE`）と、buffer 引数を取る場合の検証順序を書く。
**手順の skill なので、次に関数を足す人が読む場所に置く。**

- [ ] **Step 5: 全レーンを回して実測値を集める**

```
pwsh tools/dev.ps1 test
pwsh tools/dev.ps1 test-asan
pwsh tools/dev.ps1 test-tools-slow
pwsh tools/dev.ps1 test-managed-probe
pwsh tools/dev.ps1 test-unity-editmode
pwsh tools/dev.ps1 test-unity-player
```

それぞれの**実測時間**を記録する。`test` が更に伸びていたら、その数字を
CLAUDE.md に書く（伸びを隠さない）。

- [ ] **Step 6: コミット**

```bash
git add CLAUDE.md README.md docs/roadmap.md docs/README.md .claude/skills/add-abi-function/SKILL.md
git commit -m "docs(m2): true up every document against what the vertical slice actually does"
```

---

## 実行時の注意

**このマイルストーンで最も危険なのは Task 2 である。** buffer の検証が甘いと、
Unity のヒープを踏み越えて「後から無関係な場所が壊れる」状態になる。Windows の
ASan は Unity のアロケータを見られないので、CI も気づかない。Task 2 の Step 8
（変異テスト）を省略しないこと。

**Task 7 は Unity ライセンスが要る。** 未登録なら止めて報告する。資格情報の登録を
エージェントが代行しない。

**Task 4 の結果が否定的でも、それは失敗ではなく発見である。** L3 が有限時間で
赤くならないと分かったなら、そう報告すること。回避策を作って「証明できた」と
書かないこと。
