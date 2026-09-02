# M5 条件 2 の最後 — カメラの歪み補正

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** カメラの歪みを補正する経路を C ABI に出し、M5 完了条件 2 を閉じる。

**Architecture:** **調査の結果、`calib` module は要らないことが分かった**（下記「この計画の
前提が調査で変わった」）。`undistort` は `imgproc`、`findChessboardCorners` は `objdetect` に
あり、**どちらも既にリンク済みで今すぐ呼べる**（実測）。したがって構成ハッシュは変わらず、
5 platform 分の OpenCV を作り直す必要も無い。

**Tech Stack:** C++17 / OpenCV 5.0.0（static）/ CMake 3.25+ / .NET 8（generator と L3）/
netstandard2.1（Unity 側 Runtime）/ PowerShell 7（レーンの入口）

**Spec:** [`docs/roadmap.md`](../../roadmap.md) の M5 節、完了条件 2
（「`geometry` / `calib` / `features` / `objdetect` などを**利用例に基づいて**追加する」）。
**`objdetect` / `features` / `geometry` は出し済みで、残るのは `calib` の担当分だけである。**

**関連する正本:**
- `.claude/skills/add-abi-function/SKILL.md` — ABI を 1 本足す手順の正本。**全タスクがこれに従う**
- `.claude/skills/prove-a-check-works/SKILL.md` — 検査を足す・変えるときの規律
- [`docs/abi-ownership-and-versioning.md`](../../abi-ownership-and-versioning.md) — 所有権・versioning・allowlist の正本

---

## この計画の前提が調査で変わった（着手前に必ず読む）

**当初は「`calib` を `Modules` に足して 5 platform 分の OpenCV を作り直す」計画だった。**
2026-09-01 に実測して、その前提が 2 つとも崩れた。

### 1. `calib` module は要らない

歪み補正に要る関数は、**既にリンック済みの module に在る**:

| 関数 | 在る module | リンク済みか |
| --- | --- | --- |
| `cv::undistort` | **`imgproc`** | **済み** |
| `cv::initUndistortRectifyMap` | **`imgproc`** | **済み** |
| `cv::undistortPoints` | **`geometry`** | **済み**（M5 で足した） |
| `cv::findChessboardCorners` | **`objdetect`** | **済み** |
| `cv::calibrateCamera` | `calib` | **無い** |

**実測（`ocvu_static` にリンクした probe をビルドして実行した）:**

```
undistort OK rows=32
findChessboardCorners OK found=0
```

**`Modules` にも `COMPONENTS` にも 1 文字も足さずに通った。**

### 2. 「`calib` を足すと `a197bbcbdaf5`」は誤りだった

roadmap と `CLAUDE.md` が書いていたその値は、**`geometry` を足したときのもの**である。
測り直した実測値は次のとおり（`eef12fd` で訂正済み）:

```
現在              4785d98e9aad
geometry を足すと a197bbcbdaf5   ← 以前 calib の値として書かれていた
calib を足すと    09fcbe260d87   ← 正しい値
```

### したがってこの計画は `calib` を足さない

**残るのは `calibrateCamera`（較正して係数を求める側）だけ**で、それは:

- **入力がチェスボードの撮影画像 N 枚**という重い形で、1 回の ABI 呼び出しに乗らない
- **利用例が要る** —— 較正はアプリの初回起動時に 1 度やるのか、開発時に済ませて係数を
  焼き込むのかで、出す API がまるで違う
- **足すと 5 platform 分の再ビルドが要る**（上記）

**この計画では出さない。** 条件 2 に対する判定は下の「完了条件への影響」を参照。

---

## Global Constraints

spec と `CLAUDE.md` から、値をそのまま写したもの。**各タスクの要件はこの節を暗黙に含む。**

- **C ABI が唯一の native contract。** `cv::Mat*` や STL 型を境界の外へ出さない。opaque handle と固定サイズ型（`int32_t`、`int64_t`、`double`、明示 struct）のみ。
- **例外を ABI の外へ出さない。** 公開関数の本体は `OCVU_TRY_BEGIN` / `OCVU_TRY_END` で囲む。**`cv::Exception` は個別に受ける** —— `OCVU_TRY_END` は `std::exception` を `OCVU_STATUS_UNKNOWN_ERROR` にするので、そこへ落とすと OpenCV 由来の失敗が「原因不明」になる（M5 で 1 度踏んだ）。
- **`extern "C" ocvu_status ocvu_名前(` までを 1 物理行に置く。** `.claude/hooks/check-exception-barrier.sh` の awk がこの形で関数を認識する。
- **借用 handle を作らない。** Unity 所有のメモリを指す handle を返さない。
- **buffer 引数の長さは必ず検証する（呼ぶ側を信用しない）。** **単位はバイト**で統一されている（`ocvu_mat_copy_from_buffer` / `ocvu_imdecode` / `ocvu_find_homography`）。**要素数にしない** —— 既存に慣れた呼び手が 4 倍の値を渡して検査を通過する方向に倒れる。
- **失敗したときは出力を書き換えない。**
- **`Runtime/Interop` と `Runtime/Core` は `UnityEngine` を参照してはならない。** 参照した瞬間に netstandard2.1 shim のビルドが落ち、L3 レーンが失われる。
- **宣言を手で書かない。** spec に書いて `./tools/dev.ps1 generate` を実行する。**唯一の例外**は `native/include/opencv_unity_native.h` の `#include "ocvu/<module>.h"` の行で、**M5 でそこに検査を置いた**（`tools/tests/BindingGenerator.Tests.ps1`）。
- **生成物も一緒にコミットする**（`.meta` を含む）。
- **`git add -A` / `git add .` は hook が拒否する。**
- **`dev.ps1` のレーンは相互排他。** 2 つ同時に走らせない。
- **`test-tools-slow` をローカルで叩かない。** OpenCV のツリーが消える事故が実際に起きた。
- **本数を数えるのは `docs/api-map.md` の冒頭だけ。**
- **`OCVU_ABI_VERSION` は上げない。** 新しい関数を足すのは bump しない変更である。
- **`tools/opencv-config.psd1` の `Modules` は触らない。** 構成ハッシュが変わり、5 platform 分の OpenCV を作り直すことになる。

---

## スコープ

### 含むもの

**C ABI 2 本**（`docs/api-map.md` の本数は 24 → 26 になる）:

| 関数 | 何をするか |
| --- | --- |
| `ocvu_undistort` | 歪んだ画像を、カメラ行列と歪み係数で補正する |
| `ocvu_find_chessboard_corners` | チェスボードの格子点を見つける（較正の入力を作る側） |

**module は新設しない。** `undistort` は `imgproc`、`findChessboardCorners` は `objdetect` に
在るので、**既存の `bindings/spec/imgproc.json` と `objdetect.json` に足す。**

### 含まないもの（非ゴール）

- **`cv::calibrateCamera`。** `calib` module が要り、構成ハッシュが変わる（上記）。
  加えて**利用例が決まっていない** —— 較正をいつ誰がやるかで API の形が変わる。
- **`initUndistortRectifyMap` / `remap` による高速経路。** 毎フレーム補正するなら
  map を 1 度作って使い回すほうが速いが、**map を保持する新しい handle 型**が要る。
  `docs/abi-ownership-and-versioning.md` §1 の所有権は「native 所有の handle」と
  「呼び出しの内側で完結する借用」の 2 種類だけなので、**そこを増やす判断が別に要る。**
- **`undistortPoints`**（点だけを補正する）。`geometry` に在ってリンク済みだが、
  画像の補正が先である。
- **チェスボード以外のパターン**（円グリッド、ChArUco）。

---

## File Structure

### 新規作成

| ファイル | 責務 |
| --- | --- |
| `native/src/ocvu_calibration.cpp` | 2 本の実装。**`imgproc` と `objdetect` にまたがるので、module 名ではなく用途で 1 ファイルにまとめる** |
| `native/tests/test_calibration.cpp` | L1（往復・失敗経路・境界） |
| `Packages/.../Runtime/Core/CvCalibration.cs`（+ `.meta`） | C# 公開 API |
| `tests/Managed/CvUnity.Tests.Managed/CalibrationTests.cs` | L3 |

### 変更

| ファイル | 変更内容 |
| --- | --- |
| `bindings/spec/imgproc.json` | `ocvu_undistort` の 1 entry |
| `bindings/spec/objdetect.json` | `ocvu_find_chessboard_corners` の 1 entry |
| `native/CMakeLists.txt` | `OCVU_SOURCES` に `.cpp` 1 本 |
| `native/tests/CMakeLists.txt` | `ocvu_tests` に `.cpp` 1 本 |
| `docs/abi-ownership-and-versioning.md` | §3 allowlist に 2 本（15 → 17） |
| `docs/api-reference.md` | C ABI と `CvCalibration` |
| `docs/roadmap.md` | M5 条件 2 の判定 |
| `CLAUDE.md` | 現状・ファイル配置・本数 |

### 生成物（`dev.ps1 generate` が書く。手で編集しない）

`native/include/ocvu/imgproc.h` / `objdetect.h` / `NativeMethods.Imgproc.g.cs` /
`NativeMethods.Objdetect.g.cs` / `AbiReachabilityChecks.g.cs` / `docs/api-map.md`。
**新しいファイルは増えない**（module を新設しないため）ので、生成物は **16 のまま**である。

---

## Task 1: 歪み補正と較正パターンがリンク済みであることを実証する

**Files:**
- Modify: `native/tests/test_module_linkage.cpp`

**Interfaces:**
- Consumes: なし（最初のタスク）
- Produces: `cv::undistort` と `cv::findChessboardCorners` が呼べる状態が**テストで固定される**

**なぜ最初か:** この計画の前提そのものだからである。**「既にリンク済み」は調査で実測したが、
それを固定するテストが無い。** 上流が module を再編したら（OpenCV 5 は 4.x から実際に
再編した）、この前提は黙って崩れる。

- [ ] **Step 1: テストを足す**

`native/tests/test_module_linkage.cpp` に追記（先頭の `#include` に
`#include <opencv2/objdetect.hpp>` は既にある。`imgproc` を足す）:

```cpp
TEST(ModuleLinkage, UndistortionSymbolsResolveWithoutCalib) {
    // **この計画の前提を固定する。** カメラの歪み補正に要る関数は
    // calib module ではなく imgproc と objdetect に在り、どちらも
    // 既にリンク済みである（2026-09-01 実測）。
    //
    // **上流が module を再編したら、この前提は黙って崩れる** ——
    // OpenCV 5 は 4.x の calib3d を geometry / calib / stereo / ptcloud へ
    // 実際に割った。次に同じことが起きたとき、ここが最初に赤くなる。
    const cv::Mat src = cv::Mat::zeros(32, 32, CV_8UC1);
    const cv::Mat camera = (cv::Mat_<double>(3, 3) << 100, 0, 16, 0, 100, 16, 0, 0, 1);
    const cv::Mat coeffs = (cv::Mat_<double>(1, 5) << 0.1, -0.05, 0, 0, 0);

    cv::Mat dst;
    cv::undistort(src, dst, camera, coeffs);
    EXPECT_EQ(dst.rows, 32);
    EXPECT_EQ(dst.cols, 32);

    // 真っ黒な画像に格子は写っていないので false が返る。
    // ここで見たいのはリンクなので、結果ではなく「呼べた」ことを確かめる。
    std::vector<cv::Point2f> corners;
    const bool found = cv::findChessboardCorners(src, cv::Size(7, 7), corners);
    EXPECT_FALSE(found);
}
```

- [ ] **Step 2: 走らせて緑を確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: PASS。**RED にはならない** —— 既にリンク済みだからである
（M5 の `geometry` でも同じことが起きた。**それが分かっていることを確かめるテスト**である）。
GoogleTest の総数が 1 増える。

- [ ] **Step 3: 前提が本物か、壊して確かめる（prove-a-check-works）**

`cmake/FindOpenCvUnityDeps.cmake` の `COMPONENTS` から **`imgproc` を一時的に外し**、
このテストがリンクエラーで落ちることを見る。確認したら手で戻す。
**`git checkout --` は使わないこと**（他の未コミットの変更ごと消える）。

**落ちなければ、このテストは何も見ていない。**

- [ ] **Step 4: コミット**

```bash
git add native/tests/test_module_linkage.cpp
git commit -m "test(m5): 歪み補正が calib 無しでリンク済みであることを固定する"
```

---

## Task 2: `ocvu_undistort` — 歪んだ画像を補正する

**Files:**
- Modify: `bindings/spec/imgproc.json`
- Create: `native/src/ocvu_calibration.cpp`
- Create: `native/tests/test_calibration.cpp`
- Modify: `native/CMakeLists.txt`、`native/tests/CMakeLists.txt`

**Interfaces:**
- Consumes: Task 1 のリンク
- Produces: `ocvu_status ocvu_undistort(ocvu_mat_handle src, const double* camera_matrix, int64_t camera_matrix_length, const double* dist_coeffs, int64_t dist_coeffs_length, ocvu_mat_handle dst)`

**形の根拠:** カメラ行列は 3x3 の 9 要素、歪み係数は 4 / 5 / 8 / 12 / 14 要素の
いずれか（OpenCV が受け付ける長さ）。**どちらも小さい固定長なので、handle ではなく
借用で渡す** —— `docs/abi-ownership-and-versioning.md` §1 の「呼び出しの内側で完結する
借用」である。**長さはバイトで受け取る**（この ABI の統一）。

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_calibration.cpp` を新規作成:

```cpp
// カメラの歪み補正の契約テスト。
//
// **calib module は使っていない。** undistort は imgproc、
// findChessboardCorners は objdetect に在り、どちらも既にリンク済みである
// （native/tests/test_module_linkage.cpp がその前提を固定している）。

#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <cstring>
#include <vector>

namespace {

class ScopedMat {
public:
    explicit ScopedMat(int rows = 1, int cols = 1) {
        EXPECT_EQ(ocvu_mat_create(rows, cols, OCVU_MAT_TYPE_8UC1, &handle_), OCVU_STATUS_OK);
    }
    ~ScopedMat() { ocvu_mat_release(handle_); }
    ScopedMat(const ScopedMat&) = delete;
    ScopedMat& operator=(const ScopedMat&) = delete;

    ocvu_mat_handle get() const { return handle_; }

private:
    ocvu_mat_handle handle_ = OCVU_MAT_HANDLE_NONE;
};

// 焦点距離 100、中心 (16, 16) の 3x3 カメラ行列（行優先）。
const std::vector<double> kCamera{100, 0, 16, 0, 100, 16, 0, 0, 1};

// 樽型の歪みを持つ 5 要素の係数。
const std::vector<double> kCoeffs{0.1, -0.05, 0, 0, 0};

constexpr int64_t kCameraBytes = 9 * static_cast<int64_t>(sizeof(double));
constexpr int64_t kCoeffsBytes = 5 * static_cast<int64_t>(sizeof(double));

}  // namespace

TEST(Calibration, UndistortProducesAnImageOfTheSameShape) {
    ScopedMat src(32, 32);
    ScopedMat dst;

    ASSERT_EQ(ocvu_undistort(src.get(), kCamera.data(), kCameraBytes,
                             kCoeffs.data(), kCoeffsBytes, dst.get()),
              OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 32);
    EXPECT_EQ(info.cols, 32);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_8UC1);
}

TEST(Calibration, UndistortRejectsInvalidArguments) {
    ScopedMat src(32, 32);
    ScopedMat dst;

    EXPECT_EQ(ocvu_undistort(src.get(), nullptr, kCameraBytes,
                             kCoeffs.data(), kCoeffsBytes, dst.get()),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_undistort(src.get(), kCamera.data(), kCameraBytes,
                             nullptr, kCoeffsBytes, dst.get()),
              OCVU_STATUS_NULL_POINTER);

    // **カメラ行列はちょうど 9 要素（72 バイト）でなければならない。**
    // 足りなければ終端を越えて読み、多ければ呼ぶ側の意図と食い違う。
    EXPECT_EQ(ocvu_undistort(src.get(), kCamera.data(), kCameraBytes - 1,
                             kCoeffs.data(), kCoeffsBytes, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_undistort(src.get(), kCamera.data(), kCameraBytes + 8,
                             kCoeffs.data(), kCoeffsBytes, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);

    // **歪み係数は OpenCV が受ける長さだけを通す**（4 / 5 / 8 / 12 / 14）。
    // 3 要素は受け付けない。
    EXPECT_EQ(ocvu_undistort(src.get(), kCamera.data(), kCameraBytes,
                             kCoeffs.data(), 3 * static_cast<int64_t>(sizeof(double)), dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);

    EXPECT_EQ(ocvu_undistort(OCVU_MAT_HANDLE_NONE, kCamera.data(), kCameraBytes,
                             kCoeffs.data(), kCoeffsBytes, dst.get()),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_undistort(src.get(), kCamera.data(), kCameraBytes,
                             kCoeffs.data(), kCoeffsBytes, OCVU_MAT_HANDLE_NONE),
              OCVU_STATUS_INVALID_HANDLE);
}

TEST(Calibration, UndistortAcceptsEveryCoefficientCountOpenCvTakes) {
    // **OpenCV が受ける長さを、こちらも全部受ける。** 4 / 5 / 8 / 12 / 14 で、
    // どれか 1 つでも落とすと、その係数を持つ利用者だけが使えなくなる。
    ScopedMat src(32, 32);
    ScopedMat dst;

    for (const int n : {4, 5, 8, 12, 14}) {
        const std::vector<double> coeffs(static_cast<size_t>(n), 0.01);
        EXPECT_EQ(ocvu_undistort(src.get(), kCamera.data(), kCameraBytes, coeffs.data(),
                                 n * static_cast<int64_t>(sizeof(double)), dst.get()),
                  OCVU_STATUS_OK)
            << "係数 " << n << " 個が拒否された";
    }
}

TEST(Calibration, UndistortLeavesTheDestinationUntouchedWhenItFails) {
    ScopedMat src(32, 32);
    ScopedMat dst;

    ASSERT_EQ(ocvu_undistort(src.get(), kCamera.data(), kCameraBytes,
                             kCoeffs.data(), kCoeffsBytes, dst.get()),
              OCVU_STATUS_OK);
    ocvu_mat_info before{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &before), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_undistort(src.get(), nullptr, kCameraBytes,
                             kCoeffs.data(), kCoeffsBytes, dst.get()),
              OCVU_STATUS_NULL_POINTER);

    ocvu_mat_info after{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &after), OCVU_STATUS_OK);
    EXPECT_EQ(before.rows, after.rows);
    EXPECT_EQ(before.cols, after.cols);
    EXPECT_EQ(before.type, after.type);
}

TEST(Calibration, UndistortWithZeroCoefficientsIsNearlyIdentity) {
    // 歪みが無いなら、補正しても中身はほぼ変わらない。
    // **「呼べた」だけでなく「正しく計算した」ことを見る唯一のテストである。**
    ScopedMat src(16, 16);

    std::vector<uint8_t> pixels(16 * 16, 0);
    for (size_t i = 0; i < pixels.size(); ++i) {
        pixels[i] = static_cast<uint8_t>(i % 256);
    }
    ASSERT_EQ(ocvu_mat_copy_from_buffer(src.get(), pixels.data(),
                                        static_cast<int64_t>(pixels.size()), 16),
              OCVU_STATUS_OK);

    const std::vector<double> zero{0, 0, 0, 0, 0};
    ScopedMat dst;
    ASSERT_EQ(ocvu_undistort(src.get(), kCamera.data(), kCameraBytes, zero.data(),
                             5 * static_cast<int64_t>(sizeof(double)), dst.get()),
              OCVU_STATUS_OK);

    std::vector<uint8_t> out(16 * 16, 0);
    ASSERT_EQ(ocvu_mat_copy_to_buffer(dst.get(), out.data(),
                                      static_cast<int64_t>(out.size()), 16),
              OCVU_STATUS_OK);

    // 補間で端が僅かに動くので、中央付近だけを比べる。
    for (int y = 4; y < 12; ++y) {
        for (int x = 4; x < 12; ++x) {
            const size_t i = static_cast<size_t>(y) * 16 + static_cast<size_t>(x);
            EXPECT_NEAR(static_cast<int>(out[i]), static_cast<int>(pixels[i]), 2)
                << "(" << x << ", " << y << ")";
        }
    }
}
```

`native/tests/CMakeLists.txt` の `ocvu_tests` のソース一覧に
`test_calibration.cpp` を足す（既存の `test_geometry.cpp` と同じ書き方）。

- [ ] **Step 2: RED を確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: **コンパイルエラー**（`ocvu_undistort` が宣言されていない）。

- [ ] **Step 3: spec に足して生成する**

`bindings/spec/imgproc.json` の `functions` に追記（**他の entry と同じ 1 行形式**で書く）:

```json
    {
      "name": "ocvu_undistort",
      "summary": "src の歪みを camera_matrix と dist_coeffs で補正して dst に入れる。dst は結果に応じて丸ごと置き換わり、src と同じ形状・型になる。camera_matrix は行優先の 3x3（double 9 個）、dist_coeffs は OpenCV が受ける長さ（4 / 5 / 8 / 12 / 14 個）でなければならない。camera_matrix_length と dist_coeffs_length はどちらもバイト数で、この ABI の length は全部そうである。呼ぶ側を信用せず、長さが合わなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。失敗したときは dst を書き換えない。",
      "returns": "ocvu_status",
      "csReturns": "int",
      "wrapInTryBarrier": true,
      "params": [
        { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
        { "name": "camera_matrix", "cType": "const double*", "csType": "double[]", "direction": "in-buffer" },
        { "name": "camera_matrix_length", "cType": "int64_t", "csType": "long", "direction": "in" },
        { "name": "dist_coeffs", "cType": "const double*", "csType": "double[]", "direction": "in-buffer" },
        { "name": "dist_coeffs_length", "cType": "int64_t", "csType": "long", "direction": "in" },
        { "name": "dst", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" }
      ]
    }
```

**`const double*` は型表にまだ無い。** `bindings/generator/Ocvu.Generator/SpecModel.cs` の
`AllowedCsTypes` に足す（`const float*` の隣）:

```csharp
            ["const double*"] = new[] { "double[]", "System.IntPtr" },
```

**足す前に、それを見るテストを先に書く。**
`bindings/generator/Ocvu.Generator.Tests/SpecSchemaTests.cs` の
`BothSpellingsOfAnArrayParamAreAccepted` に `[InlineData]` を 2 行足す:

```csharp
    [InlineData("const double*", "double[]")]
    [InlineData("const double*", "System.IntPtr")]
```

**先にテストを走らせて 2 件落ちることを見てから**、型表に足して緑にする。

```
pwsh tools/dev.ps1 generate
```

期待: **16 ファイルのまま**（module を新設していないので数は変わらない）。
`native/include/ocvu/imgproc.h` と `NativeMethods.Imgproc.g.cs` が更新される。

- [ ] **Step 4: 実装する**

`native/src/ocvu_calibration.cpp` を新規作成:

```cpp
#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/objdetect.hpp>

#include <cstdint>
#include <vector>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

namespace {

// カメラ行列は 3x3 で固定である。
constexpr int64_t kCameraMatrixBytes = 9 * static_cast<int64_t>(sizeof(double));

// OpenCV が受け付ける歪み係数の個数。**この一覧は OpenCV の都合であって
// こちらの判断ではない** —— 減らすと、その係数を持つ利用者だけが使えなくなる。
bool IsAcceptedCoefficientCount(int64_t count) {
    return count == 4 || count == 5 || count == 8 || count == 12 || count == 14;
}

}  // namespace

extern "C" ocvu_status ocvu_undistort(ocvu_mat_handle src, const double* camera_matrix, int64_t camera_matrix_length, const double* dist_coeffs, int64_t dist_coeffs_length, ocvu_mat_handle dst) {
    OCVU_TRY_BEGIN
    if (camera_matrix == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_undistort: camera_matrix is NULL");
    }
    if (dist_coeffs == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_undistort: dist_coeffs is NULL");
    }

    // **呼ぶ側を信用しない。** 単位はバイトで、この ABI の length は全部そうである。
    // カメラ行列は「足りない」だけでなく「多い」も断る —— 3x3 は固定長なので、
    // 違う長さを渡してきた呼ぶ側は何かを取り違えている。
    if (camera_matrix_length != kCameraMatrixBytes) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_undistort: camera_matrix_length must be exactly 9 doubles");
    }

    if (dist_coeffs_length < 0 ||
        dist_coeffs_length % static_cast<int64_t>(sizeof(double)) != 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_undistort: dist_coeffs_length is not a whole number of doubles");
    }
    const int64_t coeff_count = dist_coeffs_length / static_cast<int64_t>(sizeof(double));
    if (!IsAcceptedCoefficientCount(coeff_count)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_undistort: dist_coeffs must hold 4, 5, 8, 12 or 14 doubles");
    }

    cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_undistort: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_undistort: dst handle is invalid");
    }

    // 借用はこの呼び出しの内側で完結する。cv::Mat で包むだけで所有はしない。
    const cv::Mat camera_view(3, 3, CV_64F, const_cast<double*>(camera_matrix));
    const cv::Mat coeffs_view(1, static_cast<int>(coeff_count), CV_64F,
                              const_cast<double*>(dist_coeffs));

    // **補正してから dst に入れる。** 直接 dst_mat へ書かせると、
    // 失敗したときに dst が途中まで書き換わった状態で残りうる。
    cv::Mat corrected;
    try {
        cv::undistort(*src_mat, corrected, camera_view, coeffs_view);
    } catch (const cv::Exception& e) {
        // OCVU_TRY_END でも捕まるが、そこでは UNKNOWN_ERROR になる。
        // OpenCV 由来だと分かる status を返すためにここで先に受ける。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = corrected;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

`native/CMakeLists.txt` の `OCVU_SOURCES` に `src/ocvu_calibration.cpp` を足す。

- [ ] **Step 5: GREEN を確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: `Calibration.*` の 5 件が PASS。

- [ ] **Step 6: 検査が効くことを確かめる（prove-a-check-works、3 通り）**

それぞれ**一時的に**壊して、狙ったテストだけが落ちることを見る。確認したら手で戻す
（**`git checkout --` は使わないこと**）。

1. `camera_matrix_length != kCameraMatrixBytes` を `camera_matrix_length < 0` に弱める
   → `UndistortRejectsInvalidArguments` が落ちる
2. `IsAcceptedCoefficientCount` を `return true;` にする → 同上が落ちる
3. `*dst_mat = corrected;` を `try` の中へ移す（`corrected` ではなく直接書く形にする）
   → `UndistortLeavesTheDestinationUntouchedWhenItFails` が落ちる**か**を見る。
   **落ちなければ、そのテストは失敗経路を見ていない** —— その場合はテストを直す。

- [ ] **Step 7: ASan を回す**

```
pwsh tools/dev.ps1 test-asan
```

借用した `double` の配列を `cv::Mat` で包むので、境界を踏んでいないことを見る。

- [ ] **Step 8: コミット**

```bash
git add bindings/spec/imgproc.json native/src/ocvu_calibration.cpp native/tests/test_calibration.cpp \
        native/CMakeLists.txt native/tests/CMakeLists.txt \
        native/include/ocvu/imgproc.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Imgproc.g.cs \
        bindings/generator/Ocvu.Generator/SpecModel.cs \
        bindings/generator/Ocvu.Generator.Tests/SpecSchemaTests.cs \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(m5): ocvu_undistort を足す（calib module は使わない）"
```

---

## Task 3: `ocvu_find_chessboard_corners` — 較正パターンを見つける

**Files:**
- Modify: `bindings/spec/objdetect.json`
- Modify: `native/src/ocvu_calibration.cpp`
- Modify: `native/tests/test_calibration.cpp`

**Interfaces:**
- Consumes: Task 1 のリンク、Task 2 の `ocvu_calibration.cpp`
- Produces: `ocvu_status ocvu_find_chessboard_corners(ocvu_mat_handle src, int32_t pattern_cols, int32_t pattern_rows, float* out_corners, int32_t capacity, int32_t* out_count)`

**形の根拠:** 見つかる格子点の数は `pattern_cols * pattern_rows` で**呼ぶ側が事前に
知り得る**ので、`ocvu_orb_detect` と同じ **1 回呼び**にする（2 回呼びにしない）。
出力は x と y が交互に並ぶ `float` の配列で、`ocvu_find_homography` にそのまま渡せる形である。

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_calibration.cpp` に追記:

```cpp
TEST(Calibration, FindChessboardCornersReportsNotFoundOnABlankImage) {
    // 真っ黒な画像に格子は写っていない。**これは誤りではない** ——
    // 入力の形は正しく、見つからなかっただけである
    // （ocvu_qr_decode / ocvu_find_homography と同じ扱い）。
    ScopedMat blank(64, 64);

    std::vector<float> corners(7 * 7 * 2, 0.0f);
    int32_t count = 4321;  // 0 以外で汚す
    EXPECT_EQ(ocvu_find_chessboard_corners(blank.get(), 7, 7, corners.data(),
                                           7 * 7, &count),
              OCVU_STATUS_NOT_FOUND);
    EXPECT_EQ(count, 0) << "見つからなかったときは 0 を書くこと";
}

TEST(Calibration, FindChessboardCornersRejectsInvalidArgumentsAndAlwaysWritesZero) {
    ScopedMat src(64, 64);
    std::vector<float> corners(7 * 7 * 2, 0.0f);

    EXPECT_EQ(ocvu_find_chessboard_corners(src.get(), 7, 7, corners.data(), 49, nullptr),
              OCVU_STATUS_NULL_POINTER);

    // **格子は 2x2 以上でなければならない。** 1 列や 0 列では格子にならない。
    int32_t count = 4321;
    EXPECT_EQ(ocvu_find_chessboard_corners(src.get(), 1, 7, corners.data(), 49, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    count = 4321;
    EXPECT_EQ(ocvu_find_chessboard_corners(src.get(), 7, 0, corners.data(), 49, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    count = 4321;
    EXPECT_EQ(ocvu_find_chessboard_corners(src.get(), 7, 7, nullptr, 49, &count),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(count, 0);

    count = 4321;
    EXPECT_EQ(ocvu_find_chessboard_corners(OCVU_MAT_HANDLE_NONE, 7, 7,
                                           corners.data(), 49, &count),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(count, 0);
}

TEST(Calibration, FindChessboardCornersRejectsATooSmallBufferWithoutWriting) {
    ScopedMat src(64, 64);

    // 7x7 の格子には 49 点分（float 98 個）要る。48 点分しか無いと言われたら断る。
    std::vector<float> corners(7 * 7 * 2, 0.0f);
    std::memset(corners.data(), 0xAB, corners.size() * sizeof(float));

    int32_t count = 999;
    EXPECT_EQ(ocvu_find_chessboard_corners(src.get(), 7, 7, corners.data(), 48, &count),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(count, 49) << "必要量を返すこと";

    const auto* bytes = reinterpret_cast<const uint8_t*>(corners.data());
    for (size_t i = 0; i < corners.size() * sizeof(float); ++i) {
        ASSERT_EQ(bytes[i], 0xAB) << "足りない buffer には何も書かないこと";
    }
}

TEST(Calibration, FindChessboardCornersFindsASyntheticBoard) {
    // **「呼べた」だけでなく「見つけられた」ことを見る。**
    // 8x8 の市松模様を描くと、内側の格子点は 7x7 になる。
    constexpr int kCell = 16;
    constexpr int kSize = kCell * 8;

    ocvu_mat_handle board = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(kSize, kSize, OCVU_MAT_TYPE_8UC1, &board), OCVU_STATUS_OK);

    std::vector<uint8_t> pixels(static_cast<size_t>(kSize) * kSize, 0);
    for (int y = 0; y < kSize; ++y) {
        for (int x = 0; x < kSize; ++x) {
            const bool white = ((x / kCell) + (y / kCell)) % 2 == 0;
            pixels[static_cast<size_t>(y) * kSize + static_cast<size_t>(x)] =
                white ? 255 : 0;
        }
    }
    ASSERT_EQ(ocvu_mat_copy_from_buffer(board, pixels.data(),
                                        static_cast<int64_t>(pixels.size()), kSize),
              OCVU_STATUS_OK);

    std::vector<float> corners(7 * 7 * 2, 0.0f);
    int32_t count = 0;
    const ocvu_status status =
        ocvu_find_chessboard_corners(board, 7, 7, corners.data(), 49, &count);

    // **見つかることを要求する。** 合成した完璧な市松模様で見つからないなら、
    // 実物の写真で見つかるはずがない。
    EXPECT_EQ(status, OCVU_STATUS_OK);
    EXPECT_EQ(count, 49);

    // 見つかった点が画像の中に収まっていること。
    for (int32_t i = 0; i < count * 2; ++i) {
        EXPECT_GE(corners[static_cast<size_t>(i)], 0.0f);
        EXPECT_LE(corners[static_cast<size_t>(i)], static_cast<float>(kSize));
    }

    ocvu_mat_release(board);
}
```

- [ ] **Step 2: RED を確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: コンパイルエラー（`ocvu_find_chessboard_corners` が宣言されていない）。

- [ ] **Step 3: spec に足して生成する**

`bindings/spec/objdetect.json` の `functions` に追記:

```json
    {
      "name": "ocvu_find_chessboard_corners",
      "summary": "src に写っているチェスボードの内側の格子点を見つけて out_corners へ x と y が交互に並ぶ形で書き、見つかった個数を out_count に返す。呼ぶ側は必要量を事前に知り得るので 2 回呼ぶ必要は無い（pattern_cols * pattern_rows 点で、capacity がそれに満たなければ何も書かずに OCVU_STATUS_BUFFER_TOO_SMALL を返し out_count に必要量を入れる）。pattern_cols と pattern_rows はどちらも 2 以上でなければならない。格子が写っていなければ OCVU_STATUS_NOT_FOUND を返し、これは誤りではない。buffer の所有権は最初から最後まで呼ぶ側にある。",
      "returns": "ocvu_status",
      "csReturns": "int",
      "wrapInTryBarrier": true,
      "params": [
        { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
        { "name": "pattern_cols", "cType": "int32_t", "csType": "int", "direction": "in" },
        { "name": "pattern_rows", "cType": "int32_t", "csType": "int", "direction": "in" },
        { "name": "out_corners", "cType": "float*", "csType": "float[]", "direction": "out-buffer" },
        { "name": "capacity", "cType": "int32_t", "csType": "int", "direction": "in" },
        { "name": "out_count", "cType": "int32_t*", "csType": "out int", "direction": "out" }
      ]
    }
```

**`float*`（const でない）も型表にまだ無い。** `SpecModel.cs` に足す:

```csharp
            ["float*"] = new[] { "float[]", "System.IntPtr" },
```

**先にテストを足して落ちることを見てから**足すこと（Task 2 の `const double*` と同じ手順）。

```
pwsh tools/dev.ps1 generate
```

- [ ] **Step 4: 実装する**

`native/src/ocvu_calibration.cpp` に追記:

```cpp
extern "C" ocvu_status ocvu_find_chessboard_corners(ocvu_mat_handle src, int32_t pattern_cols, int32_t pattern_rows, float* out_corners, int32_t capacity, int32_t* out_count) {
    OCVU_TRY_BEGIN
    if (out_count == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_find_chessboard_corners: out_count is NULL");
    }
    // どの経路で返っても、呼ぶ側が読む値が前回の残りにならないようにする。
    *out_count = 0;

    // 格子は 2x2 以上でなければ格子にならない。
    if (pattern_cols < 2 || pattern_rows < 2) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_find_chessboard_corners: pattern_cols and pattern_rows must be at least 2");
    }
    if (capacity < 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_find_chessboard_corners: capacity is negative");
    }
    if (capacity > 0 && out_corners == nullptr) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_NULL_POINTER,
            "ocvu_find_chessboard_corners: out_corners is NULL but capacity is positive");
    }

    cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_find_chessboard_corners: src handle is invalid");
    }

    // **検出より先に容量を見る。** 足りないと分かっている呼び出しで検出まで
    // 走らせるのは無駄で、しかも「何も書かない」契約は書く前に返ることでしか守れない。
    const int32_t needed = pattern_cols * pattern_rows;
    if (capacity < needed) {
        *out_count = needed;
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_find_chessboard_corners: capacity is smaller than pattern_cols * pattern_rows");
    }

    std::vector<cv::Point2f> corners;
    bool found = false;
    try {
        found = cv::findChessboardCorners(*src_mat, cv::Size(pattern_cols, pattern_rows),
                                          corners);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    // **見つからないのは誤りではない。** 格子が写っていなかっただけである。
    if (!found || corners.empty()) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_NOT_FOUND,
            "ocvu_find_chessboard_corners: no chessboard was found in src");
    }

    // OpenCV は pattern の点数ちょうどを返すが、契約は自分でも守る。
    const int32_t n = static_cast<int32_t>(
        std::min<size_t>(corners.size(), static_cast<size_t>(needed)));
    for (int32_t i = 0; i < n; ++i) {
        out_corners[i * 2] = corners[static_cast<size_t>(i)].x;
        out_corners[(i * 2) + 1] = corners[static_cast<size_t>(i)].y;
    }
    *out_count = n;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

`ocvu_calibration.cpp` の先頭に `#include <algorithm>` を足す（`std::min` に要る）。

- [ ] **Step 5: GREEN を確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: `Calibration.*` の 9 件が PASS（Task 2 の 5 件 + このタスクの 4 件）。

**`FindChessboardCornersFindsASyntheticBoard` が落ちたら、それは実装の誤りとは限らない。**
`cv::findChessboardCorners` は合成画像に対して厳しいことがある。**その場合は
「見つからなかった」を報告に書き、テストを `EXPECT_EQ(status, OCVU_STATUS_NOT_FOUND)`
に変えてはならない** —— 代わりに市松模様の大きさ（`kCell` / `kSize`）を変えて試し、
それでも見つからなければ**そう報告する**。合成画像で見つからないという事実自体が、
このリポジトリに記録する価値のある実測である。

- [ ] **Step 6: 検査が効くことを確かめる（prove-a-check-works、2 通り）**

1. `*out_count = 0;` を一時的に消す → `...RejectsInvalidArgumentsAndAlwaysWritesZero` と
   `...ReportsNotFoundOnABlankImage` が落ちる
2. `if (capacity < needed)` を `if (capacity < 0)` に弱める →
   `...RejectsATooSmallBufferWithoutWriting` が落ちる

確認したら手で戻す。

- [ ] **Step 7: ASan を回す**

```
pwsh tools/dev.ps1 test-asan
```

- [ ] **Step 8: コミット**

```bash
git add bindings/spec/objdetect.json native/src/ocvu_calibration.cpp native/tests/test_calibration.cpp \
        native/include/ocvu/objdetect.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Objdetect.g.cs \
        bindings/generator/Ocvu.Generator/SpecModel.cs \
        bindings/generator/Ocvu.Generator.Tests/SpecSchemaTests.cs \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(m5): ocvu_find_chessboard_corners を足す"
```

---

## Task 4: C# 公開 API と L3

**Files:**
- Create: `Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvCalibration.cs`（+ `.meta`）
- Create: `tests/Managed/CvUnity.Tests.Managed/CalibrationTests.cs`

**Interfaces:**
- Consumes: Task 2・3 の 2 本
- Produces: `CvCalibration.Undistort(CvMat src, double[] cameraMatrix, double[] distCoeffs, CvMat dst)` と
  `CvCalibration.FindChessboardCorners(CvMat src, int patternCols, int patternRows)` →
  `CvPoint2[]`（見つからなければ空配列）

**なぜ新しいクラスか:** `CvOps` は imgproc の一般的な処理、`CvGeometry` は変換の推定である。
**較正は用途としてまとまっており、2 本が別 module にまたがる** —— `CvCalibration` に置くと、
利用者から見て「歪み補正の一式」が 1 箇所にある。

**`UnityEngine` を参照しない。** `CvPoint2` は `Runtime/Core/CvGeometry.cs` に既にある
（`geometry` で定義したもの）ので、それを使う。

- [ ] **Step 1: 失敗する L3 テストを書く**

`tests/Managed/CvUnity.Tests.Managed/CalibrationTests.cs` を新規作成:

```csharp
using System;
using System.Linq;
using CvUnity;
using Xunit;

public class CalibrationTests
{
    private static readonly double[] Camera = { 100, 0, 16, 0, 100, 16, 0, 0, 1 };
    private static readonly double[] Coeffs = { 0.1, -0.05, 0, 0, 0 };

    [Fact]
    public void UndistortKeepsTheShape()
    {
        using var src = CvMat.Create(32, 32, CvMatType.Gray8);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        CvCalibration.Undistort(src, Camera, Coeffs, dst);

        Assert.Equal(32, dst.Rows);
        Assert.Equal(32, dst.Cols);
    }

    [Fact]
    public void UndistortRejectsAWrongSizedCameraMatrix()
    {
        using var src = CvMat.Create(32, 32, CvMatType.Gray8);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        var eight = new double[] { 1, 0, 0, 0, 1, 0, 0, 0 };
        Assert.Throws<ArgumentException>(
            () => CvCalibration.Undistort(src, eight, Coeffs, dst));
    }

    [Fact]
    public void UndistortRejectsAnUnsupportedCoefficientCount()
    {
        using var src = CvMat.Create(32, 32, CvMatType.Gray8);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        var three = new double[] { 0.1, 0, 0 };
        Assert.Throws<ArgumentException>(
            () => CvCalibration.Undistort(src, Camera, three, dst));
    }

    [Fact]
    public void UndistortRejectsNull()
    {
        using var src = CvMat.Create(32, 32, CvMatType.Gray8);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        Assert.Throws<ArgumentNullException>(() => CvCalibration.Undistort(null, Camera, Coeffs, dst));
        Assert.Throws<ArgumentNullException>(() => CvCalibration.Undistort(src, null, Coeffs, dst));
        Assert.Throws<ArgumentNullException>(() => CvCalibration.Undistort(src, Camera, null, dst));
        Assert.Throws<ArgumentNullException>(() => CvCalibration.Undistort(src, Camera, Coeffs, null));
    }

    [Fact]
    public void FindChessboardCornersReturnsEmptyWhenThereIsNoBoard()
    {
        using var blank = CvMat.Create(64, 64, CvMatType.Gray8);

        // **空配列は誤りではない。** 格子が写っていなかっただけである。
        Assert.Empty(CvCalibration.FindChessboardCorners(blank, 7, 7));
    }

    [Fact]
    public void FindChessboardCornersFindsASyntheticBoard()
    {
        // **盤は正方形にしない。** 正方形だと x と y の値域が同じになるので、
        // 取り違えても格子の形が変わらず、この検査が入れ替えを見抜けない
        // （L1 で実測した —— 7x7 では xy を入れ替えても緑のままだった）。
        // 128 x 112、16 画素のセルで 8x7 のセル = 7x6 の内側格子点になる。
        using var board = MakeCheckerboard(128, 112, 16);

        CvPoint2[] corners = CvCalibration.FindChessboardCorners(board, 7, 6);

        Assert.Equal(42, corners.Length);

        // **範囲だけを見ない。** 範囲しか見ない検査は、平面配置でも
        // xy 入れ替えでも同一点 42 個でも緑になる（これも L1 で実測した）。
        // 格子の構造そのものを見る —— x は 7 通り、y は 6 通りに落ちるはずである。
        var xs = corners.Select(p => (int)Math.Round(p.X / 16.0)).Distinct().OrderBy(v => v).ToArray();
        var ys = corners.Select(p => (int)Math.Round(p.Y / 16.0)).Distinct().OrderBy(v => v).ToArray();

        Assert.Equal(new[] { 1, 2, 3, 4, 5, 6, 7 }, xs);
        Assert.Equal(new[] { 1, 2, 3, 4, 5, 6 }, ys);
    }

    [Fact]
    public void FindChessboardCornersRejectsATooSmallPattern()
    {
        using var src = CvMat.Create(64, 64, CvMatType.Gray8);

        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvCalibration.FindChessboardCorners(src, 1, 7));
        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvCalibration.FindChessboardCorners(src, 7, 0));
    }

    /// <summary>市松模様を作る。**幅と高さを別々に取る** —— 正方形の盤では
    /// x と y の取り違えを検出できないため。</summary>
    private static CvMat MakeCheckerboard(int width, int height, int cell)
    {
        var mat = CvMat.Create(height, width, CvMatType.Gray8);
        var pixels = new byte[width * height];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                pixels[(y * width) + x] = ((x / cell) + (y / cell)) % 2 == 0 ? (byte)255 : (byte)0;
            }
        }
        mat.CopyFrom(pixels, width);
        return mat;
    }
}
```

- [ ] **Step 2: RED を確認する**

```
pwsh tools/dev.ps1 test-managed
```

期待: コンパイルエラー（`CvCalibration` が無い）。

- [ ] **Step 3: 公開 API を書く**

`Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvCalibration.cs` を新規作成:

```csharp
using System;
using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>
    /// カメラの歪み補正と、較正パターンの検出（OpenCV の imgproc と objdetect）。
    /// </summary>
    /// <remarks>
    /// **calib module は使っていない。** 歪みを当てる undistort は imgproc、
    /// 較正パターンを見つける findChessboardCorners は objdetect にあり、
    /// どちらも既にリンク済みである。**係数を求める calibrateCamera だけが
    /// calib にあり、それはまだ出していない**（構成ハッシュが変わるため。
    /// 詳細は docs/roadmap.md の M5 節）。
    /// </remarks>
    public static class CvCalibration
    {
        /// <summary>カメラ行列の要素数。3x3 で固定である。</summary>
        private const int CameraMatrixLength = 9;

        /// <summary>
        /// src の歪みを補正して <paramref name="dst"/> に入れる。
        /// </summary>
        /// <remarks>
        /// <paramref name="dst"/> は結果に応じて丸ごと置き換わり、
        /// <paramref name="src"/> と同じ形状・型になる —— 呼び出し前に持っていた
        /// 形状・型・内容は保持されない。
        /// <paramref name="distCoeffs"/> は OpenCV が受ける長さ（4 / 5 / 8 / 12 / 14）
        /// でなければならない。**この一覧は OpenCV の都合であって、こちらの判断ではない。**
        /// </remarks>
        /// <param name="src">補正する画像。</param>
        /// <param name="cameraMatrix">行優先の 3x3（9 要素）。</param>
        /// <param name="distCoeffs">歪み係数。4 / 5 / 8 / 12 / 14 要素。</param>
        /// <param name="dst">結果を受け取る Mat。</param>
        public static void Undistort(CvMat src, double[] cameraMatrix, double[] distCoeffs, CvMat dst)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (cameraMatrix == null) { throw new ArgumentNullException(nameof(cameraMatrix)); }
            if (distCoeffs == null) { throw new ArgumentNullException(nameof(distCoeffs)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }

            if (cameraMatrix.Length != CameraMatrixLength)
            {
                throw new ArgumentException(
                    $"カメラ行列は 3x3（{CameraMatrixLength} 要素）でなければなりません（渡されたのは {cameraMatrix.Length} 要素）。",
                    nameof(cameraMatrix));
            }

            if (!IsAcceptedCoefficientCount(distCoeffs.Length))
            {
                throw new ArgumentException(
                    $"歪み係数は 4 / 5 / 8 / 12 / 14 要素のいずれかでなければなりません（渡されたのは {distCoeffs.Length} 要素）。",
                    nameof(distCoeffs));
            }

            // 長さは native にも渡す（**バイト数** —— この ABI の length は全部そうである）。
            // **C# が正しく詰めたことを native は信用しない。**
            var status = (CvStatus)NativeMethods.ocvu_undistort(
                src.Handle,
                cameraMatrix, (long)cameraMatrix.Length * sizeof(double),
                distCoeffs, (long)distCoeffs.Length * sizeof(double),
                dst.Handle);
            CvNative.ThrowIfFailed(status);
        }

        /// <summary>
        /// src に写っているチェスボードの内側の格子点を見つける。
        /// 写っていなければ**空配列**を返す。
        /// </summary>
        /// <remarks>
        /// **空配列は誤りではない** —— 格子が写っていなかっただけである
        /// （入力の形が誤っている場合は例外になる）。
        /// 返る点は <c>patternCols * patternRows</c> 個で、
        /// <see cref="CvGeometry.FindHomography"/> にそのまま渡せる形である。
        /// </remarks>
        /// <param name="src">探す画像。</param>
        /// <param name="patternCols">内側の格子点の列数。2 以上。</param>
        /// <param name="patternRows">内側の格子点の行数。2 以上。</param>
        public static CvPoint2[] FindChessboardCorners(CvMat src, int patternCols, int patternRows)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (patternCols < 2)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(patternCols), patternCols, "格子の列数は 2 以上でなければなりません。");
            }
            if (patternRows < 2)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(patternRows), patternRows, "格子の行数は 2 以上でなければなりません。");
            }

            // 必要量は事前に分かっているので 1 回で済む。
            // **capacity も out_count も float の個数である**（点の個数ではない）。
            // x と y の 2 つで 1 点なので、点数の 2 倍が float 数になる。
            // この単位は `ocvu_orb_detect` と同じ「capacity == 配列長」であり、
            // **要素数で数える規則がこの ABI 全体で 1 つだけになるようにしてある。**
            int expectedFloats = patternCols * patternRows * 2;
            var flat = new float[expectedFloats];

            var status = (CvStatus)NativeMethods.ocvu_find_chessboard_corners(
                src.Handle, patternCols, patternRows, flat, expectedFloats, out int floatCount);

            // **見つからないのは失敗ではない。** 呼ぶ側には空配列で返す。
            if (status == CvStatus.NotFound) { return Array.Empty<CvPoint2>(); }

            CvNative.ThrowIfFailed(status);

            // native が返すのは float の個数なので、点に戻すのはここの仕事である。
            var corners = new CvPoint2[floatCount / 2];
            for (int i = 0; i < corners.Length; i++)
            {
                corners[i] = new CvPoint2(flat[i * 2], flat[(i * 2) + 1]);
            }
            return corners;
        }

        /// <summary>OpenCV が受け付ける歪み係数の個数か。</summary>
        private static bool IsAcceptedCoefficientCount(int count)
        {
            return count == 4 || count == 5 || count == 8 || count == 12 || count == 14;
        }
    }
}
```

**`.meta` を作る。** 既存の `Runtime/Core/*.cs.meta` と同じ形（**60 バイト、
1 行目のみ CRLF、末尾改行なし、guid は 32 桁 hex でリポジトリ内一意**）にする。

- [ ] **Step 4: GREEN を確認する**

```
pwsh tools/dev.ps1 test-managed
```

期待: 新しい 7 件を含めて全件 PASS。

- [ ] **Step 5: 上限・下限の複製が両側で一致することを確かめる**

**`IsAcceptedCoefficientCount` が C と C# に二重に書かれている。** C# から C の
実装は読めないので、これは意図的な複製である。**両側を native に問うテスト**を
`CalibrationTests.cs` に足す:

```csharp
    [Fact]
    public void TheManagedCoefficientCountsMatchWhatNativeAccepts()
    {
        // IsAcceptedCoefficientCount は C と C# に二重に書かれている。
        // **片方だけ変わったときに落ちる検査を置く。**
        using var src = CvMat.Create(32, 32, CvMatType.Gray8);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        foreach (int n in new[] { 4, 5, 8, 12, 14 })
        {
            var coeffs = new double[n];
            var ex = Record.Exception(() => CvCalibration.Undistort(src, Camera, coeffs, dst));
            Assert.Null(ex);
        }

        // native も同じ集合を持っていることを、C# の検証を迂回して確かめる。
        foreach (int n in new[] { 3, 6, 15 })
        {
            var coeffs = new double[n];
            var status = (CvStatus)CvUnity.Interop.NativeMethods.ocvu_undistort(
                src.Handle, Camera, (long)Camera.Length * sizeof(double),
                coeffs, (long)n * sizeof(double), dst.Handle);
            Assert.Equal(CvStatus.InvalidArgument, status);
        }
    }
```

**このテストは `NativeMethods` を直接叩く。** `CvUnity.Tests.Managed` は
`InternalsVisibleTo` で内部型が見えている（`FeaturesTests` が同じことをしている）。

- [ ] **Step 6: 全レーンを回す**

```
pwsh tools/dev.ps1 test
```

期待: exit 0。`verify-generated` が **16 ファイル**で一致する
（module を新設していないので数は変わらない）。

- [ ] **Step 7: コミット**

```bash
git add Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvCalibration.cs \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvCalibration.cs.meta \
        tests/Managed/CvUnity.Tests.Managed/CalibrationTests.cs
git commit -m "feat(m5): CvCalibration を足し、係数の個数を両側から挟む"
```

---

## Task 5: 文書・判定・Unity レーン

**Files:**
- Modify: `docs/abi-ownership-and-versioning.md`（§3 allowlist）
- Modify: `docs/api-reference.md`
- Modify: `docs/roadmap.md`（M5 の判定）
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: Task 1〜4 のすべて
- Produces: 判定と文書が実物と一致した状態

**なぜ独立したタスクか:** `CLAUDE.md` は**毎セッション自動で読み込まれる**ので、
古いと以降の全エージェントに効き続ける。**M0 で Critical になったのはこの経路で、
CI は緑のままだった。**

- [ ] **Step 1: Unity のレーンを両方回す**

```
pwsh tools/dev.ps1 test-unity-editmode
```

その**完了を待ってから**（レーンは相互排他）:

```
pwsh tools/dev.ps1 test-unity-player
```

期待: EditMode 34 passed、Player 19/19 で `EveryEntryPointIsReachable` が Passed。
**件数は変わらない** —— 到達性テストは 1 件で、中で呼ぶ宣言が 2 本増えるだけである。

**このマシンは重く、Player は十数分かかることがある。完走できなければ
「走らせられなかった」と正直に報告すること。**

- [ ] **Step 2: allowlist に足す**

`docs/abi-ownership-and-versioning.md` の §3 に新しい節を足す:

```markdown
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

**係数を求める `cv::calibrateCamera` は出していない** —— そちらは `calib` に在り、
足すと構成ハッシュが変わって 5 platform 分の OpenCV を作り直すことになる
（実測: `4785d98e9aad` → `09fcbe260d87`）。加えて**利用例が決まっていない** ——
較正をアプリの初回に行うのか、開発時に済ませて係数を焼き込むのかで API の形が変わる。
```

**`docs/abi-ownership-and-versioning.md` の「まだ作らないもの」から
`calib` を消さないこと** —— `calibrateCamera` はまだ出していない。
**代わりに「`undistort` は出した」ことを明記する。**

- [ ] **Step 3: `docs/api-reference.md` に足す**

§1 の C ABI 表に 2 本、§2 に `CvCalibration` の節を足す。
**冒頭の対象範囲の数え（「C ABI 15 関数」）と、末尾の「まだ無い機能」の一覧が
同時に古くなる** —— 歪み補正がそちらに残っていないか必ず見る。

- [ ] **Step 4: `docs/roadmap.md` の M5 判定を直す**

条件 2 の行に次を足す:

- **歪み補正を出した**（`ocvu_undistort` / `ocvu_find_chessboard_corners`）
- **`calib` module は要らなかった** —— 必要な関数は `imgproc` と `objdetect` に在り、
  既にリンク済みだった（実測）
- **`cv::calibrateCamera` は出していない**（構成ハッシュが変わる + 利用例が未決）

**条件 2 を「満たした」と書くか「部分的に満たした」のままにするかを、
判断して書くこと。** 下の「完了条件への影響」に材料がある。

- [ ] **Step 5: `CLAUDE.md` を直す**

**数えている数を全部洗う**（`grep -rn` で数字ごと探す）:

- 「リポジトリの現状」の M5 の段
- **公開 ABI の内訳の段**（`ocvu_find_homography` などを列挙している箇所）
- `native/src/` の一覧に `ocvu_calibration.cpp`
- `dev.ps1 test-managed` の行の件数（**件数を書いてあるのはこの行だけ**）
- `dev.ps1 test-native` の行の GoogleTest 件数
- **`COMPONENTS` の行は変わらない**（`calib` を足していないので）

- [ ] **Step 6: 文書のリンクを検算する**

```
pwsh -NoProfile -Command "
  git ls-files '*.md' | ForEach-Object { \$_ }
"
```
に対して、コードブロックの外の相対リンクが解決することを確かめる
（`ci-lint.yml` の「Documentation links」job と同じ観点。ローカルでは
`.github/workflows/ci-lint.yml` の該当 step の PowerShell を読んで同じことをする）。

- [ ] **Step 7: 改行を壊していないか確かめる**

**M5 の `geometry` で実際に踏んだ。** 編集スクリプトのバグで文書 1 本が
LF から CRLF に全面変換され、新しい節に `\r\r\n` が入った。
**実質 42 行の変更が 921 行の差分に埋もれた。**

```
pwsh -NoProfile -Command "
  git diff --numstat | ForEach-Object { \$_ }
"
```

**行数が変更の実感と大きく食い違ったら、改行を疑う。**

- [ ] **Step 8: コミット**

```bash
git add docs/abi-ownership-and-versioning.md docs/api-reference.md docs/roadmap.md CLAUDE.md
git commit -m "docs(m5): 歪み補正を足したことを判定と文書に反映する"
```

---

## 完了条件への影響（Task 5 Step 4 の材料）

条件 2 の原文は「`geometry` / `calib` / `features` / `objdetect` などを
**利用例に基づいて**追加する」である。

この計画が終わった時点で:

| module | 状態 |
| --- | --- |
| `objdetect` | **出した**（QR + チェスボード） |
| `features` | **出した**（ORB） |
| `geometry` | **出した**（射影変換の推定） |
| `calib` | **module としては足していない。** ただし**歪み補正という用途は出した** |

**判断の材料:**

- 条件は module 名を挙げているが、**目的は「利用例に基づいて API を足す」ことである**。
  歪み補正は `calib` を足さずに実現できた —— これは**条件の想定より良い結果**である
  （構成ハッシュを変えずに済んだ）
- 一方、**`calibrateCamera` は出していない。** 「較正」を名乗るなら係数を求める側が要る、
  という読み方は成り立つ
- **`geometry` のときと同じ問題がある** —— この 2 本も「利用例から選んだ」のではなく
  「既にリンク済みで安かったから選んだ」側面が大きい。**そこは正直に書くこと**

**「満たした」と書くなら、`calibrateCamera` を出していないことを同じ段落に書く。**
**「部分的に満たした」のままにするなら、何が足りないのかを 1 文で書く。**
どちらでもよいが、**読む人が実物との差を測れる形にすること。**

---

## この計画が意図的に決めていること

| 決定 | 理由 | 間違っていた場合のコスト |
| --- | --- | --- |
| `calib` module を足さない | 必要な関数は既にリンク済みで、足すと 5 platform 分の再ビルドになる | `calibrateCamera` が要る利用者に届かない |
| `undistort` を `imgproc` の spec に入れる | 実際にその module に在る。用途で分けると spec と実物がずれる | C# 側のクラスと spec の module 名が一致しない（`CvCalibration` は 2 つの spec にまたがる） |
| 実装は 1 ファイル（`ocvu_calibration.cpp`） | 2 本が別 module にまたがるが、**用途は 1 つ**である | module ごとに分ける規則があると読めば、置き場所が予想外になる |
| 係数の個数を C と C# に二重に書く | C# から C の実装は読めない | 片方だけ変わりうる → **L3 が両側を native に問う** |
| 格子点の検出を 1 回呼びにする | 必要量が `cols * rows` で事前に分かる | 呼ぶ側が常に最大量を確保する |
| 合成した市松模様で「見つかる」ことを要求する | 完璧な入力で見つからないなら実物で見つかるはずがない | `findChessboardCorners` が合成画像に厳しければ落ちる → **その事実を報告に書く** |
