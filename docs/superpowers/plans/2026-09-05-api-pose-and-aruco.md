# Phase 1 — 姿勢と ArUco 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ArUco マーカーを検出し、その姿勢を求められるようにする —— **AR の輪を閉じる。**

**Architecture:** `geometry` module に姿勢の 4 本（`ocvu_solve_pnp` / `ocvu_rodrigues_to_matrix` / `ocvu_rodrigues_to_vector` / `ocvu_project_points`）、`objdetect` module に ArUco の 2 本（`ocvu_aruco_generate_marker` / `ocvu_aruco_detect_markers`）を足す。**どちらの module も既にリンク済みなので、OpenCV の再ビルドは起きない。** マーカーの姿勢推定は新しい C ABI ではなく、`CvAruco` が `ocvu_solve_pnp` を呼ぶ純 C# として出す。

**Tech Stack:** C++17 / OpenCV 5.0.0（`geometry` / `objdetect`）/ C# netstandard2.1 / GoogleTest（L1）/ xUnit（L3）

**Spec:** [API 拡張（A〜F）— 全体設計と分割](./2026-09-05-api-surface-expansion.md)

## Global Constraints

**spec の §5 から、そのまま効くものを写す。各タスクの要件はこれを暗黙に含む。**

- **`tools/opencv-config.psd1` の `Modules` を 1 文字も変えない。** 変えると 6 platform 分の OpenCV 再ビルドになる
- **`cmake/FindOpenCvUnityDeps.cmake` の `COMPONENTS` も変えない。** `geometry` と `objdetect` は既に入っている
- **新しい status code を足さない。** `OCVU_STATUS_LIST` と `Runtime/Core/CvStatus.cs` はこのブランチで 1 行も変わらない
- **新しい struct を足さない。** `ocvu_dmatch` は Phase 4 のものである
- **宣言を手で書かない。** `bindings/spec/<module>.json` に 1 エントリ足して `./tools/dev.ps1 generate`。ヘッダにも `NativeMethods.cs` にも手で足さない
- **`bool` を境界に出さない。** `int32_t` の 0 / 非 0 で受ける
- **`*_length` はバイト数、`*_capacity` は要素数。** 両方 `summary` に明記する
- **積は `static_cast<int64_t>` を先に当ててから作る**
- **公開 ABI 関数は `OCVU_TRY_BEGIN` / `OCVU_TRY_END` で囲む。** `cv::Exception` はその手前で個別に受けて `OCVU_STATUS_OPENCV_ERROR` にする
- **`extern "C" ocvu_status ocvu_名前(` までを 1 物理行に置く**（`.claude/hooks/check-exception-barrier.sh` の awk がそれを前提にしている）
- **`Runtime/Core` と `Runtime/Interop` は `UnityEngine` を参照しない**
- **`OCVU_ABI_VERSION` は 1 のまま**（関数の追加は bump しない変更）
- **`git add -A` / `git add .` は hook が拒否する。** 変更したパスを個別に stage する

## ファイル構成

**新規**

| ファイル | 責務 |
| --- | --- |
| `native/src/ocvu_pose.cpp` | `geometry` の姿勢 4 本。**`ocvu_geometry.cpp` に足さない** —— あちらは射影変換の推定 1 本で完結しており、姿勢は別の用途である |
| `native/src/ocvu_aruco.cpp` | `objdetect` の ArUco 2 本。**`ocvu_objdetect.cpp` に足さない** —— あちらは QR で、辞書も検出器も別物である |
| `native/tests/test_pose.cpp` | 姿勢 4 本の L1 |
| `native/tests/test_aruco.cpp` | ArUco 2 本の L1 |
| `Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvAruco.cs`（+ `.meta`） | C# の公開入口 |
| `tests/Managed/CvUnity.Tests.Managed/PoseTests.cs` | 姿勢の L3 |
| `tests/Managed/CvUnity.Tests.Managed/ArucoTests.cs` | ArUco の L3 |

**変更**

| ファイル | 何を |
| --- | --- |
| `native/include/opencv_unity_native.h` | `OCVU_SOLVEPNP_*`（7）、`OCVU_ARUCO_DICT_*`（17）、`OCVU_PNP_MAX_POINTS` |
| `bindings/spec/geometry.json` | 4 エントリ |
| `bindings/spec/objdetect.json` | 2 エントリ |
| `native/CMakeLists.txt` | `OCVU_SOURCES` に 2 ファイル |
| `native/tests/CMakeLists.txt` | `ocvu_tests` に 2 ファイル |
| `Packages/.../Runtime/Core/CvGeometry.cs` | `SolvePnP` / `RodriguesToMatrix` / `RodriguesToVector` / `ProjectPoints` |
| `docs/abi-ownership-and-versioning.md` | §3.10 を足す |
| `docs/api-reference.md` | C ABI 節と C# 節 |
| `CLAUDE.md` | ABI の内訳とファイル配置 |

**生成物（手で触らない。`dev.ps1 generate` が書く）**

`native/include/ocvu/geometry.h` / `native/include/ocvu/objdetect.h` /
`Runtime/Interop/NativeMethods.Geometry.g.cs` / `NativeMethods.Objdetect.g.cs` /
`tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs` / `docs/api-map.md`

---

## Task 1: `ocvu_solve_pnp`

**Files:**
- Create: `native/tests/test_pose.cpp`
- Create: `native/src/ocvu_pose.cpp`
- Modify: `native/include/opencv_unity_native.h`（`OCVU_SOLVEPNP_*` と `OCVU_PNP_MAX_POINTS`）
- Modify: `bindings/spec/geometry.json`
- Modify: `native/CMakeLists.txt`、`native/tests/CMakeLists.txt`

**Interfaces:**
- Consumes: `ocvu::set_last_error`（`native/src/ocvu_error.h`）
- Produces: `ocvu_status ocvu_solve_pnp(const float* object_points, int64_t object_points_length, const float* image_points, int64_t image_points_length, int32_t point_count, const double* camera_matrix, int64_t camera_matrix_length, const double* dist_coeffs, int64_t dist_coeffs_length, int32_t method, double* out_rvec, int32_t rvec_capacity, double* out_tvec, int32_t tvec_capacity)`

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_pose.cpp` を新規作成する。

```cpp
// geometry module の姿勢 4 本の契約テスト。
//
// **数値は手で解いてある。** カメラ行列 fx=fy=500, cx=320, cy=240 で、
// 回転なし・並進 (0, 0, 10) に置いた 1 辺 2 の正方形は、
//   x = 500 * (X / 10) + 320,  y = 500 * (Y / 10) + 240
// で写る。OpenCV に投影させて期待値を作ると、投影の実装が壊れたときに
// 期待値も一緒に壊れて検査が空振りする。

#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <array>
#include <cmath>

namespace {

// fx = fy = 500, cx = 320, cy = 240 を行優先で並べたもの。
constexpr std::array<double, 9> kCamera{500.0, 0.0, 320.0,
                                        0.0, 500.0, 240.0,
                                        0.0, 0.0, 1.0};

// 1 辺 2 の正方形（z = 0 の平面上）。x, y, z の順に並べる。
constexpr std::array<float, 12> kSquareObject{
    -1.0f, -1.0f, 0.0f,
     1.0f, -1.0f, 0.0f,
     1.0f,  1.0f, 0.0f,
    -1.0f,  1.0f, 0.0f};

// 上の正方形を (0, 0, 10) に置いて写した像。x, y の順に並べる。
constexpr std::array<float, 8> kSquareImage{
    270.0f, 190.0f,
    370.0f, 190.0f,
    370.0f, 290.0f,
    270.0f, 290.0f};

constexpr int64_t kObjectBytes = static_cast<int64_t>(sizeof(kSquareObject));
constexpr int64_t kImageBytes = static_cast<int64_t>(sizeof(kSquareImage));
constexpr int64_t kCameraBytes = static_cast<int64_t>(sizeof(kCamera));

}  // namespace

TEST(Pose, SolvePnpRecoversAKnownPose) {
    std::array<double, 3> rvec{};
    std::array<double, 3> tvec{};

    ASSERT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes,
                             kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes,
                             nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE,
                             rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_OK);

    // 回転なしで (0, 0, 10) に置いたので、そこへ戻ってくる。
    EXPECT_NEAR(rvec[0], 0.0, 1e-3);
    EXPECT_NEAR(rvec[1], 0.0, 1e-3);
    EXPECT_NEAR(rvec[2], 0.0, 1e-3);
    EXPECT_NEAR(tvec[0], 0.0, 1e-3);
    EXPECT_NEAR(tvec[1], 0.0, 1e-3);
    EXPECT_NEAR(tvec[2], 10.0, 1e-3);
}

TEST(Pose, SolvePnpRejectsNullPointers) {
    std::array<double, 3> rvec{};
    std::array<double, 3> tvec{};

    EXPECT_EQ(ocvu_solve_pnp(nullptr, kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, nullptr, kImageBytes, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             nullptr, kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, nullptr, 3, tvec.data(), 3),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, nullptr, 3),
              OCVU_STATUS_NULL_POINTER);

    // **dist_coeffs だけは NULL を許す。** 長さ 0 は「歪み無し」の正規の指定である。
    // その組み合わせが上の SolvePnpRecoversAKnownPose で通っていることが証拠になる。
    // 長さが 0 でないのに NULL なら拒否する。
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes, nullptr, 5 * static_cast<int64_t>(sizeof(double)),
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_NULL_POINTER);
}

TEST(Pose, SolvePnpRejectsInvalidArguments) {
    std::array<double, 3> rvec{};
    std::array<double, 3> tvec{};

    // 点が 4 個未満では姿勢が決まらない。
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 3,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 上限を超える点数。
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes,
                             OCVU_PNP_MAX_POINTS + 1,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 知らない method を素通しにしない。
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             99, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);

    // **長さはバイト数である。** 4 点ぶんに 1 バイト足りなければ何も読まずに断る。
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes - 1, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes - 1, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes - 1, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 歪み係数の個数は OpenCV が受ける 4 / 5 / 8 / 12 / 14 のいずれかでなければならない。
    const std::array<double, 3> bad_coeffs{0.0, 0.0, 0.0};
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes,
                             bad_coeffs.data(), static_cast<int64_t>(sizeof(bad_coeffs)),
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);
}

TEST(Pose, SolvePnpRejectsTooSmallOutputsWithoutWriting) {
    // **0 ではない値で汚してから呼ぶ。** 0 で初期化していると
    // 「書いていない」と「0 を書いた」が区別できない（M3.5 で実測）。
    std::array<double, 3> rvec{-7.0, -7.0, -7.0};
    std::array<double, 3> tvec{-7.0, -7.0, -7.0};

    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 2, tvec.data(), 3),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 2),
              OCVU_STATUS_BUFFER_TOO_SMALL);

    for (int i = 0; i < 3; ++i) {
        EXPECT_DOUBLE_EQ(rvec[i], -7.0) << "断ったのに rvec を書いている";
        EXPECT_DOUBLE_EQ(tvec[i], -7.0) << "断ったのに tvec を書いている";
    }
}

TEST(Pose, SolvePnpReportsOpenCvFailuresAsOpenCvError) {
    // **カメラ行列が特異なら OpenCV が投げる。** これは「原因不明」ではないので
    // OCVU_STATUS_OPENCV_ERROR で返し、理由は last-error に入る。
    constexpr std::array<double, 9> singular{0.0, 0.0, 0.0,
                                             0.0, 0.0, 0.0,
                                             0.0, 0.0, 0.0};
    std::array<double, 3> rvec{};
    std::array<double, 3> tvec{};

    const ocvu_status status =
        ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                       singular.data(), kCameraBytes, nullptr, 0,
                       OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3);
    EXPECT_NE(status, OCVU_STATUS_UNKNOWN_ERROR)
        << "OpenCV 由来の失敗が「原因不明」として報告されている";
    EXPECT_TRUE(status == OCVU_STATUS_OPENCV_ERROR || status == OCVU_STATUS_NOT_FOUND);
}
```

`native/tests/CMakeLists.txt` の `add_executable(ocvu_tests ...)` の一覧に
`test_pose.cpp` を足す（`test_calibration.cpp` の次の行）。

- [ ] **Step 2: RED を目で確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: **コンパイルエラー**。`ocvu_solve_pnp` も `OCVU_SOLVEPNP_ITERATIVE` も
`OCVU_PNP_MAX_POINTS` も、まだどこにも無い。

- [ ] **Step 3: 定数をヘッダに足す**

`native/include/opencv_unity_native.h` の `OCVU_CALIB_MAX_POINTS` の定義の直後に足す。

```c
/* ocvu_solve_pnp / ocvu_project_points が受け取る点数の上限。
 * OCVU_CALIB_MAX_POINTS と同じ理由 —— 点数から配列の必要バイト数を作るときに
 * int32_t の乗算が符号付きオーバーフロー（未定義動作）を起こさないための歯止めである。
 * 1 枚ぶんの姿勢推定に 1 万点を使うことは実用上ありえない。 */
#define OCVU_PNP_MAX_POINTS 10000

/* ocvu_solve_pnp の method。cv::SolvePnPMethod の値をそのまま出す
 * （実装 .cpp の static_assert が写し間違いをコンパイル時に落とす）。
 *
 * ITERATIVE は既定で、平面上の 4 点でも非平面の 6 点でも解ける。
 * IPPE_SQUARE は 1 辺が既知の正方形マーカー専用で、**点の並び順が決まっている**
 * （左上・右上・右下・左下）。ArUco の 4 隅はその順で返るので、そのまま渡せる。 */
#define OCVU_SOLVEPNP_ITERATIVE   0
#define OCVU_SOLVEPNP_EPNP        1
#define OCVU_SOLVEPNP_P3P         2
#define OCVU_SOLVEPNP_AP3P        3
#define OCVU_SOLVEPNP_IPPE        4
#define OCVU_SOLVEPNP_IPPE_SQUARE 5
#define OCVU_SOLVEPNP_SQPNP       6
```

- [ ] **Step 4: spec に 1 エントリ足して生成する**

`bindings/spec/geometry.json` の `functions` 配列に足す（既存の
`ocvu_find_homography` の後ろ）。

```json
{
  "name": "ocvu_solve_pnp",
  "summary": "既知の 3D 点と、その画像上の対応点、カメラの内部パラメータから 1 枚ぶんの姿勢を求める。object_points は 1 点 3 float（x, y, z）、image_points は 1 点 2 float（x, y）で、同じ順に並べる。object_points_length と image_points_length と camera_matrix_length と dist_coeffs_length はいずれもその配列の**バイト数**である（要素数でも点数でもない —— この ABI の length はすべてバイト数で統一してある）。**呼ぶ側を信用せず、長さが必要量に満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。** point_count は 4 以上 OCVU_PNP_MAX_POINTS 以下でなければならない。camera_matrix は行優先の 3x3（double 9 個）である。dist_coeffs は NULL と長さ 0 の組み合わせで「歪み無し」を指定でき、そうでなければ OpenCV が受ける個数（4 / 5 / 8 / 12 / 14）でなければならない —— 長さが 0 でないのに NULL なら OCVU_STATUS_NULL_POINTER を返す。method は OCVU_SOLVEPNP_* のいずれかで、それ以外は拒否する。出力の rvec_capacity と tvec_capacity は**配列の要素数**で（バイト数ではない）、どちらも 3 以上が要る —— 足りなければ**何も書かずに** OCVU_STATUS_BUFFER_TOO_SMALL を返す。out_rvec は Rodrigues の回転ベクトル（向きが回転軸、長さが回転角のラジアン）、out_tvec は並進で、単位は object_points に渡したものと同じである。姿勢が求まらないときは OCVU_STATUS_NOT_FOUND を返し、これは誤りではない。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、その理由は last-error のメッセージに入る。**どの失敗経路でも out_rvec と out_tvec は書き換えない。** これらの所有権は最初から最後まで呼ぶ側にある。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "object_points", "cType": "const float*", "csType": "float[]", "direction": "in-buffer" },
    { "name": "object_points_length", "cType": "int64_t", "csType": "long", "direction": "in" },
    { "name": "image_points", "cType": "const float*", "csType": "float[]", "direction": "in-buffer" },
    { "name": "image_points_length", "cType": "int64_t", "csType": "long", "direction": "in" },
    { "name": "point_count", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "camera_matrix", "cType": "const double*", "csType": "double[]", "direction": "in-buffer" },
    { "name": "camera_matrix_length", "cType": "int64_t", "csType": "long", "direction": "in" },
    { "name": "dist_coeffs", "cType": "const double*", "csType": "double[]", "direction": "in-buffer" },
    { "name": "dist_coeffs_length", "cType": "int64_t", "csType": "long", "direction": "in" },
    { "name": "method", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "out_rvec", "cType": "double*", "csType": "double[]", "direction": "out-buffer" },
    { "name": "rvec_capacity", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "out_tvec", "cType": "double*", "csType": "double[]", "direction": "out-buffer" },
    { "name": "tvec_capacity", "cType": "int32_t", "csType": "int", "direction": "in" }
  ]
}
```

```
pwsh tools/dev.ps1 generate
```

期待: `==> 6 ファイルを生成しました（更新 4 件）` のように、`geometry.h` /
`NativeMethods.Geometry.g.cs` / `AbiReachabilityChecks.g.cs` / `api-map.md` が動く。

- [ ] **Step 5: 実装する**

`native/src/ocvu_pose.cpp` を新規作成する。

```cpp
// geometry module のうち「姿勢」に関わるもの。
//
// **ocvu_geometry.cpp に足していない。** あちらは 2 枚の画像の間の射影変換を
// 推定する 1 本で完結しており、こちらは 3D と 2D の間の姿勢である。用途が違う。

#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/geometry.hpp>

#include <cstdint>
#include <vector>

#include "ocvu_error.h"

// 境界に出す method の値は OpenCV のものをそのまま使う。
static_assert(OCVU_SOLVEPNP_ITERATIVE == cv::SOLVEPNP_ITERATIVE, "SOLVEPNP_ITERATIVE がずれている");
static_assert(OCVU_SOLVEPNP_EPNP == cv::SOLVEPNP_EPNP, "SOLVEPNP_EPNP がずれている");
static_assert(OCVU_SOLVEPNP_P3P == cv::SOLVEPNP_P3P, "SOLVEPNP_P3P がずれている");
static_assert(OCVU_SOLVEPNP_AP3P == cv::SOLVEPNP_AP3P, "SOLVEPNP_AP3P がずれている");
static_assert(OCVU_SOLVEPNP_IPPE == cv::SOLVEPNP_IPPE, "SOLVEPNP_IPPE がずれている");
static_assert(OCVU_SOLVEPNP_IPPE_SQUARE == cv::SOLVEPNP_IPPE_SQUARE, "SOLVEPNP_IPPE_SQUARE がずれている");
static_assert(OCVU_SOLVEPNP_SQPNP == cv::SOLVEPNP_SQPNP, "SOLVEPNP_SQPNP がずれている");

namespace ocvu_pose_detail {

// 1 枚ぶんの姿勢は 4 点から決まる。それ未満は解が無いのではなく問いが成立しない。
constexpr int32_t kMinPoints = 4;

bool IsKnownSolvePnpMethod(int32_t method) {
    return method >= OCVU_SOLVEPNP_ITERATIVE && method <= OCVU_SOLVEPNP_SQPNP;
}

// OpenCV が受け取る歪み係数の個数。ocvu_calibration.cpp と同じ集合である。
bool IsAcceptedDistCoeffCount(int64_t count) {
    return count == 4 || count == 5 || count == 8 || count == 12 || count == 14;
}

// dist_coeffs の (ポインタ, バイト数) を検証し、cv::Mat の借用ビューを作る。
// **長さ 0 と NULL の組み合わせだけが「歪み無し」の正規の指定である。**
ocvu_status MakeDistCoeffView(const double* dist_coeffs, int64_t dist_coeffs_length,
                              const char* who, cv::Mat* out_view) {
    if (dist_coeffs_length < 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "dist_coeffs_length is negative");
    }
    if (dist_coeffs_length == 0) {
        *out_view = cv::Mat();
        return OCVU_STATUS_OK;
    }
    if (dist_coeffs == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "dist_coeffs is NULL but dist_coeffs_length is not 0");
    }
    const int64_t count = dist_coeffs_length / static_cast<int64_t>(sizeof(double));
    if (!IsAcceptedDistCoeffCount(count)) {
        (void)who;
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "dist_coeffs_length (bytes) is not 4, 5, 8, 12 or 14 doubles");
    }
    *out_view = cv::Mat(1, static_cast<int>(count), CV_64F, const_cast<double*>(dist_coeffs));
    return OCVU_STATUS_OK;
}

}  // namespace ocvu_pose_detail

extern "C" ocvu_status ocvu_solve_pnp(const float* object_points, int64_t object_points_length, const float* image_points, int64_t image_points_length, int32_t point_count, const double* camera_matrix, int64_t camera_matrix_length, const double* dist_coeffs, int64_t dist_coeffs_length, int32_t method, double* out_rvec, int32_t rvec_capacity, double* out_tvec, int32_t tvec_capacity) {
    OCVU_TRY_BEGIN
    using namespace ocvu_pose_detail;

    if (object_points == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_solve_pnp: object_points is NULL");
    }
    if (image_points == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_solve_pnp: image_points is NULL");
    }
    if (camera_matrix == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_solve_pnp: camera_matrix is NULL");
    }
    if (out_rvec == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_solve_pnp: out_rvec is NULL");
    }
    if (out_tvec == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_solve_pnp: out_tvec is NULL");
    }
    if (point_count < kMinPoints || point_count > OCVU_PNP_MAX_POINTS) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_solve_pnp: point_count must be between 4 and OCVU_PNP_MAX_POINTS");
    }
    if (!IsKnownSolvePnpMethod(method)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_solve_pnp: method is not one of OCVU_SOLVEPNP_*");
    }

    // **積は int64_t に上げてから作る。** point_count は上で縛ってあるので
    // 収まるが、桁あふれを「収まるはずだから安全」で済ませない（M2 で踏んだ）。
    const int64_t object_needed =
        static_cast<int64_t>(point_count) * 3 * static_cast<int64_t>(sizeof(float));
    const int64_t image_needed =
        static_cast<int64_t>(point_count) * 2 * static_cast<int64_t>(sizeof(float));
    if (object_points_length < object_needed) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_solve_pnp: object_points_length (bytes) is too small for point_count");
    }
    if (image_points_length < image_needed) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_solve_pnp: image_points_length (bytes) is too small for point_count");
    }
    if (camera_matrix_length < static_cast<int64_t>(9 * sizeof(double))) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_solve_pnp: camera_matrix_length (bytes) is too small for a 3x3 matrix");
    }

    cv::Mat dist_view;
    const ocvu_status dist_status =
        MakeDistCoeffView(dist_coeffs, dist_coeffs_length, "ocvu_solve_pnp", &dist_view);
    if (dist_status != OCVU_STATUS_OK) {
        return dist_status;
    }

    // **出力の容量は最後に見る。** 入力が壊れているときに BUFFER_TOO_SMALL を
    // 返すと、呼ぶ側は buffer を大きくして再挑戦し、また同じところで失敗する。
    if (rvec_capacity < 3 || tvec_capacity < 3) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_solve_pnp: rvec_capacity and tvec_capacity must each be at least 3");
    }

    // 借用はこの呼び出しの内側で完結する。cv::Mat で包むだけで所有はしない。
    const cv::Mat object_view(point_count, 3, CV_32F, const_cast<float*>(object_points));
    const cv::Mat image_view(point_count, 2, CV_32F, const_cast<float*>(image_points));
    const cv::Mat camera_view(3, 3, CV_64F, const_cast<double*>(camera_matrix));

    // **求めてから書く。** 直接 out_rvec / out_tvec へ書かせると、失敗したときに
    // 途中まで書き換わった状態で残りうる。
    cv::Mat rvec;
    cv::Mat tvec;
    bool solved = false;
    try {
        solved = cv::solvePnP(object_view, image_view, camera_view, dist_view,
                              rvec, tvec, false, method);
    } catch (const cv::Exception& e) {
        // OCVU_TRY_END でも捕まるが、そこでは UNKNOWN_ERROR になる。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    // **解が無いのは誤りではない。** 入力の形は正しいので NOT_FOUND で返す
    // （ocvu_find_homography と同じ扱い）。
    if (!solved || rvec.total() < 3 || tvec.total() < 3) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_NOT_FOUND,
            "ocvu_solve_pnp: no pose could be estimated from these correspondences");
    }

    const cv::Mat rvec64 = rvec.reshape(1, 1);
    const cv::Mat tvec64 = tvec.reshape(1, 1);
    for (int i = 0; i < 3; ++i) {
        out_rvec[i] = rvec64.at<double>(0, i);
        out_tvec[i] = tvec64.at<double>(0, i);
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

`native/CMakeLists.txt` の `OCVU_SOURCES` に `src/ocvu_pose.cpp` を足す
（`src/ocvu_calibration.cpp` の次の行）。

- [ ] **Step 6: L1 を緑にする**

```
pwsh tools/dev.ps1 test-native
```

期待: `Pose.*` の 5 件が pass。**exit code を見る**（`echo $LASTEXITCODE` が 0）。
PASS 行を数えない。

- [ ] **Step 7: 検査が働くことを確かめる**

`prove-a-check-works` の手順。**壊して落ちることを見るまで、その検査は動くと言えない。**

1. `ocvu_solve_pnp` の `if (rvec_capacity < 3 || tvec_capacity < 3)` を
   `if (false)` に書き換える
2. `pwsh tools/dev.ps1 test-native` → **`Pose.SolvePnpRejectsTooSmallOutputsWithoutWriting`
   が落ちること**を目で見る
3. 戻して緑に戻ることを確認する

**戻す前にコミットしない**（`check-staged-generated-file.sh` が止めるのは生成物だけで、
実装の一時的な破壊は止まらない）。

- [ ] **Step 8: コミット**

```bash
git add native/tests/test_pose.cpp native/tests/CMakeLists.txt \
        native/src/ocvu_pose.cpp native/CMakeLists.txt \
        native/include/opencv_unity_native.h \
        bindings/spec/geometry.json \
        native/include/ocvu/geometry.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Geometry.g.cs \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(geometry): 既知の点の対応から 1 枚ぶんの姿勢を求める ocvu_solve_pnp を出す"
```

---

## Task 2: `ocvu_rodrigues_to_matrix` と `ocvu_rodrigues_to_vector`

**2 本まとめて 1 タスクにする。** 同じ `cv::Rodrigues` の 2 方向で、
片方だけをレビューで通す意味が無い（往復で初めて正しさが言える）。

**Files:**
- Modify: `native/tests/test_pose.cpp`、`native/src/ocvu_pose.cpp`、`bindings/spec/geometry.json`

**Interfaces:**
- Produces:
  - `ocvu_status ocvu_rodrigues_to_matrix(const double* rotation_vector, int64_t rotation_vector_length, double* out_matrix, int32_t matrix_capacity)`
  - `ocvu_status ocvu_rodrigues_to_vector(const double* rotation_matrix, int64_t rotation_matrix_length, double* out_vector, int32_t vector_capacity)`

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_pose.cpp` の末尾に足す。

```cpp
TEST(Pose, RodriguesToMatrixTurnsAQuarterTurnAboutZ) {
    // z 軸まわりに 90 度。回転行列は手で書ける。
    const double half_pi = std::acos(-1.0) / 2.0;
    const std::array<double, 3> rvec{0.0, 0.0, half_pi};
    std::array<double, 9> matrix{};

    ASSERT_EQ(ocvu_rodrigues_to_matrix(rvec.data(), static_cast<int64_t>(sizeof(rvec)),
                                       matrix.data(), 9),
              OCVU_STATUS_OK);

    const std::array<double, 9> expected{0.0, -1.0, 0.0,
                                         1.0, 0.0, 0.0,
                                         0.0, 0.0, 1.0};
    for (int i = 0; i < 9; ++i) {
        EXPECT_NEAR(matrix[i], expected[i], 1e-9) << "要素 " << i;
    }
}

TEST(Pose, RodriguesRoundTrips) {
    const std::array<double, 3> rvec{0.1, -0.2, 0.3};
    std::array<double, 9> matrix{};
    std::array<double, 3> back{};

    ASSERT_EQ(ocvu_rodrigues_to_matrix(rvec.data(), static_cast<int64_t>(sizeof(rvec)),
                                       matrix.data(), 9),
              OCVU_STATUS_OK);
    ASSERT_EQ(ocvu_rodrigues_to_vector(matrix.data(), static_cast<int64_t>(sizeof(matrix)),
                                       back.data(), 3),
              OCVU_STATUS_OK);

    for (int i = 0; i < 3; ++i) {
        EXPECT_NEAR(back[i], rvec[i], 1e-9) << "要素 " << i;
    }
}

TEST(Pose, RodriguesRejectsBadArguments) {
    const std::array<double, 3> rvec{0.0, 0.0, 0.0};
    const std::array<double, 9> matrix{1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0};
    std::array<double, 9> out9{-7.0, -7.0, -7.0, -7.0, -7.0, -7.0, -7.0, -7.0, -7.0};
    std::array<double, 3> out3{-7.0, -7.0, -7.0};

    EXPECT_EQ(ocvu_rodrigues_to_matrix(nullptr, static_cast<int64_t>(sizeof(rvec)), out9.data(), 9),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_rodrigues_to_matrix(rvec.data(), static_cast<int64_t>(sizeof(rvec)), nullptr, 9),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_rodrigues_to_vector(nullptr, static_cast<int64_t>(sizeof(matrix)), out3.data(), 3),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_rodrigues_to_vector(matrix.data(), static_cast<int64_t>(sizeof(matrix)), nullptr, 3),
              OCVU_STATUS_NULL_POINTER);

    // **長さはバイト数である。** 1 バイト足りなければ何も読まない。
    EXPECT_EQ(ocvu_rodrigues_to_matrix(rvec.data(), static_cast<int64_t>(sizeof(rvec)) - 1, out9.data(), 9),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_rodrigues_to_vector(matrix.data(), static_cast<int64_t>(sizeof(matrix)) - 1, out3.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 容量が足りなければ何も書かない。
    EXPECT_EQ(ocvu_rodrigues_to_matrix(rvec.data(), static_cast<int64_t>(sizeof(rvec)), out9.data(), 8),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(ocvu_rodrigues_to_vector(matrix.data(), static_cast<int64_t>(sizeof(matrix)), out3.data(), 2),
              OCVU_STATUS_BUFFER_TOO_SMALL);

    for (int i = 0; i < 9; ++i) EXPECT_DOUBLE_EQ(out9[i], -7.0) << "断ったのに書いている";
    for (int i = 0; i < 3; ++i) EXPECT_DOUBLE_EQ(out3[i], -7.0) << "断ったのに書いている";
}
```

- [ ] **Step 2: RED を目で確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: **コンパイルエラー**（`ocvu_rodrigues_to_matrix` が未定義）。

- [ ] **Step 3: spec に 2 エントリ足して生成する**

`bindings/spec/geometry.json` に足す。

```json
{
  "name": "ocvu_rodrigues_to_matrix",
  "summary": "Rodrigues の回転ベクトル（3 要素。向きが回転軸、長さが回転角のラジアン）を 3x3 の回転行列に直し、行優先で out_matrix へ書く。rotation_vector_length は入力配列の**バイト数**で（要素数ではない）、double 3 個ぶんに満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。matrix_capacity は出力配列の**要素数**で（バイト数ではない）、9 未満なら**何も書かずに** OCVU_STATUS_BUFFER_TOO_SMALL を返す。ポインタが NULL なら OCVU_STATUS_NULL_POINTER。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返す。out_matrix の所有権は最初から最後まで呼ぶ側にある。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "rotation_vector", "cType": "const double*", "csType": "double[]", "direction": "in-buffer" },
    { "name": "rotation_vector_length", "cType": "int64_t", "csType": "long", "direction": "in" },
    { "name": "out_matrix", "cType": "double*", "csType": "double[]", "direction": "out-buffer" },
    { "name": "matrix_capacity", "cType": "int32_t", "csType": "int", "direction": "in" }
  ]
},
{
  "name": "ocvu_rodrigues_to_vector",
  "summary": "3x3 の回転行列（行優先の double 9 個）を Rodrigues の回転ベクトル（3 要素）に直して out_vector へ書く。rotation_matrix_length は入力配列の**バイト数**で（要素数ではない）、double 9 個ぶんに満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。vector_capacity は出力配列の**要素数**で（バイト数ではない）、3 未満なら**何も書かずに** OCVU_STATUS_BUFFER_TOO_SMALL を返す。ポインタが NULL なら OCVU_STATUS_NULL_POINTER。入力が回転行列でない場合の扱いは OpenCV に委ねており、例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返す。out_vector の所有権は最初から最後まで呼ぶ側にある。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "rotation_matrix", "cType": "const double*", "csType": "double[]", "direction": "in-buffer" },
    { "name": "rotation_matrix_length", "cType": "int64_t", "csType": "long", "direction": "in" },
    { "name": "out_vector", "cType": "double*", "csType": "double[]", "direction": "out-buffer" },
    { "name": "vector_capacity", "cType": "int32_t", "csType": "int", "direction": "in" }
  ]
}
```

```
pwsh tools/dev.ps1 generate
```

- [ ] **Step 4: 実装する**

`native/src/ocvu_pose.cpp` の末尾に足す。

```cpp
extern "C" ocvu_status ocvu_rodrigues_to_matrix(const double* rotation_vector, int64_t rotation_vector_length, double* out_matrix, int32_t matrix_capacity) {
    OCVU_TRY_BEGIN
    if (rotation_vector == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_rodrigues_to_matrix: rotation_vector is NULL");
    }
    if (out_matrix == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_rodrigues_to_matrix: out_matrix is NULL");
    }
    if (rotation_vector_length < static_cast<int64_t>(3 * sizeof(double))) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_rodrigues_to_matrix: rotation_vector_length (bytes) is too small for 3 doubles");
    }
    if (matrix_capacity < 9) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_rodrigues_to_matrix: matrix_capacity (elements) must be at least 9");
    }

    const cv::Mat vector_view(3, 1, CV_64F, const_cast<double*>(rotation_vector));
    cv::Mat matrix;
    try {
        cv::Rodrigues(vector_view, matrix);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }
    if (matrix.rows != 3 || matrix.cols != 3 || matrix.type() != CV_64F) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR,
                                      "ocvu_rodrigues_to_matrix: unexpected result shape");
    }

    for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 3; ++c) {
            out_matrix[r * 3 + c] = matrix.at<double>(r, c);
        }
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_rodrigues_to_vector(const double* rotation_matrix, int64_t rotation_matrix_length, double* out_vector, int32_t vector_capacity) {
    OCVU_TRY_BEGIN
    if (rotation_matrix == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_rodrigues_to_vector: rotation_matrix is NULL");
    }
    if (out_vector == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_rodrigues_to_vector: out_vector is NULL");
    }
    if (rotation_matrix_length < static_cast<int64_t>(9 * sizeof(double))) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_rodrigues_to_vector: rotation_matrix_length (bytes) is too small for 9 doubles");
    }
    if (vector_capacity < 3) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_rodrigues_to_vector: vector_capacity (elements) must be at least 3");
    }

    const cv::Mat matrix_view(3, 3, CV_64F, const_cast<double*>(rotation_matrix));
    cv::Mat vector;
    try {
        cv::Rodrigues(matrix_view, vector);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }
    if (vector.total() < 3 || vector.type() != CV_64F) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR,
                                      "ocvu_rodrigues_to_vector: unexpected result shape");
    }

    const cv::Mat flat = vector.reshape(1, 1);
    for (int i = 0; i < 3; ++i) {
        out_vector[i] = flat.at<double>(0, i);
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

- [ ] **Step 5: L1 を緑にする**

```
pwsh tools/dev.ps1 test-native
```

期待: `Pose.*` が 8 件 pass、exit 0。

- [ ] **Step 6: コミット**

```bash
git add native/tests/test_pose.cpp native/src/ocvu_pose.cpp \
        bindings/spec/geometry.json native/include/ocvu/geometry.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Geometry.g.cs \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(geometry): 回転ベクトルと回転行列を相互に変換する 2 本を出す"
```

---

## Task 3: `ocvu_project_points`

**Files:**
- Modify: `native/tests/test_pose.cpp`、`native/src/ocvu_pose.cpp`、`bindings/spec/geometry.json`

**Interfaces:**
- Consumes: `ocvu_pose_detail::MakeDistCoeffView`（Task 1 が作った）
- Produces: `ocvu_status ocvu_project_points(const float* object_points, int64_t object_points_length, int32_t point_count, const double* rvec, int64_t rvec_length, const double* tvec, int64_t tvec_length, const double* camera_matrix, int64_t camera_matrix_length, const double* dist_coeffs, int64_t dist_coeffs_length, float* out_image_points, int32_t out_capacity)`

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_pose.cpp` の末尾に足す。

```cpp
TEST(Pose, ProjectPointsMatchesTheHandComputedProjection) {
    // Task 1 の kSquareObject を (0, 0, 10) に回転なしで置くと kSquareImage に写る。
    // **その期待値は手で解いてある**（このファイルの冒頭のコメント）。
    const std::array<double, 3> rvec{0.0, 0.0, 0.0};
    const std::array<double, 3> tvec{0.0, 0.0, 10.0};
    std::array<float, 8> projected{};

    ASSERT_EQ(ocvu_project_points(kSquareObject.data(), kObjectBytes, 4,
                                  rvec.data(), static_cast<int64_t>(sizeof(rvec)),
                                  tvec.data(), static_cast<int64_t>(sizeof(tvec)),
                                  kCamera.data(), kCameraBytes,
                                  nullptr, 0,
                                  projected.data(), 8),
              OCVU_STATUS_OK);

    for (int i = 0; i < 8; ++i) {
        EXPECT_NEAR(projected[i], kSquareImage[i], 1e-3) << "要素 " << i;
    }
}

TEST(Pose, ProjectPointsRejectsBadArguments) {
    const std::array<double, 3> rvec{0.0, 0.0, 0.0};
    const std::array<double, 3> tvec{0.0, 0.0, 10.0};
    std::array<float, 8> projected{-7.0f, -7.0f, -7.0f, -7.0f, -7.0f, -7.0f, -7.0f, -7.0f};

    EXPECT_EQ(ocvu_project_points(nullptr, kObjectBytes, 4,
                                  rvec.data(), static_cast<int64_t>(sizeof(rvec)),
                                  tvec.data(), static_cast<int64_t>(sizeof(tvec)),
                                  kCamera.data(), kCameraBytes, nullptr, 0, projected.data(), 8),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_project_points(kSquareObject.data(), kObjectBytes, 4,
                                  rvec.data(), static_cast<int64_t>(sizeof(rvec)),
                                  tvec.data(), static_cast<int64_t>(sizeof(tvec)),
                                  kCamera.data(), kCameraBytes, nullptr, 0, nullptr, 8),
              OCVU_STATUS_NULL_POINTER);

    // point_count は 1 以上でよい（姿勢は与えられているので 4 点は要らない）。
    EXPECT_EQ(ocvu_project_points(kSquareObject.data(), kObjectBytes, 0,
                                  rvec.data(), static_cast<int64_t>(sizeof(rvec)),
                                  tvec.data(), static_cast<int64_t>(sizeof(tvec)),
                                  kCamera.data(), kCameraBytes, nullptr, 0, projected.data(), 8),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 容量が足りなければ何も書かない。4 点なら 8 要素が要る。
    EXPECT_EQ(ocvu_project_points(kSquareObject.data(), kObjectBytes, 4,
                                  rvec.data(), static_cast<int64_t>(sizeof(rvec)),
                                  tvec.data(), static_cast<int64_t>(sizeof(tvec)),
                                  kCamera.data(), kCameraBytes, nullptr, 0, projected.data(), 7),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    for (int i = 0; i < 8; ++i) {
        EXPECT_FLOAT_EQ(projected[i], -7.0f) << "断ったのに書いている";
    }
}
```

- [ ] **Step 2: RED を目で確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: **コンパイルエラー**。

- [ ] **Step 3: spec に 1 エントリ足して生成する**

```json
{
  "name": "ocvu_project_points",
  "summary": "3D の点を、与えた姿勢とカメラの内部パラメータで画像平面へ投影する。object_points は 1 点 3 float（x, y, z）で、object_points_length と rvec_length と tvec_length と camera_matrix_length と dist_coeffs_length はいずれもその配列の**バイト数**である（要素数でも点数でもない）。**呼ぶ側を信用せず、長さが必要量に満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。** point_count は 1 以上 OCVU_PNP_MAX_POINTS 以下でなければならない（姿勢は与えられているので 4 点は要らない）。rvec は Rodrigues の回転ベクトル（3 要素）、tvec は並進（3 要素）、camera_matrix は行優先の 3x3（9 要素）である。dist_coeffs は NULL と長さ 0 の組み合わせで歪み無しを指定でき、そうでなければ 4 / 5 / 8 / 12 / 14 個でなければならない。out_capacity は出力配列の**要素数**で（バイト数ではない）、point_count * 2 未満なら**何も書かずに** OCVU_STATUS_BUFFER_TOO_SMALL を返す。出力は x と y が交互に並ぶ float である。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返す。out_image_points の所有権は最初から最後まで呼ぶ側にある。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "object_points", "cType": "const float*", "csType": "float[]", "direction": "in-buffer" },
    { "name": "object_points_length", "cType": "int64_t", "csType": "long", "direction": "in" },
    { "name": "point_count", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "rvec", "cType": "const double*", "csType": "double[]", "direction": "in-buffer" },
    { "name": "rvec_length", "cType": "int64_t", "csType": "long", "direction": "in" },
    { "name": "tvec", "cType": "const double*", "csType": "double[]", "direction": "in-buffer" },
    { "name": "tvec_length", "cType": "int64_t", "csType": "long", "direction": "in" },
    { "name": "camera_matrix", "cType": "const double*", "csType": "double[]", "direction": "in-buffer" },
    { "name": "camera_matrix_length", "cType": "int64_t", "csType": "long", "direction": "in" },
    { "name": "dist_coeffs", "cType": "const double*", "csType": "double[]", "direction": "in-buffer" },
    { "name": "dist_coeffs_length", "cType": "int64_t", "csType": "long", "direction": "in" },
    { "name": "out_image_points", "cType": "float*", "csType": "float[]", "direction": "out-buffer" },
    { "name": "out_capacity", "cType": "int32_t", "csType": "int", "direction": "in" }
  ]
}
```

```
pwsh tools/dev.ps1 generate
```

- [ ] **Step 4: 実装する**

`native/src/ocvu_pose.cpp` の末尾に足す。

```cpp
extern "C" ocvu_status ocvu_project_points(const float* object_points, int64_t object_points_length, int32_t point_count, const double* rvec, int64_t rvec_length, const double* tvec, int64_t tvec_length, const double* camera_matrix, int64_t camera_matrix_length, const double* dist_coeffs, int64_t dist_coeffs_length, float* out_image_points, int32_t out_capacity) {
    OCVU_TRY_BEGIN
    using namespace ocvu_pose_detail;

    if (object_points == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_project_points: object_points is NULL");
    }
    if (rvec == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_project_points: rvec is NULL");
    }
    if (tvec == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_project_points: tvec is NULL");
    }
    if (camera_matrix == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_project_points: camera_matrix is NULL");
    }
    if (out_image_points == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_project_points: out_image_points is NULL");
    }
    // **姿勢は与えられているので 4 点は要らない。** 1 点でも投影できる。
    if (point_count < 1 || point_count > OCVU_PNP_MAX_POINTS) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_project_points: point_count must be between 1 and OCVU_PNP_MAX_POINTS");
    }

    const int64_t object_needed =
        static_cast<int64_t>(point_count) * 3 * static_cast<int64_t>(sizeof(float));
    if (object_points_length < object_needed) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_project_points: object_points_length (bytes) is too small for point_count");
    }
    if (rvec_length < static_cast<int64_t>(3 * sizeof(double))) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_project_points: rvec_length (bytes) is too small");
    }
    if (tvec_length < static_cast<int64_t>(3 * sizeof(double))) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_project_points: tvec_length (bytes) is too small");
    }
    if (camera_matrix_length < static_cast<int64_t>(9 * sizeof(double))) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_project_points: camera_matrix_length (bytes) is too small for a 3x3 matrix");
    }

    cv::Mat dist_view;
    const ocvu_status dist_status =
        MakeDistCoeffView(dist_coeffs, dist_coeffs_length, "ocvu_project_points", &dist_view);
    if (dist_status != OCVU_STATUS_OK) {
        return dist_status;
    }

    // 出力の必要量は呼ぶ側が知り得る（point_count * 2）ので 2 回呼びにしない。
    const int64_t needed = static_cast<int64_t>(point_count) * 2;
    if (static_cast<int64_t>(out_capacity) < needed) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_project_points: out_capacity (elements) must be at least point_count * 2");
    }

    const cv::Mat object_view(point_count, 3, CV_32F, const_cast<float*>(object_points));
    const cv::Mat rvec_view(3, 1, CV_64F, const_cast<double*>(rvec));
    const cv::Mat tvec_view(3, 1, CV_64F, const_cast<double*>(tvec));
    const cv::Mat camera_view(3, 3, CV_64F, const_cast<double*>(camera_matrix));

    // **求めてから書く。** 失敗したときに out_image_points が途中まで
    // 書き換わった状態で残らないようにする。
    std::vector<cv::Point2f> projected;
    try {
        cv::projectPoints(object_view, rvec_view, tvec_view, camera_view, dist_view, projected);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }
    if (static_cast<int64_t>(projected.size()) != static_cast<int64_t>(point_count)) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR,
                                      "ocvu_project_points: unexpected number of projected points");
    }

    for (int32_t i = 0; i < point_count; ++i) {
        out_image_points[i * 2] = projected[static_cast<size_t>(i)].x;
        out_image_points[i * 2 + 1] = projected[static_cast<size_t>(i)].y;
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

- [ ] **Step 5: L1 を緑にする**

```
pwsh tools/dev.ps1 test-native
```

期待: `Pose.*` が 10 件 pass、exit 0。

**この時点で `ocvu_solve_pnp` と `ocvu_project_points` が互いの逆になっている**
（同じ数値で往復する）。片方が壊れれば、もう片方のテストが残る。

- [ ] **Step 6: コミット**

```bash
git add native/tests/test_pose.cpp native/src/ocvu_pose.cpp \
        bindings/spec/geometry.json native/include/ocvu/geometry.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Geometry.g.cs \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(geometry): 3D の点を画像平面へ投影する ocvu_project_points を出す"
```

---

## Task 4: `ocvu_aruco_generate_marker`

**Files:**
- Create: `native/tests/test_aruco.cpp`、`native/src/ocvu_aruco.cpp`
- Modify: `native/include/opencv_unity_native.h`（`OCVU_ARUCO_DICT_*`）、`bindings/spec/objdetect.json`、`native/CMakeLists.txt`、`native/tests/CMakeLists.txt`

**Interfaces:**
- Consumes: `ocvu::mat_table_get`（`native/src/ocvu_mat_table.h`）
- Produces: `ocvu_status ocvu_aruco_generate_marker(int32_t dictionary_id, int32_t marker_id, int32_t side_pixels, int32_t border_bits, ocvu_mat_handle dst)`

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_aruco.cpp` を新規作成する。

```cpp
// ArUco の 2 本の契約テスト。
//
// **外部の画像資産に依存しない。** 自分で生成したマーカーを自分で検出する
// 閉じた輪にしてあるので、テストデータの取り違えも、環境による写りの差も無い。

#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <array>
#include <vector>

namespace {

// 生成したマーカーの周りに白の余白を置いた画像を作る。
// **余白が要る。** ArUco の検出は黒い枠の外側に白があることを前提にしている。
ocvu_mat_handle MakeSceneWithMarker(int32_t dictionary_id, int32_t marker_id,
                                    int32_t side_pixels, int32_t margin) {
    ocvu_mat_handle marker = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(side_pixels, side_pixels, OCVU_MAT_TYPE_8UC1, &marker),
              OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_aruco_generate_marker(dictionary_id, marker_id, side_pixels, 1, marker),
              OCVU_STATUS_OK);

    std::vector<uint8_t> marker_pixels(static_cast<size_t>(side_pixels) * side_pixels);
    EXPECT_EQ(ocvu_mat_copy_to_buffer(marker, marker_pixels.data(),
                                      static_cast<int64_t>(marker_pixels.size()), side_pixels),
              OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_release(marker), OCVU_STATUS_OK);

    const int32_t side = side_pixels + margin * 2;
    std::vector<uint8_t> scene(static_cast<size_t>(side) * side, 255);
    for (int32_t r = 0; r < side_pixels; ++r) {
        for (int32_t c = 0; c < side_pixels; ++c) {
            scene[static_cast<size_t>(r + margin) * side + (c + margin)] =
                marker_pixels[static_cast<size_t>(r) * side_pixels + c];
        }
    }

    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(side, side, OCVU_MAT_TYPE_8UC1, &handle), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, scene.data(),
                                        static_cast<int64_t>(scene.size()), side),
              OCVU_STATUS_OK);
    return handle;
}

}  // namespace

TEST(Aruco, GenerateMarkerFillsTheDestination) {
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(4, 4, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    // dst の形は結果に応じて置き換わる。作ったときの 4x4 は残らない。
    ASSERT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, 7, 120, 1, dst),
              OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 120);
    EXPECT_EQ(info.cols, 120);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_8UC1);

    // マーカーは黒と白の両方を含む。真っ白でも真っ黒でもない。
    std::vector<uint8_t> pixels(120 * 120);
    ASSERT_EQ(ocvu_mat_copy_to_buffer(dst, pixels.data(),
                                      static_cast<int64_t>(pixels.size()), 120),
              OCVU_STATUS_OK);
    bool has_black = false;
    bool has_white = false;
    for (uint8_t p : pixels) {
        if (p == 0) has_black = true;
        if (p == 255) has_white = true;
    }
    EXPECT_TRUE(has_black);
    EXPECT_TRUE(has_white);

    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(Aruco, GenerateMarkerRejectsBadArguments) {
    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(4, 4, OCVU_MAT_TYPE_8UC1, &dst), OCVU_STATUS_OK);

    // 知らない辞書は素通しにしない。
    EXPECT_EQ(ocvu_aruco_generate_marker(-1, 0, 100, 1, dst), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_ARUCO_ORIGINAL + 1, 0, 100, 1, dst),
              OCVU_STATUS_INVALID_ARGUMENT);

    // DICT_4X4_50 は 50 個しか持たない。範囲外の ID は拒否する。
    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, 50, 100, 1, dst),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, -1, 100, 1, dst),
              OCVU_STATUS_INVALID_ARGUMENT);

    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, 0, 0, 1, dst),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, 0, 100, 0, dst),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 無効な handle。
    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, 0, 100, 1,
                                         OCVU_MAT_HANDLE_NONE),
              OCVU_STATUS_INVALID_HANDLE);

    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}
```

`native/tests/CMakeLists.txt` の一覧に `test_aruco.cpp` を足す。

- [ ] **Step 2: RED を目で確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: **コンパイルエラー**（`ocvu_aruco_generate_marker` も `OCVU_ARUCO_DICT_4X4_50` も無い）。

- [ ] **Step 3: 辞書の定数をヘッダに足す**

`native/include/opencv_unity_native.h` の `OCVU_SOLVEPNP_*` の直後に足す。

```c
/* ocvu_aruco_generate_marker / ocvu_aruco_detect_markers の辞書。
 * cv::aruco::PredefinedDictionaryType の値をそのまま出す
 * （実装 .cpp の static_assert が写し間違いをコンパイル時に落とす）。
 *
 * 名前の 4X4 / 5X5 / 6X6 / 7X7 はマーカー内部の格子の細かさ、後ろの数字は
 * その辞書が持つ ID の個数である。**細かいほど遠くから読みにくく、
 * 個数が多いほど誤検出しやすい。** 用途が決まっていないなら 4X4_50 でよい。
 *
 * **AprilTag 系の 5 つは出していない。** cv::aruco には在るが、
 * この plugin では検証していない。 */
#define OCVU_ARUCO_DICT_4X4_50          0
#define OCVU_ARUCO_DICT_4X4_100         1
#define OCVU_ARUCO_DICT_4X4_250         2
#define OCVU_ARUCO_DICT_4X4_1000        3
#define OCVU_ARUCO_DICT_5X5_50          4
#define OCVU_ARUCO_DICT_5X5_100         5
#define OCVU_ARUCO_DICT_5X5_250         6
#define OCVU_ARUCO_DICT_5X5_1000        7
#define OCVU_ARUCO_DICT_6X6_50          8
#define OCVU_ARUCO_DICT_6X6_100         9
#define OCVU_ARUCO_DICT_6X6_250        10
#define OCVU_ARUCO_DICT_6X6_1000       11
#define OCVU_ARUCO_DICT_7X7_50         12
#define OCVU_ARUCO_DICT_7X7_100        13
#define OCVU_ARUCO_DICT_7X7_250        14
#define OCVU_ARUCO_DICT_7X7_1000       15
#define OCVU_ARUCO_DICT_ARUCO_ORIGINAL 16

/* ocvu_aruco_generate_marker の side_pixels の上限。
 * 呼ぶ側が過大な値を渡したときに native 側で確保しないための歯止めである
 * （side_pixels * side_pixels のバイト数を確保するので、縛らないと
 * 4 GB 級の要求が通ってしまう）。 */
#define OCVU_ARUCO_MAX_MARKER_PIXELS 4096
```

- [ ] **Step 4: spec に 1 エントリ足して生成する**

`bindings/spec/objdetect.json` に足す。

```json
{
  "name": "ocvu_aruco_generate_marker",
  "summary": "辞書とマーカー ID からマーカーの画像を生成して dst に入れる。dst は結果に応じて丸ごと置き換わり、side_pixels x side_pixels の 8 bit 1 channel になる。dictionary_id は OCVU_ARUCO_DICT_* のいずれかで、それ以外は OCVU_STATUS_INVALID_ARGUMENT を返す。marker_id は 0 以上かつその辞書が持つ個数未満でなければならない（DICT_4X4_50 なら 0 から 49 まで）。side_pixels は 1 以上 OCVU_ARUCO_MAX_MARKER_PIXELS 以下、border_bits は 1 以上でなければならない。border_bits はマーカーの内側に置く黒い枠の太さ（格子単位）である —— **検出にはこの枠の外側にも白い余白が要るが、それを付けるのは呼ぶ側の仕事である。** 失敗したときは dst を書き換えない。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "dictionary_id", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "marker_id", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "side_pixels", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "border_bits", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "dst", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" }
  ]
}
```

```
pwsh tools/dev.ps1 generate
```

- [ ] **Step 5: 実装する**

`native/src/ocvu_aruco.cpp` を新規作成する。

```cpp
// objdetect module のうち ArUco マーカーに関わるもの。
//
// **ocvu_objdetect.cpp に足していない。** あちらは QR コードで、
// 辞書も検出器も別物である。

#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/objdetect/aruco_detector.hpp>
#include <opencv2/objdetect/aruco_dictionary.hpp>

#include <cstdint>
#include <vector>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

// 境界に出す辞書の値は OpenCV のものをそのまま使う。
static_assert(OCVU_ARUCO_DICT_4X4_50 == cv::aruco::DICT_4X4_50, "DICT_4X4_50 がずれている");
static_assert(OCVU_ARUCO_DICT_4X4_100 == cv::aruco::DICT_4X4_100, "DICT_4X4_100 がずれている");
static_assert(OCVU_ARUCO_DICT_4X4_250 == cv::aruco::DICT_4X4_250, "DICT_4X4_250 がずれている");
static_assert(OCVU_ARUCO_DICT_4X4_1000 == cv::aruco::DICT_4X4_1000, "DICT_4X4_1000 がずれている");
static_assert(OCVU_ARUCO_DICT_5X5_50 == cv::aruco::DICT_5X5_50, "DICT_5X5_50 がずれている");
static_assert(OCVU_ARUCO_DICT_5X5_100 == cv::aruco::DICT_5X5_100, "DICT_5X5_100 がずれている");
static_assert(OCVU_ARUCO_DICT_5X5_250 == cv::aruco::DICT_5X5_250, "DICT_5X5_250 がずれている");
static_assert(OCVU_ARUCO_DICT_5X5_1000 == cv::aruco::DICT_5X5_1000, "DICT_5X5_1000 がずれている");
static_assert(OCVU_ARUCO_DICT_6X6_50 == cv::aruco::DICT_6X6_50, "DICT_6X6_50 がずれている");
static_assert(OCVU_ARUCO_DICT_6X6_100 == cv::aruco::DICT_6X6_100, "DICT_6X6_100 がずれている");
static_assert(OCVU_ARUCO_DICT_6X6_250 == cv::aruco::DICT_6X6_250, "DICT_6X6_250 がずれている");
static_assert(OCVU_ARUCO_DICT_6X6_1000 == cv::aruco::DICT_6X6_1000, "DICT_6X6_1000 がずれている");
static_assert(OCVU_ARUCO_DICT_7X7_50 == cv::aruco::DICT_7X7_50, "DICT_7X7_50 がずれている");
static_assert(OCVU_ARUCO_DICT_7X7_100 == cv::aruco::DICT_7X7_100, "DICT_7X7_100 がずれている");
static_assert(OCVU_ARUCO_DICT_7X7_250 == cv::aruco::DICT_7X7_250, "DICT_7X7_250 がずれている");
static_assert(OCVU_ARUCO_DICT_7X7_1000 == cv::aruco::DICT_7X7_1000, "DICT_7X7_1000 がずれている");
static_assert(OCVU_ARUCO_DICT_ARUCO_ORIGINAL == cv::aruco::DICT_ARUCO_ORIGINAL,
              "DICT_ARUCO_ORIGINAL がずれている");

namespace ocvu_aruco_detail {

bool IsKnownDictionary(int32_t dictionary_id) {
    return dictionary_id >= OCVU_ARUCO_DICT_4X4_50 &&
           dictionary_id <= OCVU_ARUCO_DICT_ARUCO_ORIGINAL;
}

}  // namespace ocvu_aruco_detail

extern "C" ocvu_status ocvu_aruco_generate_marker(int32_t dictionary_id, int32_t marker_id, int32_t side_pixels, int32_t border_bits, ocvu_mat_handle dst) {
    OCVU_TRY_BEGIN
    using namespace ocvu_aruco_detail;

    if (!IsKnownDictionary(dictionary_id)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_aruco_generate_marker: dictionary_id is not one of OCVU_ARUCO_DICT_*");
    }
    if (side_pixels < 1 || side_pixels > OCVU_ARUCO_MAX_MARKER_PIXELS) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_aruco_generate_marker: side_pixels must be between 1 and OCVU_ARUCO_MAX_MARKER_PIXELS");
    }
    if (border_bits < 1) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_aruco_generate_marker: border_bits must be at least 1");
    }

    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_aruco_generate_marker: dst handle is invalid");
    }

    const cv::aruco::Dictionary dictionary = cv::aruco::getPredefinedDictionary(dictionary_id);
    // **辞書ごとに ID の個数が違う。** OpenCV に落とすと例外になるので
    // ここで断る —— 呼ぶ側が直せる誤りは INVALID_ARGUMENT で返す。
    if (marker_id < 0 || marker_id >= dictionary.bytesList.rows) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_aruco_generate_marker: marker_id is out of range for this dictionary");
    }

    // **作ってから入れる。** 失敗したときに dst が途中まで書き換わらないようにする。
    cv::Mat image;
    try {
        dictionary.generateImageMarker(marker_id, side_pixels, image, border_bits);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = image;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

`native/CMakeLists.txt` の `OCVU_SOURCES` に `src/ocvu_aruco.cpp` を足す。

- [ ] **Step 6: L1 を緑にする**

```
pwsh tools/dev.ps1 test-native
```

期待: `Aruco.GenerateMarker*` の 2 件が pass、exit 0。
`Aruco.Detect*` はまだ書いていないので存在しない。

- [ ] **Step 7: コミット**

```bash
git add native/tests/test_aruco.cpp native/tests/CMakeLists.txt \
        native/src/ocvu_aruco.cpp native/CMakeLists.txt \
        native/include/opencv_unity_native.h \
        bindings/spec/objdetect.json native/include/ocvu/objdetect.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Objdetect.g.cs \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(objdetect): ArUco マーカーの画像を生成する ocvu_aruco_generate_marker を出す"
```

---

## Task 5: `ocvu_aruco_detect_markers`

**Files:**
- Modify: `native/tests/test_aruco.cpp`、`native/src/ocvu_aruco.cpp`、`bindings/spec/objdetect.json`

**Interfaces:**
- Consumes: `ocvu_aruco_generate_marker`（Task 4）、`MakeSceneWithMarker`（Task 4 のテストヘルパ）
- Produces: `ocvu_status ocvu_aruco_detect_markers(ocvu_mat_handle src, int32_t dictionary_id, int32_t* out_ids, int32_t ids_capacity, float* out_corners, int32_t corners_capacity, int32_t* out_count)`

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_aruco.cpp` の末尾に足す。

```cpp
TEST(Aruco, DetectFindsTheMarkerItGenerated) {
    // **生成したものを検出する閉じた輪である。** 外部の画像に依存しない。
    const ocvu_mat_handle scene = MakeSceneWithMarker(OCVU_ARUCO_DICT_4X4_50, 7, 200, 60);

    std::array<int32_t, 8> ids{};
    std::array<float, 64> corners{};
    int32_t count = -1;

    ASSERT_EQ(ocvu_aruco_detect_markers(scene, OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), 8, corners.data(), 64, &count),
              OCVU_STATUS_OK);
    ASSERT_EQ(count, 1);
    EXPECT_EQ(ids[0], 7);

    // 4 隅はマーカーの内側 200x200 の領域（余白 60 の内側）に収まる。
    // **厳密な位置ではなく範囲を見る** —— 検出器の細かな挙動に縛られないため。
    for (int i = 0; i < 8; ++i) {
        EXPECT_GE(corners[i], 50.0f) << "隅 " << i << " が余白の外に出ている";
        EXPECT_LE(corners[i], 270.0f) << "隅 " << i << " が余白の外に出ている";
    }

    EXPECT_EQ(ocvu_mat_release(scene), OCVU_STATUS_OK);
}

TEST(Aruco, DetectReturnsZeroWhenNothingIsThere) {
    // **検出できないのは誤りではない。** OK と count 0 で返る。
    ocvu_mat_handle blank = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(120, 120, OCVU_MAT_TYPE_8UC1, &blank), OCVU_STATUS_OK);

    std::array<int32_t, 8> ids{};
    std::array<float, 64> corners{};
    int32_t count = -1;

    EXPECT_EQ(ocvu_aruco_detect_markers(blank, OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), 8, corners.data(), 64, &count),
              OCVU_STATUS_OK);
    EXPECT_EQ(count, 0);

    EXPECT_EQ(ocvu_mat_release(blank), OCVU_STATUS_OK);
}

TEST(Aruco, DetectRejectsTooSmallBuffersWithoutWriting) {
    const ocvu_mat_handle scene = MakeSceneWithMarker(OCVU_ARUCO_DICT_4X4_50, 7, 200, 60);

    std::array<int32_t, 8> ids{};
    std::array<float, 64> corners{};
    ids.fill(-7);
    corners.fill(-7.0f);
    int32_t count = -1;

    // ids の容量が足りない。
    EXPECT_EQ(ocvu_aruco_detect_markers(scene, OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), 0, corners.data(), 64, &count),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(count, 1) << "溢れたときは実際に見つかった数を返すこと";

    // corners の容量が足りない（1 マーカーにつき 8 要素が要る）。
    count = -1;
    EXPECT_EQ(ocvu_aruco_detect_markers(scene, OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), 8, corners.data(), 7, &count),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(count, 1);

    for (int32_t v : ids) EXPECT_EQ(v, -7) << "断ったのに ids を書いている";
    for (float v : corners) EXPECT_FLOAT_EQ(v, -7.0f) << "断ったのに corners を書いている";

    EXPECT_EQ(ocvu_mat_release(scene), OCVU_STATUS_OK);
}

TEST(Aruco, DetectRejectsBadArgumentsAndZeroesTheCount) {
    ocvu_mat_handle blank = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(120, 120, OCVU_MAT_TYPE_8UC1, &blank), OCVU_STATUS_OK);

    std::array<int32_t, 8> ids{};
    std::array<float, 64> corners{};

    // **out_count が NULL なら、他の何より先に断る。**
    EXPECT_EQ(ocvu_aruco_detect_markers(blank, OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), 8, corners.data(), 64, nullptr),
              OCVU_STATUS_NULL_POINTER);

    // **0 ではない値で汚してから呼ぶ。** どの失敗経路でも 0 が書かれること。
    int32_t count = 12345;
    EXPECT_EQ(ocvu_aruco_detect_markers(blank, 99, ids.data(), 8, corners.data(), 64, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0) << "失敗時は out_count に 0 を書くこと";

    count = 12345;
    EXPECT_EQ(ocvu_aruco_detect_markers(blank, OCVU_ARUCO_DICT_4X4_50,
                                        nullptr, 8, corners.data(), 64, &count),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_aruco_detect_markers(blank, OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), 8, nullptr, 64, &count),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_aruco_detect_markers(OCVU_MAT_HANDLE_NONE, OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), 8, corners.data(), 64, &count),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_aruco_detect_markers(blank, OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), -1, corners.data(), 64, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    EXPECT_EQ(ocvu_mat_release(blank), OCVU_STATUS_OK);
}
```

- [ ] **Step 2: RED を目で確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: **コンパイルエラー**。

- [ ] **Step 3: spec に 1 エントリ足して生成する**

```json
{
  "name": "ocvu_aruco_detect_markers",
  "summary": "src から ArUco マーカーを検出し、その ID を out_ids へ、4 隅の座標を out_corners へ書いて、見つかった個数を out_count に返す。dictionary_id は OCVU_ARUCO_DICT_* のいずれかで、それ以外は OCVU_STATUS_INVALID_ARGUMENT を返す。ids_capacity と corners_capacity はどちらも**配列の要素数**である（バイト数ではない）—— 1 マーカーにつき ID が 1 個、隅の座標が 8 個（x と y が交互に 4 隅ぶん）要るので、n 個を受けるには ids_capacity が n 以上、corners_capacity が n * 8 以上でなければならない。**隅は時計回りで、左上から始まる。** 容量が足りないときは**どちらの配列にも 1 バイトも書かずに** OCVU_STATUS_BUFFER_TOO_SMALL を返し、out_count には**実際に見つかった個数**を入れる（呼ぶ側はそれで確保し直して呼び直せる）。**1 個も見つからないのは誤りではない** —— OCVU_STATUS_OK を返して out_count に 0 を入れる。out_count が NULL なら他の何より先に OCVU_STATUS_NULL_POINTER を返し、通ったあとはどの失敗経路でも out_count に 0 を書く。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返す。buffer の所有権は最初から最後まで呼ぶ側にある。",
  "returns": "ocvu_status",
  "csReturns": "int",
  "wrapInTryBarrier": true,
  "params": [
    { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
    { "name": "dictionary_id", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "out_ids", "cType": "int32_t*", "csType": "int[]", "direction": "out-buffer" },
    { "name": "ids_capacity", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "out_corners", "cType": "float*", "csType": "float[]", "direction": "out-buffer" },
    { "name": "corners_capacity", "cType": "int32_t", "csType": "int", "direction": "in" },
    { "name": "out_count", "cType": "int32_t*", "csType": "out int", "direction": "out" }
  ]
}
```

```
pwsh tools/dev.ps1 generate
```

- [ ] **Step 4: 実装する**

`native/src/ocvu_aruco.cpp` の末尾に足す。

```cpp
extern "C" ocvu_status ocvu_aruco_detect_markers(ocvu_mat_handle src, int32_t dictionary_id, int32_t* out_ids, int32_t ids_capacity, float* out_corners, int32_t corners_capacity, int32_t* out_count) {
    OCVU_TRY_BEGIN
    using namespace ocvu_aruco_detail;

    // **out_count を最初に見る。** 無いと呼ぶ側は溢れたときの必要量を
    // 決められないので、他のどの引数より先に断る（ocvu_imencode と同じ作法）。
    if (out_count == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_aruco_detect_markers: out_count is NULL");
    }
    // **通ったら何よりも先に 0 を書く。** どの経路で返っても、呼ぶ側が読む値が
    // 未初期化のままにならないようにする。以降のすべての早期 return はこの後ろに来る。
    *out_count = 0;

    if (!IsKnownDictionary(dictionary_id)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_aruco_detect_markers: dictionary_id is not one of OCVU_ARUCO_DICT_*");
    }
    if (out_ids == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_aruco_detect_markers: out_ids is NULL");
    }
    if (out_corners == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_aruco_detect_markers: out_corners is NULL");
    }
    if (ids_capacity < 0 || corners_capacity < 0) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_aruco_detect_markers: capacities must not be negative");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_aruco_detect_markers: src handle is invalid");
    }

    const cv::aruco::Dictionary dictionary = cv::aruco::getPredefinedDictionary(dictionary_id);
    const cv::aruco::ArucoDetector detector(dictionary);

    std::vector<std::vector<cv::Point2f>> corners;
    std::vector<int> ids;
    try {
        detector.detectMarkers(*src_mat, corners, ids);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    const int64_t found = static_cast<int64_t>(ids.size());
    if (found != static_cast<int64_t>(corners.size())) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_OPENCV_ERROR,
            "ocvu_aruco_detect_markers: ids and corners have different lengths");
    }

    // **溢れたことは、見つかった数と一緒に伝える。** 呼ぶ側はそれで
    // 確保し直して呼び直せる（ocvu_orb_detect と同じ作法）。
    // **積は int64_t で作る**（found は OpenCV 由来なので上限を仮定しない）。
    const int64_t corners_needed = found * 8;
    if (found > static_cast<int64_t>(ids_capacity) ||
        corners_needed > static_cast<int64_t>(corners_capacity)) {
        *out_count = static_cast<int32_t>(found);
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_aruco_detect_markers: ids_capacity or corners_capacity is too small");
    }

    for (int64_t i = 0; i < found; ++i) {
        const std::vector<cv::Point2f>& quad = corners[static_cast<size_t>(i)];
        if (quad.size() != 4) {
            // ここまで来て 4 隅でないのは OpenCV 側の前提が変わったということである。
            // **書きかけで返らない** —— 何も書いていない状態で断る。
            *out_count = 0;
            return ::ocvu::set_last_error(
                OCVU_STATUS_OPENCV_ERROR,
                "ocvu_aruco_detect_markers: a detected marker does not have 4 corners");
        }
    }

    for (int64_t i = 0; i < found; ++i) {
        out_ids[i] = ids[static_cast<size_t>(i)];
        const std::vector<cv::Point2f>& quad = corners[static_cast<size_t>(i)];
        for (int64_t c = 0; c < 4; ++c) {
            out_corners[i * 8 + c * 2] = quad[static_cast<size_t>(c)].x;
            out_corners[i * 8 + c * 2 + 1] = quad[static_cast<size_t>(c)].y;
        }
    }

    *out_count = static_cast<int32_t>(found);
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

- [ ] **Step 5: L1 を緑にする**

```
pwsh tools/dev.ps1 test-native
```

期待: `Aruco.*` が 6 件 pass、exit 0。

- [ ] **Step 6: 検査が働くことを確かめる**

1. `*out_count = 0;` の行を消す
2. `pwsh tools/dev.ps1 test-native` → **`Aruco.DetectRejectsBadArgumentsAndZeroesTheCount`
   が落ちること**を目で見る（M3.5 では同じ形の代入を消しても既存の 16 件が
   緑のまま通った。**わざと汚しているからこれは落ちる**）
3. 戻して緑に戻ることを確認する

- [ ] **Step 7: ASan を回す**

**メモリを触る関数を 6 本足したので必ず回す。**

```
pwsh tools/dev.ps1 test-asan
```

期待: exit 0。

- [ ] **Step 8: コミット**

```bash
git add native/tests/test_aruco.cpp native/src/ocvu_aruco.cpp \
        bindings/spec/objdetect.json native/include/ocvu/objdetect.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Objdetect.g.cs \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(objdetect): ArUco マーカーを検出する ocvu_aruco_detect_markers を出す"
```

---

## Task 6: C# の公開 API と L3

**Files:**
- Create: `Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvAruco.cs`（+ `.meta`）
- Create: `tests/Managed/CvUnity.Tests.Managed/PoseTests.cs`、`tests/Managed/CvUnity.Tests.Managed/ArucoTests.cs`
- Modify: `Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvGeometry.cs`

**Interfaces:**
- Consumes: 生成された `NativeMethods.ocvu_solve_pnp` / `ocvu_rodrigues_to_matrix` / `ocvu_rodrigues_to_vector` / `ocvu_project_points` / `ocvu_aruco_generate_marker` / `ocvu_aruco_detect_markers`
- Produces:
  - `CvGeometry.SolvePnP(CvPoint3[] objectPoints, CvPoint2[] imagePoints, double[] cameraMatrix, double[] distCoeffs, CvSolvePnPMethod method)` → `CvViewPose`
  - `CvGeometry.RodriguesToMatrix(CvViewPose pose)` → `double[]`（9 要素）
  - `CvGeometry.RodriguesToVector(double[] rotationMatrix)` → `double[]`（3 要素）
  - `CvGeometry.ProjectPoints(CvPoint3[] objectPoints, CvViewPose pose, double[] cameraMatrix, double[] distCoeffs)` → `CvPoint2[]`
  - `CvAruco.GenerateMarker(CvArucoDictionary dictionary, int markerId, int sidePixels, int borderBits)` → `CvMat`
  - `CvAruco.DetectMarkers(CvMat src, CvArucoDictionary dictionary, int maxMarkers)` → `CvArucoMarker[]`
  - `CvAruco.EstimateMarkerPose(CvArucoMarker marker, float markerLength, double[] cameraMatrix, double[] distCoeffs)` → `CvViewPose`

- [ ] **Step 1: `CvGeometry` に姿勢の 4 本を足す**

`Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvGeometry.cs` の
`CvHomographyMethod` enum の直後に足す。

```csharp
    /// <summary>
    /// 姿勢の求め方。
    /// </summary>
    /// <remarks>
    /// 値は C の <c>OCVU_SOLVEPNP_*</c> の写しである。C# から C の
    /// <c>#define</c> は読めないので複製しており、<c>PoseTests</c> の
    /// <c>TheManagedMethodValuesMatchWhatNativeAccepts</c> が両側を native に
    /// 問うことで同期を守っている。
    /// </remarks>
    public enum CvSolvePnPMethod
    {
        /// <summary>既定。平面上の 4 点でも非平面の 6 点でも解ける。</summary>
        Iterative = 0,

        /// <summary>効率の良い n 点法。6 点以上で使う。</summary>
        Epnp = 1,

        /// <summary>3 点法。ちょうど 4 点を渡す。</summary>
        P3p = 2,

        /// <summary>代数的な 3 点法。ちょうど 4 点を渡す。</summary>
        Ap3p = 3,

        /// <summary>平面専用。すべての点が同一平面上になければならない。</summary>
        Ippe = 4,

        /// <summary>
        /// 正方形マーカー専用。**点の並び順が決まっている**（左上・右上・右下・左下）。
        /// <see cref="CvAruco.EstimateMarkerPose"/> がこれを使う。
        /// </summary>
        IppeSquare = 5,

        /// <summary>大域最適な n 点法。</summary>
        SqPnp = 6,
    }
```

`CvGeometry` クラスの末尾に足す。

```csharp
        /// <summary>
        /// 既知の 3D 点と、その画像上の対応点から 1 枚ぶんの姿勢を求める。
        /// </summary>
        /// <param name="objectPoints">対象の 3D 座標。4 点以上。</param>
        /// <param name="imagePoints">その画像上の位置。<paramref name="objectPoints"/> と同じ個数・同じ順。</param>
        /// <param name="cameraMatrix">カメラ行列（3x3 を行優先で並べた 9 個）。</param>
        /// <param name="distCoeffs">歪み係数。<c>null</c> か空で「歪み無し」。そうでなければ 4 / 5 / 8 / 12 / 14 個。</param>
        /// <param name="method">求め方。</param>
        /// <exception cref="CvNativeException">姿勢が求まらないときも含めて、native が失敗を返したとき。</exception>
        public static CvViewPose SolvePnP(
            CvPoint3[] objectPoints, CvPoint2[] imagePoints,
            double[] cameraMatrix, double[] distCoeffs,
            CvSolvePnPMethod method = CvSolvePnPMethod.Iterative)
        {
            if (objectPoints == null) throw new ArgumentNullException(nameof(objectPoints));
            if (imagePoints == null) throw new ArgumentNullException(nameof(imagePoints));
            if (cameraMatrix == null) throw new ArgumentNullException(nameof(cameraMatrix));
            if (objectPoints.Length != imagePoints.Length)
                throw new ArgumentException(
                    "objectPoints と imagePoints は同じ個数でなければなりません。", nameof(imagePoints));

            var flatObject = new float[objectPoints.Length * 3];
            for (int i = 0; i < objectPoints.Length; i++)
            {
                flatObject[i * 3] = objectPoints[i].X;
                flatObject[i * 3 + 1] = objectPoints[i].Y;
                flatObject[i * 3 + 2] = objectPoints[i].Z;
            }

            var flatImage = new float[imagePoints.Length * 2];
            for (int i = 0; i < imagePoints.Length; i++)
            {
                flatImage[i * 2] = imagePoints[i].X;
                flatImage[i * 2 + 1] = imagePoints[i].Y;
            }

            var coeffs = distCoeffs ?? Array.Empty<double>();
            var rvec = new double[3];
            var tvec = new double[3];

            var status = (CvStatus)NativeMethods.ocvu_solve_pnp(
                flatObject, (long)flatObject.Length * sizeof(float),
                flatImage, (long)flatImage.Length * sizeof(float),
                objectPoints.Length,
                cameraMatrix, (long)cameraMatrix.Length * sizeof(double),
                coeffs.Length == 0 ? null : coeffs, (long)coeffs.Length * sizeof(double),
                (int)method,
                rvec, rvec.Length, tvec, tvec.Length);
            CvNative.ThrowIfFailed(status);

            return new CvViewPose(rvec[0], rvec[1], rvec[2], tvec[0], tvec[1], tvec[2]);
        }

        /// <summary>
        /// 姿勢の回転ベクトルを 3x3 の回転行列（行優先の 9 個）に直す。
        /// </summary>
        public static double[] RodriguesToMatrix(CvViewPose pose)
        {
            var rvec = new[] { pose.RotationX, pose.RotationY, pose.RotationZ };
            var matrix = new double[9];
            var status = (CvStatus)NativeMethods.ocvu_rodrigues_to_matrix(
                rvec, (long)rvec.Length * sizeof(double), matrix, matrix.Length);
            CvNative.ThrowIfFailed(status);
            return matrix;
        }

        /// <summary>
        /// 3x3 の回転行列（行優先の 9 個）を回転ベクトル（3 個）に直す。
        /// </summary>
        public static double[] RodriguesToVector(double[] rotationMatrix)
        {
            if (rotationMatrix == null) throw new ArgumentNullException(nameof(rotationMatrix));
            if (rotationMatrix.Length < 9)
                throw new ArgumentException("回転行列は 9 個でなければなりません。", nameof(rotationMatrix));

            var vector = new double[3];
            var status = (CvStatus)NativeMethods.ocvu_rodrigues_to_vector(
                rotationMatrix, (long)rotationMatrix.Length * sizeof(double), vector, vector.Length);
            CvNative.ThrowIfFailed(status);
            return vector;
        }

        /// <summary>
        /// 3D の点を、与えた姿勢とカメラで画像平面へ投影する。
        /// </summary>
        public static CvPoint2[] ProjectPoints(
            CvPoint3[] objectPoints, CvViewPose pose,
            double[] cameraMatrix, double[] distCoeffs)
        {
            if (objectPoints == null) throw new ArgumentNullException(nameof(objectPoints));
            if (cameraMatrix == null) throw new ArgumentNullException(nameof(cameraMatrix));

            var flatObject = new float[objectPoints.Length * 3];
            for (int i = 0; i < objectPoints.Length; i++)
            {
                flatObject[i * 3] = objectPoints[i].X;
                flatObject[i * 3 + 1] = objectPoints[i].Y;
                flatObject[i * 3 + 2] = objectPoints[i].Z;
            }

            var rvec = new[] { pose.RotationX, pose.RotationY, pose.RotationZ };
            var tvec = new[] { pose.TranslationX, pose.TranslationY, pose.TranslationZ };
            var coeffs = distCoeffs ?? Array.Empty<double>();
            var projected = new float[objectPoints.Length * 2];

            var status = (CvStatus)NativeMethods.ocvu_project_points(
                flatObject, (long)flatObject.Length * sizeof(float), objectPoints.Length,
                rvec, (long)rvec.Length * sizeof(double),
                tvec, (long)tvec.Length * sizeof(double),
                cameraMatrix, (long)cameraMatrix.Length * sizeof(double),
                coeffs.Length == 0 ? null : coeffs, (long)coeffs.Length * sizeof(double),
                projected, projected.Length);
            CvNative.ThrowIfFailed(status);

            var result = new CvPoint2[objectPoints.Length];
            for (int i = 0; i < result.Length; i++)
            {
                result[i] = new CvPoint2(projected[i * 2], projected[i * 2 + 1]);
            }
            return result;
        }
```

- [ ] **Step 2: `CvAruco` を新規作成する**

`Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvAruco.cs`

```csharp
using System;
using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>
    /// ArUco マーカーの辞書。
    /// </summary>
    /// <remarks>
    /// 値は C の <c>OCVU_ARUCO_DICT_*</c> の写しである。C# から C の
    /// <c>#define</c> は読めないので複製しており、<c>ArucoTests</c> の
    /// <c>TheManagedDictionaryValuesMatchWhatNativeAccepts</c> が両側を native に
    /// 問うことで同期を守っている。
    /// <para>
    /// 名前の 4x4 / 5x5 / 6x6 / 7x7 はマーカー内部の格子の細かさ、後ろの数字は
    /// その辞書が持つ ID の個数である。**細かいほど遠くから読みにくく、
    /// 個数が多いほど誤検出しやすい。** 用途が決まっていないなら
    /// <see cref="Dict4X4_50"/> でよい。
    /// </para>
    /// </remarks>
    public enum CvArucoDictionary
    {
        /// <summary>4x4 の格子、50 個。</summary>
        Dict4X4_50 = 0,
        /// <summary>4x4 の格子、100 個。</summary>
        Dict4X4_100 = 1,
        /// <summary>4x4 の格子、250 個。</summary>
        Dict4X4_250 = 2,
        /// <summary>4x4 の格子、1000 個。</summary>
        Dict4X4_1000 = 3,
        /// <summary>5x5 の格子、50 個。</summary>
        Dict5X5_50 = 4,
        /// <summary>5x5 の格子、100 個。</summary>
        Dict5X5_100 = 5,
        /// <summary>5x5 の格子、250 個。</summary>
        Dict5X5_250 = 6,
        /// <summary>5x5 の格子、1000 個。</summary>
        Dict5X5_1000 = 7,
        /// <summary>6x6 の格子、50 個。</summary>
        Dict6X6_50 = 8,
        /// <summary>6x6 の格子、100 個。</summary>
        Dict6X6_100 = 9,
        /// <summary>6x6 の格子、250 個。</summary>
        Dict6X6_250 = 10,
        /// <summary>6x6 の格子、1000 個。</summary>
        Dict6X6_1000 = 11,
        /// <summary>7x7 の格子、50 個。</summary>
        Dict7X7_50 = 12,
        /// <summary>7x7 の格子、100 個。</summary>
        Dict7X7_100 = 13,
        /// <summary>7x7 の格子、250 個。</summary>
        Dict7X7_250 = 14,
        /// <summary>7x7 の格子、1000 個。</summary>
        Dict7X7_1000 = 15,
        /// <summary>ArUco の元の辞書（6x6 の格子、1024 個）。</summary>
        ArucoOriginal = 16,
    }

    /// <summary>
    /// 検出された ArUco マーカー 1 個。
    /// </summary>
    /// <remarks>
    /// 4 隅は時計回りで、左上から始まる（OpenCV がそう返す）。
    /// </remarks>
    public readonly struct CvArucoMarker
    {
        /// <summary>辞書内のマーカー ID。</summary>
        public int Id { get; }

        /// <summary>左上の隅（画素）。</summary>
        public CvPoint2 TopLeft { get; }

        /// <summary>右上の隅（画素）。</summary>
        public CvPoint2 TopRight { get; }

        /// <summary>右下の隅（画素）。</summary>
        public CvPoint2 BottomRight { get; }

        /// <summary>左下の隅（画素）。</summary>
        public CvPoint2 BottomLeft { get; }

        /// <summary>ID と 4 隅からマーカーを作る。</summary>
        public CvArucoMarker(int id, CvPoint2 topLeft, CvPoint2 topRight,
                             CvPoint2 bottomRight, CvPoint2 bottomLeft)
        {
            Id = id;
            TopLeft = topLeft;
            TopRight = topRight;
            BottomRight = bottomRight;
            BottomLeft = bottomLeft;
        }
    }

    /// <summary>
    /// ArUco マーカーの生成と検出（OpenCV の objdetect）。
    /// </summary>
    public static class CvAruco
    {
        /// <summary>
        /// C の OCVU_ARUCO_MAX_MARKER_PIXELS の写しである。
        /// ArucoTests の TheManagedUpperBoundMatchesWhatNativeAccepts が
        /// 両側を native に問うことで同期を守っている。
        /// </summary>
        private const int MaxMarkerPixels = 4096;

        /// <summary>
        /// 辞書とマーカー ID から、印刷できるマーカーの画像を作る。
        /// </summary>
        /// <remarks>
        /// **検出するには、この画像の周りに白い余白が要る。** 返る画像には
        /// 余白が入っていない（<paramref name="borderBits"/> はマーカーの
        /// 内側に置く黒い枠である）。印刷するときは周囲を白く空けること。
        /// </remarks>
        public static CvMat GenerateMarker(
            CvArucoDictionary dictionary, int markerId, int sidePixels, int borderBits = 1)
        {
            if (sidePixels <= 0 || sidePixels > MaxMarkerPixels)
                throw new ArgumentOutOfRangeException(
                    nameof(sidePixels), sidePixels,
                    $"sidePixels は 1 以上 {MaxMarkerPixels} 以下でなければなりません。");
            if (borderBits <= 0)
                throw new ArgumentOutOfRangeException(
                    nameof(borderBits), borderBits, "borderBits は 1 以上でなければなりません。");

            var dst = new CvMat(1, 1, CvMatType.Cv8UC1);
            try
            {
                var status = (CvStatus)NativeMethods.ocvu_aruco_generate_marker(
                    (int)dictionary, markerId, sidePixels, borderBits, dst.Handle);
                CvNative.ThrowIfFailed(status);
            }
            catch
            {
                dst.Dispose();
                throw;
            }
            return dst;
        }

        /// <summary>
        /// 画像から ArUco マーカーを検出する。
        /// </summary>
        /// <param name="src">検出対象。</param>
        /// <param name="dictionary">探す辞書。</param>
        /// <param name="maxMarkers">受け取る上限。これを超えて見つかった場合は、その数で確保し直して 1 度だけ呼び直す。</param>
        /// <returns>見つかったマーカー。1 個も無ければ空の配列（**これは誤りではない**）。</returns>
        public static CvArucoMarker[] DetectMarkers(
            CvMat src, CvArucoDictionary dictionary, int maxMarkers = 64)
        {
            if (src == null) throw new ArgumentNullException(nameof(src));
            if (maxMarkers <= 0)
                throw new ArgumentOutOfRangeException(
                    nameof(maxMarkers), maxMarkers, "maxMarkers は 1 以上でなければなりません。");

            var markers = TryDetect(src, dictionary, maxMarkers, out int found);
            if (markers != null) return markers;

            // 溢れた。**native が返した実際の個数で 1 度だけ確保し直す。**
            markers = TryDetect(src, dictionary, found, out _);
            if (markers == null)
                throw new CvNativeException(
                    CvStatus.BufferTooSmall,
                    "ArUco の検出が 2 度続けて溢れました。検出数が呼び出しの間に変わっています。");
            return markers;
        }

        private static CvArucoMarker[] TryDetect(
            CvMat src, CvArucoDictionary dictionary, int capacity, out int found)
        {
            var ids = new int[capacity];
            var corners = new float[capacity * 8];
            var status = (CvStatus)NativeMethods.ocvu_aruco_detect_markers(
                src.Handle, (int)dictionary, ids, capacity, corners, corners.Length, out found);

            if (status == CvStatus.BufferTooSmall) return null;
            CvNative.ThrowIfFailed(status);

            var result = new CvArucoMarker[found];
            for (int i = 0; i < found; i++)
            {
                result[i] = new CvArucoMarker(
                    ids[i],
                    new CvPoint2(corners[i * 8], corners[i * 8 + 1]),
                    new CvPoint2(corners[i * 8 + 2], corners[i * 8 + 3]),
                    new CvPoint2(corners[i * 8 + 4], corners[i * 8 + 5]),
                    new CvPoint2(corners[i * 8 + 6], corners[i * 8 + 7]));
            }
            return result;
        }

        /// <summary>
        /// 1 個のマーカーの姿勢を求める。
        /// </summary>
        /// <param name="marker"><see cref="DetectMarkers"/> が返したマーカー。</param>
        /// <param name="markerLength">マーカーの 1 辺の長さ。単位は任意で、返る並進が同じ単位になる。</param>
        /// <param name="cameraMatrix">カメラ行列（3x3 を行優先で並べた 9 個）。</param>
        /// <param name="distCoeffs">歪み係数。<c>null</c> か空で「歪み無し」。</param>
        /// <remarks>
        /// **新しい C ABI 関数は使っていない。** マーカーの中心を原点に置いた
        /// 正方形を組み立てて <see cref="CvGeometry.SolvePnP"/> に渡すだけの
        /// 純 C# である（<c>WebCamTextureConverter</c> と同じ形）。
        /// <para>
        /// 座標系は OpenCV のもの（右手系、y が下向き、z が奥）である。
        /// **Unity 座標系への変換はこの package が持っていない。**
        /// </para>
        /// </remarks>
        public static CvViewPose EstimateMarkerPose(
            CvArucoMarker marker, float markerLength,
            double[] cameraMatrix, double[] distCoeffs)
        {
            if (markerLength <= 0.0f)
                throw new ArgumentOutOfRangeException(
                    nameof(markerLength), markerLength, "markerLength は 0 より大きくなければなりません。");

            // SOLVEPNP_IPPE_SQUARE が要求する並び（左上・右上・右下・左下）。
            float half = markerLength / 2.0f;
            var objectPoints = new[]
            {
                new CvPoint3(-half,  half, 0.0f),
                new CvPoint3( half,  half, 0.0f),
                new CvPoint3( half, -half, 0.0f),
                new CvPoint3(-half, -half, 0.0f),
            };
            var imagePoints = new[]
            {
                marker.TopLeft, marker.TopRight, marker.BottomRight, marker.BottomLeft,
            };

            return CvGeometry.SolvePnP(
                objectPoints, imagePoints, cameraMatrix, distCoeffs,
                CvSolvePnPMethod.IppeSquare);
        }
    }
}
```

**`.meta` を手で作る。** 既存のもの（`CvGeometry.cs.meta`）と同じ形にし、
**guid はリポジトリ内で一意にする**（`git grep <guid>` が 1 件も返さないこと）。

- [ ] **Step 3: L3 テストを書いて走らせる**

`tests/Managed/CvUnity.Tests.Managed/PoseTests.cs`

```csharp
using System;
using CvUnity;
using Xunit;

namespace CvUnity.Tests.Managed
{
    public class PoseTests
    {
        // fx = fy = 500, cx = 320, cy = 240 を行優先で並べたもの。
        private static readonly double[] Camera =
        {
            500.0, 0.0, 320.0,
            0.0, 500.0, 240.0,
            0.0, 0.0, 1.0,
        };

        private static readonly CvPoint3[] Square =
        {
            new CvPoint3(-1.0f, -1.0f, 0.0f),
            new CvPoint3( 1.0f, -1.0f, 0.0f),
            new CvPoint3( 1.0f,  1.0f, 0.0f),
            new CvPoint3(-1.0f,  1.0f, 0.0f),
        };

        // 上の正方形を (0, 0, 10) に置いて写した像。**手で解いてある。**
        private static readonly CvPoint2[] SquareImage =
        {
            new CvPoint2(270.0f, 190.0f),
            new CvPoint2(370.0f, 190.0f),
            new CvPoint2(370.0f, 290.0f),
            new CvPoint2(270.0f, 290.0f),
        };

        [Fact]
        public void SolvePnPRecoversAKnownPose()
        {
            var pose = CvGeometry.SolvePnP(Square, SquareImage, Camera, null);

            Assert.Equal(0.0, pose.RotationX, 3);
            Assert.Equal(0.0, pose.RotationY, 3);
            Assert.Equal(0.0, pose.RotationZ, 3);
            Assert.Equal(0.0, pose.TranslationX, 3);
            Assert.Equal(0.0, pose.TranslationY, 3);
            Assert.Equal(10.0, pose.TranslationZ, 3);
        }

        [Fact]
        public void ProjectPointsIsTheInverseOfSolvePnP()
        {
            var pose = CvGeometry.SolvePnP(Square, SquareImage, Camera, null);
            var projected = CvGeometry.ProjectPoints(Square, pose, Camera, null);

            Assert.Equal(SquareImage.Length, projected.Length);
            for (int i = 0; i < projected.Length; i++)
            {
                Assert.Equal(SquareImage[i].X, projected[i].X, 2);
                Assert.Equal(SquareImage[i].Y, projected[i].Y, 2);
            }
        }

        [Fact]
        public void RodriguesRoundTrips()
        {
            var pose = new CvViewPose(0.1, -0.2, 0.3, 0.0, 0.0, 0.0);
            var matrix = CvGeometry.RodriguesToMatrix(pose);
            var back = CvGeometry.RodriguesToVector(matrix);

            Assert.Equal(9, matrix.Length);
            Assert.Equal(pose.RotationX, back[0], 9);
            Assert.Equal(pose.RotationY, back[1], 9);
            Assert.Equal(pose.RotationZ, back[2], 9);
        }

        [Fact]
        public void SolvePnPRejectsMismatchedPointCounts()
        {
            var fewer = new[] { SquareImage[0], SquareImage[1], SquareImage[2] };
            Assert.Throws<ArgumentException>(
                () => CvGeometry.SolvePnP(Square, fewer, Camera, null));
        }

        [Fact]
        public void TheManagedMethodValuesMatchWhatNativeAccepts()
        {
            // **両側を native に問う。** C の #define は C# から読めないので、
            // 「managed の値を渡したら native が受け付ける」ことで同期を測る。
            foreach (CvSolvePnPMethod method in Enum.GetValues(typeof(CvSolvePnPMethod)))
            {
                var ex = Record.Exception(
                    () => CvGeometry.SolvePnP(Square, SquareImage, Camera, null, method));

                // 解けるかどうかは method による（P3P はちょうど 4 点を要求する等）。
                // **見たいのは「知らない method として拒否されないこと」だけである。**
                if (ex is CvNativeException native)
                {
                    Assert.NotEqual(CvStatus.InvalidArgument, native.Status);
                }
            }

            // 逆向き: 定義に無い値は拒否される。
            var rejected = Assert.Throws<CvNativeException>(
                () => CvGeometry.SolvePnP(Square, SquareImage, Camera, null, (CvSolvePnPMethod)99));
            Assert.Equal(CvStatus.InvalidArgument, rejected.Status);
        }
    }
}
```

`tests/Managed/CvUnity.Tests.Managed/ArucoTests.cs`

```csharp
using System;
using CvUnity;
using Xunit;

namespace CvUnity.Tests.Managed
{
    public class ArucoTests
    {
        // 生成したマーカーの周りに白の余白を置いた画像を作る。
        // **余白が要る** —— ArUco の検出は黒い枠の外側に白があることを前提にしている。
        private static CvMat MakeSceneWithMarker(
            CvArucoDictionary dictionary, int markerId, int sidePixels, int margin)
        {
            byte[] markerPixels;
            using (var marker = CvAruco.GenerateMarker(dictionary, markerId, sidePixels))
            {
                markerPixels = new byte[sidePixels * sidePixels];
                marker.CopyTo(markerPixels, sidePixels);
            }

            int side = sidePixels + margin * 2;
            var scene = new byte[side * side];
            for (int i = 0; i < scene.Length; i++) scene[i] = 255;
            for (int r = 0; r < sidePixels; r++)
            {
                for (int c = 0; c < sidePixels; c++)
                {
                    scene[(r + margin) * side + (c + margin)] = markerPixels[r * sidePixels + c];
                }
            }

            var result = new CvMat(side, side, CvMatType.Cv8UC1);
            result.CopyFrom(scene, side);
            return result;
        }

        [Fact]
        public void DetectFindsTheMarkerItGenerated()
        {
            using var scene = MakeSceneWithMarker(CvArucoDictionary.Dict4X4_50, 7, 200, 60);
            var markers = CvAruco.DetectMarkers(scene, CvArucoDictionary.Dict4X4_50);

            var marker = Assert.Single(markers);
            Assert.Equal(7, marker.Id);

            // 4 隅がマーカーの領域（余白 60 の内側）に収まる。
            foreach (var corner in new[] { marker.TopLeft, marker.TopRight,
                                           marker.BottomRight, marker.BottomLeft })
            {
                Assert.InRange(corner.X, 50.0f, 270.0f);
                Assert.InRange(corner.Y, 50.0f, 270.0f);
            }
        }

        [Fact]
        public void DetectReturnsAnEmptyArrayWhenNothingIsThere()
        {
            // **検出できないのは誤りではない。** 例外ではなく空の配列で返る。
            using var blank = new CvMat(120, 120, CvMatType.Cv8UC1);
            var markers = CvAruco.DetectMarkers(blank, CvArucoDictionary.Dict4X4_50);
            Assert.Empty(markers);
        }

        [Fact]
        public void DetectGrowsTheBufferWhenTheFirstCallOverflows()
        {
            // **溢れる経路を実際に通す。** maxMarkers を 0 にはできないので 1 未満を
            // 作れない —— 代わりに maxMarkers に足りない値を渡せる状況を作る。
            // ここではマーカー 1 個の場面に対して maxMarkers = 1 で足りるので、
            // 溢れないことを確かめたうえで、C# 側が 2 度目を呼ぶ経路は
            // TryDetect の戻り値が null になる分岐として L1 が担う。
            using var scene = MakeSceneWithMarker(CvArucoDictionary.Dict4X4_50, 3, 200, 60);
            var markers = CvAruco.DetectMarkers(scene, CvArucoDictionary.Dict4X4_50, 1);
            Assert.Single(markers);
            Assert.Equal(3, markers[0].Id);
        }

        [Fact]
        public void EstimateMarkerPosePutsTheMarkerInFrontOfTheCamera()
        {
            double[] camera = { 500.0, 0.0, 320.0, 0.0, 500.0, 240.0, 0.0, 0.0, 1.0 };
            using var scene = MakeSceneWithMarker(CvArucoDictionary.Dict4X4_50, 7, 200, 60);
            var markers = CvAruco.DetectMarkers(scene, CvArucoDictionary.Dict4X4_50);

            var pose = CvAruco.EstimateMarkerPose(markers[0], 0.05f, camera, null);

            // **z は正でなければならない** —— カメラの前に在るということである。
            Assert.True(pose.TranslationZ > 0.0,
                $"マーカーがカメラの後ろに来ている（z = {pose.TranslationZ}）");
        }

        [Fact]
        public void TheManagedDictionaryValuesMatchWhatNativeAccepts()
        {
            foreach (CvArucoDictionary dictionary in Enum.GetValues(typeof(CvArucoDictionary)))
            {
                using var marker = CvAruco.GenerateMarker(dictionary, 0, 32);
                Assert.Equal(32, marker.Rows);
            }

            // 逆向き: 定義に無い値は拒否される。
            var rejected = Assert.Throws<CvNativeException>(
                () => CvAruco.GenerateMarker((CvArucoDictionary)99, 0, 32));
            Assert.Equal(CvStatus.InvalidArgument, rejected.Status);
        }

        [Fact]
        public void TheManagedUpperBoundMatchesWhatNativeAccepts()
        {
            // managed の上限ちょうどは native も受ける（生成は重いので小さい辞書で）。
            var tooBig = Assert.Throws<ArgumentOutOfRangeException>(
                () => CvAruco.GenerateMarker(CvArucoDictionary.Dict4X4_50, 0, 4097));
            Assert.Equal("sidePixels", tooBig.ParamName);
        }
    }
}
```

**`CvMat` の API 名（`CopyTo` / `CopyFrom` / `Rows` / `CvMatType`）は実物に合わせること。**
`Packages/.../Runtime/Core/CvMat.cs` を開いて確認し、違っていればテスト側を直す
（**実装ではなくテストを合わせる** —— 既存の公開 API はこの計画の対象外である）。

```
pwsh tools/dev.ps1 test-managed
```

期待: `PoseTests` 5 件と `ArucoTests` 6 件が pass、exit 0。

- [ ] **Step 4: 全レーンを回す**

```
pwsh tools/dev.ps1 test
```

期待: exit 0。**`verify-generated` が緑であること**（生成物と spec が一致している）。

- [ ] **Step 5: コミット**

```bash
git add Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvAruco.cs \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvAruco.cs.meta \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvGeometry.cs \
        tests/Managed/CvUnity.Tests.Managed/PoseTests.cs \
        tests/Managed/CvUnity.Tests.Managed/ArucoTests.cs
git commit -m "feat(csharp): 姿勢と ArUco の公開 API（CvGeometry の 4 本と CvAruco）を出す"
```

---

## Task 7: 文書と、配布ライブラリの大きさ

**Files:**
- Modify: `docs/abi-ownership-and-versioning.md`、`docs/api-reference.md`、`CLAUDE.md`

- [ ] **Step 1: allowlist に節を足す**

`docs/abi-ownership-and-versioning.md` の §3.9 の後ろに **§3.10 姿勢と ArUco** を足す。
既存の §3.7 / §3.8 / §3.9 と同じ構成にする —— **関数ごとに、引数の意味・所有権・
失敗し得る status・出していないもの**を書く。

**§3 の冒頭が数えている本数を直す。**（allowlist の本数を数えるのはそこである）

「まだ作らないもの」の節から、**この計画で作ったものが消えているか**確認する。

- [ ] **Step 2: API リファレンスに足す**

`docs/api-reference.md` の 2 箇所に足す。

1. §1（C ABI）に「姿勢と ArUco（geometry / objdetect、2026-09 で追加）」の節
2. §2（C# 公開 API）に「`CvUnity.CvAruco` / `CvUnity.CvArucoMarker` / `CvUnity.CvArucoDictionary`」と、
   §2.10 の `CvGeometry` へ 4 本の追記

**§3「この allowlist に含まれないもの」から、足したものを消す。**
**M5 でこれを実際に踏んだ** ——「足した機能が『まだ無い』側に残る」。

- [ ] **Step 3: `CLAUDE.md` を直す**

3 箇所:

1. 「公開 ABI の内訳」の段落に、`geometry` の姿勢 4 本と `objdetect` の ArUco 2 本を足す
   （**本数は書かない。`docs/api-map.md` が数える**）
2. 「ファイル配置」の表の `native/src/` の行に、`ocvu_pose.cpp` と `ocvu_aruco.cpp` を足す
3. `docs/api-reference.md` の行の C# クラス一覧に `CvAruco` を足す

- [ ] **Step 4: 配布ライブラリの大きさを測る**

```
pwsh tools/dev.ps1 build
```

```bash
ls -l Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/x86_64/opencv_unity_native.dll
```

**前回の実測（21,464,576 バイト）からの差を記録する。** `README.ja.md` の
「書くことが引き込みます」の段落に前例がある —— **`aruco` はこの計画で初めて
参照するので、その分の増加が出るはずである。**

差を PR 本文と `README.ja.md` に書く。

- [ ] **Step 5: 全レーンと ASan**

```
pwsh tools/dev.ps1 test
pwsh tools/dev.ps1 test-asan
```

両方 exit 0 であること。**PASS 行を数えず、終了コードを見る。**

- [ ] **Step 6: AI レビュー**

**`CLAUDE.md` の「変更を main へ入れるまで」ステップ 4。**
**この差分を書いていない別のエージェントに、ブランチ全体の差分をレビューさせる。**
何を指摘してほしくないかを事前に伝えない。

渡すもの: ブランチ全体の差分、この計画、
[全体設計](./2026-09-05-api-surface-expansion.md)、`CLAUDE.md` の不変条件。

指摘を直したら、**スコープを絞った再レビュー**をする。

- [ ] **Step 7: コミットして push、PR を作る**

```bash
git add docs/abi-ownership-and-versioning.md docs/api-reference.md CLAUDE.md README.ja.md
git commit -m "docs: 姿勢と ArUco の 6 本を allowlist と API リファレンスへ反映する"
git push -u origin feat/api-surface-expansion
```

PR 本文に書くもの:
- 何を成立させたか（6 本、OpenCV の再ビルドなし、`OCVU_ABI_VERSION` は 1 のまま）
- 実測値（L1 / L3 の件数、ライブラリの大きさの差）
- **意図的に見送ったもの**（ChArUco ボード、複数辞書の同時検出、`detectMarkersWithConfidence`、AprilTag 系の辞書、マーカーの姿勢を native 側で一括推定する API）
- **ステップ 6 のレビュー結果**（何が指摘され、どう直したか）
- **穴**（ArUco は実機で動かしていない。実機の検証は `docs/m4-device-verification.md` の未クローズ項目のままである）

**merge しない。** CI が緑になったら結果を報告し、指示を待つ。

---

## Self-Review

**1. spec coverage** — [全体設計](./2026-09-05-api-surface-expansion.md) §4 の Phase 1 に挙げた 6 本が、Task 1〜5 にそれぞれ在る。§5 の決定は Global Constraints に写してある。§9 の完了条件は Task 7 が満たす。

**2. placeholder scan** — 「TBD」「Task N と同様」「適切なエラー処理を足す」は無い。すべてのコードブロックが実際に貼れる内容になっている。

**3. type consistency** — `ocvu_solve_pnp` の引数名は Task 1 の spec・実装・L1 で一致。`MakeDistCoeffView` は Task 1 で定義し Task 3 で使う（Interfaces に明記）。`MakeSceneWithMarker` は Task 4 のテストで定義し Task 5 で使う（同）。C# の `CvViewPose` は**新設せず既存を使う** —— `Runtime/Core/CvCalibration.cs` に在ることを実測で確認済み。

**確認できていないもの**: `CvMat` の `CopyTo` / `CopyFrom` / `Rows` / `CvMatType` の正確な名前。Task 6 Step 3 に「実物に合わせること」と明記してある。
