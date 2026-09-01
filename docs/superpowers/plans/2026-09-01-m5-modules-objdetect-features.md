# M5 条件 2 の前半 — objdetect / features を C ABI に出す

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `objdetect`（QR コードの符号化・復号）と `features`（ORB の特徴点検出）を、spec を正本として C ABI に 3 本出し、Unity の Player まで通す。

**Architecture:** OpenCV 側は既に両モジュールをビルドしているので、`cmake/FindOpenCvUnityDeps.cmake` の `COMPONENTS` に足せばリンクできる（**構成ハッシュは変わらない** = 5 platform 分の OpenCV を作り直さない）。関数は `bindings/spec/{objdetect,features}.json` に書き、`dev.ps1 generate` が C ヘッダ・C# の P/Invoke・到達性テスト・API 対応表を出す。実装だけを手で書く。

**Tech Stack:** C++17 / OpenCV 5.0.0（static）/ CMake 3.25+ / .NET 8（generator と L3）/ netstandard2.1（Unity 側 Runtime）/ PowerShell 7（レーンの入口）

**Spec:** [`docs/roadmap.md`](../../roadmap.md) の M5 節、完了条件 2
（「`geometry` / `calib` / `features` / `objdetect` などを**利用例に基づいて**追加する」）。
**この計画はそのうち `objdetect` と `features` だけを扱う。**
判断の根拠は下の「スコープ」にある。

**関連する正本:**
- `.claude/skills/add-abi-function/SKILL.md` — ABI を 1 本足す手順の正本。**全タスクがこれに従う**
- `.claude/skills/prove-a-check-works/SKILL.md` — 検査を足す・変えるときの規律
- [`docs/abi-ownership-and-versioning.md`](../../abi-ownership-and-versioning.md) — 所有権・versioning・allowlist の正本

---

## Global Constraints

spec と `CLAUDE.md` から、値をそのまま写したもの。**各タスクの要件はこの節を暗黙に含む。**

- **C ABI が唯一の native contract。** `cv::Mat*` や STL 型を境界の外へ出さない。opaque handle と固定サイズ型（`int32_t`、`int64_t`、`float`、明示 struct）のみ。
- **例外を ABI の外へ出さない。** 公開関数の本体は `OCVU_TRY_BEGIN` / `OCVU_TRY_END` で囲む。この計画で足す 3 本は**すべて囲う**（`wrapInTryBarrier: true`）。
- **`extern "C" ocvu_status ocvu_名前(` までを 1 物理行に置く。** `.claude/hooks/check-exception-barrier.sh` の awk がこの形で関数を認識する。引数側の改行は問題ない。
- **借用 handle を作らない。** Unity 所有のメモリを指す handle を返さない。buffer は呼び出しの内側で完結する借用。
- **buffer の長さは必ず検証し、1 つでも合わなければ何も書かずに返す。**
- **`Runtime/Interop` と `Runtime/Core` は `UnityEngine` を参照してはならない。** 参照した瞬間に netstandard2.1 shim のビルドが落ち、L3 レーンが失われる。
- **宣言を手で書かない。** ヘッダにも `NativeMethods.cs` にも足さない。spec に書いて `./tools/dev.ps1 generate` を実行する。`dev.ps1 verify-generated` が落とす。
- **生成物も一緒にコミットする**（`.meta` を含む）。spec だけ入れると CI が 3 platform で落ちる。
- **`git add -A` / `git add .` は hook が拒否する。** パスを個別に stage する。
- **非 ASCII を出力する PowerShell スクリプトは `[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()` を先頭に置く。**
- **`dev.ps1` のレーンは相互排他。** 2 つ同時に走らせない（`artifacts/test-results/` を共有し、後から始めたほうが先行を無音で殺す）。
- **本数を数えるのは `docs/api-map.md` の冒頭だけ。** 他所に数字を写さない。
- **`OCVU_ABI_VERSION` は上げない。** この計画がするのは「新しい関数を足す」と「`OCVU_STATUS_LIST` の**末尾**に status を足す」だけで、どちらも bump しない変更である（`docs/abi-ownership-and-versioning.md` §2）。

---

## スコープ

### 含むもの

**C ABI 3 本**（`docs/api-map.md` の本数は 20 → 23 になる）:

| 関数 | module | 形 |
| --- | --- | --- |
| `ocvu_qr_encode` | objdetect | text → Mat |
| `ocvu_qr_decode` | objdetect | Mat → text（**2 回呼び**） |
| `ocvu_orb_detect` | features | Mat → keypoint 配列 |

### 含まないもの（非ゴール）

- **`calib` の追加。** `tools/opencv-config.psd1` の `Modules` に無く、OpenCV 側がビルドしていない。足すと**構成ハッシュが変わり、5 platform 分の OpenCV を CI で作り直す**ことになる（実測: `Modules` に 1 つ足すとハッシュが `4785d98e9aad` → `a197bbcbdaf5` に変わる）。これは別の計画である。
- **`geometry` の C ABI 化。** ライブラリ自体は既にビルド済みなので**リンクは安い**（下記の発見）が、出す API（solvePnP 等）は姿勢推定の入力形式を決める設計作業が別に要る。**この計画では出さない。**
- **aruco / barcode / charuco / face**（objdetect の残り）。`FaceDetectorYN` は `dnn` を要求するので現構成では扱えない。
- **SIFT / AKAZE / matcher**（features の残り）。ORB の 1 本で「新しい module が spec から生成できる」ことは示せる。
- **descriptor の取得。** `ocvu_orb_detect` は keypoint だけを返す。descriptor は `Mat` に出るので既存の handle で表現できるが、API の形が別途要る。

### 着手前に知っておくこと（この計画を書く過程で分かった 2 件）

**発見 1: `geometry` と `flann` は既にビルドされている。**
`Modules` は `core, imgproc, imgcodecs, objdetect, features` の 5 つだが、
復元済みの木に実在するのは **7 つ**である（実測、`4785d98e9aad`）:

```
opencv_core  opencv_features  opencv_flann  opencv_geometry
opencv_imgcodecs  opencv_imgproc  opencv_objdetect
```

`flann` と `geometry` は `features` / `objdetect` の依存として引かれている。
`OpenCVModules.cmake` も 7 つ全部を component として公開している。
**したがって「`geometry` はビルドされていないから高い」は誤りである** ——
高いのは `calib` だけである。

**発見 2: この計画の `COMPONENTS` 変更で、構成ハッシュは変わらない。**
`Get-OpenCvConfigHash` が読むのは `tools/opencv-config.psd1` であって
`cmake/FindOpenCvUnityDeps.cmake` ではない。**`Modules`（OpenCV が何を作るか）と
`COMPONENTS`（この plugin が何をリンクするか）は別である** —— M3.5 の
`imgcodecs` で踏んだ取り違えがこれで、`ocvu_get_build_information()` の
`To be built:` を根拠にすると誤る。

---

## File Structure

### 新規作成

| ファイル | 責務 |
| --- | --- |
| `bindings/spec/objdetect.json` | objdetect の宣言の正本（2 entry） |
| `bindings/spec/features.json` | features の宣言の正本（1 entry） |
| `native/src/ocvu_objdetect.cpp` | `ocvu_qr_encode` / `ocvu_qr_decode` の実装 |
| `native/src/ocvu_features.cpp` | `ocvu_orb_detect` の実装 |
| `native/tests/test_objdetect.cpp` | L1（QR の往復・失敗経路・境界） |
| `native/tests/test_features.cpp` | L1（ORB の検出・失敗経路・境界） |
| `Packages/.../Runtime/Core/CvQrCode.cs` | C# 公開 API（2 回呼びを隠す） |
| `Packages/.../Runtime/Core/CvFeatures.cs` | C# 公開 API（keypoint 配列） |
| `tests/Managed/CvUnity.Tests.Managed/ObjdetectTests.cs` | L3 |
| `tests/Managed/CvUnity.Tests.Managed/FeaturesTests.cs` | L3 |

### 生成物（`dev.ps1 generate` が書く。手で編集しない）

| ファイル | 備考 |
| --- | --- |
| `native/include/ocvu/objdetect.h` | 新規 |
| `native/include/ocvu/features.h` | 新規 |
| `Packages/.../Runtime/Interop/NativeMethods.Objdetect.g.cs`（+ `.meta`） | 新規 |
| `Packages/.../Runtime/Interop/NativeMethods.Features.g.cs`（+ `.meta`） | 新規 |
| `tests/UnityProject/.../AbiReachabilityChecks.g.cs` | 3 行増える |
| `docs/api-map.md` | 本数が 20 → 23、行が 3 つ増える |

### 変更

| ファイル | 変更内容 |
| --- | --- |
| `cmake/FindOpenCvUnityDeps.cmake:84` | `COMPONENTS core imgproc imgcodecs` → `+ objdetect features` |
| `native/CMakeLists.txt` | `OCVU_SOURCES` に `.cpp` 2 本 |
| `native/tests/CMakeLists.txt` | `ocvu_tests` に `.cpp` 2 本 |
| `native/include/opencv_unity_native.h` | status 1 行 / `ocvu_keypoint` struct / `OCVU_ORB_MAX_FEATURES` / `#include` 2 行（**この 4 つは生成物ではない**） |
| `Packages/.../Runtime/Core/CvStatus.cs` | `NotFound = 8` |
| `Packages/.../Runtime/Interop/NativeMethods.cs` | `OcvuKeyPoint` struct（`OcvuMatInfo` の隣） |
| `bindings/generator/Ocvu.Generator/SpecModel.cs` | `AllowedCsTypes` に `ocvu_keypoint*` |
| `bindings/generator/Ocvu.Generator.Tests/SpecSchemaTests.cs` | 型表の新エントリのテスト |
| `docs/abi-ownership-and-versioning.md` | §3 allowlist に 3 本（11 → 14） |
| `docs/api-reference.md` | `CvQrCode` / `CvFeatures` |
| `docs/roadmap.md` | M5 の判定、条件 2 の現在地 |
| `CLAUDE.md` | リポジトリの現状 / ファイル配置 / `COMPONENTS` の行 |
| `THIRD_PARTY_NOTICES.md` | 「リンクされていない」分類の再確認（変わらない可能性が高いが**確かめる**） |

---

## Task 1: objdetect / features をリンクし、リンクできたことを L1 で実証する

**Files:**
- Modify: `cmake/FindOpenCvUnityDeps.cmake:84`
- Create: `native/tests/test_module_linkage.cpp`
- Modify: `native/tests/CMakeLists.txt`

**既存の `test_opencv_link.cpp` に足さない。** あちらが見ているのは
「固定した版か」「禁じた依存が入っていないか」で、**構成の検査**である。
こちらは**モジュールごとのリンクの検査**で、module を足すたびに行が増える。
混ぜると、片方が落ちたときにどちらの問題か読み取れない。

**Interfaces:**
- Consumes: なし（最初のタスク）
- Produces: `cv::QRCodeEncoder` / `cv::QRCodeDetector` / `cv::ORB` が native からリンクして呼べる状態。以降の全タスクがこれに依存する

**なぜ最初か:** リンクが通らなければ以降のタスクは 1 つも書けない。そして**リンクは「ビルドが通る」では確かめられない** —— 参照しない限りリンカは何も引かないので、`COMPONENTS` に足しただけでは binary は 1 バイトも増えない（M3.5 実測）。**実際に `cv::` のシンボルを参照するテストだけが証拠になる。**

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_module_linkage.cpp` を新規作成:

```cpp
// objdetect / features が「ビルドされている」ではなく
// 「この plugin にリンクされている」ことを見る。
//
// **この 2 つは別である。** tools/opencv-config.psd1 の Modules に載っていれば
// OpenCV 側は当然ビルドされ、ocvu_get_build_information() も To be built: に
// その名前を出す。それを根拠にすると誤る —— M3.5 で imgcodecs がこれで、
// cmake/FindOpenCvUnityDeps.cmake の COMPONENTS に無いまま
// 「リンク済み」と複数の文書が書いていた。リンカが cv::imencode を
// 未解決にして初めて分かった。
//
// **参照しないと引かれない。** COMPONENTS に足すだけでは binary は
// 1 バイトも増えないので、実際にシンボルを参照するここが唯一の証拠になる。

#include <gtest/gtest.h>

#include <opencv2/core.hpp>
#include <opencv2/features.hpp>
#include <opencv2/objdetect.hpp>

TEST(ModuleLinkage, ObjdetectSymbolsResolve) {
    cv::Ptr<cv::QRCodeEncoder> encoder = cv::QRCodeEncoder::create();
    ASSERT_FALSE(encoder.empty());

    cv::QRCodeDetector detector;
    // 空の Mat を渡しても例外にならず、見つからないだけであること。
    // ここで見たいのはリンクなので、結果ではなく「呼べた」ことを確かめる。
    const std::string decoded = detector.detectAndDecode(cv::Mat());
    EXPECT_TRUE(decoded.empty());
}

TEST(ModuleLinkage, FeaturesSymbolsResolve) {
    cv::Ptr<cv::ORB> orb = cv::ORB::create(16);
    ASSERT_FALSE(orb.empty());
    EXPECT_EQ(orb->getMaxFeatures(), 16);
}
```

`native/tests/CMakeLists.txt` の `ocvu_tests` のソース一覧に
`test_module_linkage.cpp` を足す（既存の `test_imgcodecs.cpp` と同じ書き方）。

- [ ] **Step 2: RED を目で確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: **リンクエラー**（`LNK2019` / `undefined reference to cv::ORB::create`）。
`COMPONENTS` にまだ `objdetect features` が無いので、シンボルが解決しない。

**コンパイルエラー（ヘッダが無い）ではなくリンクエラーであること**を確認する。
ヘッダは `include/opencv2/` に既に在るので、前者が出たら OpenCV の復元が
おかしい（`./tools/opencv.ps1 status` を見る）。

- [ ] **Step 3: COMPONENTS に足す**

`cmake/FindOpenCvUnityDeps.cmake:84` を変更:

```cmake
    COMPONENTS core imgproc imgcodecs objdetect features
```

**`tools/opencv-config.psd1` は触らない。** `Modules` には既に両方入っており、
そちらを変えると構成ハッシュが変わって 5 platform 分の OpenCV を作り直すことになる。

- [ ] **Step 4: GREEN を確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: `ModuleLinkage.ObjdetectSymbolsResolve` と
`ModuleLinkage.FeaturesSymbolsResolve` が PASS。GoogleTest の件数が 64 → 66 になる。

**`flann` / `geometry` を `COMPONENTS` に書いていないのにリンクが通ること**を
確認する。両者は `features` / `objdetect` の依存として `OpenCVModules.cmake` が
宣言しているので、CMake が推移的に引く。**通らなかった場合はここに足す**
（その場合はこの計画の記述が誤っていたということなので、コミットメッセージに書く）。

- [ ] **Step 5: 検査が実際に効くことを確かめる（prove-a-check-works）**

`COMPONENTS` から `objdetect features` を一度戻し、Step 2 と同じリンクエラーが
出ることを確認してから、また足す。**「壊して落ちることを見る」を通していない検査は、
通っても証拠にならない。**

```
# COMPONENTS から objdetect features を手で外す
git diff cmake/FindOpenCvUnityDeps.cmake   # 外れたことを確認
pwsh tools/dev.ps1 test-native             # Step 2 と同じリンクエラーが出ることを確認
# COMPONENTS に objdetect features を手で戻す
```

**`git checkout --` を使わないこと。** この時点ではまだコミットしていないので、
それを実行すると**足した COMPONENTS ごと消える**。外すのも戻すのも手で行う。
（Task 1 の実装者が実際にこの矛盾を踏み、散文の「また足す」を優先して正しく処理した。）

- [ ] **Step 6: binary の大きさを測って記録する**

```
pwsh -NoProfile -Command "(Get-Item build/windows-x64-debug/native/opencv_unity_native.dll).Length"
```

**この値をコミットメッセージに書く。** M3.5 で「`COMPONENTS` に足すだけでは
binary は 1 バイトも増えない」ことが分かっている（静的リンクは参照された
object しか引かない）。**いまはテストが `cv::` を参照しているので、
テスト側の binary は増えるが配る plugin は増えないはず**である ——
**増えていたら前提が違うので、その事実を書く。**

- [ ] **Step 7: コミット**

```bash
git add cmake/FindOpenCvUnityDeps.cmake native/tests/test_module_linkage.cpp native/tests/CMakeLists.txt
git commit -m "feat(m5): objdetect / features をリンクし、リンクを L1 で実証する"
```

---

## Task 2: `OCVU_STATUS_NOT_FOUND` を足す

**Files:**
- Modify: `native/include/opencv_unity_native.h:42-50`（`OCVU_STATUS_LIST`）
- Modify: `Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvStatus.cs`

**Interfaces:**
- Consumes: なし
- Produces: `OCVU_STATUS_NOT_FOUND`（値 **8**）と C# の `CvStatus.NotFound`。Task 4 の `ocvu_qr_decode` が使う

**なぜ要るか:** `ocvu_qr_decode` は「画像に QR が無かった」を返す必要がある。
`OCVU_STATUS_OK` + 長さ 0 で表すと、**「空文字列を符号化した QR」と区別できない。**
既存の status にも当てはまるものが無い（`OPENCV_ERROR` は例外の変換であって、
「見つからなかった」は誤りではない）。

**ABI version は上げない。** `OCVU_STATUS_LIST` の**末尾**に足すのは
bump しない変更である（`docs/abi-ownership-and-versioning.md` §2）。
呼ぶ側が未知の status を扱えることが契約になっており、
`CvNative.IsFailure` は `OK` と `BUFFER_TOO_SMALL` 以外を失敗として扱う。

- [ ] **Step 1: C 側に足す**

`native/include/opencv_unity_native.h` の `OCVU_STATUS_LIST` の**末尾**に 1 行:

```c
#define OCVU_STATUS_LIST(X)               \
    X(OCVU_STATUS_OK,                  0) \
    X(OCVU_STATUS_INVALID_ARGUMENT,    1) \
    X(OCVU_STATUS_NULL_POINTER,        2) \
    X(OCVU_STATUS_OUT_OF_MEMORY,       3) \
    X(OCVU_STATUS_OPENCV_ERROR,        4) \
    X(OCVU_STATUS_UNKNOWN_ERROR,       5) \
    X(OCVU_STATUS_BUFFER_TOO_SMALL,    6) \
    X(OCVU_STATUS_INVALID_HANDLE,      7) \
    X(OCVU_STATUS_NOT_FOUND,           8)
```

**既存の行の値を 1 つも変えない。** 数値が変わるのは bump する変更である。

- [ ] **Step 2: RED を確認する（片側だけ足した状態）**

```
pwsh tools/dev.ps1 test-managed
```

期待: `StatusCodeSyncTests` が **FAIL**。C 側の表は 9 件、C# 側は 8 件で
食い違う。これが安全網が効いていることの証拠である。

**この RED を目で見ること。** 見ずに両側同時に足すと、
`StatusCodeSyncTests` が本当に見ているのかを確かめないまま進むことになる。

- [ ] **Step 3: C# 側に足す**

`Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvStatus.cs` の
enum の末尾に、既存のコメント様式に揃えて足す:

```csharp
        /// <summary>
        /// 探した対象が見つからなかった。**誤りではない。**
        /// </summary>
        /// <remarks>
        /// 画像に QR コードが写っていない場合がこれである。
        /// OCVU_STATUS_OK と長さ 0 で表すと「空文字列を符号化した QR」と
        /// 区別できないので、別の status にしてある。
        /// </remarks>
        NotFound = 8,
```

- [ ] **Step 4: GREEN を確認する**

```
pwsh tools/dev.ps1 test-managed
```

期待: `StatusCodeSyncTests` を含めて全件 PASS。

- [ ] **Step 5: コミット**

```bash
git add native/include/opencv_unity_native.h Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvStatus.cs
git commit -m "feat(m5): OCVU_STATUS_NOT_FOUND を足す（末尾追加なので ABI は上げない）"
```

---

## Task 3: `ocvu_qr_encode` — objdetect の spec と実装

**Files:**
- Create: `bindings/spec/objdetect.json`
- Create: `native/src/ocvu_objdetect.cpp`
- Create: `native/tests/test_objdetect.cpp`
- Modify: `native/CMakeLists.txt`（`OCVU_SOURCES`）
- Modify: `native/tests/CMakeLists.txt`
- Modify: `native/include/opencv_unity_native.h`（`#include "ocvu/objdetect.h"` の 1 行）

**Interfaces:**
- Consumes: Task 1 のリンク
- Produces: `ocvu_status ocvu_qr_encode(const char* text, ocvu_mat_handle dst)`。Task 4 の L1 テストがこれを使って QR 画像を作る（**fixture ファイルを置かずに済む**）

**なぜ encode を先にやるか:** decode のテストには QR 画像が要る。
encode があれば**テストが自己完結する** —— 画像ファイルをリポジトリに置くと、
その画像が何を符号化しているかがコードから読めなくなる。

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_objdetect.cpp` を新規作成:

```cpp
#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <string>

namespace {

// テスト用の Mat を 1 つ作って、抜けるときに必ず解放する。
class ScopedMat {
public:
    // 既定は 1x1。ocvu_qr_encode は dst の形状を上書きするので、
    // 符号化の受け皿としてはこれで足りる。
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

}  // namespace

TEST(Objdetect, EncodeProducesASquareSingleChannelImage) {
    ScopedMat dst;
    ASSERT_EQ(ocvu_qr_encode("OpenCVUnityNative", dst.get()), OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &info), OCVU_STATUS_OK);
    EXPECT_GT(info.rows, 0);
    EXPECT_EQ(info.rows, info.cols) << "QR は正方形である";
    EXPECT_EQ(info.channels, 1);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_8UC1);
}

TEST(Objdetect, EncodeRejectsInvalidArguments) {
    ScopedMat dst;

    EXPECT_EQ(ocvu_qr_encode(nullptr, dst.get()), OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_qr_encode("", dst.get()), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_qr_encode("x", OCVU_MAT_HANDLE_NONE), OCVU_STATUS_INVALID_HANDLE);
}

TEST(Objdetect, EncodeReportsAnOpenCvErrorForTextThatDoesNotFit) {
    // **spec の summary が「符号化できない長さの text は OCVU_STATUS_OPENCV_ERROR
    // になる」と約束している。** その文字列は C の doc コメント・C# の XML doc・
    // API 対応表の 3 箇所に出るので、**約束したなら実証する。**
    //
    // cv::Exception を個別に受けていないと、ここは UNKNOWN_ERROR(5) になる
    // （OCVU_TRY_END の catch(std::exception) に落ちるため）。
    ScopedMat dst;
    const std::string too_long(5000, 'A');  // QR 1 個の容量を超える
    EXPECT_EQ(ocvu_qr_encode(too_long.c_str(), dst.get()), OCVU_STATUS_OPENCV_ERROR);
}

TEST(Objdetect, EncodeLeavesTheDestinationUntouchedWhenItFails) {
    ScopedMat dst;

    // 先に成功させて、既知の形にしておく。
    ASSERT_EQ(ocvu_qr_encode("first", dst.get()), OCVU_STATUS_OK);
    ocvu_mat_info before{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &before), OCVU_STATUS_OK);

    // 失敗する呼び出しが dst を書き換えないこと。
    EXPECT_EQ(ocvu_qr_encode(nullptr, dst.get()), OCVU_STATUS_NULL_POINTER);

    ocvu_mat_info after{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &after), OCVU_STATUS_OK);
    EXPECT_EQ(before.rows, after.rows);
    EXPECT_EQ(before.cols, after.cols);
}
```

`native/tests/CMakeLists.txt` の `ocvu_tests` に `test_objdetect.cpp` を足す。

- [ ] **Step 2: RED を確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: **コンパイルエラー**（`ocvu_qr_encode` が宣言されていない）。
宣言はまだ spec に無いので、生成されたヘッダにも無い。

- [ ] **Step 3: spec を書く**

`bindings/spec/objdetect.json` を新規作成。**この時点では 1 entry だけ**
（`ocvu_qr_decode` は Task 4 で足す）:

```json
{
  "module": "objdetect",
  "functions": [
    {
      "name": "ocvu_qr_encode",
      "summary": "text を QR コードの画像に符号化して dst に入れる。dst の形状と型は結果に応じて上書きされ、8 bit 1 channel の正方形になる。text は NUL 終端の UTF-8 byte 列で、NULL と空文字列は拒否する。符号化できない長さの text は OCVU_STATUS_OPENCV_ERROR になる。失敗したときは dst を書き換えない。",
      "returns": "ocvu_status",
      "csReturns": "int",
      "wrapInTryBarrier": true,
      "params": [
        { "name": "text", "cType": "const char*", "csType": "byte[]", "direction": "in-buffer" },
        { "name": "dst", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" }
      ]
    }
  ]
}
```

**`summary` は 1 行で書く。** 改行を入れると `schema.json` の `pattern` が弾く。
`<`、`>`、`&`、`*/` も禁じられている（C の doc コメントと C# の XML doc の
両方に同じ文字列が出るため）。

- [ ] **Step 4: 生成する**

```
pwsh tools/dev.ps1 generate
```

期待: `native/include/ocvu/objdetect.h` と
`Packages/.../Runtime/Interop/NativeMethods.Objdetect.g.cs` が**新規に**出る。
`docs/api-map.md` の本数が 20 → 21 になる。

**`.meta` も出ているか確認する** —— Unity は `.meta` の無い `.cs` を
自分で作るので、追跡していないと CI とローカルで差分が出る。

```
git status --short
```

- [ ] **Step 5: ヘッダの include を 1 行足す（これは生成物ではない）**

`native/include/opencv_unity_native.h` の既存の `#include` 一覧に足す:

```c
#include "ocvu/objdetect.h"
```

**この 1 行だけは手で書く。** 生成器は module ごとのヘッダを出すが、
それを束ねる入口は生成しない（`add-abi-function` skill に明記されている）。

- [ ] **Step 6: 実装する**

`native/src/ocvu_objdetect.cpp` を新規作成:

```cpp
#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/objdetect.hpp>

#include <string>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

extern "C" ocvu_status ocvu_qr_encode(const char* text, ocvu_mat_handle dst) {
    OCVU_TRY_BEGIN
    if (text == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_qr_encode: text is NULL");
    }
    if (text[0] == '\0') {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_qr_encode: text is empty");
    }

    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_qr_encode: dst handle is invalid");
    }

    // **符号化してから dst に入れる。** 直接 dst_mat へ encode させると、
    // 失敗したときに dst が途中まで書き換わった状態で残りうる。
    cv::Mat encoded;
    try {
        cv::Ptr<cv::QRCodeEncoder> encoder = cv::QRCodeEncoder::create();
        encoder->encode(std::string(text), encoded);
    } catch (const cv::Exception& e) {
        // OCVU_TRY_END でも捕まるが、そこでは UNKNOWN_ERROR になる。
        // OpenCV 由来だと分かる status を返すためにここで先に受ける
        // （QR の容量を超える長さの text がここに来る）。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    if (encoded.empty()) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR,
                                      "ocvu_qr_encode: the encoder produced an empty image");
    }

    *dst_mat = encoded;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

`native/CMakeLists.txt` の `OCVU_SOURCES` に `src/ocvu_objdetect.cpp` を足す。
**SHARED と STATIC の両ターゲットがこのリストを共有しているので 1 箇所で済む。**

**`cv::Exception` は個別に受ける。** `OCVU_TRY_END` は `std::exception` を
`OCVU_STATUS_UNKNOWN_ERROR` にするので、そこへ落とすと **OpenCV 由来の失敗が
「原因不明」として報告される**。`native/src/ocvu_imgcodecs.cpp` が確立済みの
形（同ファイルのコメントに理由が書いてある）で、この計画の 3 本もそれに揃える。


- [ ] **Step 7: GREEN を確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: `Objdetect.*` の 3 件が PASS。

- [ ] **Step 8: 生成物が spec と一致していることを確認する**

```
pwsh tools/dev.ps1 verify-generated
```

期待: `==> 生成物は spec と一致しています（12 ファイル）`
（10 → 12。objdetect のヘッダと P/Invoke が増えた）。

- [ ] **Step 9: コミット**

```bash
git add bindings/spec/objdetect.json native/src/ocvu_objdetect.cpp native/tests/test_objdetect.cpp \
        native/CMakeLists.txt native/tests/CMakeLists.txt native/include/opencv_unity_native.h \
        native/include/ocvu/objdetect.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Objdetect.g.cs \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Objdetect.g.cs.meta \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(m5): ocvu_qr_encode を spec から生成し実装する"
```

---

## Task 4: `ocvu_qr_decode` — 2 回呼びで text を返す

**Files:**
- Modify: `bindings/spec/objdetect.json`（2 entry 目）
- Modify: `native/src/ocvu_objdetect.cpp`
- Modify: `native/tests/test_objdetect.cpp`

**Interfaces:**
- Consumes: Task 2 の `OCVU_STATUS_NOT_FOUND`、Task 3 の `ocvu_qr_encode`
- Produces: `ocvu_status ocvu_qr_decode(ocvu_mat_handle src, char* buffer, int32_t buffer_size, int32_t* out_required_size)`。Task 7 の `CvQrCode.Decode` が包む

**形の根拠:** 復号した text の長さは呼ぶ側に事前に分からないので、
**2 回呼び**（`BUFFER_TOO_SMALL` + `out_required_size`）にする。
`ocvu_imencode` と同じ作法で、新しい idiom ではない
（参照実装は `native/src/ocvu_imgcodecs.cpp`）。
**native が確保した blob を handle で返す形は採らない** ——
`docs/abi-ownership-and-versioning.md` §1 の所有権は 2 種類だけである。

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_objdetect.cpp` に追記:

```cpp
TEST(Objdetect, DecodeRoundTripsWhatEncodeProduced) {
    const std::string payload = "OpenCVUnityNative";

    ScopedMat img;
    ASSERT_EQ(ocvu_qr_encode(payload.c_str(), img.get()), OCVU_STATUS_OK);

    // 1 回目: 大きさを問い合わせる。buffer に NULL を渡すのは正常な呼び方である。
    int32_t needed = 0;
    ASSERT_EQ(ocvu_qr_decode(img.get(), nullptr, 0, &needed),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(needed, static_cast<int32_t>(payload.size()) + 1) << "NUL の分を含む";

    // 2 回目: その大きさで受け取る。
    std::vector<char> buffer(static_cast<size_t>(needed), '\0');
    ASSERT_EQ(ocvu_qr_decode(img.get(), buffer.data(), needed, &needed),
              OCVU_STATUS_OK);
    EXPECT_STREQ(buffer.data(), payload.c_str());
}

TEST(Objdetect, DecodeReportsNotFoundOnAnImageWithoutAQrCode) {
    // 何も書き込んでいない 64x64。QR は写っていない。
    ocvu_mat_handle blank = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(64, 64, OCVU_MAT_TYPE_8UC1, &blank), OCVU_STATUS_OK);

    int32_t needed = 4321;  // 0 以外で汚す
    EXPECT_EQ(ocvu_qr_decode(blank, nullptr, 0, &needed), OCVU_STATUS_NOT_FOUND);
    EXPECT_EQ(needed, 0) << "見つからなかったときは 0 を書くこと";

    ocvu_mat_release(blank);
}

TEST(Objdetect, DecodeRejectsInvalidArgumentsAndAlwaysWritesZero) {
    ScopedMat img;
    ASSERT_EQ(ocvu_qr_encode("payload", img.get()), OCVU_STATUS_OK);

    // out_required_size が NULL なら、他のどの引数より先に断る。
    EXPECT_EQ(ocvu_qr_decode(img.get(), nullptr, 0, nullptr), OCVU_STATUS_NULL_POINTER);

    // **0 ではない値で汚してから呼ぶ。** 0 で初期化していると
    // 「書いていない」と「0 を書いた」が区別できない（M3.5 で実測。
    // 代入を消しても 16 件が緑のまま通った）。
    int32_t needed = 12345;
    EXPECT_EQ(ocvu_qr_decode(OCVU_MAT_HANDLE_NONE, nullptr, 0, &needed),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(needed, 0);

    needed = 12345;
    EXPECT_EQ(ocvu_qr_decode(img.get(), nullptr, -1, &needed),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(needed, 0);

    // buffer_size > 0 なのに buffer が NULL。
    needed = 12345;
    EXPECT_EQ(ocvu_qr_decode(img.get(), nullptr, 8, &needed),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(needed, 0);
}

TEST(Objdetect, DecodeRejectsATooSmallBufferWithoutWriting) {
    const std::string payload = "OpenCVUnityNative";

    ScopedMat img;
    ASSERT_EQ(ocvu_qr_encode(payload.c_str(), img.get()), OCVU_STATUS_OK);

    int32_t needed = 0;
    ASSERT_EQ(ocvu_qr_decode(img.get(), nullptr, 0, &needed),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    ASSERT_GT(needed, 1);

    // ちょうど 1 バイト足りない buffer を 0xAB で埋めて渡す。
    std::vector<char> buffer(static_cast<size_t>(needed), '\xAB');
    EXPECT_EQ(ocvu_qr_decode(img.get(), buffer.data(), needed - 1, &needed),
              OCVU_STATUS_BUFFER_TOO_SMALL);

    // **1 バイトも書かれていないこと。** 部分的に書くと、呼ぶ側は
    // 途中まで正しい buffer を掴むことになり、壊れ方が
    // 「その場では気づけない」形になる。
    for (const char c : buffer) {
        ASSERT_EQ(c, '\xAB') << "足りない buffer には何も書かないこと";
    }
}
```

テストの先頭に `#include <vector>` を足す。

- [ ] **Step 2: RED を確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: コンパイルエラー（`ocvu_qr_decode` が宣言されていない）。

- [ ] **Step 3: spec に 2 entry 目を足す**

`bindings/spec/objdetect.json` の `functions` に追記:

```json
    {
      "name": "ocvu_qr_decode",
      "summary": "src に写っている QR コードを 1 つ検出して復号し、NUL 終端の UTF-8 byte 列として buffer へ書く。復号後の長さは呼ぶ側に分からないので 2 回呼ぶ（1 回目は buffer に NULL を渡して out_required_size に NUL を含む必要バイト数を受け取る。そのとき返る OCVU_STATUS_BUFFER_TOO_SMALL は失敗ではない）。buffer の所有権は最初から最後まで呼ぶ側にあり、足りなければ何も書かない。QR が写っていなければ OCVU_STATUS_NOT_FOUND を返し、これは誤りではない。",
      "returns": "ocvu_status",
      "csReturns": "int",
      "wrapInTryBarrier": true,
      "params": [
        { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
        { "name": "buffer", "cType": "char*", "csType": "byte[]", "direction": "out-buffer" },
        { "name": "buffer_size", "cType": "int32_t", "csType": "int", "direction": "in" },
        { "name": "out_required_size", "cType": "int32_t*", "csType": "out int", "direction": "out" }
      ]
    }
```

```
pwsh tools/dev.ps1 generate
```

- [ ] **Step 4: 実装する**

`native/src/ocvu_objdetect.cpp` に追記（`#include <cstring>` と
`#include <cstdint>` を先頭に足す）:

```cpp
extern "C" ocvu_status ocvu_qr_decode(ocvu_mat_handle src, char* buffer, int32_t buffer_size, int32_t* out_required_size) {
    OCVU_TRY_BEGIN
    // **これを最初に見る。** 無いと呼ぶ側は 2 回目の大きさを決められないので、
    // 他のどの引数より先に断る。
    if (out_required_size == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_qr_decode: out_required_size is NULL");
    }
    // **何よりも先に 0 を書く。** どの経路で返っても、呼ぶ側が読む値が
    // 前回の呼び出しの残りにならないようにする。以降の早期 return は
    // すべてこの後ろに来る。
    *out_required_size = 0;

    if (buffer_size < 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_qr_decode: buffer_size is negative");
    }
    // buffer == NULL かつ buffer_size == 0 は正常な問い合わせなので通す。
    if (buffer_size > 0 && buffer == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_qr_decode: buffer is NULL but buffer_size is positive");
    }

    cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_qr_decode: src handle is invalid");
    }
    if (src_mat->empty()) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_qr_decode: src is empty");
    }

    std::string text;
    try {
        cv::QRCodeDetector detector;
        text = detector.detectAndDecode(*src_mat);
    } catch (const cv::Exception& e) {
        // OCVU_TRY_END でも捕まるが、そこでは UNKNOWN_ERROR になる。
        // OpenCV 由来だと分かる status を返すためにここで先に受ける。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }
    if (text.empty()) {
        // **誤りではない。** 画像に QR が写っていなかっただけである。
        return ::ocvu::set_last_error(OCVU_STATUS_NOT_FOUND,
                                      "ocvu_qr_decode: no QR code was found in src");
    }

    const size_t needed = text.size() + 1;  // NUL を含む
    if (needed > static_cast<size_t>(INT32_MAX)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_qr_decode: the decoded text does not fit in int32_t");
    }
    *out_required_size = static_cast<int32_t>(needed);

    if (static_cast<size_t>(buffer_size) < needed) {
        // 必要量を入れてから返す。buffer には 1 バイトも書かない。
        return ::ocvu::set_last_error(OCVU_STATUS_BUFFER_TOO_SMALL,
                                      "ocvu_qr_decode: buffer is too small for the decoded text");
    }

    std::memcpy(buffer, text.c_str(), needed);
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

- [ ] **Step 5: GREEN を確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: `Objdetect.*` の 8 件が PASS（既存 4 件 + このタスクの 4 件）。

- [ ] **Step 6: 「失敗時に 0 を書く」規則が本当に守られていることを確かめる**

`*out_required_size = 0;` の行を**一時的に消して**、テストが落ちることを見る。

```
pwsh tools/dev.ps1 test-native
```

期待: `DecodeRejectsInvalidArgumentsAndAlwaysWritesZero` と
`DecodeReportsNotFoundOnAnImageWithoutAQrCode` が **FAIL**。
**落ちなければテストが 0 初期化に頼っている**ので、テストを直す。
確認したら行を戻す。

- [ ] **Step 7: ASan を回す**

```
pwsh tools/dev.ps1 test-asan
```

`std::memcpy` で buffer に書くので、境界を踏んでいないことを見る。

- [ ] **Step 8: コミット**

```bash
git add bindings/spec/objdetect.json native/src/ocvu_objdetect.cpp native/tests/test_objdetect.cpp \
        native/include/ocvu/objdetect.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Objdetect.g.cs \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(m5): ocvu_qr_decode を 2 回呼びで足す"
```

---

## Task 5: `ocvu_keypoint` 型を境界に足し、generator の型表を広げる

**Files:**
- Modify: `native/include/opencv_unity_native.h`（struct と定数）
- Modify: `Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.cs`
- Modify: `bindings/generator/Ocvu.Generator/SpecModel.cs`（`AllowedCsTypes`）
- Modify: `bindings/generator/Ocvu.Generator.Tests/SpecSchemaTests.cs`

**Interfaces:**
- Consumes: なし
- Produces: C の `ocvu_keypoint`（**28 バイト**）、C# の `OcvuKeyPoint`、
  型表の `["ocvu_keypoint*"] = { "OcvuKeyPoint[]", "System.IntPtr" }`。Task 6 の spec がこれを使う

**なぜ独立したタスクか:** 型表は**生成器の側の変更**で、
レビュアーが「ABI 関数の設計」とは別の観点で見るべきものである。
`AllowedCsTypes` に足す作業は、**素通しにすると新しい型が 1 つだけ静かに
marshalling の検査から外れる**という性質を持つ（`SpecModel.cs` の doc コメント）。

- [ ] **Step 1: 型表のテストを先に書く**

`bindings/generator/Ocvu.Generator.Tests/SpecSchemaTests.cs` に追記
（既存の型表テストの隣に置く）:

```csharp
    // ocvu_keypoint* は 2 つの入口を持つ。managed 配列を marshal する版と、
    // アドレスを直接渡す版で、どちらも正しい（const uint8_t* と同じ形）。
    [Theory]
    [InlineData("ocvu_keypoint*", "OcvuKeyPoint[]")]
    [InlineData("ocvu_keypoint*", "System.IntPtr")]
    public void BothSpellingsOfAKeypointParamAreAccepted(string cType, string csType)
    {
        Assert.Equal(csType, LoadOneParam(cType, csType).Single().Functions.Single().Params.Single().CsType);
    }

    [Fact]
    public void AKeypointParamRejectsAnUnrelatedCsType()
    {
        // 型表が「知らない cType は拒む」だけでなく、
        // 「知っている cType に合わない csType も拒む」ことを見る。
        var ex = Assert.Throws<SpecFormatException>(() => LoadOneParam("ocvu_keypoint*", "out int"));
        Assert.Contains("ocvu_keypoint*", ex.Message);
    }
```

**`LoadOneParam` は既存の private ヘルパである**（同ファイル内。
`BothSpellingsOfABufferParamAreAccepted` が同じ形で使っている）。
**新しいヘルパを作らないこと** —— 同じことをする 2 つ目のヘルパは、
次に型を足す人がどちらを使うか迷う原因になる。

- [ ] **Step 2: RED を確認する**

```
pwsh tools/dev.ps1 test-managed
```

期待: `BothSpellingsOfAKeypointParamAreAccepted` が **FAIL**
（「cType 'ocvu_keypoint*' を知りません」）。

- [ ] **Step 3: C の struct を足す**

`native/include/opencv_unity_native.h` の `ocvu_mat_info` の下に:

```c
/*
 * 特徴点 1 つ。境界に出るので固定サイズ型だけで構成する。
 *
 * cv::KeyPoint をそのまま出すことはできない（C++ のクラスで、
 * layout の保証も無い）。**この struct の layout がこちら側の正本である。**
 * 実装 .cpp に static_assert を置いて大きさを固定してあり、
 * C# 側の OcvuKeyPoint とは L3 が Marshal.SizeOf で突き合わせる。
 *
 * x / y は画素座標、size は特徴点の直径、angle は度（見つからない場合は -1）、
 * response は応答の強さ、octave は検出したピラミッドの段、
 * class_id は分類の識別子（ORB は使わないので -1 になる）。
 */
typedef struct ocvu_keypoint {
    float   x;
    float   y;
    float   size;
    float   angle;
    float   response;
    int32_t octave;
    int32_t class_id;
} ocvu_keypoint;

/* ocvu_orb_detect の max_features の上限。
 * 呼ぶ側が過大な値を渡したときに native 側で確保しないための歯止めである。 */
#define OCVU_ORB_MAX_FEATURES 10000
```

- [ ] **Step 4: C# の struct を足す**

`Packages/.../Runtime/Interop/NativeMethods.cs` の `OcvuMatInfo` の隣に:

```csharp
    /// <summary>
    /// 特徴点 1 つ。native の ocvu_keypoint と layout を合わせる。
    /// </summary>
    /// <remarks>
    /// struct の layout は正本を native のヘッダ側に置いてある。
    /// 大きさが食い違うと marshalling だけが壊れるので、
    /// L3 の FeaturesTests が Marshal.SizeOf で突き合わせる。
    /// </remarks>
    [StructLayout(LayoutKind.Sequential)]
    internal struct OcvuKeyPoint
    {
        internal float X;
        internal float Y;
        internal float Size;
        internal float Angle;
        internal float Response;
        internal int Octave;
        internal int ClassId;
    }
```

- [ ] **Step 5: 型表に足す**

`bindings/generator/Ocvu.Generator/SpecModel.cs` の `AllowedCsTypes` に、
`ocvu_mat_info*` の下へ:

```csharp
            ["ocvu_keypoint*"] = new[] { "OcvuKeyPoint[]", "System.IntPtr" },
```

- [ ] **Step 6: GREEN を確認する**

```
pwsh tools/dev.ps1 test-managed
```

期待: 新しい 2 件を含めて全件 PASS。

- [ ] **Step 7: 型表の検査が効くことを確かめる（prove-a-check-works）**

足した行を一時的に消して `BothSpellingsOfAKeypointParamAreAccepted` が
落ちること、`AllowedCsTypes` の `"OcvuKeyPoint[]"` を `"byte[]"` に
書き換えて `AKeypointParamRejectsAnUnrelatedCsType` の側が変わることを
確認してから戻す。

- [ ] **Step 8: コミット**

```bash
git add native/include/opencv_unity_native.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.cs \
        bindings/generator/Ocvu.Generator/SpecModel.cs \
        bindings/generator/Ocvu.Generator.Tests/SpecSchemaTests.cs
git commit -m "feat(m5): ocvu_keypoint を境界に足し、generator の型表を広げる"
```

---

## Task 6: `ocvu_orb_detect` — features の spec と実装

**Files:**
- Create: `bindings/spec/features.json`
- Create: `native/src/ocvu_features.cpp`
- Create: `native/tests/test_features.cpp`
- Modify: `native/CMakeLists.txt`、`native/tests/CMakeLists.txt`
- Modify: `native/include/opencv_unity_native.h`（`#include "ocvu/features.h"`）

**Interfaces:**
- Consumes: Task 1 のリンク、Task 5 の `ocvu_keypoint`
- Produces: `ocvu_status ocvu_orb_detect(ocvu_mat_handle src, int32_t max_features, ocvu_keypoint* out_keypoints, int32_t capacity, int32_t* out_count)`

**形の根拠:** `ocvu_qr_decode` と違い、**呼ぶ側は必要量を事前に知り得る** ——
`max_features` が上限だからである。したがって 2 回呼びにせず、
「`capacity` が `max_features` に満たなければ `BUFFER_TOO_SMALL` を返し、
`out_count` に必要量（= `max_features`）を入れる」形にする。
**実際の運用では 1 回で済む。**

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_features.cpp` を新規作成:

```cpp
#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <vector>

namespace {

// ORB が特徴点を見つけられる、角のある画像を作る。
// 一様な画像では 0 件になるので、市松模様を書き込む。
ocvu_mat_handle MakeCheckerboard(int size, int cell) {
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(size, size, OCVU_MAT_TYPE_8UC1, &handle), OCVU_STATUS_OK);

    std::vector<uint8_t> pixels(static_cast<size_t>(size) * static_cast<size_t>(size), 0);
    for (int y = 0; y < size; ++y) {
        for (int x = 0; x < size; ++x) {
            const bool white = ((x / cell) + (y / cell)) % 2 == 0;
            pixels[static_cast<size_t>(y) * static_cast<size_t>(size) + static_cast<size_t>(x)] =
                white ? 255 : 0;
        }
    }
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(),
                                        static_cast<int64_t>(pixels.size()),
                                        static_cast<int64_t>(size)),
              OCVU_STATUS_OK);
    return handle;
}

}  // namespace

TEST(Features, DetectFindsKeypointsOnACheckerboard) {
    const ocvu_mat_handle img = MakeCheckerboard(128, 16);

    constexpr int32_t kMax = 64;
    std::vector<ocvu_keypoint> keypoints(kMax);
    int32_t count = 0;

    ASSERT_EQ(ocvu_orb_detect(img, kMax, keypoints.data(), kMax, &count), OCVU_STATUS_OK);
    EXPECT_GT(count, 0) << "市松模様には角がある";
    EXPECT_LE(count, kMax);

    // 見つかった分の座標が画像の中に収まっていること。
    for (int32_t i = 0; i < count; ++i) {
        EXPECT_GE(keypoints[static_cast<size_t>(i)].x, 0.0f);
        EXPECT_LE(keypoints[static_cast<size_t>(i)].x, 128.0f);
        EXPECT_GE(keypoints[static_cast<size_t>(i)].y, 0.0f);
        EXPECT_LE(keypoints[static_cast<size_t>(i)].y, 128.0f);
    }

    ocvu_mat_release(img);
}

TEST(Features, DetectRejectsATooSmallBufferWithoutWriting) {
    const ocvu_mat_handle img = MakeCheckerboard(128, 16);

    constexpr int32_t kMax = 64;
    // capacity を 1 つ足りなくして、0xAB で埋める。
    std::vector<ocvu_keypoint> keypoints(kMax);
    std::memset(keypoints.data(), 0xAB, keypoints.size() * sizeof(ocvu_keypoint));

    int32_t count = 999;
    EXPECT_EQ(ocvu_orb_detect(img, kMax, keypoints.data(), kMax - 1, &count),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(count, kMax) << "必要量を返すこと";

    const auto* bytes = reinterpret_cast<const uint8_t*>(keypoints.data());
    for (size_t i = 0; i < keypoints.size() * sizeof(ocvu_keypoint); ++i) {
        ASSERT_EQ(bytes[i], 0xAB) << "足りない buffer には何も書かないこと";
    }

    ocvu_mat_release(img);
}

TEST(Features, DetectRejectsInvalidArgumentsAndAlwaysWritesZero) {
    const ocvu_mat_handle img = MakeCheckerboard(64, 8);
    std::vector<ocvu_keypoint> keypoints(8);

    EXPECT_EQ(ocvu_orb_detect(img, 8, keypoints.data(), 8, nullptr), OCVU_STATUS_NULL_POINTER);

    // **0 以外で汚してから呼ぶ。**
    int32_t count = 4321;
    EXPECT_EQ(ocvu_orb_detect(img, 0, keypoints.data(), 8, &count), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    count = 4321;
    EXPECT_EQ(ocvu_orb_detect(img, OCVU_ORB_MAX_FEATURES + 1, keypoints.data(), 8, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    count = 4321;
    EXPECT_EQ(ocvu_orb_detect(OCVU_MAT_HANDLE_NONE, 8, keypoints.data(), 8, &count),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(count, 0);

    count = 4321;
    EXPECT_EQ(ocvu_orb_detect(img, 8, nullptr, 8, &count), OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(count, 0);

    count = 4321;
    EXPECT_EQ(ocvu_orb_detect(img, 8, keypoints.data(), -1, &count), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    ocvu_mat_release(img);
}

TEST(Features, TheKeypointStructHasTheLayoutTheAbiPromises) {
    // C# 側の OcvuKeyPoint と突き合わせる根拠になる。
    EXPECT_EQ(sizeof(ocvu_keypoint), 28u);
}
```

先頭に `#include <cstring>` と `#include <cstdint>` を足す。
`native/tests/CMakeLists.txt` に `test_features.cpp` を足す。

- [ ] **Step 2: RED を確認する**

```
pwsh tools/dev.ps1 test-native
```

期待: コンパイルエラー（`ocvu_orb_detect` が宣言されていない）。

- [ ] **Step 3: spec を書く**

`bindings/spec/features.json` を新規作成:

```json
{
  "module": "features",
  "functions": [
    {
      "name": "ocvu_orb_detect",
      "summary": "src から ORB の特徴点を検出して out_keypoints へ書き、見つかった個数を out_count に返す。呼ぶ側は必要量を事前に知り得るので 2 回呼ぶ必要は無い（上限は max_features で、capacity がそれに満たなければ何も書かずに OCVU_STATUS_BUFFER_TOO_SMALL を返し out_count に max_features を入れる）。max_features は 1 以上 OCVU_ORB_MAX_FEATURES 以下でなければならない。buffer の所有権は最初から最後まで呼ぶ側にある。",
      "returns": "ocvu_status",
      "csReturns": "int",
      "wrapInTryBarrier": true,
      "params": [
        { "name": "src", "cType": "ocvu_mat_handle", "csType": "ulong", "direction": "in" },
        { "name": "max_features", "cType": "int32_t", "csType": "int", "direction": "in" },
        { "name": "out_keypoints", "cType": "ocvu_keypoint*", "csType": "OcvuKeyPoint[]", "direction": "out-buffer" },
        { "name": "capacity", "cType": "int32_t", "csType": "int", "direction": "in" },
        { "name": "out_count", "cType": "int32_t*", "csType": "out int", "direction": "out" }
      ]
    }
  ]
}
```

```
pwsh tools/dev.ps1 generate
```

`native/include/opencv_unity_native.h` に `#include "ocvu/features.h"` を足す。

- [ ] **Step 4: 実装する**

`native/src/ocvu_features.cpp` を新規作成:

```cpp
#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/features.hpp>

#include <algorithm>
#include <cstdint>
#include <vector>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

// 境界に出る struct の大きさを固定する。C# の OcvuKeyPoint と食い違うと
// marshalling だけが壊れるので、写し間違いをコンパイル時に落とす。
static_assert(sizeof(ocvu_keypoint) == 28,
              "ocvu_keypoint の layout が変わった。C# の OcvuKeyPoint も直すこと");

extern "C" ocvu_status ocvu_orb_detect(ocvu_mat_handle src, int32_t max_features, ocvu_keypoint* out_keypoints, int32_t capacity, int32_t* out_count) {
    OCVU_TRY_BEGIN
    if (out_count == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_orb_detect: out_count is NULL");
    }
    // どの経路で返っても、呼ぶ側が読む値が前回の残りにならないようにする。
    *out_count = 0;

    if (max_features <= 0 || max_features > OCVU_ORB_MAX_FEATURES) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_orb_detect: max_features is out of range");
    }
    if (capacity < 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_orb_detect: capacity is negative");
    }
    if (capacity > 0 && out_keypoints == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_orb_detect: out_keypoints is NULL but capacity is positive");
    }

    cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_orb_detect: src handle is invalid");
    }
    if (src_mat->empty()) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_orb_detect: src is empty");
    }

    // **検出より先に容量を見る。** 足りないと分かっている呼び出しで
    // 検出まで走らせるのは無駄で、しかも「何も書かない」契約は
    // 書く前に返ることでしか守れない。
    if (capacity < max_features) {
        *out_count = max_features;
        return ::ocvu::set_last_error(OCVU_STATUS_BUFFER_TOO_SMALL,
                                      "ocvu_orb_detect: capacity is smaller than max_features");
    }

    std::vector<cv::KeyPoint> found;
    try {
        cv::Ptr<cv::ORB> orb = cv::ORB::create(max_features);
        orb->detect(*src_mat, found);
    } catch (const cv::Exception& e) {
        // OCVU_TRY_END でも捕まるが、そこでは UNKNOWN_ERROR になる。
        // OpenCV 由来だと分かる status を返すためにここで先に受ける。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    // ORB は nfeatures を超えないが、契約は自分でも守る。
    const int32_t n = static_cast<int32_t>(
        std::min<size_t>(found.size(), static_cast<size_t>(max_features)));
    for (int32_t i = 0; i < n; ++i) {
        const cv::KeyPoint& k = found[static_cast<size_t>(i)];
        ocvu_keypoint& out = out_keypoints[i];
        out.x        = k.pt.x;
        out.y        = k.pt.y;
        out.size     = k.size;
        out.angle    = k.angle;
        out.response = k.response;
        out.octave   = static_cast<int32_t>(k.octave);
        out.class_id = static_cast<int32_t>(k.class_id);
    }
    *out_count = n;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

`native/CMakeLists.txt` の `OCVU_SOURCES` に `src/ocvu_features.cpp` を足す。

- [ ] **Step 5: GREEN を確認する**

```
pwsh tools/dev.ps1 test-native
pwsh tools/dev.ps1 verify-generated
```

期待: `Features.*` の 4 件が PASS。`verify-generated` は
`==> 生成物は spec と一致しています（14 ファイル）` を出す
（10 → objdetect で 12 → features で 14）。

- [ ] **Step 6: ASan を回す**

```
pwsh tools/dev.ps1 test-asan
```

`out_keypoints[i]` への書き込みが `capacity` を越えていないことを見る。

- [ ] **Step 7: 境界検査が効くことを確かめる（prove-a-check-works）**

`if (capacity < max_features)` を `if (capacity < 0)` に**一時的に**弱めて、
`DetectRejectsATooSmallBufferWithoutWriting` が落ちることを見てから戻す。
**落ちなければ、そのテストは境界を見ていない。**

- [ ] **Step 8: コミット**

```bash
git add bindings/spec/features.json native/src/ocvu_features.cpp native/tests/test_features.cpp \
        native/CMakeLists.txt native/tests/CMakeLists.txt native/include/opencv_unity_native.h \
        native/include/ocvu/features.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Features.g.cs \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Features.g.cs.meta \
        tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs \
        docs/api-map.md
git commit -m "feat(m5): ocvu_orb_detect を spec から生成し実装する"
```

---

## Task 7: C# 公開 API と L3

**Files:**
- Create: `Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvQrCode.cs`（+ `.meta`）
- Create: `Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvFeatures.cs`（+ `.meta`）
- Create: `tests/Managed/CvUnity.Tests.Managed/ObjdetectTests.cs`
- Create: `tests/Managed/CvUnity.Tests.Managed/FeaturesTests.cs`

**Interfaces:**
- Consumes: Task 3〜6 の 3 本
- Produces: `CvQrCode.Encode(string, CvMat)` / `CvQrCode.Decode(CvMat)` / `CvFeatures.DetectOrb(CvMat, int)` と `CvKeyPoint`

**なぜ新しいクラスか:** `CvOps` は imgproc に範囲を限っており、
`CvCodecs` が imgcodecs を持っている。**1 つのクラスに全モジュールを詰めると、
この plugin がどの OpenCV モジュールをリンクしているかが C# 側から読み取れなくなる**
（`add-abi-function` skill）。

**`UnityEngine` を参照しない。** `Runtime/Core` は netstandard2.1 shim が
ビルドで強制している。

- [ ] **Step 1: 失敗する L3 テストを書く**

`tests/Managed/CvUnity.Tests.Managed/ObjdetectTests.cs`:

```csharp
using System;
using CvUnity;
using Xunit;

public class ObjdetectTests
{
    [Fact]
    public void EncodeThenDecodeRoundTripsTheText()
    {
        const string payload = "OpenCVUnityNative";

        using var img = CvMat.Create(1, 1, CvMatType.Gray8);
        CvQrCode.Encode(payload, img);
        Assert.Equal(img.Rows, img.Cols);

        Assert.Equal(payload, CvQrCode.Decode(img));
    }

    [Fact]
    public void DecodeReturnsNullWhenNoCodeIsPresent()
    {
        using var blank = CvMat.Create(64, 64, CvMatType.Gray8);
        Assert.Null(CvQrCode.Decode(blank));
    }

    [Fact]
    public void EncodeRejectsNullAndEmptyText()
    {
        using var img = CvMat.Create(1, 1, CvMatType.Gray8);
        Assert.Throws<ArgumentNullException>(() => CvQrCode.Encode(null, img));
        Assert.Throws<ArgumentException>(() => CvQrCode.Encode("", img));
    }
}
```

`tests/Managed/CvUnity.Tests.Managed/FeaturesTests.cs`:

```csharp
using System;
using System.Runtime.InteropServices;
using CvUnity;
using CvUnity.Interop;
using Xunit;

public class FeaturesTests
{
    [Fact]
    public void TheKeypointStructMatchesTheNativeLayout()
    {
        // native 側は static_assert(sizeof(ocvu_keypoint) == 28) で固定している。
        // 食い違うと marshalling だけが壊れるので、両側から挟む。
        Assert.Equal(28, Marshal.SizeOf<OcvuKeyPoint>());
    }

    [Fact]
    public void DetectOrbFindsKeypointsOnACheckerboard()
    {
        using var img = MakeCheckerboard(128, 16);

        CvKeyPoint[] keypoints = CvFeatures.DetectOrb(img, 64);

        Assert.NotEmpty(keypoints);
        Assert.True(keypoints.Length <= 64);
        Assert.All(keypoints, k =>
        {
            Assert.InRange(k.X, 0f, 128f);
            Assert.InRange(k.Y, 0f, 128f);
        });
    }

    [Fact]
    public void DetectOrbRejectsAnOutOfRangeMaxFeatures()
    {
        using var img = MakeCheckerboard(64, 8);
        Assert.Throws<ArgumentOutOfRangeException>(() => CvFeatures.DetectOrb(img, 0));
    }

    private static CvMat MakeCheckerboard(int size, int cell)
    {
        var mat = CvMat.Create(size, size, CvMatType.Gray8);
        var pixels = new byte[size * size];
        for (int y = 0; y < size; y++)
        {
            for (int x = 0; x < size; x++)
            {
                pixels[y * size + x] = ((x / cell) + (y / cell)) % 2 == 0 ? (byte)255 : (byte)0;
            }
        }
        mat.CopyFrom(pixels, size);
        return mat;
    }
}
```

**上の名前はこの計画を書くときに実物から確かめてある**（2026-09-01）:
`CvMat` は `new` ではなく **`CvMat.Create(rows, cols, type)`**、
enum の値は `Gray8` / `Bgr24` / `Bgra32`（`Cv8UC1` ではない）、
buffer の転送は **`CopyFrom(byte[], long stride)`** である。
**それでも食い違ったら、既存のコードが正しい。**

- [ ] **Step 2: RED を確認する**

```
pwsh tools/dev.ps1 test-managed
```

期待: コンパイルエラー（`CvQrCode` / `CvFeatures` / `CvKeyPoint` が無い）。

- [ ] **Step 3: `CvQrCode` を書く**

`Packages/.../Runtime/Core/CvQrCode.cs`:

```csharp
using System;
using System.Text;
using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>
    /// QR コードの符号化と復号（OpenCV の objdetect）。
    /// </summary>
    /// <remarks>
    /// **CvOps に入れていない。** あちらは imgproc の範囲である。
    /// クラスを分けてあるので、この plugin がどの OpenCV モジュールを
    /// リンクしているかが C# 側から読み取れる。
    /// </remarks>
    public static class CvQrCode
    {
        /// <summary>
        /// text を QR コードの画像に符号化して dst に入れる。
        /// </summary>
        public static void Encode(string text, CvMat dst)
        {
            if (text == null) throw new ArgumentNullException(nameof(text));
            if (text.Length == 0)
                throw new ArgumentException("text は空にできません。", nameof(text));
            if (dst == null) throw new ArgumentNullException(nameof(dst));

            // **文字列は自分で UTF-8 の NUL 終端 byte 列にする。**
            // string のまま marshaller に任せると、境界の文字コード変換が
            // 既定の CharSet に依存する（Mono と IL2CPP で違い得る）。
            var status = (CvStatus)NativeMethods.ocvu_qr_encode(
                ToNulTerminatedUtf8(text), dst.Handle);
            CvNative.ThrowIfFailed(status);
        }

        /// <summary>
        /// src に写っている QR コードを 1 つ復号する。写っていなければ null を返す。
        /// </summary>
        public static string Decode(CvMat src)
        {
            if (src == null) throw new ArgumentNullException(nameof(src));

            // 1 回目: 必要な大きさを問い合わせる。
            var probe = (CvStatus)NativeMethods.ocvu_qr_decode(
                src.Handle, null, 0, out int required);

            // **写っていないのは失敗ではない。** 呼ぶ側には null で返す。
            if (probe == CvStatus.NotFound) { return null; }

            // **BufferTooSmall だけを通す。** それ以外はここで投げる ——
            // 無効な handle も空の画像もこの段で判明するので、
            // null を返して呼ぶ側に気づかせない形にしない。
            if (probe != CvStatus.BufferTooSmall)
            {
                CvNative.ThrowIfFailed(probe);
                // 失敗でも BufferTooSmall でもない = 長さ 0 の復号。
                // ありえないが、黙って空文字列を返すと呼ぶ側が気づけない。
                throw new CvNativeException(
                    CvStatus.UnknownError,
                    "ocvu_qr_decode reported success for a size query");
            }

            var buffer = new byte[required];
            var status = (CvStatus)NativeMethods.ocvu_qr_decode(
                src.Handle, buffer, required, out var written);
            CvNative.ThrowIfFailed(status);

            // 2 回目で足りなくなるのは、1 回目との間に src が変わった場合である。
            // native は 1 バイトも書いていないので、ここで見ないと
            // **呼ぶ側は例外も無しに全部 0 の byte 列を受け取る**（CvCodecs と同じ形）。
            if (status != CvStatus.Ok || written != required)
            {
                throw new CvNativeException(status,
                    $"ocvu_qr_decode wrote {written} of {required} bytes " +
                    "(the source Mat likely changed between the size query and the read)");
            }

            // 末尾の NUL を落とす。
            return Encoding.UTF8.GetString(buffer, 0, required - 1);
        }

        private static byte[] ToNulTerminatedUtf8(string value)
        {
            int count = Encoding.UTF8.GetByteCount(value);
            var bytes = new byte[count + 1];
            Encoding.UTF8.GetBytes(value, 0, value.Length, bytes, 0);
            bytes[count] = 0;
            return bytes;
        }
    }
}
```

**`CvStatus` は型付きの enum である。** `int` のまま比べず、
`(CvStatus)NativeMethods.xxx(...)` と受けてから使う ——
`CvNative.ThrowIfFailed` が取るのも `CvStatus` である。
2 回呼びを隠す形の参照実装は `Runtime/Core/CvCodecs.cs` の `Encode` にある
（1 回目の扱い・2 回目の書き込み量の検査まで、上のコードはそこに揃えてある）。

- [ ] **Step 4: `CvFeatures` と `CvKeyPoint` を書く**

`Packages/.../Runtime/Core/CvFeatures.cs`:

```csharp
using System;
using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>
    /// 特徴点 1 つ。native の ocvu_keypoint に対応する読み取り専用の値。
    /// </summary>
    public readonly struct CvKeyPoint
    {
        public float X { get; }
        public float Y { get; }
        public float Size { get; }
        public float Angle { get; }
        public float Response { get; }
        public int Octave { get; }
        public int ClassId { get; }

        internal CvKeyPoint(float x, float y, float size, float angle,
                            float response, int octave, int classId)
        {
            X = x; Y = y; Size = size; Angle = angle;
            Response = response; Octave = octave; ClassId = classId;
        }
    }

    /// <summary>
    /// 特徴点の検出（OpenCV の features）。
    /// </summary>
    public static class CvFeatures
    {
        /// <summary>
        /// src から ORB の特徴点を最大 maxFeatures 個検出する。
        /// </summary>
        public static CvKeyPoint[] DetectOrb(CvMat src, int maxFeatures)
        {
            if (src == null) throw new ArgumentNullException(nameof(src));
            if (maxFeatures <= 0 || maxFeatures > 10000)
                throw new ArgumentOutOfRangeException(
                    nameof(maxFeatures), maxFeatures,
                    "maxFeatures は 1 以上 10000 以下でなければなりません。");

            // 必要量は maxFeatures と分かっているので 1 回で済む。
            var raw = new OcvuKeyPoint[maxFeatures];
            var status = (CvStatus)NativeMethods.ocvu_orb_detect(
                src.Handle, maxFeatures, raw, maxFeatures, out int count);
            CvNative.ThrowIfFailed(status);

            var result = new CvKeyPoint[count];
            for (int i = 0; i < count; i++)
            {
                result[i] = new CvKeyPoint(
                    raw[i].X, raw[i].Y, raw[i].Size, raw[i].Angle,
                    raw[i].Response, raw[i].Octave, raw[i].ClassId);
            }
            return result;
        }
    }
}
```

**`10000` を 2 箇所に書いている**（C の `OCVU_ORB_MAX_FEATURES` と
ここ）。**これは意図的な複製ではない** —— C# 側から C の `#define` は
読めないので、**L3 のテストで両者が一致することを見る**か、
上限を C 側に問う関数を足すかのどちらかが要る。
**この計画では前者を採る**（Step 5 のテストがそれである）。

- [ ] **Step 5: 上限の複製を検査で挟む**

`FeaturesTests.cs` に追記:

```csharp
    [Fact]
    public void TheManagedUpperBoundMatchesWhatNativeAccepts()
    {
        // CvFeatures の 10000 は C の OCVU_ORB_MAX_FEATURES の写しである。
        // **写しなので、放っておくと片方だけ変わる。** 境界の両側を native に問う。
        using var img = CvMat.Create(8, 8, CvMatType.Gray8);

        var raw = new OcvuKeyPoint[1];

        // 10000 は受理される（capacity 不足で BufferTooSmall になるが、
        // max_features の検証は通っている）。
        var atTheLimit = (CvStatus)NativeMethods.ocvu_orb_detect(img.Handle, 10000, raw, 1, out _);
        Assert.Equal(CvStatus.BufferTooSmall, atTheLimit);

        // 10001 は max_features の検証で弾かれる。
        var overTheLimit = (CvStatus)NativeMethods.ocvu_orb_detect(img.Handle, 10001, raw, 1, out _);
        Assert.Equal(CvStatus.InvalidArgument, overTheLimit);
    }
```

- [ ] **Step 6: GREEN を確認する**

```
pwsh tools/dev.ps1 test-managed
```

期待: 新しい 7 件を含めて全件 PASS。

- [ ] **Step 7: `.meta` を確認する**

新しい `.cs` 2 つに `.meta` が要る。**Unity を 1 回起動すると作られる**が、
起動しないなら既存の `.meta` を写して GUID だけ変える。

```
pwsh tools/dev.ps1 test-unity-editmode
git status --short   # .meta が 2 つ増えているはず
```

- [ ] **Step 8: 全レーンを回す**

```
pwsh tools/dev.ps1 test
```

期待: exit 0。`verify-generated` が **14 ファイル**で一致し、L1 と L3 が緑。
（10 → objdetect で 12 → features で 14。ヘッダと P/Invoke が module ごとに 1 つずつ増える。）

- [ ] **Step 9: コミット**

```bash
git add Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvQrCode.cs \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvQrCode.cs.meta \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvFeatures.cs \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvFeatures.cs.meta \
        tests/Managed/CvUnity.Tests.Managed/ObjdetectTests.cs \
        tests/Managed/CvUnity.Tests.Managed/FeaturesTests.cs
git commit -m "feat(m5): CvQrCode / CvFeatures を足し、L3 で境界を挟む"
```

---

## Task 8: 文書・notice・Unity レーン

**Files:**
- Modify: `docs/abi-ownership-and-versioning.md`（§3 allowlist）
- Modify: `docs/api-reference.md`
- Modify: `docs/roadmap.md`（M5 の判定）
- Modify: `CLAUDE.md`
- Verify: `THIRD_PARTY_NOTICES.md`

**Interfaces:**
- Consumes: Task 1〜7 のすべて
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

期待: EditMode が 34 → 34 のまま（到達性テストは 1 件で、
中で呼ぶ宣言が 22 → 25 に増える）、Standalone も同様。
**IL2CPP の stripping を越えて 3 本の新しい P/Invoke が解決すること**が、
このタスクで最も重要な確認である。

**落ちたら:** `EntryPointNotFoundException` は spec と実装の名前の食い違い。
`ocvu_qr_encode` などが `.cpp` に無いか、綴りが違う。

- [ ] **Step 2: allowlist を直す**

`docs/abi-ownership-and-versioning.md` §3 の冒頭にある
「現在の allowlist は §3.5 を含めて **11 本**である」を **14 本**に直し、
新しい節を足して 3 本を表に載せる。**この節は「何を出すと決めたか」の正本**
であって「いま何が出ているか」の一覧ではないので、`api-map.md` と役割が違う。

`OCVU_STATUS_NOT_FOUND` を足したことを §2 の「bump しない変更」の実例として
1 行書く（**足したこと自体が bump しない変更の 2 例目である**）。

- [ ] **Step 3: `docs/api-reference.md` に C# API を書く**

`CvCodecs` の節に揃えて、`CvQrCode` と `CvFeatures` と `CvKeyPoint` を足す。
**冒頭の対象範囲（「M2 で公開した C ABI の N 関数」のような数え）と、
末尾の「まだ無い機能」の一覧が同時に古くなる** —— QR や特徴点検出が
「まだ無い」側に残っていないか必ず見る。

- [ ] **Step 4: `docs/roadmap.md` の M5 判定を直す**

条件 2 の行を「閉じていない」から**「部分的に満たした」**に変え、
根拠を書く:

- `objdetect` / `features` を出した（QR の符号化・復号、ORB の検出）
- **`geometry` は出していないが、リンクは安い**（既にビルド済み。この計画で分かった）
- **`calib` だけが高い**（`Modules` に無く、足すと構成ハッシュが変わって
  5 platform 分の OpenCV を作り直す。実測値 `4785d98e9aad` → `a197bbcbdaf5`）
- **「`geometry` はビルドされていない」と書いていたなら、それは誤りだったと明記する**

- [ ] **Step 5: `CLAUDE.md` を直す**

次を確認して直す:

- 「リポジトリの現状」の M5 の段に objdetect / features を足したことを書く
- **公開 ABI の内訳の段**（`ocvu_imencode` などを列挙している箇所）に 3 本足す
- `cmake/FindOpenCvUnityDeps.cmake` の行の `COMPONENTS`（`core imgproc imgcodecs`
  → 5 つ）
- `bindings/spec/*.json` の行の module 名（4 → 6）
- `native/include/ocvu/{...}.h` の行の module 名（4 → 6）
- `dev.ps1 generate` の行の「**10 ファイル**」→ **14 ファイル**
- `dev.ps1 test-managed` の行の件数（**件数を書いてあるのはこの行だけである**）
- `dev.ps1 test-native` の行の GoogleTest 件数（64 → 実測値）

**数えている数を全部洗う。** `grep -rn` で数字ごと探す。

- [ ] **Step 6: notice の分類が変わっていないか確かめる**

`objdetect` / `features` をリンクしたことで、bundle された third-party の
**「リンクされている / されていない」の分類が動く可能性がある。**

```
pwsh tools/dev.ps1 test-tools-slow
```

`PackageRelease.Tests.ps1` が実物の artifact から notice を作り直すので、
**そこが緑なら分類は自動で追従している。** `THIRD_PARTY_NOTICES.md` の
「Present in `etc/licenses/` but not linked into this build」の節を開き、
`dlpack` と `flatbuffers` がまだそちら側にあることを目で確認する。

**動いていたら文書を直す。** `annoylib` / `MSCR chi_table` / `Rubik font` は
既に「リンクされている」側にあるので、おそらく変わらない ——
**しかし「おそらく」で済ませない。**

- [ ] **Step 7: 全レーンを回して数字を取り直す**

```
pwsh tools/dev.ps1 test
pwsh tools/dev.ps1 test-asan
```

`CLAUDE.md` の表に書いてある所要時間と乖離していたら、そちらも直す。

- [ ] **Step 8: コミット**

```bash
git add docs/abi-ownership-and-versioning.md docs/api-reference.md docs/roadmap.md CLAUDE.md
git commit -m "docs(m5): objdetect / features を足したことを判定と文書に反映する"
```

---

## PR を出す前に（`CLAUDE.md` の「変更を main へ入れるまで」）

1. **ローカルで全レーンを回す** — `test` / `test-asan` / `test-unity-editmode` / `test-unity-player`
2. **AI レビューをここで行う。** **この差分を書いていない別のエージェント**に、
   ブランチ全体の差分・M5 の完了条件・このリポジトリの不変条件を渡す。
   **何を指摘してほしくないかを事前に伝えない。**
3. 指摘を直し、**修正差分をスコープを絞って再レビューする**
4. push して PR を作る。本文に**実測値**と**意図的に見送ったもの**（`geometry` /
   `calib` / aruco / SIFT / descriptor）を書く。**穴があるなら隠さず書く**
5. **CI が全パスしたらマージする**

---

## この計画が意図的に決めていること

| 決定 | 理由 | 間違っていた場合のコスト |
| --- | --- | --- |
| `ocvu_qr_encode` を出す | decode のテストが**自己完結する**（fixture 画像を置かない） | ABI が 1 本増える。使わない人には無駄 |
| `NOT_FOUND` を新設する | `OK` + 長さ 0 だと「空文字列の QR」と区別できない | status が 1 つ増える（bump はしない） |
| ORB を 1 回呼びにする | 必要量が `max_features` で**事前に分かる** | 呼ぶ側が常に `max_features` 分を確保する |
| 上限 10000 を C と C# に**二重に書く** | C# から C の `#define` は読めない | 片方だけ変わりうる → **L3 が両側を native に問う**（Task 7 Step 5） |
| `geometry` を出さない | リンクは安いが、出す API の設計が別に要る | 条件 2 が閉じない（**閉じない、と判定に書く**） |
| `calib` を出さない | 構成ハッシュが変わり 5 platform の再ビルドになる | 同上 |
