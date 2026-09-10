# M7 (c) — `dnn` を opt-in profile として足す実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> ## この gate は 2026-09-08 に解除され、この計画は実行済みである（`e1b0930`）
>
> **以下の「着手する前に読むこと」は、着手前の記録として残してある。**
> 前提 1（(b) が済んでいること）は 2026-09-06 の `### M7b の判定` が、
> 前提 2 は 2026-09-08 のリポジトリ所有者による gate lift が満たした
> （やり取りの引用と、その順序が意味を持つ理由は `docs/roadmap.md` の
> 「この決定は解除された」）。**したがって、この計画を「着手してはいけない
> 計画」として読まないこと。** 完了条件 1 を閉じたのはこの計画である
> （`### M7c の判定`）。
>
> **元の決定を支えていた根拠は否定されていない** —— 上流の実測（旧エンジンの
> 削除、`enum EngineType` の再番号、`OPENCV_FORCE_DNN_ENGINE` の意味変化）は
> いまも成立しており、**5.1 が来たら作り直しが要ると見込んでよい。**
> 変わったのは、所有者がその費用を承知のうえで受け入れると判断したことだけである。
>
> ## 着手する前に読むこと（2026-09-08 より前の記録）
>
> **`docs/roadmap.md` の M7 節は「5.0 に固定した DNN ラッパーを作り込まない」と
> 決めている。** 根拠は上流の実測で、要約すると **5.0 で作り込むと 5.1 で
> 作り直しになる**（旧エンジンが削除され、`enum EngineType` の値が総入れ替えになり、
> 環境変数 `OPENCV_FORCE_DNN_ENGINE` の `2` が ONNX Runtime に変わった）。
>
> **この計画は「決定が覆ったときに何をするか」を書いたものであって、
> 着手してよいという合図ではない。** 着手の前提は 2 つ:
>
> 1. **(b) が済んでいること**（roadmap 決定 4 が明文で要求している）
> 2. **利用者の要望か、上流の安定を示す事実が新しく出ていること**
>
> **2 が無いまま着手すると、roadmap の決定を根拠なく覆すことになる。**

**Goal:** ONNX モデルをメモリ上の byte 列から読み、推論を 1 回走らせて結果を `CvMat` で受け取る経路を、`OCVU_PROFILE_DNN` が立っているときだけコンパイルされる opt-in profile として出す。

**Architecture:** (b) が作った機構に乗る —— `bindings/spec/dnn.json` に `"profile": "dnn"` を書けば、C ヘッダは `native/include/ocvu/dnn.h` へ、C# は `Runtime/Interop.Dnn/` の `NativeMethodsDnn` へ出る。native は `native/modules.cmake` の新しい module になる。**engine / backend を選ぶ引数も定数も公開しない**（設計 D7）—— 5.1 で意味が変わる数字を境界の外へ出さない。

**Tech Stack:** OpenCV 5.0.0 `dnn` module / CMake 3.25+ / .NET 8 / Unity asmdef

**Spec:** [`2026-09-05-m7-profiles-and-performance.md`](./2026-09-05-m7-profiles-and-performance.md)

**Depends on:** [`2026-09-05-m7b-module-separation.md`](./2026-09-05-m7b-module-separation.md) —— **こちらが完了するまで着手しない。**

---

## (a) 完了後の見直し（2026-09-06）

**(a) が完了したので、この計画の前提を実測で洗い直した。** 変えたのは 3 点である。

| # | 崩れていた前提 | 直した場所 |
| --- | --- | --- |
| 1 | **到達性テストの生成器が profile を知らない。** `dnn.json` を足した瞬間、存在しない `NativeMethods.ocvu_net_*` が `CvUnity.Tests.Shared` に書き出され、EditMode / Standalone / Web が同時に落ちる | **(b) 側で塞ぐ**（Task 3 Step 4b）。決定は spec の **D8**。この計画は File Structure と Task 3 で受ける |
| 2 | **L3 の件数が 181 だった。** (a) が `AllocationTests` を足して 185 になった | Task 4 Step 4 と Task 5 Step 4。**数を写す形をやめ、差分で書く** |
| 3 | **全部入り tarball の上限を (a) が機械に守らせた。** `release.yml` の `Assemble the release assets`（**必須チェック**）が `-MaxBytes 104857600` で落とす。実測 **66 MB** に対して余裕は **34 MB**、6 platform で割ると **1 platform あたり約 5.6 MB** しかない | **Task 1 に Step 4b を足した** —— 6 platform 分をビルドし終えた直後に見積もる。**Task 6 まで持ち越さない** |

**3 が最も高い。** dnn と protobuf を 6 platform 分積んで上限を超えると、
落ちるのは**この計画の最後の Task で、必須チェックの中である。**
**そこまで進んでから配布形態を作り直すことになる。**

## Global Constraints

**spec の §3 を逐語で引く。全タスクの要件に暗黙に含まれる。**

- **C ABI が唯一の native contract。** `cv::Mat*` や `cv::dnn::Net` や STL 型を境界の外へ出さない。opaque handle と固定サイズ型のみ
- **例外を ABI の外へ伝播させない。** 公開 ABI 関数は原則 `OCVU_TRY_BEGIN` / `OCVU_TRY_END` で本体を囲む。**`OCVU_TRY_END` は `cv::Exception` を `UNKNOWN_ERROR` に変換する** —— `OPENCV_ERROR` を返したいなら関数ごとに `catch (const cv::Exception&)` を書く
- **handle は常に native が所有する。Unity 所有のメモリを指す handle を返さない。** 借用は 1 回の ABI 呼び出しの内側で完結する
- **buffer 引数の長さと stride は必ず検証する。`stride * rows` を計算してはならない**（`stride > length / rows` の形で比べる）
- **境界の宣言を手で書かない。** `bindings/spec/*.json` が正本。手で足すと `verify-generated` が落とす
- **`docs/api-reference.md` に名前を書くのも同じ commit である** —— 速いレーンが「spec の全関数名が api-reference に現れること」を fail-fast で見るので、「文書は最後にまとめる」は成立しない
- **`OCVU_ABI_VERSION` を bump するかを判断する**（`docs/abi-ownership-and-versioning.md` §2）。**関数の追加だけなら bump しない**
- **すべての実装を TDD で行う**
- **`dev.ps1` のレーンは相互排他である**
- **OpenCV をローカルでビルドしない**（`block-local-opencv-build.sh` が拒否する）。**この計画は OpenCV の再ビルドを CI に投げる**
- **`git add -A` / `git add .` は hook が拒否する**
- **非 ASCII を出力する PowerShell スクリプトは、必ず先頭に** `[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()` **を置く**
- **検査を足したり変えたりしたら、壊して落ちることを見る**（`prove-a-check-works` skill）
- **数を写さない**

---

## 着手前に確定していること（実測。2026-09-05）

| 事実 | 測り方 |
| --- | --- |
| **`dnn` は復元済みツリーに 1 バイトも無い** | `find third_party/opencv/09fcbe260d87 -iname '*dnn*'` が 0 件 |
| 現在ビルドされている OpenCV module は 9 つ（`calib` `core` `features` `flann` `geometry` `imgcodecs` `imgproc` `objdetect` `stereo`） | 同ツリーの `opencv_*.lib` |
| **`dlpack-LICENSE` と `flatbuffers-LICENSE.txt` は既にツリーに在る** | 同ツリーのライセンスディレクトリ |
| **protobuf はまだ無い** | 同上に該当なし |
| **`tools/verify-opencv-artifact.ps1:177` に `@{ Pattern = '*protobuf*'; Why = 'protobuf は dnn 用で allowlist 外' }` がある** | grep |
| **`THIRD_PARTY_NOTICES.md:843` が「`Modules` に `dnn` を足したら検索をやり直せ」と明文で指示している** | grep |
| 現在の構成ハッシュは `09fcbe260d87` | `Get-OpenCvConfigHash` |
| `calib` を足したときのハッシュ変化は `4785d98e9aad` → `09fcbe260d87`、5 platform 分を作り直した | roadmap |

**したがって Task 1 は必ず赤くなる。** 依存 allowlist は protobuf を拒否し、
notices は 2 つの分類を崩す。**どちらも検査が意図どおり働いた結果である。**

---

## この計画で最も難しいところ

**`Net::forward()` が返すのは 4 次元の blob（NCHW）で、`CvMat` は
rows / cols / channels しか公開していない。**

既存の `ocvu_mat_get_info` は `rows` / `cols` / `channels` / `step` を返す。
**4 次元は表現できない。** 選択肢は 3 つある:

| 案 | 得るもの | 失うもの |
| --- | --- | --- |
| **A. 2 次元に潰して返す** | 既存の `CvMat` に何も足さない | N と C の区別が消える。分類（1×N）以外に使えない |
| **B. 形を別に返す** | どんな出力にも使える | 新しい struct と、次元数が可変であることの扱いが要る |
| **C. `ocvu_tensor_handle` を新設する** | 一般的 | **境界に 2 つ目の所有権モデルが増える** |

**この計画は A を採る。** 理由:

- **M2 が「API の広さではなく ownership / stride / エラー / IL2CPP の正しさを確定する」と
  決めた方針に沿う。** 最初の 1 本で一般的な tensor を導入すると、
  そちらの設計の正しさを dnn と同時に検証することになる
- **A が使えない出力に当たったときに B へ移れる。** 逆は移れない ——
  一度 tensor handle を出すと、それを消すのは ABI の破壊的変更である
- **A の限界を明記できる。** 「分類の出力しか受け取れない」と書けば、
  それは穴ではなく境界である

**この決定は `bindings/spec/dnn.json` の `summary` と
`docs/api-reference.md` の両方に書くこと。** 書かないと、
利用者は検出モデルを読ませて意味の無い数字を受け取る。

---

## File Structure

| ファイル | 新規/変更 | 責任 |
| --- | --- | --- |
| `tools/opencv-config.psd1` | 変更 | `Modules` に `dnn` を足す（**構成ハッシュが変わる**） |
| `tools/verify-opencv-artifact.ps1` | 変更 | protobuf の扱いを決める。`$AcceptedTransitiveModules` を見直す |
| `THIRD_PARTY_NOTICES.md` | 変更 | dlpack / flatbuffers / protobuf を「リンク済み」の節へ移し、全文を足す |
| `cmake/FindOpenCvUnityDeps.cmake` | 変更 | `COMPONENTS` に `dnn` を足す |
| `native/modules.cmake` | 変更 | `OCVU_MODULE_dnn` と `OCVU_ALL_MODULES` |
| `native/src/ocvu_dnn_table.cpp` / `.h` | 新規 | `ocvu_net_handle` の表。`ocvu_mat_table.cpp` と同じ形 |
| `native/src/ocvu_dnn.cpp` | 新規 | C ABI の実装 |
| `native/include/opencv_unity_native.h` | 変更 | `ocvu_net_handle` 型と `#include "ocvu/dnn.h"` |
| `bindings/spec/dnn.json` | 新規 | **境界の正本。`"profile": "dnn"`** |
| `native/tests/test_dnn.cpp` | 新規 | L1 |
| `native/tests/test_dnn_table_stability.cpp` | 新規 | L1。handle 表のスレッド安全性 |
| `Packages/.../Runtime/Interop.Dnn/CvUnity.Interop.Dnn.asmdef` | 変更 | (b) が空で置いたものに `references` を足す |
| `Packages/.../Runtime/Interop.Dnn/AssemblyInfo.cs` | 新規 | 到達性テスト宛の `InternalsVisibleTo` 1 本だけ（spec の D8） |
| `tests/UnityProject/Assets/Tests/Shared.Dnn/**` | 新規 | dnn の到達性テスト（生成物）と、その asmdef。**(b) Task 3 Step 4b が機構を作る** |
| `Packages/.../Runtime/Dnn/CvDnn.cs` + asmdef | 新規 | C# の公開 API |
| `tests/Managed/CvUnity.Tests.Managed/DnnTests.cs` | 新規 | L3 |
| `docs/api-reference.md` | 変更 | `CvDnn` を足す |
| `docs/abi-ownership-and-versioning.md` | 変更 | §1 に `ocvu_net_handle` の所有権、§3 に allowlist |
| `.github/workflows/*.yml` | 変更 | profile を建てる job |

---

## Task 1: OpenCV に `dnn` をビルドさせ、落ちる検査を全部見る

**Files:**
- Modify: `tools/opencv-config.psd1`

**Interfaces:**
- Produces: 新しい構成ハッシュ（`Get-OpenCvConfigHash` で読む。**値を写さない**）

**このタスクの成果物は「赤くなった検査の一覧」である。** コードは 1 行も書かない。

- [ ] **Step 1: 現在のハッシュを記録する**

```
pwsh -NoProfile -Command "Import-Module ./tools/OpenCvConfig.psm1; Get-OpenCvConfigHash"
```

期待: `09fcbe260d87`。**これを PR 本文に書くために控える。**

- [ ] **Step 2: `Modules` に `dnn` を足す**

`tools/opencv-config.psd1`:

```powershell
    Modules = @('core', 'imgproc', 'imgcodecs', 'objdetect', 'features', 'calib', 'dnn')
```

- [ ] **Step 3: ハッシュが変わったことを確かめる**

```
pwsh -NoProfile -Command "Import-Module ./tools/OpenCvConfig.psm1; Get-OpenCvConfigHash"
pwsh -NoProfile -File tools/dev.ps1 test-tools
```

期待: ハッシュが `09fcbe260d87` から変わる。
`OpenCvConfig.Tests.ps1` が**ハッシュの直書きを持っていれば落ちる** ——
落ちたら正本から読む形に直す（**写しを増やさない**）。

- [ ] **Step 4: CI に OpenCV をビルドさせる**

**ローカルでビルドしない**（`block-local-opencv-build.sh` が拒否する）。
`tools/opencv-config.psd1` の変更は `build-opencv.yml` の trigger なので、
**push すれば自動で走る。**

```bash
git add tools/opencv-config.psd1
git commit -m "build(m7c): OpenCV の Modules に dnn を足す（構成ハッシュが変わる）"
git push -u origin feat/m7-profiles-and-performance
```

**6 platform 分のビルドを待つ**（`calib` のときは 5 platform で 1 回の run だった）。

```
gh run list --workflow build-opencv.yml --limit 1
gh run watch <id>
```

- [ ] **Step 4b: 全部入り tarball が上限に収まるかを、ここで見積もる**

**この step は (a) 完了後の見直しで足した。**

(a) は `release.yml` の `Assemble the release assets`（**必須チェック**）に
`measure-package-size.ps1 -MaxBytes 104857600` を配線した。**実測の余裕は薄い**:

| | バイト |
| --- | --- |
| 現在の全部入り（v0.3.0 の実物） | 69,565,901（**66 MB**） |
| 上限 | 104,857,600（100 MB） |
| **余裕** | 約 35,000,000（**34 MB**） |
| **6 platform で割ると** | **1 platform あたり約 5.6 MB** |

**`dnn` は OpenCV の module としても、protobuf という新しい bundled 依存の
分としても大きい。** 5.6 MB に収まる保証はどこにも無い。

CI が 6 platform 分の OpenCV を出したら、**plugin をビルドする前に**
`opencv_dnn` の静的ライブラリと protobuf のサイズを platform ごとに記録する。

```
# 例（実際のパスは復元したツリーの構成に合わせる）
ls -l third_party/opencv/<new-hash>/**/libopencv_dnn.a
```

**ただしこの数字は上限そのものではない** —— 静的リンクは参照された object しか
引かないので、**実際の増分は Task 3 Step 7 で plugin をビルドして測るまで
分からない**（`CLAUDE.md` が 2 度実測している:「`COMPONENTS` に足すだけでは
binary は 1 バイトも増えない」）。**ここで見るのは「桁として無理があるか」だけである。**

**桁として無理があるなら、Task 6 まで進む前に配布形態を決め直すこと。**
Task 6 Step 1 の (A)/(B) の議論をここへ前倒しする。**最後の Task で
必須チェックが赤くなってから作り直すのが、いちばん高い。**

- [ ] **Step 5: 落ちた検査を全部記録する**

**期待される赤は少なくとも 2 種類ある**（実測で確定している。上記「着手前に確定していること」）:

1. **依存 allowlist**: `tools/verify-opencv-artifact.ps1:177` の
   `*protobuf*` が拒否する
2. **`$AcceptedTransitiveModules`**: `dnn` が新しい module を推移的に引けば拒否される

**赤を 1 つずつ、原因ごとに 1 コミットで直す**（`add-a-platform` skill の
「1 コミット 1 原因」）。**まとめて直すと、どれが効いたか分からない。**

- [ ] **Step 6: protobuf の扱いを決めて記録する**

`tools/verify-opencv-artifact.ps1` の denylist から `*protobuf*` を外し、
**allowlist の側に、なぜ受け入れるかを書く**:

```powershell
# **dnn を足したので protobuf が入る。**
#
# 以前はここに denylist の項があり、「protobuf は dnn 用で allowlist 外」と
# 書いてあった。**dnn を足した時点でその前提が失効した** ——
# 消さずにこう書き換えるのは、同じ誤解が別の場所にも在るかを
# 次に読む人が確かめられるようにするためである。
#
# **ライセンスは一次情報で確認すること**（BSD-3-Clause）。
# THIRD_PARTY_NOTICES.md に全文を足すまで、この行だけで緑にしない ——
# **利用者が読む文書は何も赤くならない**（add-a-platform skill の罠 5）。
```

- [ ] **Step 7: `THIRD_PARTY_NOTICES.md` を直す**

**`THIRD_PARTY_NOTICES.md:843` が明文で指示している作業である**:

> *"If a future `Modules` list adds `dnn` or `gapi`, re-run these searches — they will
> very likely start matching, and these two need to move up into the reproduced
> sections above."*

- `dlpack` と `flatbuffers` を「ライセンスディレクトリにあるがリンクされていない」の節から
  **「リンク済み」の節へ移し、全文を足す**
- `protobuf` を**新しく足す**（全文）
- **検索をやり直す** —— 指示にある `DLManagedTensor` / `flatbuffers::` /
  `FlatBufferBuilder` などを、**新しいツリーに対して**実行し、
  一致するようになったことを確かめる

**構成ハッシュを埋め込まない**（パスは `<hash>` 表記）。

- [ ] **Step 8: 全レーンが緑に戻ることを確かめてコミット**

```
pwsh -NoProfile -File tools/opencv.ps1 restore
pwsh -NoProfile -File tools/dev.ps1 test
pwsh -NoProfile -File tools/dev.ps1 test-tools-slow
```

```bash
git add tools/verify-opencv-artifact.ps1 THIRD_PARTY_NOTICES.md
git commit -m "build(m7c): dnn が連れてくる third-party を allowlist と notices に入れる

**依存 allowlist が意図どおり働いた。** protobuf の denylist が発火し、
気づかずに通ることはなかった。

**denylist の行を消さずに書き換えた** —— 同じ誤解が別の場所にも在るかを
次に読む人が確かめられるようにするためである。

**THIRD_PARTY_NOTICES.md:843 が明文で指示していた作業を実行した**:
dlpack と flatbuffers を「リンクされていない」側から移し、protobuf を足した。
**検索は新しいツリーに対してやり直した**（一致するようになったことを確認）。"
```

---

## Task 2: `ocvu_net_handle` の表

**Files:**
- Create: `native/src/ocvu_dnn_table.h`
- Create: `native/src/ocvu_dnn_table.cpp`
- Create: `native/tests/test_dnn_table_stability.cpp`
- Modify: `native/include/opencv_unity_native.h`
- Modify: `native/modules.cmake`
- Modify: `native/tests/CMakeLists.txt`

**Interfaces:**
- Consumes: `ocvu_mat_table.h` の設計（既存。**写して読む、ではなく設計を真似る**）
- Produces:
  - `typedef uint64_t ocvu_net_handle;`（`opencv_unity_native.h`）
  - `ocvu::net_table_add(std::unique_ptr<cv::dnn::Net>)` → `ocvu_net_handle`
  - `ocvu::net_table_get(ocvu_net_handle)` → `cv::dnn::Net*`（無効なら `nullptr`）
  - `ocvu::net_table_remove(ocvu_net_handle)` → `bool`

**なぜ独立したタスクか**: **M3 の PR #8 で、handle 表の use-after-free が
CI で 1 度だけ落ちた。** 原因は `std::vector<Slot>` が `cv::Mat` を値で持ち、
`mat_table_get` が配列内部を指すポインタを返していたこと ——
**別スレッドの create で配列が伸びると、先に解決したポインタが全部ぶら下がる。**
**壊れるのは create した側ではなく、無関係な handle を使っている側**で、
2 つのスレッドがそれぞれ自分のオブジェクトだけを触るという正しい使い方で壊れた。

**同じ形を 2 つ目の表で再生産しないために、先に固定する。**

- [ ] **Step 1: 失敗するテストを書く**

`native/tests/test_dnn_table_stability.cpp`:

```cpp
// **2 つ目の handle 表が、1 つ目と同じ欠陥を持たないことを決定的に固定する。**
//
// M3 の PR #8 で mat_table が踏んだ形: Slot が値でオブジェクトを持ち、
// get が配列内部のポインタを返すと、別スレッドの add で配列が伸びたときに
// **先に解決したポインタが全部ぶら下がる。**
//
// **ローカル 3 回と直前 3 回の CI が緑で、1 度だけ落ちた。**
// フレークとして再実行していたら残っていた。だからここでは
// **確率に頼らず、伸びを強制してから古いポインタを触る。**
#include <gtest/gtest.h>
#include <memory>
#include <thread>
#include <vector>

#include "ocvu_dnn_table.h"

TEST(DnnTableStability, APointerStaysValidWhileTheTableGrows) {
    // 1 つ確保して、そのポインタを先に解決しておく。
    auto first = ocvu::net_table_add(std::make_unique<cv::dnn::Net>());
    cv::dnn::Net* resolved = ocvu::net_table_get(first);
    ASSERT_NE(resolved, nullptr);

    // 表を大きく伸ばす。**vector<Slot> が値を持っていれば、ここで再配置が起きる。**
    std::vector<ocvu_net_handle> others;
    for (int i = 0; i < 4096; ++i) {
        others.push_back(ocvu::net_table_add(std::make_unique<cv::dnn::Net>()));
    }

    // **先に解決したポインタがまだ生きていること。**
    EXPECT_EQ(ocvu::net_table_get(first), resolved);
    EXPECT_TRUE(resolved->empty());   // 触って落ちないこと

    for (auto h : others) { ocvu::net_table_remove(h); }
    EXPECT_TRUE(ocvu::net_table_remove(first));
}

TEST(DnnTableStability, ConcurrentAddAndGetDoNotCorruptEachOther) {
    auto mine = ocvu::net_table_add(std::make_unique<cv::dnn::Net>());
    cv::dnn::Net* resolved = ocvu::net_table_get(mine);
    ASSERT_NE(resolved, nullptr);

    std::thread grower([] {
        std::vector<ocvu_net_handle> hs;
        for (int i = 0; i < 2048; ++i) {
            hs.push_back(ocvu::net_table_add(std::make_unique<cv::dnn::Net>()));
        }
        for (auto h : hs) { ocvu::net_table_remove(h); }
    });

    // **自分の handle だけを触る。これが「正しい使い方」である。**
    for (int i = 0; i < 2048; ++i) {
        cv::dnn::Net* again = ocvu::net_table_get(mine);
        ASSERT_EQ(again, resolved);
        ASSERT_TRUE(again->empty());
    }
    grower.join();
    EXPECT_TRUE(ocvu::net_table_remove(mine));
}

TEST(DnnTableStability, AReleasedHandleResolvesToNull) {
    auto h = ocvu::net_table_add(std::make_unique<cv::dnn::Net>());
    EXPECT_NE(ocvu::net_table_get(h), nullptr);
    EXPECT_TRUE(ocvu::net_table_remove(h));
    EXPECT_EQ(ocvu::net_table_get(h), nullptr);

    // **二重解放は落とさず false を返す。**
    EXPECT_FALSE(ocvu::net_table_remove(h));
}

TEST(DnnTableStability, AnUnknownHandleResolvesToNull) {
    EXPECT_EQ(ocvu::net_table_get(0), nullptr);
    EXPECT_EQ(ocvu::net_table_get(0xDEADBEEF), nullptr);
}
```

- [ ] **Step 2: 失敗することを確かめる**

```
pwsh -NoProfile -File tools/dev.ps1 test-native
```

期待: `ocvu_dnn_table.h` が無いのでコンパイルエラー。

- [ ] **Step 3: 表を実装する**

**`native/src/ocvu_mat_table.h` / `.cpp` を読み、同じ設計を使うこと。**
写経ではなく、**なぜ `std::unique_ptr` を持つのか**を理解してから書く
（Step 1 のコメントに書いてある）。

`native/src/ocvu_dnn_table.h`:

```cpp
#pragma once

#include <memory>
#include <opencv2/dnn.hpp>

#include "opencv_unity_native.h"

namespace ocvu {

// **Slot は値ではなく unique_ptr を持つ。**
//
// 値で持つと、表が伸びたときに再配置が起き、先に解決したポインタが
// 全部ぶら下がる。**壊れるのは伸ばした側ではなく、無関係な handle を
// 使っている側**である（M3 の PR #8 で mat_table が実際に踏んだ）。
ocvu_net_handle net_table_add(std::unique_ptr<cv::dnn::Net> net);

// 無効な handle には nullptr を返す。**落とさない。**
cv::dnn::Net* net_table_get(ocvu_net_handle handle);

// 解放できたら true。既に解放済み・未知なら false。**落とさない。**
bool net_table_remove(ocvu_net_handle handle);

}  // namespace ocvu
```

`opencv_unity_native.h` に:

```c
/**
 * 読み込んだニューラルネットワークの handle。
 *
 * **native が所有する。** ocvu_dnn_net_release で解放するまで生きる。
 * ocvu_mat_handle と同じ規約で、0 は常に無効である。
 */
typedef uint64_t ocvu_net_handle;
```

`native/modules.cmake` に:

```cmake
set(OCVU_MODULE_dnn src/ocvu_dnn_table.cpp src/ocvu_dnn.cpp)
```

そして `OCVU_ALL_MODULES` に `dnn` を足す。
**(b) Task 3 Step 6 の検査が「spec のファイル名と一致すること」を要求する**ので、
`bindings/spec/dnn.json` を Task 3 で作るまでは**その検査が落ちる。**
**先に落ちることを見てから進む** —— それがこの検査の負の対照である。

- [ ] **Step 4: テストが通ることを確かめる**

```
pwsh -NoProfile -File tools/dev.ps1 test-native
```

期待: `DnnTableStability` の 4 件が PASS。L1 の合計が 215 → **219**。

- [ ] **Step 5: 負の対照を取る**

**先にコミットしてから壊す。**

壊し方 —— `Slot` を `std::unique_ptr<cv::dnn::Net>` から `cv::dnn::Net` の値に変える:

```
pwsh -NoProfile -File tools/dev.ps1 test-native
```

期待: `APointerStaysValidWhileTheTableGrows` が **FAIL**
（ポインタが変わる、またはクラッシュする）。

**ASan でも見ること** —— use-after-free はこちらのほうが明確に出る:

```
pwsh -NoProfile -File tools/dev.ps1 test-asan
```

**戻して緑に戻すこと。**

- [ ] **Step 6: コミット**

```bash
git add native/src/ocvu_dnn_table.h native/src/ocvu_dnn_table.cpp native/tests/test_dnn_table_stability.cpp native/include/opencv_unity_native.h native/modules.cmake native/tests/CMakeLists.txt
git commit -m "feat(m7c): ocvu_net_handle の表を、2 つ目として先に固定する

**M3 の PR #8 が mat_table で踏んだ形を、2 つ目の表で再生産しない。**
Slot が値でオブジェクトを持つと、表が伸びたときに先に解決したポインタが
ぶら下がる —— 壊れるのは伸ばした側ではなく無関係な handle を使っている側で、
2 つのスレッドがそれぞれ自分のオブジェクトだけを触るという正しい使い方で壊れる。

**確率に頼らない。** 伸びを強制してから古いポインタを触る形にしたので、
落ちるときは決定的に落ちる（PR #8 のときはローカル 3 回と CI 3 回が緑で、
1 度だけ落ちた —— フレークとして再実行していたら残っていた）。

**負の対照**: Slot を値に戻すと該当 1 件が落ち、ASan では use-after-free が出る。"
```

---

## Task 3: C ABI の 4 本

**Files:**
- Create: `bindings/spec/dnn.json`
- Create: `native/src/ocvu_dnn.cpp`
- Create: `native/tests/test_dnn.cpp`
- Modify: `docs/api-reference.md`
- Modify: `docs/abi-ownership-and-versioning.md`

**Interfaces:**
- Consumes: Task 2 の `net_table_add` / `net_table_get` / `net_table_remove`
- Produces（`bindings/spec/dnn.json` が正本。ここは説明である）:

| 関数 | 何をするか |
| --- | --- |
| `ocvu_dnn_net_read_onnx` | メモリ上の byte 列から ONNX を読み、`ocvu_net_handle` を返す |
| `ocvu_dnn_net_release` | handle を解放する |
| `ocvu_dnn_blob_from_image` | `Mat` を推論の入力（blob）にする |
| `ocvu_dnn_net_forward` | 推論を 1 回走らせ、結果を 2 次元の `Mat` に書く |

**ファイルパスを受け取らない。** `imgcodecs` と同じ理由 ——
Windows では境界を越えるパスの文字コードが問題になり、Android では
StreamingAssets が APK の中にあってパスでは開けない。

**engine / backend を選ぶ引数も定数も出さない**（設計 D7）。

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_dnn.cpp`。**先に「リンクされているか」を見る**:

```cpp
// **COMPONENTS に足すだけでは binary は 1 バイトも増えない。**
// 静的リンクは参照された object しか引かないので、
// **cv::dnn:: を実際に参照するテストだけが「リンクした」の証拠になる**
// （M3.5 と M5 で 2 度実測した）。
#include <gtest/gtest.h>
#include <opencv2/dnn.hpp>

TEST(ModuleLinkage, DnnIsLinked) {
    cv::dnn::Net net;
    EXPECT_TRUE(net.empty());
}
```

> **`native/tests/test_module_linkage.cpp` に既存の同型（`CalibIsLinked`）がある。**
> **そちらに足すこと** —— 新しいファイルを作ると、リンク検証が 2 箇所に散る。

続けて本体の失敗するテスト:

```cpp
#include <gtest/gtest.h>
#include <cstdint>
#include <vector>

#include "opencv_unity_native.h"

// **有効な ONNX を手で組むのは現実的でない。** だからこのテストは
// **壊れた入力に対する振る舞い**を固定する。正常系は L3 が、
// 実物の小さなモデルを使って見る（Task 5）。

TEST(Dnn, ReadingGarbageAsOnnxFailsWithoutCrashing) {
    std::vector<uint8_t> garbage(64, 0xAB);
    ocvu_net_handle handle = 0;

    ocvu_status st = ocvu_dnn_net_read_onnx(
        garbage.data(), static_cast<int32_t>(garbage.size()), &handle);

    // **OPENCV_ERROR を要求する。**
    // OCVU_TRY_END は cv::Exception を UNKNOWN_ERROR に変換するので、
    // この関数は自分で catch (const cv::Exception&) を書かなければならない。
    EXPECT_EQ(st, OCVU_STATUS_OPENCV_ERROR);
    EXPECT_EQ(handle, 0u) << "失敗したのに handle が書かれた";
}

TEST(Dnn, ANullBufferIsRejected) {
    ocvu_net_handle handle = 0;
    EXPECT_EQ(ocvu_dnn_net_read_onnx(nullptr, 16, &handle), OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(handle, 0u);
}

TEST(Dnn, ANullOutHandleIsRejected) {
    std::vector<uint8_t> bytes(16, 0);
    EXPECT_EQ(ocvu_dnn_net_read_onnx(bytes.data(), 16, nullptr),
              OCVU_STATUS_NULL_POINTER);
}

TEST(Dnn, ANegativeOrZeroLengthIsRejected) {
    std::vector<uint8_t> bytes(16, 0);
    ocvu_net_handle handle = 0;
    EXPECT_EQ(ocvu_dnn_net_read_onnx(bytes.data(), 0, &handle),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_dnn_net_read_onnx(bytes.data(), -1, &handle),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(handle, 0u);
}

TEST(Dnn, ReleasingAnUnknownHandleIsRejectedWithoutCrashing) {
    EXPECT_EQ(ocvu_dnn_net_release(0), OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_dnn_net_release(0xDEADBEEF), OCVU_STATUS_INVALID_HANDLE);
}

TEST(Dnn, ForwardOnAnUnknownHandleIsRejected) {
    ocvu_mat_handle input = 0, output = 0;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_32FC1, &input), OCVU_STATUS_OK);
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_32FC1, &output), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_dnn_net_forward(0xDEADBEEF, input, output),
              OCVU_STATUS_INVALID_HANDLE);

    ocvu_mat_release(input);
    ocvu_mat_release(output);
}

// **blob の寸法は呼ぶ側が渡す int32_t で、OpenCV の中で寸法になる。**
// cv::cornerSubPix の win_size で踏んだのと同じ形なので、上限を置く
// （add-abi-function skill の「buffer ではないのに上限が要る引数」）。
TEST(Dnn, AnAbsurdBlobSizeIsRejectedRatherThanAttempted) {
    ocvu_mat_handle src = 0, blob = 0;
    ASSERT_EQ(ocvu_mat_create(8, 8, OCVU_MAT_TYPE_8UC3, &src), OCVU_STATUS_OK);
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_32FC1, &blob), OCVU_STATUS_OK);

    const double mean[3] = {0.0, 0.0, 0.0};
    EXPECT_EQ(
        ocvu_dnn_blob_from_image(src, blob, 1.0, 1 << 20, 1 << 20, mean, 0, 0),
        OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(
        ocvu_dnn_blob_from_image(src, blob, 1.0, 0, 8, mean, 0, 0),
        OCVU_STATUS_INVALID_ARGUMENT);

    ocvu_mat_release(src);
    ocvu_mat_release(blob);
}
```

- [ ] **Step 2: 失敗することを確かめる**

```
pwsh -NoProfile -File tools/dev.ps1 test-native
```

期待: `ocvu_dnn_net_read_onnx` が未宣言でコンパイルエラー。
**`DnnIsLinked` も同時に落ちる**（`COMPONENTS` にまだ `dnn` が無い）。

- [ ] **Step 3: `COMPONENTS` に `dnn` を足し、リンクだけ通す**

`cmake/FindOpenCvUnityDeps.cmake`:

```cmake
    COMPONENTS core imgproc imgcodecs objdetect features geometry calib stereo dnn
```

```
pwsh -NoProfile -File tools/dev.ps1 test-native
```

期待: `DnnIsLinked` だけが PASS になる。**他はまだコンパイルエラー。**

**binary の大きさを測る**（`add-abi-function` skill）:

```
pwsh -NoProfile -Command "(Get-Item build/windows-x64-debug/native/Debug/opencv_unity_native.dll).Length"
```

**`COMPONENTS` に足しただけでは増えないはずである**（M3.5 と M5 で 2 度実測）。
**増えたら、それは `DnnIsLinked` が参照した `cv::dnn::Net` のぶんである** ——
数字を記録して PR 本文に書く。

- [ ] **Step 4: spec を書く**

`bindings/spec/dnn.json`。**`"profile": "dnn"` を必ず書く。**

**`summary` に「4 次元の出力は 2 次元に潰される」ことを書く** ——
上の「この計画で最も難しいところ」の決定 A である。

```json
{
  "module": "dnn",
  "profile": "dnn",
  "functions": [
    {
      "name": "ocvu_dnn_net_read_onnx",
      "summary": "メモリ上の ONNX の byte 列からネットワークを読み、handle を out_handle に書く。ファイルパスは受け取らない（Windows の文字コードと Android の StreamingAssets のため）。読めなければ OCVU_STATUS_OPENCV_ERROR を返し out_handle は変更しない。data が NULL、out_handle が NULL なら OCVU_STATUS_NULL_POINTER。length が 1 未満なら OCVU_STATUS_INVALID_ARGUMENT。",
      "returns": "ocvu_status",
      "csReturns": "int",
      "wrapInTryBarrier": true,
      "params": [
        { "name": "data", "cType": "const uint8_t*", "csType": "byte[]", "summary": "ONNX の byte 列" },
        { "name": "length", "cType": "int32_t", "csType": "int", "summary": "data の長さ" },
        { "name": "out_handle", "cType": "ocvu_net_handle*", "csType": "out ulong", "summary": "読み込んだネットワークの handle" }
      ]
    }
  ]
}
```

> **`ocvu_net_handle*` / `ocvu_net_handle` は生成器の型表（`SpecModel.AllowedCsTypes`）に
> 無い。** 足さないと `generate` が `SpecFormatException` で落ちる ——
> **2026-09 の API 拡張で `int32_t*` と `ocvu_dmatch*` を足したときと同じ形である。**
> **落ちることを先に見てから足すこと。**

残る 3 本も同じ形で書く。**`ocvu_dnn_net_forward` の `summary` に必ず書く:**

> 出力は 2 次元の Mat に潰される（rows × cols）。**4 次元の blob を返す
> モデル（検出など）では、N と C の区別が失われる。** 分類モデルの
> 1 × N の出力を受け取ることを想定している。

- [ ] **Step 5: 生成して、落ちることを見る**

```
pwsh -NoProfile -File tools/dev.ps1 generate
```

期待: 型表に無いので `SpecFormatException`。**これが型表が閉じている証拠である。**

`SpecModel.cs` の `AllowedCsTypes` に足す:

```csharp
["ocvu_net_handle"]  = new[] { "ulong" },
["ocvu_net_handle*"] = new[] { "out ulong" },
```

```
pwsh -NoProfile -File tools/dev.ps1 generate
```

期待: `native/include/ocvu/dnn.h` と
`Packages/.../Runtime/Interop.Dnn/NativeMethods.Dnn.g.cs` が現れる。
**(b) が作った profile の分岐が、実物で働いた瞬間である。**

- [ ] **Step 6: 実装する**

`native/src/ocvu_dnn.cpp`。**規約を全部満たすこと**:

```cpp
OCVU_API ocvu_status ocvu_dnn_net_read_onnx(
    const uint8_t* data, int32_t length, ocvu_net_handle* out_handle) {
    OCVU_TRY_BEGIN
    if (data == nullptr || out_handle == nullptr) {
        return OCVU_STATUS_NULL_POINTER;
    }
    if (length < 1) { return OCVU_STATUS_INVALID_ARGUMENT; }

    // **OCVU_TRY_END は cv::Exception を UNKNOWN_ERROR に変換する。**
    // OPENCV_ERROR を返したいので、ここで自分で捕まえる。
    try {
        std::vector<uint8_t> buffer(data, data + length);
        auto net = std::make_unique<cv::dnn::Net>(
            cv::dnn::readNetFromONNX(buffer));
        if (net->empty()) {
            ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, "ONNX が空のネットワークになった");
            return OCVU_STATUS_OPENCV_ERROR;
        }
        // **成功してから初めて out_handle に書く。**
        *out_handle = ocvu::net_table_add(std::move(net));
        return OCVU_STATUS_OK;
    } catch (const cv::Exception& e) {
        ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
        return OCVU_STATUS_OPENCV_ERROR;
    }
    OCVU_TRY_END
}
```

**`ocvu_dnn_blob_from_image` には上限を置く**（`OCVU_DNN_MAX_BLOB_DIM`）。
値は 4096 とし、`opencv_unity_native.h` に定数として書く。
**上限は「native か OpenCV がその値から何かを作るときだけ置く」**
（`add-abi-function` skill）—— ここは `cv::dnn::blobFromImage` が
その寸法のメモリを確保するので、置く側である。

- [ ] **Step 7: テストが通ることを確かめる**

```
pwsh -NoProfile -File tools/dev.ps1 test-native
pwsh -NoProfile -File tools/dev.ps1 test-asan
```

期待: L1 の合計が 219 → **226**（7 件追加）。

**binary の大きさを測り直す** —— **ここで初めて増えるはずである。**

- [ ] **Step 8: `docs/api-reference.md` と allowlist を同じコミットで書く**

**速いレーンが「spec の全関数名が api-reference に現れること」を fail-fast で見る**ので、
**「文書は最後にまとめる」は成立しない。**

`docs/abi-ownership-and-versioning.md`:
- §1 に **`ocvu_net_handle` の所有権**（native が所有する、`ocvu_dnn_net_release` で解放）
- §3 に allowlist（**本数は §3 の冒頭が数える。写さない**）
- §2 に **`OCVU_ABI_VERSION` を bump しない判断**と理由（関数の追加だけである）

- [ ] **Step 9: 負の対照を取る**

**先にコミットしてから壊す。**

壊し方 1 —— `length < 1` の検証を消す:
期待: `ANegativeOrZeroLengthIsRejected` が **FAIL**。

壊し方 2 —— `catch (const cv::Exception&)` を消す:
期待: `ReadingGarbageAsOnnxFailsWithoutCrashing` が
`UNKNOWN_ERROR` を受けて **FAIL**。**これが「`OCVU_TRY_END` は
`cv::Exception` を `UNKNOWN_ERROR` に変換する」の実証である。**

壊し方 3 —— `OCVU_DNN_MAX_BLOB_DIM` の検証を消す:
期待: `AnAbsurdBlobSizeIsRejectedRatherThanAttempted` が **FAIL**
（確保に失敗するか、時間が掛かりすぎる）。

**全部戻すこと。**

- [ ] **Step 10: コミット**

```bash
git add bindings/spec/dnn.json bindings/generator/Ocvu.Generator/SpecModel.cs native/src/ocvu_dnn.cpp native/tests/test_dnn.cpp native/tests/test_module_linkage.cpp cmake/FindOpenCvUnityDeps.cmake native/include/opencv_unity_native.h docs/api-reference.md docs/abi-ownership-and-versioning.md
# 生成物も一緒に
git add native/include/ocvu/dnn.h Packages/com.ayutaz.opencv-unity-native/Runtime/Interop.Dnn/NativeMethods.Dnn.g.cs docs/api-map.md
# 到達性テストは profile ごとに別ファイル・別 assembly へ出る（spec の D8。(b) Task 3 Step 4b）
git add tests/UnityProject/Assets/Tests/Shared.Dnn/ Packages/com.ayutaz.opencv-unity-native/Runtime/Interop.Dnn/AssemblyInfo.cs
git commit -m "feat(m7c): dnn の C ABI 4 本

**(b) が作った profile の分岐が、実物で初めて働いた** —— spec に
\"profile\": \"dnn\" を書くと、C# の宣言が Runtime/Interop.Dnn/ の
NativeMethodsDnn へ出た。

**engine / backend を選ぶ引数も定数も出していない**（設計 D7）——
上流の 5.1 で enum EngineType の値が総入れ替えになったので、
5.1 で意味が変わる数字を境界の外へ出さない。

**4 次元の blob は 2 次元に潰す**（決定 A）。分類の 1×N を想定していて、
検出モデルでは N と C の区別が失われる。**spec の summary と
api-reference の両方に書いた** —— 書かないと利用者は検出モデルを
読ませて意味の無い数字を受け取る。

**型表が閉じていることを確かめた**: ocvu_net_handle を足す前に
generate が SpecFormatException で落ちた。

**負の対照 3 通り**: 長さの検証を消すと 1 件、cv::Exception の catch を
消すと 1 件（UNKNOWN_ERROR になる）、blob の上限を消すと 1 件が落ちる。"
```

---

## Task 4: C# の公開 API と、profile が切れることの実証

**Files:**
- Create: `Packages/.../Runtime/Dnn/CvDnn.cs`
- Create: `Packages/.../Runtime/Dnn/CvUnity.Dnn.asmdef`
- Modify: `Packages/.../Runtime/Interop.Dnn/CvUnity.Interop.Dnn.asmdef`
- Create: `tests/Managed/CvUnity.Tests.Managed/DnnTests.cs`
- Modify: `tests/UnityProject/Assets/Tests/EditMode/ProfileGatingTests.cs`

**Interfaces:**
- Consumes: `NativeMethodsDnn`（Task 3 の生成物）、`CvMat`（既存）
- Produces:
  - `CvNet`（`IDisposable`。`ocvu_net_handle` を包む）
  - `CvDnn.ReadOnnx(byte[])` → `CvNet`
  - `CvDnn.BlobFromImage(CvMat src, CvMat dst, double scale, int width, int height, double[] mean, bool swapRb, bool crop)`
  - `CvDnn.Forward(CvNet net, CvMat input, CvMat output)`

**`CvUnity.Dnn` も `defineConstraints` を持つ。** そうしないと、
`OCVU_PROFILE_DNN` が無いときに `CvUnity.Interop.Dnn` を参照する assembly が
参照先を失ってコンパイルエラーになる —— **利用者のプロジェクトが壊れる。**

- [ ] **Step 1: 失敗する L3 テストを書く**

```csharp
using System;
using CvUnity;
using CvUnity.Dnn;
using Xunit;

/// <summary>
/// **有効な ONNX を手で組むのは現実的でない。**
/// ここが見るのは、壊れた入力・寿命・所有権である。
/// **正常系は Task 5 が、実物の小さなモデルを使って見る。**
/// </summary>
public class DnnTests
{
    [Fact]
    public void ReadingGarbageThrowsRatherThanReturningABrokenNet()
    {
        var garbage = new byte[64];
        for (int i = 0; i < garbage.Length; i++) { garbage[i] = 0xAB; }

        var ex = Assert.Throws<CvException>(() => CvDnn.ReadOnnx(garbage));
        Assert.Equal(CvStatus.OpenCvError, ex.Status);
    }

    [Fact]
    public void ANullBufferIsRejected()
        => Assert.Throws<ArgumentNullException>(() => CvDnn.ReadOnnx(null));

    [Fact]
    public void AnEmptyBufferIsRejected()
        => Assert.Throws<ArgumentException>(() => CvDnn.ReadOnnx(Array.Empty<byte>()));

    /// <summary>
    /// **二重解放が落ちないこと。** mat_table と同じ規約である。
    /// </summary>
    [Fact]
    public void DisposingTwiceIsSafe()
    {
        // 読めない入力なので net は作れない。**代わりに、
        // 解放済みの handle を native がどう扱うかを直接見る。**
        // （CvNet を作れないので、ここは NativeMethodsDnn を直接叩く）
        Assert.Equal(
            (int)CvStatus.InvalidHandle,
            CvUnity.Interop.Dnn.NativeMethodsDnn.ocvu_dnn_net_release(0));
    }
}
```

> **`CvException` / `CvStatus` の実際の名前を、着手時に
> `Packages/.../Runtime/Core/` で確かめること。** 推測で書かない。

- [ ] **Step 2: 失敗することを確かめる**

```
pwsh -NoProfile -File tools/dev.ps1 test-managed
```

期待: `CvDnn` が未定義でコンパイルエラー。

> **`CvUnity.Tests.Managed` は `.csproj` なので `defineConstraints` の
> 影響を受けない。** Unity の asmdef 制約は Unity の中でだけ効くので、
> **L3 は常に dnn を見る。** これは意図した形である ——
> **L3 で常に検証しておき、Unity 側では切れることを別に確かめる**（Step 5）。

- [ ] **Step 3: `CvDnn` と `CvNet` を実装する**

**`CvMat` の寿命管理を読んで、同じ形にすること。**

`Packages/.../Runtime/Dnn/CvUnity.Dnn.asmdef`:

```json
{
    "name": "CvUnity.Dnn",
    "rootNamespace": "CvUnity.Dnn",
    "references": [
        "CvUnity.Interop",
        "CvUnity.Interop.Dnn",
        "CvUnity.Core"
    ],
    "includePlatforms": [],
    "excludePlatforms": [],
    "allowUnsafeCode": true,
    "noEngineReferences": true,
    "defineConstraints": [
        "OCVU_PROFILE_DNN"
    ]
}
```

`Runtime/Interop.Dnn/CvUnity.Interop.Dnn.asmdef` に `InternalsVisibleTo` 相当を用意する
—— **`AssemblyInfo.cs` を `Interop.Dnn` にも置く**:

```csharp
using System.Runtime.CompilerServices;

// **Interop.Dnn の internal は、Dnn 層と L3 のテストからだけ見える。**
// public にはしない —— P/Invoke 宣言は実装詳細である
// （Runtime/Interop/AssemblyInfo.cs と同じ方針）。
[assembly: InternalsVisibleTo("CvUnity.Dnn")]
[assembly: InternalsVisibleTo("CvUnity.Tests.Managed")]
[assembly: InternalsVisibleTo("CvUnity.Runtime")]
```

- [ ] **Step 4: テストが通ることを確かめる**

```
pwsh -NoProfile -File tools/dev.ps1 test-managed
```

期待: `CvUnity.Tests.Managed` が **+4**。**着手前に測った値からの差で見る** ——
絶対の件数をここに写すと、別の計画が先に入った日にこの行だけが嘘になる
（(a) が L3 を 181 → 185 にしたとき、実際にこの行が古くなった）。

- [ ] **Step 5: Unity で profile が切れることを実証する**

`ProfileGatingTests.cs` に足す:

```csharp
    /// <summary>
    /// **dnn の公開 API 層も、define が無ければコンパイルされない。**
    ///
    /// Interop.Dnn だけを切っても足りない —— それを参照する
    /// CvUnity.Dnn が残ると、参照先を失って**利用者のプロジェクトが
    /// コンパイルエラーになる。**
    /// </summary>
    [Test]
    public void TheDnnPublicApiAssemblyIsAlsoAbsentWithoutItsDefine()
    {
        var names = CompilationPipeline.GetAssemblies(AssembliesType.Editor)
            .Select(a => a.name).ToList();
        Assert.That(names, Does.Not.Contain("CvUnity.Dnn"),
            "define が無いのに dnn の公開 API assembly がコンパイルされている");
    }
```

```
pwsh -NoProfile -File tools/dev.ps1 test-unity-editmode
```

期待: PASS。

**define を立てて、両方が現れることも見る**（(b) Task 4 Step 5 と同じ手順）。
**戻すこと。**

- [ ] **Step 6: コミット**

```bash
git add Packages/com.ayutaz.opencv-unity-native/Runtime/Dnn/ Packages/com.ayutaz.opencv-unity-native/Runtime/Interop.Dnn/ tests/Managed/CvUnity.Tests.Managed/DnnTests.cs tests/UnityProject/Assets/Tests/EditMode/ProfileGatingTests.cs
git commit -m "feat(m7c): dnn の C# 公開 API と、Unity で切れることの実証

**公開 API 層にも defineConstraints を置く。** Interop.Dnn だけを切ると、
それを参照する CvUnity.Dnn が参照先を失って**利用者のプロジェクトが
コンパイルエラーになる。**

**L3 は常に dnn を見る**（.csproj は asmdef の制約を受けない）。
これは意図した形で、L3 で常に検証しておき、
Unity 側では切れることを別に確かめる。"
```

---

## Task 5: 実物のモデルで正常系を通す

**Files:**
- Create: `tests/Managed/CvUnity.Tests.Managed/DnnInferenceTests.cs`
- Create: `tests/Managed/CvUnity.Tests.Managed/TestModels/tiny.onnx`
- Modify: `THIRD_PARTY_NOTICES.md`（モデルのライセンス）

**Interfaces:**
- Consumes: Task 4 の `CvDnn.ReadOnnx` / `BlobFromImage` / `Forward`
- Produces: なし（テストのみ）

**なぜ最後か**: **ここまでは全部「壊れた入力にどう振る舞うか」だった。**
正常系はモデルという外部の資産を要求するので、
**それが無くても他が全部通る形にしてから足す。**

- [ ] **Step 1: モデルを用意する**

**外から取ってこない。自分で作る。**

理由: 外部のモデルは (1) ライセンスの確認が要り、(2) リポジトリに数 MB が入り、
(3) 上流が消すと CI が壊れる。**この 3 つを避けるため、
`Identity` 1 ノードだけの最小の ONNX を生成する。**

```bash
uv run --with onnx python - <<'PY'
import onnx
from onnx import helper, TensorProto

# 入力をそのまま返すだけのネットワーク。**推論の正しさは OpenCV の責任で、
# ここが確かめるのは「境界を通ったか」である。**
node = helper.make_node('Identity', ['input'], ['output'])
graph = helper.make_graph(
    [node], 'tiny',
    [helper.make_tensor_value_info('input',  TensorProto.FLOAT, [1, 3, 4, 4])],
    [helper.make_tensor_value_info('output', TensorProto.FLOAT, [1, 3, 4, 4])])
model = helper.make_model(graph, opset_imports=[helper.make_opsetid('', 13)])
onnx.checker.check_model(model)
onnx.save(model, 'tests/Managed/CvUnity.Tests.Managed/TestModels/tiny.onnx')
print('bytes:', len(model.SerializeToString()))
PY
```

**生成に使ったスクリプトを、モデルの隣に `tiny.onnx.py` として置くこと** ——
**モデルは binary なので、中身が読めない。** 作り方が残っていないと、
次に誰かが opset を上げたくなったときに作り直せない。

- [ ] **Step 2: 失敗するテストを書く**

```csharp
using System;
using System.IO;
using CvUnity;
using CvUnity.Dnn;
using Xunit;

/// <summary>
/// **実物の ONNX を通して、境界の往復が成立することを見る。**
///
/// モデルは Identity 1 ノードなので、推論の中身は何もしない ——
/// **確かめているのは「読めて、blob になって、forward が返る」ことである。**
/// 推論そのものの正しさは OpenCV の責任であって、この境界の責任ではない。
/// </summary>
public class DnnInferenceTests
{
    private static byte[] TinyModel()
    {
        var path = Path.Combine(
            AppContext.BaseDirectory, "TestModels", "tiny.onnx");
        Assert.True(File.Exists(path), $"テスト用のモデルが無い: {path}");
        return File.ReadAllBytes(path);
    }

    [Fact]
    public void AValidOnnxLoads()
    {
        using var net = CvDnn.ReadOnnx(TinyModel());
        Assert.NotNull(net);
    }

    [Fact]
    public void BlobFromImageProducesTheRequestedShape()
    {
        using var src = CvMat.Create(8, 8, CvMatType.Rgb24);
        using var blob = CvMat.Create(1, 1, CvMatType.Gray32F);

        CvDnn.BlobFromImage(
            src, blob, scale: 1.0 / 255.0, width: 4, height: 4,
            mean: new[] { 0.0, 0.0, 0.0 }, swapRb: false, crop: false);

        // **4 次元は 2 次元に潰される**（決定 A）。
        // 1×3×4×4 = 48 要素が、rows × cols として現れる。
        Assert.Equal(48, blob.Rows * blob.Cols);
    }

    [Fact]
    public void ForwardReturnsTheInputUnchangedForAnIdentityNetwork()
    {
        using var net = CvDnn.ReadOnnx(TinyModel());
        using var src = CvMat.Create(4, 4, CvMatType.Rgb24);
        using var blob = CvMat.Create(1, 1, CvMatType.Gray32F);
        using var output = CvMat.Create(1, 1, CvMatType.Gray32F);

        CvDnn.BlobFromImage(
            src, blob, scale: 1.0, width: 4, height: 4,
            mean: new[] { 0.0, 0.0, 0.0 }, swapRb: false, crop: false);

        CvDnn.Forward(net, blob, output);

        // Identity なので、要素数は変わらない。
        Assert.Equal(blob.Rows * blob.Cols, output.Rows * output.Cols);
    }

    /// <summary>
    /// **解放した net で forward を呼んでも落ちないこと。**
    /// mat_table と同じ規約 —— 解放後アクセスは status で返る。
    /// </summary>
    [Fact]
    public void ForwardOnADisposedNetIsRejected()
    {
        var net = CvDnn.ReadOnnx(TinyModel());
        net.Dispose();

        using var input = CvMat.Create(1, 48, CvMatType.Gray32F);
        using var output = CvMat.Create(1, 1, CvMatType.Gray32F);

        Assert.Throws<ObjectDisposedException>(() => CvDnn.Forward(net, input, output));
    }
}
```

> **`CvMatType.Rgb24` / `Gray32F` の実際の名前を、着手時に
> `Packages/.../Runtime/Core/CvMatType.cs` で確かめること。**
> **`OCVU_MAT_TYPE_32FC1` を M7 (c) で足す必要があるかも同時に確かめる** ——
> 2026-09 の API 拡張で 32FC1 は足してあるはずだが、**確かめてから使う。**

- [ ] **Step 3: `.csproj` にモデルをコピーさせる**

`CvUnity.Tests.Managed.csproj` に:

```xml
  <ItemGroup>
    <None Include="TestModels\**\*.onnx" CopyToOutputDirectory="PreserveNewest" />
  </ItemGroup>
```

- [ ] **Step 4: テストが通ることを確かめる**

```
pwsh -NoProfile -File tools/dev.ps1 test-managed
```

期待: `CvUnity.Tests.Managed` が **さらに +4**（Task 4 の後の値から）。
**絶対の件数を写さない。**

- [ ] **Step 5: 負の対照を取る**

壊し方 —— `tiny.onnx` を 8 バイトのダミーで上書きする:

期待: `AValidOnnxLoads` を含む 4 件が **FAIL**。
**これは M6 で `.a` を 8 バイトのダミーで上書きしたときに検査が捕まえたのと同じ形である。**

**戻すこと**（`git checkout -- tests/Managed/CvUnity.Tests.Managed/TestModels/tiny.onnx`）。

- [ ] **Step 6: コミット**

```bash
git add tests/Managed/CvUnity.Tests.Managed/DnnInferenceTests.cs tests/Managed/CvUnity.Tests.Managed/TestModels/ tests/Managed/CvUnity.Tests.Managed/CvUnity.Tests.Managed.csproj
git commit -m "test(m7c): 実物の ONNX を通して境界の往復を確かめる

**モデルは外から取ってこず、自分で作った** —— 外部のモデルは
ライセンスの確認が要り、リポジトリに数 MB が入り、上流が消すと CI が壊れる。
Identity 1 ノードの最小の ONNX なので、**推論の中身は何もしない。**
確かめているのは「読めて、blob になって、forward が返る」ことである。

**生成スクリプトをモデルの隣に置いた。** モデルは binary なので中身が
読めず、作り方が残っていないと opset を上げたくなったときに作り直せない。"
```

---

## Task 6: 配布と判定

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `tools/pack-upm-tarball.ps1`
- Modify: `docs/roadmap.md`
- Modify: `CLAUDE.md`
- Modify: `README.md` / `README.ja.md`

- [ ] **Step 1: profile 込みの成果物をどう配るかを決めて書く**

**決めることが 2 つある。判断を先送りしない。**

| 問い | 選択肢 |
| --- | --- |
| dnn 入りの native binary を別に配るか | (A) 同じ binary に全部入れ、C# 側だけ切る / (B) profile ごとに別の binary |
| tarball を分けるか | (A) 1 つ / (B) `-dnn` を別に |

**推奨は (A)+(A) である。** 理由:

- **全部入り tarball を配る正にしたのは M3.5 の決着**で、
  分けると利用者は 2 つを導入して版を合わせる責任を負う
- **native を分けると `DllImport` の名前が profile で変わる。**
  iOS と Web は `__Internal` なので名前で分けられず、
  **6 platform のうち 2 つで機構が成立しない**
- 代償は **binary が大きくなること**。**Task 3 Step 7 で測った増分を
  `docs/performance.md` と README に書く** —— (a) が作った
  `measure-package-size.ps1` の上限に当たるなら、**そこで初めて (B) を考える**

**決めたほうを roadmap の「まだ決めていないこと」から
「決定」へ移し、理由と、間違っていた場合のコストを書く。**

- [ ] **Step 2: `OCVU_PROFILE_DNN` をどう立てるかを文書化する**

利用者は自分のプロジェクトの Player Settings で
`OCVU_PROFILE_DNN` を足す。**それを `README.md` と `README.ja.md` に書く。**

**`package.json` の `versionDefines` で自動化しない。**
`versionDefines` は「ある package が入っていれば define を立てる」機構で、
**profile の意思表示には使えない**（dnn は同じ package の中にある）。

- [ ] **Step 3: roadmap の M7 判定表を書く**

完了条件 1 と 5 の行を埋める。

**条件 5 は「同梱しない」と記録する** ——
cuDNN は 1 platform あたり 698〜772 MB で、`pack-upm-tarball.ps1` の
上限 512 MB を 1 platform 分だけで超える。
**ライセンスが解決しても現在の形では配れない。**

**「満たしたが、実証はしていない」を第 3 の欄として使う**（`milestone-complete` skill）:
- **実機で dnn を動かしていない**（M4 の穴がそのまま残る）
- **Web で dnn が動くかは CI の browser E2E が見るが、手元では確かめていない**
- **推論の速さを測っていない** —— (a) の benchmark に dnn の項は無い

- [ ] **Step 4: `CLAUDE.md` を更新する**

- 「リポジトリの現状」に **`dnn` profile が在ること**と、**既定では入らないこと**
- ファイル配置の表に `bindings/spec/dnn.json` / `Runtime/Dnn/` / `native/src/ocvu_dnn*.cpp`
- `tools/opencv-config.psd1` の行の `Modules` に `dnn` が入ったこと
  （**数を写さない。正本は同ファイル**）
- **リンク済み module が 8 → 9 になったこと**
  （`docs/abi-ownership-and-versioning.md` §3 の表現を合わせる）
- **`OCVU_ABI_VERSION` は 1 のままであること**

- [ ] **Step 5: 全レーンを回す**

**1 つずつ順に回すこと。**

```
pwsh -NoProfile -File tools/dev.ps1 test
pwsh -NoProfile -File tools/dev.ps1 test-asan
pwsh -NoProfile -File tools/dev.ps1 test-tools-slow
pwsh -NoProfile -File tools/dev.ps1 test-unity-editmode
pwsh -NoProfile -File tools/dev.ps1 test-unity-player
pwsh -NoProfile -File tools/dev.ps1 test-unity-tarball
pwsh -NoProfile -File tools/verify-exported-symbols.ps1 -LibraryPath build/windows-x64-debug/native/Debug/opencv_unity_native.dll
```

> **`verify-exported-symbols.ps1`（(b) Task 1）は、
> dnn の関数も spec に在るので一致するはずである。**
> **`OCVU_PROFILE_DNN` は C# 側の機構で、native 側には効かない** ——
> native は `OCVU_MODULES` で切る。**その非対称を roadmap に書くこと。**

- [ ] **Step 6: コミット**

```bash
git add .github/workflows/release.yml tools/pack-upm-tarball.ps1 docs/roadmap.md CLAUDE.md README.md README.ja.md
git commit -m "docs(m7c): dnn profile の配布形態を決め、M7 の判定を書く

**native と C# で切り方が違う**ことを明記した:
  C# 側は OCVU_PROFILE_DNN（asmdef の defineConstraints）
  native 側は OCVU_MODULES（CMake）
**この非対称は意図したものである** —— 配る binary は 1 つで、
iOS と Web は DllImport(\"__Internal\") なので名前で分けられない。

**条件 5 は「同梱しない」と記録した。** cuDNN は 1 platform あたり
698〜772 MB で、pack-upm-tarball.ps1 の上限 512 MB を 1 platform 分だけで
超える。**ライセンスが解決しても現在の形では配れない。**

**実証していないこと**: 実機で dnn を動かしていない、Web での動作は
CI に任せて手元では確かめていない、推論の速さを測っていない。"
```

---

## Self-Review

**1. Spec coverage**

| spec の要件 | 実装するタスク |
| --- | --- |
| 完了条件 1（profile ごとの artifact / manifest / notices） | Task 1（notices）/ Task 6（artifact） |
| 完了条件 5（CUDA の再配布条件、または同梱しないと記録） | Task 6 Step 3 |
| D6（`Modules` を触ると 6 platform 分の再ビルド） | Task 1 |
| D7（engine / backend を出さない） | Task 3 |
| 「最も難しいところ」の決定 A | Task 3 Step 4（spec の summary）/ Task 5（実証） |
| (b) への依存 | 冒頭と Task 3 Step 5 |

**ギャップ**: 完了条件 1 の「manifest」は `package-release.ps1` が
実物の artifact から作るので、**`dnn` を足せば自動で入る。**
確かめる step が Task 6 Step 5 の `test-tools-slow` に含まれる
（`PackageRelease.Tests.ps1` が走る）。**明示的な step を Task 6 に足すこと** ——
`build-manifest.json` に `dnn` が現れることを目で確かめる。

**2. Placeholder scan**

- Task 3 Step 4 の spec は 1 本だけ全文を書き、残る 3 本は「同じ形で書く」とした。
  **これは省略である** —— ただし **`summary` に必ず書くこと**を名指しで指示し、
  型表に足す必要があることも予告してある。**着手時に 4 本すべてを書くこと。**
- Task 4 Step 1 / Task 5 Step 2 の型名に「着手時に確かめること」を書いた ——
  **推測で書かないという指示であって TBD ではない**
- Task 6 Step 1 は選択肢と推奨と理由と代償を書き、**判断を先送りしていない**

**3. Type consistency**

- `ocvu_net_handle`（`uint64_t`）：Task 2 で定義、Task 3 の 4 関数で使用 ✓
- `net_table_add` / `net_table_get` / `net_table_remove`：Task 2 で定義、Task 3 で使用 ✓
- `ocvu_dnn_net_read_onnx(const uint8_t*, int32_t, ocvu_net_handle*)`：
  Task 3 Step 1 のテスト、Step 4 の spec、Step 6 の実装で一致 ✓
- `ocvu_dnn_blob_from_image(src, dst, scale, width, height, mean[3], swap_rb, crop)`：
  Task 3 Step 1 のテストと Task 5 Step 2 の C# 呼び出しで引数の順序が一致 ✓
- `CvDnn.ReadOnnx(byte[])` → `CvNet`：Task 4 で定義、Task 5 で使用 ✓
- `CvDnn.BlobFromImage(CvMat, CvMat, double, int, int, double[], bool, bool)`：
  Task 4 の Produces と Task 5 の呼び出しで一致（名前つき引数で呼んでいる）✓
- assembly `CvUnity.Interop.Dnn` / `CvUnity.Dnn`、クラス `NativeMethodsDnn`：
  (b) の設計と Task 3・4 で一致 ✓
- `OCVU_DNN_MAX_BLOB_DIM`：Task 3 Step 6 で定義、Step 1 のテストが 1<<20 で
  超えることを見る ✓
