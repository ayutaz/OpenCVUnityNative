# OpenCV Unity Native ロードマップ

- 作成日: **2026-08-25**
- 文書の状態: 計画（実装済み機能の記録ではない）
- 前提: [競合調査と初期計画](./unity-opencv-integration-research-and-plan.md) / [Native backend 実装言語の評価](./native-backend-language-tdd-evaluation.md)

## 確定事項

| 項目 | 決定 | 根拠 |
| --- | --- | --- |
| native backend 実装言語 | **C++** | [言語評価](./native-backend-language-tdd-evaluation.md) §1。sanitizer が安定版ツールチェーンで使える、`opencv` crate の unstable 表明と `Mat` 共有可変性の警告を回避、iOS / Web のツールチェーン鎖が短い |
| UPM package ID | **`com.ayutaz.opencv-unity-native`** | 個人リポジトリとして公開 |
| 対象 Unity | **6000.x のみ**（2022 LTS 非対応） | 検証マトリクスを最小化。IL2CPP / .NET Standard 2.1 前提で単純化 |
| OpenCV 入手 | **allowlist 構成で 1 回ビルドしキャッシュ**（ビルドは CI が担当） | 計画書 §8.3 の依存方針を最初から満たす。開発ループでは artifact の download のみ |
| CI/CD | **GitHub Actions を全面的に活用** | public OSS リポジトリのため GitHub-hosted runner が無償。重い検証はすべて CI に寄せる |
| ライセンス | Apache-2.0 | 計画書 §8 |

## 開発方針

**すべての実装を Claude Code が TDD で行い、開発イテレーションを自動で回す。** この前提から次が導かれる。

1. **ハーネスが最優先の成果物である。** 言語評価の結論どおり、反復速度を決めるのは実装言語ではなくテスト構造である。よって M0 は OpenCV を一切含まず、ハーネスそのものを作って完成させる。
2. **Unity を経由しないテスト層を最大化する。** P/Invoke・マーシャリング・破棄経路は素の .NET 上で秒単位に検証し、Unity は Mono / IL2CPP / stripping の差分検証だけに使う。
3. **クラッシュは「赤いテスト」でなければならない。** ネイティブ層でループを殺す最大要因はテスト失敗ではなくハングである。タイムアウトとクラッシュダイアログ抑止を最初のマイルストーンに含める。
4. **各マイルストーンは単独で動作し、テスト可能なソフトウェアを produce する。** マイルストーンごとに個別の実装計画を書く。

### テストレーン

| 層 | 内容 | 想定時間 | 実行頻度 | 導入 |
| --- | --- | --- | --- | --- |
| L0 | spec → 生成物の golden test | < 1 秒 | 毎編集 | M5 |
| L1 | C ABI 契約テスト（GoogleTest + CTest） | 1〜5 秒 | 毎編集 | M0 |
| L2 | ASan / UBSan レーン | 10〜30 秒 | 毎コミット | M0 |
| L3 | P/Invoke 検証（素の .NET、Unity 不使用） | 2〜5 秒 | 毎編集 | M0 |
| L4 | Unity EditMode (Mono) | 1〜3 分 | pre-merge | M2 |
| L5 | Unity IL2CPP Player | 5〜20 分 | nightly / release | M2 |

### CI/CD 戦略

public OSS リポジトリのため GitHub-hosted runner を無償で使える。これを前提に、**ローカルループと CI の役割を明確に分離する**。

| | 担当 | 原則 |
| --- | --- | --- |
| **ローカル（エージェントの TDD ループ）** | L0〜L3 のみ | **秒単位を死守する。**重い処理を一切持ち込まない |
| **CI（GitHub Actions）** | 上記すべて + マトリクス、sanitizer、Unity、実機、Web | **網羅性を担当する。**時間をかけてよい |

この分離から導かれる重要な帰結:

- **OpenCV は CI がビルドし、artifact として配布する。** エージェントもローカル開発者も OpenCV を自分でビルドしない（`tools/opencv.ps1 restore` が固定ハッシュの artifact を download するだけ）。M1 の 30〜60 分のビルドコストが開発ループから完全に消える。
- **sanitizer レーンはローカルでは任意、CI では必須にする。** ローカルの毎編集ループは通常ビルドで秒単位を保ち、ASan / UBSan / Valgrind は push ごとに CI が全部回す。
- **マトリクスをケチらない。** platform × 構成 × Unity バージョンの組み合わせを削る理由がないため、削らない。
- **CI が唯一の正本の検証結果である。** ローカルの green は速さのための近似であり、merge 可否は CI が決める。

**ワークフロー構成**（各マイルストーンで段階的に追加）

| ワークフロー | トリガー | 内容 | 導入 |
| --- | --- | --- | --- |
| `ci-native.yml` | push / PR | L1 + L3、通常ビルド | M0 |
| `ci-sanitizers.yml` | push / PR | ASan / UBSan レーン | M0 |
| `build-opencv.yml` | 手動 + 構成変更時 | allowlist 構成の OpenCV をビルドし artifact 公開 | M1 |
| `ci-unity.yml` | PR / nightly | Unity EditMode (L4) + IL2CPP Player (L5) | M2 |
| `ci-desktop-matrix.yml` | push / PR | Windows / macOS / Linux マトリクス、Linux で LSan / Valgrind | M3 |
| `ci-mobile.yml` | nightly | Android / iOS ビルドと実機 smoke test | M4 |
| `ci-web.yml` | nightly | Unity 同梱 Emscripten での Wasm ビルドと browser E2E | M6 |
| `release.yml` | tag | 全 platform artifact、manifest、checksums、SBOM | M3 |

**CI が満たすべき制約**（ハーネスと同じ理由で、これらは M0 で確立する）

- ワークフローはローカルと**同一のコマンド**（`tools/dev.ps1`）を呼ぶ。CI 専用の手順を作らない
- すべてのジョブに `timeout-minutes` を設定する。ハングしたジョブが枠を占有しない
- テスト結果を機械可読形式（JUnit XML）で artifact 化し、失敗時に読める状態にする
- 依存は hash / tag で固定し、`actions/*` も含めてバージョンを明示する

---

## M0 — 自動 TDD ハーネスの成立（OpenCV 非依存）

**目的**
以降すべてのマイルストーンの反復速度を決める土台を、他の何よりも先に固定する。OpenCV を含めないのは、ハーネスの成立をハーネス単体で証明するためである。ここで妥協すると、以降の全マイルストーンが遅いループの上で進むことになる。

**ゴール**
OpenCV を一切含まない最小 C ABI に対して L1〜L3 が単一コマンドで回り、**クラッシュ・ハング・メモリ破壊が人手を介さず赤く落ちる**状態。

**完了条件**

- `tools/dev.ps1 test` 一発で L1（native）と L3（managed）が通り、失敗時に非ゼロ終了コードを返す
- segfault するプローブが 30 秒以内に赤で返る（モーダルダイアログが出ない）
- 無限ループのプローブが 5 秒で赤で返る
- ASan ビルドで use-after-free が `heap-use-after-free` を含む出力とともに検出される
- C++ 例外が ABI 境界を越えず、status code と last-error に変換されることがテストされている
- `Runtime/Interop` と `Runtime/Core` が netstandard2.1・C# 9 単体でコンパイルできる（＝UnityEngine 非依存が機械的に強制されている）
- `ci-native.yml` と `ci-sanitizers.yml` が **`tools/dev.ps1` と同一のコマンド**で通り、JUnit XML を artifact 化する
- すべての CI ジョブに `timeout-minutes` が設定されている

**非ゴール**
OpenCV の呼び出し。Unity Editor / Player テスト。画像処理。複数プラットフォーム。

**実装計画**: [docs/superpowers/plans/2026-08-25-m0-tdd-harness.md](./superpowers/plans/2026-08-25-m0-tdd-harness.md)

---

## M1 — OpenCV 5.0.0 の再現可能ビルドとキャッシュ

**目的**
計画書 §8.3 の依存 allowlist を**最初から**満たす。「後で依存を削る」は配布直前に破綻するため、最小構成を最初に確定させる。同時に、**OpenCV のビルドを CI に完全に追い出し**、開発ループから 30〜60 分のコストを消して M0 で得た反復速度を維持する。

**ゴール**
allowlist 構成の OpenCV 5.0.0 を **CI がビルドして artifact として公開**し、ローカルは download するだけで使える。**想定外の依存が有効になったら CI が落ちる。**

**完了条件**

- `build-opencv.yml` が固定 tag・固定 CMake flags で OpenCV 5.0.0 をビルドし、構成ハッシュ付きの artifact として公開する
- `tools/opencv.ps1 restore` が固定ハッシュの artifact を download・展開する（**ローカルビルドは発生しない**）
- `tools/opencv.ps1 build` がローカル再現用の経路として存在する（CI の結果を検証できる）
- `videoio` / FFmpeg / GStreamer が無効であることを CMake configure summary から機械的に検証し、有効なら非ゼロ終了する
- `build-manifest.json`（OpenCV tag、compiler、CMake flags、依存 version、hash）が artifact に含まれる
- 構成を変えると artifact のハッシュが変わり、古いキャッシュが使われないことをテストする
- M0 のハーネスが OpenCV にリンクした状態で全レーン通過を維持する

**非ゴール**
複数プラットフォーム対応（M1 は Windows x64 のみ）。パッケージ配布。SBOM の完成（M3）。

---

## M2 — Windows vertical slice

**目的**
API の広さを追わず、**ownership / stride / pixel format / エラー / IL2CPP の正しさ**を最小 API で確定する。ここで曖昧さを残すと、M5 の generator が誤った契約を大量に複製することになる。

**ゴール**
`Mat` のライフサイクルと少数の `imgproc` API が C# から動き、**Unity Editor (Mono) と Windows IL2CPP Player で同一結果**になる。

**完了条件**

- `ocvu_mat_*`（create / wrap / clone / query / release）と `cvtColor` / `resize` / `GaussianBlur` が C ABI にある
- 所有権契約が L3 で明示的にテストされている — borrowed と owned の区別、二重解放、解放後アクセス、Unity 側 buffer を wrap した際の lifetime
- Texture2D / NativeArray からの入力と結果反映が動く
- ABI version / OpenCV version / build features を実行時に問い合わせられる
- vertical slice 全体が ASan レーンで clean
- Unity EditMode (Mono) と Windows IL2CPP Player の両方で同じ smoke test が通る（L4 / L5 の導入）
- `ci-unity.yml` が CI 上で L4 / L5 を実行する（Unity ライセンスを GitHub Secrets に登録し、アクティベーションを自動化する）
- ローカル参照可能な最小 UPM パッケージとして動作する

**非ゴール**
Windows 以外のプラットフォーム。API の拡張。generator。

---

## M3 — Desktop 3 platform と配布の再現性

**目的**
「CI から再現できる native binaries」という差別化点（計画書 §7）を、主張ではなく**検証可能な事実**にする。

**ゴール**
Windows / macOS / Linux の native artifact が CI から再現生成され、UPM として導入できる。

**完了条件**

- 3 platform の CI build と、platform / architecture 別の Plugin Import Settings
- Git URL または tarball から導入できる UPM パッケージ
- artifact manifest、checksums、`THIRD_PARTY_NOTICES.md`、SBOM
- **Linux レーンでのリーク検出**（LeakSanitizer / Valgrind）— MSVC の ASan は LeakSanitizer 非対応のため、リーク検出は Linux CI が担う
- Unity sample と最小 API reference

**非ゴール**
mobile / Web。optional profile。

---

## M4 — Mobile

**目的**
独自 C ABI が Unity の**最も制約の強い実行環境**で成立することを確認する。ここで見つかる制約（stripping、static link、page size）は、M5 で生成するコードの形を規定する。

**ゴール**
Android arm64-v8a と iOS arm64 で実機 smoke test が通る。

**完了条件**

- Android arm64-v8a と iOS arm64 の native artifact を CI が生成する
- Android の 16 KB page size を CI で検証する
- iOS の `__Internal` static link と linker stripping 後も P/Invoke が解決することを実機で確認する
- lifecycle（background / foreground）と memory pressure を検証する
- カメラ入力は Unity の WebCamTexture / AR Foundation 側から受ける

**非ゴール**
カメラ入力の独自実装。Web。

---

## M5 — binding specification と generator

**目的**
API 拡張を手書きから**レビュー可能な仕様からの生成**に切り替え、OpenCV の巨大な API 面を制御下で扱えるようにする。

**M4 の後に置く理由**: 生成されるコードの形は iOS static link と IL2CPP stripping の制約を満たす必要がある。制約を実機で確定してから大量生成するほうが手戻りが小さい。

**ゴール**
binding specification から C ABI 宣言 / C# P/Invoke / API 対応表 / conformance test が生成される（L0 の導入）。

**完了条件**

- spec を正本として生成物が作られ、golden test で一致が検証される
- `geometry` / `calib` / `features` / `objdetect` などを**利用例に基づいて**追加する
- API 対応表を生成し、「OpenCV 全対応」という曖昧な表現を使わない
- 生成された P/Invoke が IL2CPP stripping を生き延びることを L5 で確認する

**非ゴール**
OpenCV 全 API の網羅。

---

## M6 — Web / Wasm

**目的**
競合が持たない Web 対応を、**Unity 同梱 Emscripten と整合した形**で獲得する。LLVM はバージョン間のバイナリ互換を保証しないため、この整合性の維持自体が継続的な作業になる。

**ゴール**
Unity Web Player 上で P/Invoke と代表処理が動く。

**完了条件**

- Unity version と Emscripten version の対応表を作り、CI で不一致を検出する
- Unity 同梱 Emscripten で Wasm object (`.o`) を生成し `.a` にまとめる
- single-thread / SIMD を先に成立させる
- Web Player の起動、P/Invoke、メモリ転送、代表処理の browser E2E test

**非ゴール**
threads profile（別 profile として後続）。

---

## M7 — Optional profiles と性能

**目的**
「小さな標準 build + opt-in profile」（計画書 §7）を、方針から**実際の配布形態**にする。

**ゴール**
DNN / contrib / codec / videoio が opt-in profile として追加でき、低コピー経路が評価済みになる。

**完了条件**

- profile ごとの native artifact、manifest、third-party notices
- RenderTexture / native texture pointer / AsyncGPUReadback を使う低コピー経路の評価
- package size、startup time、frame time、allocation の benchmark を公開

---

## マイルストーン間の依存

```text
M0 ハーネス ──> M1 OpenCV ビルド ──> M2 Windows slice ──> M3 Desktop 配布
                                                              |
                                                              v
                                                          M4 Mobile
                                                              |
                                                              v
                                                        M5 generator ──> M6 Web ──> M7 profiles
```

## 再評価のトリガー

次のいずれかが起きた場合、backend 言語の決定（C++）を再評価する価値がある。

- **Rust の AddressSanitizer / LeakSanitizer が stable 化する** — 言語評価 §4.4 の決定的な差が消える。Rust project goals の 2026 目標として進行中
- Web または iOS がスコープから外れる
- generator を採用せず bridge を大量に手書きする方針に変わる

再評価が安価であるために、**public C header と契約テスト（L1 / L3）は backend 実装から独立に保つ**。この不変条件は M0 で確立し、以降のすべてのマイルストーンで維持する。
