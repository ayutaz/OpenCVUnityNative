# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## リポジトリの現状

**M0（自動 TDD ハーネス）と M1（OpenCV 5.0.0 の再現可能ビルド）は完了している。** ビルドシステム、C ABI の骨格、テストレーン 3 本（L1 / L2 / L3）に加え、CI がビルドし artifact 配布する allowlist 構成の OpenCV 5.0.0 が全レーンにリンクされた状態で、ローカルでも CI でも green になる。

**M2（Windows vertical slice）は、8 件の完了条件のうち 7 件を満たしている。残る 1 件は未達で、M2 を完了と称さない。** `Mat` のライフサイクル（create / release / clone / get_info / copy_from_buffer / copy_to_buffer）と `imgproc` 3 関数（cvtColor / resize / GaussianBlur）が C ABI にあり、所有権契約（二重解放・解放後アクセス・buffer の長さ/stride/NULL 検証）が L3 でテストされ、Unity Editor (Mono) と Windows IL2CPP Player の両方で同じ smoke test が通る。未達は 1 件。**条件 7**（「`ci-unity.yml` が CI 上で L4/L5 を実行する」）は、workflow ファイルは在るが 一度も実行されていない。残作業は 3 つで、うち 2 つはエージェントが書ける: (a) CI ランナーへの Unity 導入（GitHub ホストの windows-2022 に Unity は含まれない）、(b) ライセンスのアクティベーション実装（`UNITY_LICENSE` 等を env に置いてあるが、読むコードが無い）、(c) GitHub Secrets への資格情報登録（これだけがユーザーの操作）。**資格情報を登録しただけでは動かない。** 現在 trigger は `workflow_dispatch` のみに絞ってある（push で走らせると恒常的に赤くなるため）。 判定の詳細は `docs/superpowers/plans/2026-08-26-m2-windows-vertical-slice.md` の実装計画と、その進行記録（`.superpowers/sdd/2026-08-26-m2-windows-vertical-slice/progress.md`）にある。

現在の公開 ABI は 18 本。M0/M1 由来の 8 本（`ocvu_get_abi_version`、last-error の取得、status 表の照会、`ocvu_get_opencv_version` / `ocvu_get_build_information`）に、M2 で `Mat` のライフサイクルと buffer 転送の 6 本（`ocvu_mat_create` / `_release` / `_clone` / `_get_info` / `_copy_from_buffer` / `_copy_to_buffer`。`native/src/ocvu_mat_table.cpp`、`native/src/ocvu_mat.cpp`、`native/src/ocvu_mat_buffer.cpp`）、`imgproc` の 3 本（`ocvu_cvt_color` / `ocvu_resize` / `ocvu_gaussian_blur`。`native/src/ocvu_imgproc.cpp`）、L3 のクラッシュ・ハング耐性を実証する `ocvu_debug_crash`（`native/src/ocvu_debug.cpp`）が加わった。所有権・versioning・API allowlist の正本は `docs/abi-ownership-and-versioning.md`。

### 開発コマンド

ローカル開発はすべて `tools/dev.ps1` を通す。これが唯一の入口であり、CI も同じコマンドを呼ぶ（CI 専用の手順は無い）。PowerShell 7 以上が必要。OpenCV の取得は別の入口 `tools/opencv.ps1` が持つ（下記）。

| コマンド | 内容 | 実測 |
| --- | --- | --- |
| `./tools/dev.ps1 build` | native の configure + build | — |
| `./tools/dev.ps1 test` | **既定**。tools の速いテスト 2 本 + L1 + L3 | 約 25 秒（増分、成果物が最新） |
| `./tools/dev.ps1 test-tools` | `tools/tests/` の速い 2 本（OpenCV 構成・ハッシュ無効化） | 約 18 秒 |
| `./tools/dev.ps1 test-tools-slow` | **CI 専用**。allowlist 検証と restore の実 download | 約 70 秒 + download |
| `./tools/dev.ps1 test-native` | L1 のみ（GoogleTest + CTest） | 約 10 秒 |
| `./tools/dev.ps1 test-managed` | L3 のみ（xUnit から P/Invoke） | 約 11 秒 |
| `./tools/dev.ps1 test-asan` | L2（AddressSanitizer） | 約 11 秒（増分） |
| `./tools/dev.ps1 test-managed-probe` | **CI 専用**。L3 のクラッシュ・ハングプローブ | 約 50 秒（segfault 6 秒 + hang 36 秒） |
| `./tools/dev.ps1 test-unity-editmode` | L4（Unity EditMode、Mono） | 約 24 秒（増分） |
| `./tools/dev.ps1 test-unity-player` | L5（Unity IL2CPP Player のビルドと実行） | 約 50 秒（増分・キャッシュ温状態。cold 実測はまだ無く、roadmap の想定は 5〜20 分） |
| `./tools/dev.ps1 clean` | `build/` を削除 | — |

上記のうち `test` / `test-native` / `test-managed` / `test-asan` は 2026-08-27 に、ネイティブ成果物が最新の状態（直前のビルドから変更なし）で再実測した値である。**M1 時点でソースの変更を伴う増分ビルドを計測したときは `test` が約 65 秒（`test-native` 約 28 秒、`test-managed` 約 43 秒）だった。** 差の主因は毎回のビルドで実際に何を再コンパイルするかで、OpenCV の `find_package` を伴う CMake の再 configure 自体は毎回走る。成果物が最新かどうかで数字は大きく動くので、ここでの「実測」は目安であって上限の保証ではない。

「ローカルループは秒単位を死守する」という不変条件（本ファイル下部）と、ソース変更を伴う `test` の実測（約 65 秒）はすでに緊張関係にある。M1 ではこれを**受け入れて記録するに留めており、解消していない**。着手するなら configure の結果を跨いで再利用するか、OpenCV に依存しないレーンを分けることになる。

重いツールテスト 2 本（`VerifyOpenCvArtifact` は 1 ケースごとに `pwsh -NoProfile -File` を起こす作りで単体 69 秒、`OpenCvRestore` は実 download）は `test` から外して `test-tools-slow` に分け、必須チェック `ci-native` の step として走らせている。**ローカルで走らないが、CI では必ず走る。** どこからも走らない状態にしないことが目的である（M1 のレビュー H2）。

`tools/dev.ps1` は OpenCV を自動では取得しない。`native` の configure/build より先に `./tools/opencv.ps1 restore` を実行しておくこと（未実行だと明示的なエラーで止まる）。

| コマンド | 内容 |
| --- | --- |
| `./tools/opencv.ps1 restore` | **既定**。CI が公開した artifact を `gh run download` で取得する（`gh` CLI と認証が必要）。ローカルでビルドしない |
| `./tools/opencv.ps1 build` | ローカル再現用の遅い経路。CI 実測は clone〜verify まで通しで 4 分 09 秒（`windows-2022` runner、run 32849957498）。ローカルでの実測はまだ無い。CI の結果を検証するときだけ使う |
| `./tools/opencv.ps1 verify` | 展開済みツリーに対して依存 allowlist を再検証する |
| `./tools/opencv.ps1 status` | 現在の構成ハッシュと展開状態を表示する |
| `./tools/opencv.ps1 clean` | `third_party/opencv/<hash>/` を削除する |

ビルド構成は `CMakePresets.json` の `windows-x64-debug` と `windows-x64-asan` の 2 つ。OpenCV のビルド構成は `tools/opencv-config.psd1` の 1 箇所に集約され、そこから算出される構成ハッシュが artifact 名と展開先ディレクトリ名（`third_party/opencv/<hash>/`）に埋め込まれる。開発環境の要件は `README.md` の Requirements にある（Visual Studio 2022 の C++ ワークロード / CMake 3.25+ / .NET 8 SDK / PowerShell 7+ / `gh` CLI）。

**非 ASCII を出力する PowerShell スクリプトは必ず `[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()` を先頭で設定する。** 指定しないと Windows の既定 ANSI コードページ（日本語環境は cp932、CI の en-US runner は cp1252）で書き出され、エラーメッセージの日本語部分が文字化けするか非可逆に失われる。M1 中に 3 つの別スクリプトで同じ欠落が独立に起きており、隣接するファイル（`tools/opencv.ps1` や `tools/verify-opencv-artifact.ps1`）に同じ対応が既にあっても、それを読むだけでは発見できないことが実証済みである。新しい PowerShell スクリプトを書くときは必ずこれを先頭に置くこと。

### ファイル配置

| 場所 | 内容 |
| --- | --- |
| `native/include/opencv_unity_native.h` | 公開 C ABI ヘッダ。`OCVU_STATUS_LIST` が status code の唯一の定義元 |
| `native/src/` | C ABI 実装（version / last-error / status 表 / debug throw・crash / OpenCV version・build information / `Mat` のライフサイクルと buffer 転送 / imgproc 3 関数） |
| `native/tests/` | L1 の GoogleTest と、意図的にクラッシュ・ハングする `ocvu_probe` |
| `cmake/run_expect_failure.cmake` | 「失敗するはずのコマンド」を走らせる CTest ドライバ |
| `cmake/FindOpenCvUnityDeps.cmake` | `third_party/opencv/<hash>/` を探して OpenCV を取り込む |
| `tools/opencv-config.psd1` | OpenCV ビルド構成の唯一の定義元（tag、module allowlist、CMake flags） |
| `tools/OpenCvConfig.psm1` | 構成の読み込みと構成ハッシュの算出（`opencv.ps1` と CI の両方が使う） |
| `tools/opencv.ps1` | OpenCV の `restore` / `build` / `verify` / `status` / `clean` の入口 |
| `tools/verify-opencv-artifact.ps1` | ビルド済み OpenCV ツリーに対する依存 allowlist の検証（denylist ではない） |
| `third_party/opencv/<hash>/` | 展開先（gitignore 済み）。`build-manifest.json` に実測の構成が入る |
| `THIRD_PARTY_NOTICES.md` | OpenCV が bundle する third-party（zlib / libpng / libjpeg-turbo / libclapack）のライセンス全文 |
| `Packages/com.ayutaz.opencv-unity-native/` | UPM パッケージ本体（`Runtime/Core`、`Runtime/Interop`、`Runtime/UnityIntegration`） |
| `Packages/com.ayutaz.opencv-unity-native/Runtime/UnityIntegration/` | UnityEngine に依存するコード（`TextureConverter` 等）を置く別 asmdef。`Runtime/Core` / `Runtime/Interop` には置かない |
| `tests/Managed/CvUnity.Runtime.Shim/` | netstandard2.1 の shim。UnityEngine 非依存をビルドで強制する |
| `tests/Managed/CvUnity.Tests.Managed/` | L3 の xUnit テスト（net8.0）。`HarnessProbeTests.cs` がクラッシュ・ハングプローブを持つ |
| `tests/UnityProject/` | L4（EditMode）と L5（IL2CPP Player）用の最小 Unity プロジェクト。UPM パッケージは `manifest.json` から `file:../../../Packages/...` でローカル参照する |
| `.github/workflows/` | `ci-native.yml`（L1 + L3）、`ci-sanitizers.yml`（L2）、`build-opencv.yml`（OpenCV のビルドと artifact 公開）、`ci-unity.yml`（L4 + L5。**書かれているが CI では一度も実行されていない。**残作業は 3 つで、うち 2 つはエージェントが書ける — ランナーへの Unity 導入、アクティベーションの実装、Secrets 登録。**資格情報を登録しただけでは動かない。**現在 trigger は `workflow_dispatch` のみ） |

正本となる設計文書:

- `docs/roadmap.md` — **確定事項と M0〜M7 のマイルストーン定義。まずここを読む。**
- `docs/superpowers/plans/2026-08-25-m0-tdd-harness.md` — M0 の実装計画（タスク単位、TDD 手順つき）
- `docs/superpowers/plans/2026-08-25-m1-opencv-build.md` — M1 の実装計画（タスク単位、TDD 手順つき）
- `docs/superpowers/plans/2026-08-26-m2-windows-vertical-slice.md` — M2 の実装計画（タスク単位、TDD 手順つき）
- `docs/abi-ownership-and-versioning.md` — `Mat` と Unity メモリの所有権契約、`OCVU_ABI_VERSION` の versioning 規約、`core`/`imgproc` API allowlist の正本
- `docs/unity-opencv-integration-research-and-plan.md` — 競合調査、アーキテクチャ、ライセンス方針、命名方針（519 行）
- `docs/native-backend-language-tdd-evaluation.md` — C++ / Rust の評価とテストハーネス設計
- `docs/README.md` — 文書一覧とステータス

## 確定事項

| 項目 | 決定 |
| --- | --- |
| native backend 実装言語 | **C++**（Rust spike は不要になった） |
| UPM package ID | **`com.ayutaz.opencv-unity-native`** |
| 対象 Unity | **6000.x のみ**（2022 LTS 非対応） |
| C# ターゲット | netstandard2.1 / C# 9 |
| OpenCV 入手 | allowlist 構成で CI がビルドし artifact 配布。**ローカルではビルドしない** |
| CI/CD | public OSS のため GitHub Actions を全面活用。重い検証はすべて CI |
| Windows の compiler / runtime linkage | **共有（/MD、`CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL`）。embedded（/MT）にしない。** このパッケージを組み込む開発者が、自分のゲームに何を同梱するかを自分で決められる状態を保つのが理由で、パッケージ側が選択肢を奪わない（M1 Task 8）。OpenCV 自身は `BUILD_WITH_STATIC_CRT=OFF` を明示しないと `cmake/OpenCVCRTLinkage.cmake` がこの指定を黙って /MT へ上書きする（M1 Task 7 で発見） |

この文書の記述は「確認済み事実 / プロジェクト自己申告 / 提案」に区別されている（同文書 §2）。設計を語る際はこの区別を維持し、**提案を実装済みの事実として扱わない**こと。

## プロジェクトの目的

> OpenCV 5 C++ を、Unity / IL2CPP 向けの安定した独自 C ABI と C# API で提供する、再現可能なネイティブ UPM パッケージ。

Apache-2.0 の OSS として公開予定。既存の代替（Enox の OpenCV for Unity、neon-izm/OpenCV-plus-Unity、OpenCvSharp、Emgu CV）との差別化は「機能の総数」ではなく **OpenCV 5 / OSS / OpenCvSharp 非依存の Unity 専用 ABI / ビルド再現性 / Unity データとの低コピー連携** に置く。

## アーキテクチャの中核

レイヤ構成（同文書 §6）:

```
Unity application
  -> Unity integration layer (Texture2D / WebCamTexture / NativeArray / lifecycle)
  -> C# public API + 生成された P/Invoke 宣言
  -> プロジェクト所有のバージョン付き C ABI (opaque handle / error code / 明示的 ownership)
  -> native bridge (C++)
  -> OpenCV 5 C++ API
```

複数ファイルを読まないと分からない、実装時に効いてくる不変条件:

- **C ABI が唯一の native contract**。`cv::Mat*` や STL 型を境界の外へ出さない。`ocvu_mat_handle` のような opaque handle と固定サイズ型（`int32_t`、`uint64_t`、明示 struct）のみを公開する。
- **例外を ABI の外へ伝播させない**。OpenCV / C++ 例外は status code + thread-local last-error に変換する。FFI 境界を越える unwind は未定義動作になり得る。公開 ABI 関数は原則 `OCVU_TRY_BEGIN` / `OCVU_TRY_END` で本体を囲む。**ただし `ocvu_get_last_error_status` と `ocvu_get_last_error_message` は囲んではならない**: `OCVU_TRY_BEGIN` は `clear_last_error()` を呼ぶため、エラーを報告するために存在する関数が、報告すべきエラーを読む直前に自分で消してしまう。同様に `ocvu_get_abi_version` と `ocvu_get_status_count` は `ocvu_status` を返さないので囲めない。囲まない関数は「throw し得ない実装であること」が条件であり、この一覧は `native/src/ocvu_error.h` のマクロ定義の隣にも書いてある。
- **エラー報告経路自体が throw してはならない**。`ocvu::set_last_error` は `OCVU_TRY_END` の `catch (std::bad_alloc&)` の内側からも呼ばれる。よってアロケートせず、固定長 thread-local バッファへの bounded copy だけを行う（`noexcept` で契約を固定している）。上限を超えたメッセージは UTF-8 の文字境界で切り詰められ、`out_required_size` は常に「実際に取得できるバイト数 + NUL」を返す。
- **`ocvu_mat_handle` は常に native が所有する。Unity 所有のメモリを指す handle を返さない**（`docs/abi-ownership-and-versioning.md` §1 で確定）。Unity 側の buffer はその場でポインタ・長さ・stride を受け取って読み書きするだけで、handle にはならない。借用は 1 回の ABI 呼び出しの内側で完結する。理由は、借用 handle が buffer より長く生きたときの壊れ方が「即座には落ちず、後から無関係な場所が壊れる」形で、Windows の ASan は Unity のアロケータを見られないため CI でも検出できないからである。規約で禁じるのではなく、**表現できなくする**。buffer 引数の長さと stride は必ず検証し、`rows * stride` が渡された長さを超えるなら何も書かずに `OCVU_STATUS_INVALID_ARGUMENT` を返す（呼ぶ側を信用しない）。
- **C ABI と C# 宣言は手書き header の無制限解析から生成しない**。レビュー可能な binding specification（`bindings/spec/`）を正本とし、そこから C ABI 宣言 / C# P/Invoke / API 対応表 / conformance test を生成する。
- **IL2CPP / AOT を前提とする**。P/Invoke 宣言が stripping で消えないことを検証する。iOS は静的リンク + `DllImport("__Internal")`。
- **毎フレームの細かな境界呼び出しを避ける**。必要に応じて処理をまとめた粒度の粗い API も用意する。

命名規約（同文書 §11）:

| 用途 | 名前 |
| --- | --- |
| リポジトリ / 表示名 | `OpenCVUnityNative` / OpenCV Unity Native |
| C# namespace・ブランド | `CvUnity` |
| native library | `opencv_unity_native` |
| C ABI 関数 prefix | `ocvu_` |
| UPM package ID | `com.ayutaz.opencv-unity-native` |

`OpenCV for Unity`、`OpenCV-plus-Unity`、`UnityCV` は既存製品との混同・衝突のため使わない。

## 重要な制約

- **OpenCV 5 は 4.x の互換 wrapper ではない**。レガシー C API は完全削除済み、最低 C++17、`calib3d` は `geometry`/`calib`/`stereo`/`ptcloud` へ、`features2d` は `features` へ再編。ML・G-API・Haar/HOG 系の一部は contrib へ移動。API 設計は 5.x のモジュール構成を基準にする。
- **OpenCvSharp5 を Unity に持ち込む前提で設計しない**。managed layer が net8.0 / C# 12 対象で、Unity の managed plug-in は .NET Standard / .NET Framework 対象。OpenCvSharp の managed API 名を互換目的で複製することも目的外。
- **「本体が Apache-2.0」と「バイナリ内の全依存が Apache-2.0」は別問題**（同文書 §8.2）。OpenCV の CMake は FFmpeg / GStreamer / JPEG / PNG / TIFF / WebP / OpenEXR / protobuf / IPP 等の optional・bundled 依存を持ち、`WITH_FFMPEG` は既定で有効。初期標準 build では `videoio` と FFmpeg/GStreamer を外し、`imgcodecs` は notice 確認後に opt-in。**CMake configure summary を保存し、想定外の依存が有効なら CI を失敗させる**。
- native artifact ごとに OpenCV tag、contrib tag、compiler、toolchain、CMake flags、依存 version、hash を manifest 化する（`artifacts/<platform>/build-manifest.json`、`sbom.spdx.json`）。
- ライセンス面はプロジェクト方針であり法的助言ではない。公開前に別途法務確認が必要。

## 開発の進め方: TDD と自動イテレーション

**すべての実装を TDD で行い、開発イテレーションを自動で回す。** この前提から次が導かれる（詳細は `docs/native-backend-language-tdd-evaluation.md` §5）。

**テストレーン**（層が上がるほど遅く、実行頻度を下げる）

| 層 | 内容 | 想定時間 | 導入 |
| --- | --- | --- | --- |
| L0 | spec → 生成物の golden test | < 1 秒 | M5 |
| L1 | C ABI 契約テスト（GoogleTest + CTest） | 1〜5 秒 | M0 |
| L2 | ASan / UBSan レーン | 10〜30 秒 | M0 |
| L3 | **P/Invoke 検証（素の .NET、Unity 不使用）** | 2〜5 秒 | M0 |
| L4 | Unity EditMode (Mono) | 1〜3 分 | M2 |
| L5 | Unity IL2CPP Player | 5〜20 分 | M2 |

**「想定時間」は roadmap 起草時の見積もりであり、実測はもっと速い。** `dev.ps1 test-unity-editmode` は約 24 秒、`dev.ps1 test-unity-player`（IL2CPP Player の実ビルド込み）は約 50 秒だった（いずれも 2026-08-27、Unity / Bee のキャッシュが温まった状態での増分実測。cold の実測はまだ無い）。両レーンとも `tests/UnityProject/` から `Packages/com.ayutaz.opencv-unity-native/` をローカル参照して動く。CI（`ci-unity.yml`）はまだ一度も走っていないので、CI 実測はまだ無い。

**L3 のクラッシュ・ハング耐性は M2 Task 4 で実証済み。** `ocvu_debug_crash`（`native/src/ocvu_debug.cpp`、kind=0 で不正アクセス、kind=1 で無限ループ。戻らない前提の関数なので `OCVU_TRY_BEGIN` では囲まない）を `tests/Managed/CvUnity.Tests.Managed/HarnessProbeTests.cs` から P/Invoke し、`tools/run-managed-probe.ps1`（`dev.ps1 test-managed-probe` 経由）が「非 0 終了かつ有限時間」を assertion する形で確かめている。実測（このマシン、2026-08-27）: segfault は `AccessViolationException` で 6 秒後に非 0 終了、hang は `--blame-hang-timeout 30s` に捕まり 36 秒後に非 0 終了・hangdump を生成。いずれも 60〜180 秒の上限内に収まった。数字は実行のたびに数秒動く（初回計測では 5 秒 / 35 秒だった）。L1 / L2 の `native/tests/ocvu_probe.cpp` が持つ expect-failure の構図（`cmake/run_expect_failure.cmake`）の L3 版であり、`cmake/run_expect_failure.cmake` 同様「非 0 で終わっただけ」では合格にせず、スタックトレース／hangdump の宛先テスト名でプローブが意図した経路に実際に到達したことまで見ている。このプローブは意図的に落ちるため通常の `dev.ps1 test` には含めない（`Category!=Probe` で除外、`StatusCodeSyncTests` 等の既存 L3 とは別枠）。数分かかるので CI 専用（`ci-native.yml` の「Run the L3 crash and hang probes」）で、ローカルでは走らない。

守るべき不変条件:

- **L3 を維持するために `Runtime/Interop` と `Runtime/Core` は `UnityEngine` を参照してはならない。** UnityEngine 依存コードは `Runtime/UnityIntegration/`（別 asmdef）にのみ置く。この制約は netstandard2.1 の shim プロジェクト（`tests/Managed/CvUnity.Runtime.Shim/`）がビルドで機械的に強制する。
- **ローカルループは秒単位を死守する。** 重い処理を持ち込まない。OpenCV はローカルでビルドせず、CI が生成した artifact を download する。
- **クラッシュは「赤いテスト」でなければならない。** ネイティブ層でループを殺す最大要因はテスト失敗ではなくハングとモーダルダイアログ。テストは必ずタイムアウト付きサブプロセスで実行し、Windows では `SetErrorMode` / `_CrtSetReportMode` でダイアログを抑止する。
- **CI はローカルと同一のコマンド（`tools/dev.ps1`）を呼ぶ。** CI 専用の手順を作らない。全ジョブに `timeout-minutes` を設定する。
- **CI が唯一の正本の検証結果。** ローカルの green は速さのための近似であり、merge 可否は CI が決める。

## backend 言語決定の再評価トリガー

C++ を選んだ主因は、**sanitizer が安定版ツールチェーンで使えること**である（MSVC ASan は GA、Rust の sanitizer は nightly 限定）。加えて Miri は FFI 層を検査できないため、Rust の安全性優位はこのプロジェクトの危険な層で大きく減衰する。

次のいずれかが起きたら再評価の価値がある: **Rust の ASan / LSan が stable 化する**（Rust project goals の 2026 目標として進行中）／ Web または iOS がスコープから外れる ／ generator を採用せず bridge を大量に手書きする方針に変わる。

再評価を安価に保つため、**public C header と契約テスト（L1 / L3）は backend 実装から独立に保つ**。この不変条件は M0 で確立し、以降のすべてのマイルストーンで維持する。

## マイルストーン（現在地: M2 は 8 件中 7 件達成。未達 1 件 — 条件 7）

詳細と完了条件は `docs/roadmap.md` にある。要点のみ:

| M | 目的 |
| --- | --- |
| **M0** | **自動 TDD ハーネスの成立（OpenCV 非依存）。** 反復速度の土台を他の何よりも先に固定する — **完了** |
| **M1** | **OpenCV 5.0.0 の再現可能ビルド。CI がビルドし artifact 配布、ローカルは download のみ — 完了** |
| **M2** | **Windows vertical slice。API の広さではなく ownership / stride / エラー / IL2CPP の正しさを確定 — 8 件中 7 件達成。未達は条件 7（CI で L4/L5 が一度も実行されていない。Unity 導入とアクティベーション実装が未着手で、資格情報登録だけでは動かない）** |
| M3 | Desktop 3 platform と配布の再現性。Linux レーンでリーク検出（MSVC ASan は LSan 非対応）。**M1 が見送った「成果物の linkage・有効言語・リンク済み依存が構成の意図と一致するか」の機械的検証もここで拾う**（送った CMake flag ではなく、できたバイナリを読む。まず Windows 分から） |
| M4 | Mobile。ここで見つかる制約（stripping、static link、16 KB page size）が M5 の生成コードの形を規定する |
| M5 | binding specification と generator |
| M6 | Web / Wasm（Unity 同梱 Emscripten と整合） |
| M7 | Optional profiles と性能 |

**M2 以降の完了条件には、native 単体テストだけでなく実際の Unity Player から C# → P/Invoke → C ABI → OpenCV を通る smoke test を含める。** M2 はこれをローカルで満たした（L4 / L5 とも green）。CI 上での実行だけが残っている。

## 実装に着手するとき

1. `docs/roadmap.md` で対象マイルストーンの目的・ゴール・完了条件・**非ゴール**を確認する
2. 実装計画があればそれに従う。M0 の計画は `docs/superpowers/plans/2026-08-25-m0-tdd-harness.md`、M1 の計画は `docs/superpowers/plans/2026-08-25-m1-opencv-build.md`、M2 の計画は `docs/superpowers/plans/2026-08-26-m2-windows-vertical-slice.md`（いずれも実施済み。M2 は Task 8 まで完了しているが、完了条件 7 件目は上記のとおり未達）。M3 以降の計画はまだ無いので、`superpowers:writing-plans` で先に書く
3. 計画は**マイルストーンごとに 1 つ**書く。各計画は単独で動作・テスト可能なソフトウェアを produce すること

M2 以降で確定が必要な残りの事項（計画書 §12 のうち未決定分）: OpenCV 5.0.0 の固定期間と 5.x update policy、ライセンス表示と SBOM の公開フロー、各 platform で必須とする Editor / Mono / IL2CPP / device test matrix。

決定済みで、計画書 §12 の記述より新しいもの（**計画書より下の表と参照先を優先すること**）:

| 事項 | 決定 | 決定場所 |
| --- | --- | --- |
| Windows の compiler / runtime linkage | 実行時ライブラリは共有する形。組み込む開発者が同梱物を選べる状態を保つ | M1 Task 8。上の「確定事項」表 |
| `Mat` と Unity メモリの lifetime contract | **借用 handle を作らない。** handle は常に native 所有、Unity の buffer は呼び出し内で完結する借用 | `docs/abi-ownership-and-versioning.md` §1 |
| C ABI の versioning / 後方互換 | 単一整数の `OCVU_ABI_VERSION`、C# 側は**完全一致**で検査。bump する変更としない変更を明記 | 同 §2 |
| 初期 `core` / `imgproc` API の allowlist | Mat の create / release / clone / get_info / copy_from_buffer / copy_to_buffer と cvtColor / resize / GaussianBlur の 9 本 | 同 §3 |

ディレクトリ構成の想定は計画書 §10 にある（`native/`、`bindings/spec|generator|generated-checks/`、`Packages/com.ayutaz.opencv-unity-native/`、`tests/UnityProject/`、`tools/`、`cmake/`、`.github/workflows/`）。このうち `native/`、`Packages/com.ayutaz.opencv-unity-native/`、`tests/Managed/`、`tools/`、`cmake/`、`.github/workflows/` は M0 で実在するようになり、`tests/UnityProject/` は M2 で実在するようになった。`bindings/`（M5 予定）だけがまだ無い。

## 変更を main へ入れるまで

**人間のレビューは挟まない。したがって PR を出す前の AI レビューが唯一のゲートである。**
この順序を守ること。

1. **main で直接作業しない。** ブランチを切る。
2. 実装する（TDD。マイルストーン作業なら該当する計画に従う）。
3. **ローカルで全レーンを回す** — `tools/dev.ps1 test`、メモリを触ったなら `test-asan` も。
4. **AI レビューをここで行う。** PR を出した後ではない。差分全体を、タスク単位ではなく
   ブランチ単位で見る。指摘が出たら修正し、修正差分をスコープを絞って再レビューする。
   マイルストーンの完了なら `milestone-complete` skill の手順を踏む。
5. push して PR を作る。PR 本文には、何を成立させたか・実測値・**意図的に見送ったもの**を書く。
   穴があるなら隠さず書く。読むのは将来の自分と外部の利用者である。
   **ステップ 4 のレビュー結果も本文に残す** — 何が指摘され、どう直したか。GitHub 側は
   レビューが行われたかを検査できないので、ここに書かれていないことは省略されたのと
   区別がつかない。省略を「見えない」から「見て分かる」に変えるのがこの記載の役目である。
6. **CI が全パスしたらマージする。** 落ちたら直す。ローカルが緑で CI が赤なら CI が正しい。

この流れの帰結として、**PR は「レビューしてもらう場」ではなく「CI に判定させる場」**である。
レビューで見つかるはずだったものは、PR を出した時点で全部潰れていなければならない。

### 「AI レビュー」の定義

**書いた本人が読み返すことはレビューではない。** ステップ 4 は、**その差分を書いていない
別のエージェントを起動して**行う。実装したエージェントが自分の差分を読み直して
「レビュー済み」と称するのが、この流れで最も起きやすい失敗である。文面上は満たせるが、
ゲートとしては機能していない。

レビュアーには次を渡す: ブランチ全体の差分、対象マイルストーンの完了条件（あれば）、
このリポジトリの不変条件。そして**何を指摘してほしくないかを事前に伝えない**。
偽陽性だと思う指摘は、出させてから自分で裁定する。

### PR を出した後に直したとき

CI が赤くて直した場合、その修正差分にもレビューが要るかを判断する。

- **要る** — 挙動・スコープ・公開 API・文書のいずれかが変わったとき。CI は
  ビルドと L1 / L2 / L3 しか見ない。文書の陳腐化、過大な主張、スコープ超過は
  素通りする。**M0 で Critical になったのはまさにこの種類で、CI は緑のままだった。**
- **要らない** — CI 環境側の問題（runner の一時障害、キャッシュキー）や、
  挙動を変えない機械的な修正。

判断に迷うなら要る側に倒す。修正差分は小さいので、スコープを絞った再レビューは安い。

### 機構として強制されていること

この流れは慣習ではなく、GitHub 側の設定で強制されている。守ろうとしなくても守らされる。

| 設定 | 値 | 意味 |
| --- | --- | --- |
| main の branch protection | 有効 | 直接 push は `GH006` で拒否される |
| 必須チェック | `Windows x64 (L1 + L3)` / `Windows x64 AddressSanitizer (L2)` | 両方 pass しないと merge できない |
| strict | 有効 | ブランチが main より古いと merge できない（`allow_update_branch` で自動更新可） |
| 必須レビュー数 | **0** | PR は必須だが人間の承認は不要 |
| enforce_admins | **有効** | 管理者も例外ではない。抜け道は無い |
| 許可されるマージ方式 | **squash のみ** | merge commit と rebase は無効 |
| linear history | 必須 | main は一直線に保たれる |
| force push / ブランチ削除 | 禁止 | main の履歴は書き換えられない |
| auto-merge | 有効 | `gh pr merge <n> --auto --squash` で予約でき、CI が緑になった時点で自動的に入る |

main には squash された 1 コミットしか残らないので、**squash の本文にそのブランチの要約を書く**。
個々のコミットは PR ページに残る。

**CI が構成上の理由で永久に赤くなった場合**（runner イメージの廃止など）、必須チェックを
満たせないため main が固まる。その場合は protection を一時的に外して直し、すぐ戻す。
これは意図的に「面倒な操作」にしてある。日常の抜け道として使わないこと。

### CI が保証していないこと

「CI が唯一の正本の検証結果である」は **merge 可否の判定について**の話であって、
「CI が緑なら正しい」という意味ではない。CI が見ているのは Windows x64 の
ビルドと L1 / L2 / L3 だけである。次はどれも緑のまま通過する。

- 文書の陳腐化（M0 で Critical になった経路。CI は緑だった）
- 完了条件を満たしていないのに完了と称すること、スコープ超過
- Windows 以外のプラットフォーム、Unity Editor / Player 上の挙動（M2 以降）
- メモリリーク（MSVC ASan は LeakSanitizer 非対応。M3 の Linux レーンの担当）

**これらを見るのが PR 前の AI レビューである。** 2 つのゲートは重なっておらず、
どちらかで代替できない。CI が機械的に検査できないものを人手なしで拾う唯一の場が
ステップ 4 であり、だからそこを省略すると誰も見ていないことになる。

## このリポジトリの skill と hook

`.claude/` にプロジェクト固有の skill と hook がある。いずれもコミット済みで、
全員・全エージェントに効く。

**skill**（手順。CLAUDE.md が「事実」を持ち、skill が「手順」を持つ）

| skill | いつ使うか |
| --- | --- |
| `add-abi-function` | `ocvu_` の ABI 関数を追加・変更・削除するとき。ヘッダ → 実装 → L1 → P/Invoke → L3 → status 同期の TDD 順序と、所有権・バッファ・例外バリアの規約 |
| `milestone-complete` | マイルストーンの完了を判定するとき。roadmap の完了条件との実測照合、**文書の陳腐化確認**、CI での確定 |
| `prove-a-check-works` | テスト・assertion・検証スクリプト・allowlist・CI ゲート・hook を足すか変えるとき。**壊して落ちることを見るまで、その検査は動くと言えない。** M1 の全タスクが同じ欠陥（著者が列挙した形だけを見る）を生んだので手順にした |

**hook**（`.claude/settings.json`）

| hook | 契機 | 動作 |
| --- | --- | --- |
| `block-bulk-git-add.sh` | PreToolUse (Bash/PowerShell) | `git add -A` / `git add .` を**拒否**。連結コマンド内も見る |
| `check-unityengine-leak.sh` | PostToolUse (Write/Edit) | `Runtime/Interop` と `Runtime/Core` への `UnityEngine` 混入を指摘 |
| `check-exception-barrier.sh` | PostToolUse (Write/Edit) | `ocvu_status` を返す `extern "C"` 関数の `OCVU_TRY_BEGIN` 囲い忘れを指摘 |
| `check-powershell-encoding.sh` | PostToolUse (Write/Edit) | 非 ASCII を出力する `.ps1` / `.psm1` の `[Console]::OutputEncoding` 未設定を指摘。M1 で 3 つの別々のスクリプトに順に現れた |
| `check-assertions-reachable.sh` | PostToolUse (Write/Edit) | `*.Tests.ps1` で、終了コードを決めた後ろに置かれ**落ちようがない** assertion を指摘 |

後の 2 つが検出するのは、どちらも M1 で実際に起きたものである。前者は修正が隣の
ファイルに在っても再発し、後者は PASS 表示が出るので目視では気づけなかった。
「近くのコードを読めば分かる」類ではないから機械に見させている。

hook は PowerShell ではなく **sh** で書いてある。この環境では pwsh の起動に
約 3.3 秒、python に約 2.4 秒かかるのに対し sh は約 0.19 秒で、hook は毎回の
ツール呼び出しで走るため起動コストがそのまま開発ループの速度になる。副次的に
macOS / Linux でもそのまま動くので M3 で書き直さなくてよい。`jq` が無い環境では
黙って素通しする（hook が理由でツールが使えなくなる方が有害なため）。

**hook にマイルストーン固有の不変条件を入れないこと。** 例えば「OpenCV に依存
しない」は M0 限定で M1 で失効する。期限のある条件を hook に埋めると、まさに
M0 で `CLAUDE.md` が陥ったのと同じ陳腐化を起こす。

## Unity 起動

Unity プロジェクトを開く必要が生じたら、`uloop-launch` skill を使うと Editor バージョンを合わせて起動できる。
