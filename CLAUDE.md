# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## リポジトリの現状

**M0（自動 TDD ハーネス）は完了している。** ビルドシステム、C ABI の骨格、テストレーン 3 本（L1 / L2 / L3）がすべて存在し、ローカルでも CI でも green になる。

**ただし OpenCV との統合はまだ何も無い。C ABI は骨格のままである。** 現在の公開 ABI は `ocvu_get_abi_version`、last-error の取得、status 表の照会、conformance 用の `ocvu_debug_throw` だけで、OpenCV への依存はリポジトリのどこにも存在しない。M0 が固定したのは反復速度の土台であって機能ではない。

### 開発コマンド

ローカル開発はすべて `tools/dev.ps1` を通す。これが唯一の入口であり、CI も同じコマンドを呼ぶ（CI 専用の手順は無い）。PowerShell 7 以上が必要。

| コマンド | 内容 | 実測 |
| --- | --- | --- |
| `./tools/dev.ps1 build` | native の configure + build | — |
| `./tools/dev.ps1 test` | **既定**。L1 + L3 | 約 20 秒 |
| `./tools/dev.ps1 test-native` | L1 のみ（GoogleTest + CTest） | 約 14 秒 |
| `./tools/dev.ps1 test-managed` | L3 のみ（xUnit から P/Invoke） | 約 12 秒 |
| `./tools/dev.ps1 test-asan` | L2（AddressSanitizer） | 約 20 秒（cold build 時はさらに掛かる） |
| `./tools/dev.ps1 clean` | `build/` を削除 | — |

実測はいずれも増分ビルド時のもので、うち約 5 秒はハング検出テストの待ち時間。`test` は fail-fast で、L1 が落ちた時点で L3 は走らない。結果は `artifacts/test-results/*.xml` に出る（各コマンドの開始時に空にされる）。

ビルド構成は `CMakePresets.json` の `windows-x64-debug` と `windows-x64-asan` の 2 つ。開発環境の要件は `README.md` の Requirements にある（Visual Studio 2022 の C++ ワークロード / CMake 3.25+ / .NET 8 SDK / PowerShell 7+）。

### ファイル配置

| 場所 | 内容 |
| --- | --- |
| `native/include/opencv_unity_native.h` | 公開 C ABI ヘッダ。`OCVU_STATUS_LIST` が status code の唯一の定義元 |
| `native/src/` | C ABI 実装（version / last-error / status 表 / debug throw） |
| `native/tests/` | L1 の GoogleTest と、意図的にクラッシュ・ハングする `ocvu_probe` |
| `cmake/run_expect_failure.cmake` | 「失敗するはずのコマンド」を走らせる CTest ドライバ |
| `Packages/com.ayutaz.opencv-unity-native/` | UPM パッケージ本体（`Runtime/Core`、`Runtime/Interop`） |
| `tests/Managed/CvUnity.Runtime.Shim/` | netstandard2.1 の shim。UnityEngine 非依存をビルドで強制する |
| `tests/Managed/CvUnity.Tests.Managed/` | L3 の xUnit テスト（net8.0） |
| `.github/workflows/` | `ci-native.yml`（L1 + L3）、`ci-sanitizers.yml`（L2） |

正本となる設計文書:

- `docs/roadmap.md` — **確定事項と M0〜M7 のマイルストーン定義。まずここを読む。**
- `docs/superpowers/plans/2026-08-25-m0-tdd-harness.md` — M0 の実装計画（タスク単位、TDD 手順つき）
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
- **ownership を仕様に明記する**。create / retain / release、borrowed / owned、pointer・stride・buffer length・alignment・lifetime をすべて binding specification 側に書く。`Mat` 所有メモリと Unity 所有 NativeArray メモリの lifetime contract は未決定事項の一つ。
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

**L3 のクラッシュ・ハング耐性はまだ証明されていない。** L1 / L2 には意図的にクラッシュ・ハングする `native/tests/ocvu_probe.cpp` があり、「クラッシュが赤いテストになる」ことを expect-failure テストで実証している。L3 には同等のプローブが無い。`tools/dev.ps1` は `dotnet test --blame-hang --blame-hang-timeout 60s` で時間の上限だけは与えているが、managed 側からネイティブがクラッシュ／デッドロックしたときに本当に有限時間で赤くなるかは未検証である。managed の expect-failure プローブを足すのは M2 の作業。**それまで L3 にこの耐性があると仮定しないこと。**

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

## マイルストーン（現在地: M0 完了、次は M1）

詳細と完了条件は `docs/roadmap.md` にある。要点のみ:

| M | 目的 |
| --- | --- |
| **M0** | **自動 TDD ハーネスの成立（OpenCV 非依存）。** 反復速度の土台を他の何よりも先に固定する — **完了** |
| **M1** | **OpenCV 5.0.0 の再現可能ビルド。CI がビルドし artifact 配布、ローカルは download のみ — 次はここ** |
| M2 | Windows vertical slice。API の広さではなく ownership / stride / エラー / IL2CPP の正しさを確定 |
| M3 | Desktop 3 platform と配布の再現性。Linux レーンでリーク検出（MSVC ASan は LSan 非対応） |
| M4 | Mobile。ここで見つかる制約（stripping、static link、16 KB page size）が M5 の生成コードの形を規定する |
| M5 | binding specification と generator |
| M6 | Web / Wasm（Unity 同梱 Emscripten と整合） |
| M7 | Optional profiles と性能 |

**M2 以降の完了条件には、native 単体テストだけでなく実際の Unity Player から C# → P/Invoke → C ABI → OpenCV を通る smoke test を含める。**

## 実装に着手するとき

1. `docs/roadmap.md` で対象マイルストーンの目的・ゴール・完了条件・**非ゴール**を確認する
2. 実装計画があればそれに従う（M0 の計画は `docs/superpowers/plans/2026-08-25-m0-tdd-harness.md`。実施済み）。M1 の計画はまだ無いので、`superpowers:writing-plans` で先に書く
3. 計画は**マイルストーンごとに 1 つ**書く。各計画は単独で動作・テスト可能なソフトウェアを produce すること

M1 以降で確定が必要な残りの事項（計画書 §12 のうち未決定分）: OpenCV 5.0.0 の固定期間と 5.x update policy、Windows の compiler / runtime linkage、`Mat` と NativeArray の lifetime contract、C ABI の versioning / backward compatibility policy、初期 `core` / `imgproc` API の具体的 allowlist、ライセンス表示と SBOM の公開フロー。

ディレクトリ構成の想定は計画書 §10 にある（`native/`、`bindings/spec|generator|generated-checks/`、`Packages/com.ayutaz.opencv-unity-native/`、`tests/UnityProject/`、`tools/`、`cmake/`、`.github/workflows/`）。このうち `native/`、`Packages/com.ayutaz.opencv-unity-native/`、`tests/Managed/`、`tools/`、`cmake/`、`.github/workflows/` は M0 で実在するようになった。`bindings/`（M5）と `tests/UnityProject/`（M2）はまだ無い。

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
- L3 のクラッシュ・ハング耐性（L1 / L2 にはプローブがあるが L3 には無い。M2 の作業）
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

**hook**（`.claude/settings.json`）

| hook | 契機 | 動作 |
| --- | --- | --- |
| `block-bulk-git-add.sh` | PreToolUse (Bash/PowerShell) | `git add -A` / `git add .` を**拒否**。連結コマンド内も見る |
| `check-unityengine-leak.sh` | PostToolUse (Write/Edit) | `Runtime/Interop` と `Runtime/Core` への `UnityEngine` 混入を指摘 |
| `check-exception-barrier.sh` | PostToolUse (Write/Edit) | `ocvu_status` を返す `extern "C"` 関数の `OCVU_TRY_BEGIN` 囲い忘れを指摘 |

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
