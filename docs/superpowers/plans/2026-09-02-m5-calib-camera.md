# カメラ校正（`cv::calibrateCamera`）実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `calib` module を足し、`cv::calibrateCamera` を C ABI と C# に出して**カメラ校正の輪を閉じる**。M5 完了条件 2 の最後の 1 つ。

**Architecture:** 既存の 2 本（`ocvu_find_chessboard_corners` で格子点を見つけ、`ocvu_undistort` で補正する）の間に欠けていた「係数を求める」段を足す。実装は既存の `native/src/ocvu_calibration.cpp` に同居させる —— 用途が 1 つだからである。**姿勢（各画像の回転・並進）も返す。**

**Tech Stack:** C++17 / OpenCV 5.0.0 `calib` module / netstandard2.1 C# / `bindings/spec` からの生成

**Spec:** `docs/roadmap.md` の M5 節（完了条件 2）と `docs/abi-ownership-and-versioning.md` §3

## Global Constraints

- **`ocvu_` の宣言を手で書かない。** `bindings/spec/*.json` に 1 エントリ書いて `./tools/dev.ps1 generate` を実行するのが、関数を足す唯一の経路である。手で足すと `dev.ps1 verify-generated` が落とす。
- **in-buffer の `*_length` は必ずバイト数**（`ocvu_find_homography` / `ocvu_undistort` と同じ）。**out-buffer の `capacity` は必ず配列の要素数**（`ocvu_orb_detect` / `ocvu_find_chessboard_corners` と同じ）。**この 2 つを取り違えると、検査がゆるい側に外れる。**
- **`cv::Exception` を個別に catch する。** `OCVU_TRY_END` は `std::exception` を `OCVU_STATUS_UNKNOWN_ERROR` に落とすので、OpenCV の失敗が「原因不明」になる。
- **呼ぶ側を信用しない。** NULL・長さ・容量・値域を、何かを読む前に検証する。**失敗したときは出力を 1 バイトも書き換えない。**
- **整数の乗算は `int64_t` で行い、上限定数で歯止めをかける**（`OCVU_CHESSBOARD_MAX_CORNERS` が先例）。符号付き整数の乗算オーバーフローは未定義動作である。
- **`Runtime/Core` と `Runtime/Interop` は `UnityEngine` を参照しない。**
- **本数を数えるのは `docs/api-map.md` の冒頭だけ。** 他所に数字を写さない。
- **検査を足したら壊して落ちることを見る**（`prove-a-check-works`）。**修正の側にも同じ手順を当てる** —— 直前の計画では、指摘に対する修正が 3 回同じ穴を持っていた。

---

## この計画の前提（着手前に必ず読む）

**`calib` module は既に足してある**（`f60b27d`）。構成ハッシュは
`4785d98e9aad` → **`09fcbe260d87`** に変わり、**5 platform 分の OpenCV が
作り直されている。** artifact が出るまでローカルでは何もビルドできない。

**Task 1 に入る前に `./tools/opencv.ps1 restore` が成功することを確かめること。**
失敗するなら CI がまだ artifact を出していない。**待つ。**

**`calib` は新しい推移的依存を引くかもしれない。** 依存 allowlist は
`config.Modules` から作られるので `calib` 自身は自動で許可されるが、
`calib` が引く別の module（`3d` / `stereo` など）は
`tools/verify-opencv-artifact.ps1` の `$AcceptedTransitiveModules`
（現在 `flann` と `geometry` だけ）に無いので**落ちる。**
**落ちたら、その module が何かを確かめ、レビューしてから足す。黙って通さない。**

---

## ファイル配置

| ファイル | 役割 |
| --- | --- |
| `cmake/FindOpenCvUnityDeps.cmake` | `COMPONENTS` に `calib` を足す（Task 1） |
| `tools/verify-opencv-artifact.ps1` | 新しい推移的依存が出たときだけ触る（Task 1） |
| `native/tests/test_module_linkage.cpp` | `calib` がリンクされていることを固定する（Task 1） |
| `bindings/generator/Ocvu.Generator/SpecModel.cs` | 型表に `double*` を足す（Task 2） |
| `bindings/generator/Ocvu.Generator.Tests/SpecSchemaTests.cs` | その負のテスト（Task 2） |
| `bindings/spec/calib.json` | **新設。** `ocvu_calibrate_camera` の正本（Task 3） |
| `native/include/opencv_unity_native.h` | 上限定数 `OCVU_CALIB_MAX_POINTS`（手書き。Task 3） |
| `native/src/ocvu_calibration.cpp` | 実装を既存ファイルに足す（Task 3） |
| `native/tests/test_calibration.cpp` | L1（Task 3） |
| `Packages/.../Runtime/Core/CvCalibration.cs` | C# 公開 API（Task 4） |
| `tests/Managed/CvUnity.Tests.Managed/CalibrationTests.cs` | L3（Task 4） |
| `docs/*` / `CLAUDE.md` | 判定と文書（Task 5） |

**生成物（手で編集しない）**: `native/include/ocvu/calib.h`、`Packages/.../Runtime/Interop/NativeMethods.Calib.g.cs`、`docs/api-map.md`、`tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs`。**module を新設するので生成物は 16 → 18 ファイルに増える。**

## ABI の形（Task 3 で spec に書く正確な値）

```c
ocvu_status ocvu_calibrate_camera(
    const float* object_points,          /* 3 floats/point、view-major */
    int64_t      object_points_length,   /* **バイト数** */
    const float* image_points,           /* 2 floats/point、view-major */
    int64_t      image_points_length,    /* **バイト数** */
    int32_t      view_count,
    int32_t      points_per_view,
    int32_t      image_width,
    int32_t      image_height,
    double*      out_camera_matrix,
    int32_t      camera_matrix_capacity, /* **要素数**。9 以上 */
    double*      out_dist_coeffs,
    int32_t      dist_coeffs_capacity,   /* **要素数** */
    int32_t*     out_dist_coeffs_count,
    double*      out_view_poses,
    int32_t      view_poses_capacity,    /* **要素数**。view_count * 6 以上 */
    double*      out_rms);
```

**`out_view_poses` は 1 view につき 6 個の double である**（回転ベクトル 3 個のあと並進ベクトル 3 個）。rvec と tvec を別々の buffer にすると引数が 2 本増えるので、点列を平坦化するのと同じ作法で 1 本にまとめる。**この並びは spec の `summary` に書く** —— 呼ぶ側が復号できなければ意味がない。

---

## Task 1: `calib` をリンクし、それを実証する

**Files:**
- Modify: `cmake/FindOpenCvUnityDeps.cmake:84`
- Modify: `native/tests/test_module_linkage.cpp`
- Modify（必要なときだけ）: `tools/verify-opencv-artifact.ps1`

**Interfaces:**
- Consumes: `third_party/opencv/09fcbe260d87/`（restore 済み）
- Produces: `calib` がリンク行に入った状態

- [ ] **Step 1: OpenCV を取得する**

```
pwsh ./tools/opencv.ps1 restore
pwsh ./tools/opencv.ps1 verify
```

`verify` が**未知の module で落ちたら、そこで止まる。** 落ちた module 名を報告し、
`$AcceptedTransitiveModules` に足してよいかを裁定してもらう。**黙って足さない。**

- [ ] **Step 2: 失敗するテストを書く**

`native/tests/test_module_linkage.cpp` に足す。**このファイルは「どの module が
実際にリンクされているか」を実物で固定する場所である。**

```cpp
TEST(ModuleLinkage, CalibIsLinked) {
    // **cv::calibrateCamera は calib module にしか無い。**
    // COMPONENTS に calib が無ければ、これは未解決の外部シンボルで
    // リンクに失敗する —— **コンパイルは通る。** リンクだけが落ちる。
    std::vector<std::vector<cv::Point3f>> object_points(1);
    std::vector<std::vector<cv::Point2f>> image_points(1);
    for (int i = 0; i < 4; ++i) {
        object_points[0].emplace_back(static_cast<float>(i), 0.0f, 0.0f);
        image_points[0].emplace_back(static_cast<float>(i), 0.0f);
    }
    cv::Mat camera_matrix;
    cv::Mat dist_coeffs;
    std::vector<cv::Mat> rvecs;
    std::vector<cv::Mat> tvecs;

    // 点が足りないので OpenCV は例外を投げる。**それでよい** ——
    // ここが見ているのは「シンボルが解決するか」だけである。
    EXPECT_THROW(
        cv::calibrateCamera(object_points, image_points, cv::Size(64, 64),
                            camera_matrix, dist_coeffs, rvecs, tvecs),
        cv::Exception);
}
```

**include も足す。** OpenCV 5 で校正の宣言がどのヘッダに在るかは
**実物を見て確かめること**（`third_party/opencv/09fcbe260d87/` の下を
`grep -rl calibrateCamera` する）。**推測で書かない。**

- [ ] **Step 3: RED を確認する** —— **リンクエラーであることを見る**

```
pwsh ./tools/dev.ps1 build
```

期待: `cv::calibrateCamera` が**未解決の外部シンボル**で失敗する。
**コンパイルエラーではない。**

**これが RED にならなかったら、そこで止まって報告すること。**
`geometry` のときは `COMPONENTS` に足す前から推移的にリンクされており、
**RED にならなかった。** `calib` も同じ可能性がある —— その場合
「`COMPONENTS` に足しても binary は 1 バイトも増えない」ことになるので、
**足す/足さないの判断が変わる。**

- [ ] **Step 4: `COMPONENTS` に `calib` を足す**

```cmake
    COMPONENTS core imgproc imgcodecs objdetect features geometry calib
```

- [ ] **Step 5: GREEN を確認し、binary の大きさを実測する**

```
pwsh ./tools/dev.ps1 test-native
```

**足す前と後の plugin のバイト数を両方記録する。**
`Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/` の下の binary を見る。
**「COMPONENTS に足すだけでは binary は増えない」**（静的リンクは参照された
object しか引かない）ことが M3.5 で分かっているので、**この時点では増えないのが
正しい。** 増えるのは Task 3 で関数を書いたときである。

- [ ] **Step 6: コミット**

```bash
git add cmake/FindOpenCvUnityDeps.cmake native/tests/test_module_linkage.cpp
git commit -m "build(m5): calib module をリンクし、実物で固定する"
```

---

## Task 2: 生成器の型表に `double*` を足す

**Files:**
- Modify: `bindings/generator/Ocvu.Generator/SpecModel.cs`（`int32_t*` / `float*` の隣）
- Modify: `bindings/generator/Ocvu.Generator.Tests/SpecSchemaTests.cs`

**Interfaces:**
- Produces: spec で `double*` を `out-buffer` / `out` に使えるようになる

**現状**: 型表は `int32_t*` → `out int`、`float*` → `float[]` / `IntPtr` を持つが、
**`double*`（const 無し）を持たない。** `ocvu_calibrate_camera` は
`double*` の出力を 4 つ使う（カメラ行列・歪み係数・姿勢・再投影誤差）。

- [ ] **Step 1: 失敗するテストを書く**

`SpecSchemaTests.cs` に足す。**`float*` を足したときと同じ形にする** ——
そのテストを先に読み、**隣に同じ書き方で置く。**

```csharp
[Fact]
public void ADoublePointerIsAcceptedForOutBuffersAndOutScalars()
{
    // ocvu_calibrate_camera は double* の出力を 4 つ使う。
    // **const 無しの double* を型表が知らなければ、spec を書いた瞬間に落ちる。**
    // （実際のヘルパ名は SpecModel.cs を読んで合わせること）
    Assert.True(SpecModel.IsKnownCType("double*"));
    Assert.Contains("double[]", SpecModel.CsTypesFor("double*"));
    Assert.Contains("out double", SpecModel.CsTypesFor("double*"));
}
```

- [ ] **Step 2: RED を確認する**

```
pwsh ./tools/dev.ps1 test-managed
```

- [ ] **Step 3: 型表に足す**

```csharp
["double*"] = new[] { "double[]", "out double", "System.IntPtr" },
```

- [ ] **Step 4: GREEN を確認する**

```
pwsh ./tools/dev.ps1 test-managed
```

- [ ] **Step 5: 壊して落ちることを見る**

**足した行を消して、Step 1 のテストが落ちることを確かめてから戻す。**
`prove-a-check-works` の手順である。**「入れた」で終わらせない。**

- [ ] **Step 6: コミット**

```bash
git add bindings/generator/Ocvu.Generator/SpecModel.cs bindings/generator/Ocvu.Generator.Tests/SpecSchemaTests.cs
git commit -m "feat(m5): 生成器の型表に double* を足す"
```

---

## Task 3: `ocvu_calibrate_camera` を C ABI に出す

**Files:**
- Create: `bindings/spec/calib.json`
- Modify: `native/include/opencv_unity_native.h`（`OCVU_CALIB_MAX_POINTS`）
- Modify: `native/src/ocvu_calibration.cpp`
- Modify: `native/tests/test_calibration.cpp`

**Interfaces:**
- Consumes: Task 1 の `calib` リンク、Task 2 の `double*`
- Produces: 上の「ABI の形」のシグネチャ

- [ ] **Step 1: 上限定数を足す**

`native/include/opencv_unity_native.h` の `OCVU_CHESSBOARD_MAX_CORNERS` の隣に:

```c
/* 1 回の校正で受け付ける点の総数の上限（view_count * points_per_view）。
   int32 の乗算オーバーフローを避けるための歯止めである。
   実用上の校正がこれを超えることは無い（20 枚 x 大きめの盤でも 1 万点に届かない）。 */
#define OCVU_CALIB_MAX_POINTS 100000
```

- [ ] **Step 2: spec を書く**

`bindings/spec/calib.json` を新設する。`summary` には**次を全部書く**
（`ocvu_find_chessboard_corners` の summary が水準の見本である）:

- `object_points` は 1 点 3 float、`image_points` は 1 点 2 float で、**どちらも view-major**（1 枚目の全点 → 2 枚目の全点 …）
- `object_points_length` と `image_points_length` は**バイト数**（要素数でも点数でもない）
- `camera_matrix_capacity` / `dist_coeffs_capacity` / `view_poses_capacity` は**要素数**
- `out_view_poses` は **1 view につき 6 個**（回転 3 個のあと並進 3 個）
- `view_count` は 2 以上、`points_per_view` は 4 以上
- `view_count * points_per_view` が `OCVU_CALIB_MAX_POINTS` を超えたら `OCVU_STATUS_INVALID_ARGUMENT`
- 容量が足りなければ**何も書かずに** `OCVU_STATUS_BUFFER_TOO_SMALL` を返す
- **どの失敗経路でも `out_dist_coeffs_count` に 0 を書く**
- 出力の所有権は最初から最後まで呼ぶ側にある

**未検証の挙動を書かない。** 実装がしないことを summary に書くと、
**それを見る機械は存在しない。**

- [ ] **Step 3: 生成して RED を確認する**

```
pwsh ./tools/dev.ps1 generate
pwsh ./tools/dev.ps1 build
```

期待: `ocvu_calibrate_camera` の実装が無いのでリンクに失敗する。
**生成物は 16 → 18 ファイルになる**（`ocvu/calib.h` と `NativeMethods.Calib.g.cs`）。

- [ ] **Step 4: L1 テストを書く**

`native/tests/test_calibration.cpp` に足す。**最低でも次を見る**:

1. **合成した校正で係数が求まる。** 既知のカメラ行列で 3D の格子点を投影して
   複数 view 分の画像点を作り、**元の焦点距離が誤差の範囲で戻る**ことを見る。
   **「status が OK」だけを見ない** —— それでは「何も計算せず OK を返す」
   退化実装が通る。
2. **姿勢が view の数だけ返る。** `out_view_poses` の先頭 `view_count * 6` 個が
   書かれ、**それより後ろは触られていない**（番兵を置いて確かめる）。
3. **容量が足りなければ何も書かない。** 3 つの容量それぞれについて見る。
4. **NULL・view_count < 2・points_per_view < 4・長さ不足・上限超えを断る**、
   そして**どの経路でも `out_dist_coeffs_count` が 0 になる**。
5. **上限を超える `view_count * points_per_view` が、未定義動作ではなく
   `INVALID_ARGUMENT` になる**（`int64_t` で計算していることの証拠）。

**入力を恒等にしない。** 歪み係数を 0 にした合成データだと、
「歪みを推定しない実装」でも通る。**0 でない歪みを入れて作る。**

- [ ] **Step 5: 実装する**

`native/src/ocvu_calibration.cpp` に足す。**検証を全部済ませてから 1 バイトも読まない。**
順序: NULL → 値域（`view_count` / `points_per_view` / 画像サイズ）→ 上限
（`int64_t` で計算）→ 長さ（バイト数）→ 容量（要素数）→ 変換 → 呼び出し。

`cv::calibrateCamera` は `cv::Exception` を投げうるので**個別に catch する**:

```cpp
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }
```

- [ ] **Step 6: GREEN を確認する**

```
pwsh ./tools/dev.ps1 test-native
pwsh ./tools/dev.ps1 test-asan
```

- [ ] **Step 7: 壊して落ちることを見る（最低 3 通り）**

**それぞれについて、変異を当てて落ちるテスト名を記録し、手で戻すこと。**

1. 容量の検査（`view_poses_capacity < view_count * 6`）を消す
2. `out_dist_coeffs_count` の 0 初期化を消す
3. **姿勢の並びを入れ替える**（rvec と tvec を逆に書く）—— これが落ちないなら、
   summary が書いている並びを誰も見ていない

**3 が落ちないまま進めない。** 直前の計画では、これと同じ形（「x と y が
交互」を誰も見ていない）が**実測で 2 度素通りした。**

- [ ] **Step 8: binary の大きさを実測して記録する**

Task 1 Step 5 で測った値と比べる。**ここで初めて増えるはずである。**

- [ ] **Step 9: コミット**

```bash
git add bindings/spec/calib.json native/include/opencv_unity_native.h native/src/ocvu_calibration.cpp native/tests/test_calibration.cpp native/include/ocvu/calib.h Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Calib.g.cs docs/api-map.md tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs
git commit -m "feat(m5): ocvu_calibrate_camera を足して校正の輪を閉じる"
```

---

## Task 4: C# の `CvCalibration.CalibrateCamera`

**Files:**
- Modify: `Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvCalibration.cs`
- Modify: `tests/Managed/CvUnity.Tests.Managed/CalibrationTests.cs`

**Interfaces:**
- Consumes: Task 3 の C ABI
- Produces:

```csharp
public readonly struct CvPoint3 { public float X { get; } public float Y { get; } public float Z { get; } }

public readonly struct CvViewPose
{
    public double RotationX { get; } public double RotationY { get; } public double RotationZ { get; }
    public double TranslationX { get; } public double TranslationY { get; } public double TranslationZ { get; }
}

public sealed class CvCalibrationResult
{
    public double[] CameraMatrix { get; }        // 9 個、行優先
    public double[] DistortionCoefficients { get; }
    public CvViewPose[] ViewPoses { get; }
    public double ReprojectionError { get; }
}

public static CvCalibrationResult CalibrateCamera(
    CvPoint3[][] objectPoints, CvPoint2[][] imagePoints, int imageWidth, int imageHeight);
```

- [ ] **Step 1: 失敗するテストを書く**

**最低でも次を見る**:

1. 合成した校正で焦点距離が戻る（L1 と同じ入力を C# 側から）
2. **`ViewPoses` の長さが view の数と一致し、中身が回転と並進に正しく割れている**
   —— **native が返す 6 個ずつの並びを取り違えたら落ちること。**
   `CameraMatrix` が 9 個であることも見る
3. **ぎざぎざ配列の形を断る**: `objectPoints` と `imagePoints` の view 数が違う、
   view ごとの点数が揃っていない、`null` の view が混じっている
4. `objectPoints` / `imagePoints` が `null`、view が 2 未満、点が 4 未満

**3 が重要である。** native は `points_per_view` を 1 つしか受け取らないので、
**view ごとに点数が違うことは native から見えない。** C# の入口でしか断れない。

- [ ] **Step 2: RED を確認する**

```
pwsh ./tools/dev.ps1 test-managed
```

- [ ] **Step 3: 実装する**

**`capacity` は要素数で渡す**（`ocvu_find_chessboard_corners` で
`heap-buffer-overflow` を出した実例がある）。**`long` で先に掛けてから
`int` に落とす** —— `int` のまま掛けると門に届く前に溢れる。

**`BufferTooSmall` を `CvNative.ThrowIfFailed` に任せない。**
`IsFailure` は `BufferTooSmall` を失敗として扱わないので素通しする
（`CvCodecs.cs` / `CvQrCode.cs` / `CvCalibration.cs` の既存の作法に揃える）。

- [ ] **Step 4: GREEN を確認する**

```
pwsh ./tools/dev.ps1 test
```

- [ ] **Step 5: 壊して落ちることを見る（最低 3 通り）**

1. 姿勢の詰め替えで回転と並進を入れ替える
2. `capacity` を要素数ではなく view 数で渡す
3. ぎざぎざ配列の形の検証を消す

**変異を当てて落ちるテスト名を記録し、手で戻すこと。**

- [ ] **Step 6: コミット**

```bash
git add Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvCalibration.cs tests/Managed/CvUnity.Tests.Managed/CalibrationTests.cs
git commit -m "feat(m5): CvCalibration.CalibrateCamera を足す"
```

---

## Task 5: 文書・判定・Unity レーン

**Files:**
- Modify: `docs/abi-ownership-and-versioning.md`（§3 の allowlist、§2 の versioning 判断）
- Modify: `docs/api-reference.md`
- Modify: `docs/roadmap.md`（**M5 完了条件 2 の判定**）
- Modify: `docs/README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: 全レーンを実測する**

**1 つずつ、前景で。** `dev.ps1` のレーンは相互排他である。

```
pwsh ./tools/dev.ps1 test
pwsh ./tools/dev.ps1 test-asan
pwsh ./tools/dev.ps1 test-unity-editmode
pwsh ./tools/dev.ps1 test-unity-player
```

**Player レーンが返らなくなったら**、結果 XML が既に出ていないか見る ——
`tests/UnityProject/Temp/` の下の `PlayerWithTests.exe` が残っていると
`finally` に到達しない（直前の計画で実際に起きた）。

- [ ] **Step 2: 数えている数を全部洗う**

`grep -rn` で拾い、**増減分を全部直す。** 本数を数える正本は
`docs/api-map.md` の冒頭だけである。**他所に写さない。**
**直前の計画では、この作業の中で新しいずれが 1 つ生まれた** ——
自分が足したテストの本数を `CLAUDE.md` に反映し忘れた。**最後にもう一度実測する。**

- [ ] **Step 3: allowlist に足す**

`docs/abi-ownership-and-versioning.md` §3 に `ocvu_calibrate_camera` を足し、
**冒頭の本数を直す。** §2 を読んで **`OCVU_ABI_VERSION` を上げるかを判断し、
判断の理由を書く**（既存の規約では「追加だけなら上げない」。**確かめてから書く**）。

- [ ] **Step 4: M5 完了条件 2 の判定を書き換える**

**校正の輪が閉じたので、条件 2 は「満たした」になる。**
`geometry` / `calib` / `features` / `objdetect` の 4 module がすべて出た。

**ただし、同じ段落に次を正直に書くこと**:

- **module を選んだ実際の動機**は「利用者の要望」ではなく
  「新しい module を spec から生成できることを実証する」ほうが大きかった。
  **`calib` だけは違う** —— これは「歪み補正を出したのに係数を求められない」
  という**実際に閉じていない輪**を閉じるために足した。
- **`calib` を足した費用**: 構成ハッシュが変わり、5 platform 分の OpenCV を
  作り直した（`4785d98e9aad` → `09fcbe260d87`）。**費用と、届いた機能を混ぜない。**
- **出していないもの**: ステレオ校正、魚眼、`solvePnP`（既知の係数から
  1 枚ぶんの姿勢を求める）。**「カメラ校正に対応した」と読める書き方をしない。**

- [ ] **Step 5: `CLAUDE.md` を直す**

- 「リポジトリの現状」の M5 の段
- 公開 ABI の内訳（**何が在るかを説明する。本数は書かない**）
- `native/src` の一覧（`ocvu_calibration.cpp` の説明）
- `test-native` / `test-managed` の件数
- **マイルストーンの現在地**（条件 2 が満たされたので M5 の判定が変わる）
- 「確定事項」の allowlist の行
- **`cmake/FindOpenCvUnityDeps.cmake` の行**（`COMPONENTS` の現在値）
- **`tools/opencv-config.psd1` の行**（`Modules` に `calib` が入ったこと）

- [ ] **Step 6: 文書のリンクを検査する**

```
pwsh ./tools/dev.ps1 test-tools
```

- [ ] **Step 7: コミット**

```bash
git commit -m "docs(m5): 校正の輪が閉じたことを判定と文書に反映する"
```

---

## この計画が意図的に決めていること

| 決定 | 理由 | 間違っていた場合のコスト |
| --- | --- | --- |
| `calib` module を足す | `cv::calibrateCamera` は他に無い。歪み補正だけ出して係数を求められない状態は、利用者から見て輪が閉じていない | 5 platform 分の再ビルドと、配布物の増加 |
| 姿勢（rvec / tvec）も返す | 校正で得た姿勢をそのまま AR に使える。別途 `solvePnP` を出すより引数 2 本で済む | 出力 buffer が 1 本増え、検証も増える |
| 姿勢を 1 本の buffer に 6 個ずつ入れる | rvec / tvec を別 buffer にすると引数が 2 本増える。点列を平坦化するのと同じ作法 | 呼ぶ側が並びを復号する必要がある（summary に書く） |
| 実装を `ocvu_calibration.cpp` に同居させる | 用途が 1 つだから。`undistort` と `find_chessboard_corners` も同居している | spec の module（`calib`）とファイル名が一致しない |
| `solvePnP` は出さない | この計画の眼目は校正の輪を閉じることで、姿勢推定そのものは別の用途 | 既知の係数から 1 枚ぶんの姿勢を求めたい利用者に届かない |
| 上限を `OCVU_CALIB_MAX_POINTS` = 100000 とする | `int32` の乗算オーバーフローの歯止め。実用上の校正は到底届かない | 極端に大きな校正が断られる |
