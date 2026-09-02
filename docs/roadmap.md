# OpenCV Unity Native ロードマップ

- 作成日: **2026-08-25**
- 文書の状態: 計画（実装済み機能の記録ではない）
- 前提: [競合調査と初期計画](./unity-opencv-integration-research-and-plan.md) / [Native backend 実装言語の評価](./native-backend-language-tdd-evaluation.md)

## 確定事項

| 項目 | 決定 | 根拠 |
| --- | --- | --- |
| native backend 実装言語 | **C++** | [言語評価](./native-backend-language-tdd-evaluation.md) §1。sanitizer が安定版ツールチェーンで使える、`opencv` crate の unstable 表明と `Mat` 共有可変性の警告を回避、iOS / Web のツールチェーン鎖が短い |
| UPM package ID | **`com.ayutaz.opencv-unity-native`** | 個人リポジトリとして公開 |
| 対象 Unity | **6000.x のみ**（2022 LTS 非対応）。**実際に検証しているのは 6000.3.16f1 の 1 版だけ**（M3.5 で 6000.0.82f1 から載せ替えた） | 検証マトリクスを最小化。IL2CPP / .NET Standard 2.1 前提で単純化。**6000.0 LTS の通常サポートが 2026-10 に終わるための載せ替えである**（差別化の穴 #4。日付の詳細は M3.5 の完了条件）。`package.json` の `unity` も `6000.3` を宣言する。**版が 1 つしかないこと自体は変わっていない** |
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
| L0 | spec → 生成物の golden test | < 1 秒 | 毎編集 | M5（**導入済み**。`dev.ps1 verify-generated` / `tools/tests/BindingGenerator.Tests.ps1` / `bindings/generator/Ocvu.Generator.Tests`。3 つとも `dev.ps1 test` に入るので **`ci-native` が 3 platform で走らせる**）|
| L1 | C ABI 契約テスト（GoogleTest + CTest） | 1〜5 秒 | 毎編集 | M0 |
| L2 | ASan / UBSan レーン | 10〜30 秒 | 毎コミット | M0 |
| L3 | P/Invoke 検証（素の .NET、Unity 不使用） | 2〜5 秒 | 毎編集 | M0 |
| L4 | Unity EditMode (Mono) | 1〜3 分 | pre-merge | M2 |
| L5 | Unity IL2CPP Player | 5〜20 分 | nightly / release | M2 |

**L4 / L5 の「実行頻度」は起草時の想定で、実装は違う。** どちらも
`ci-unity.yml` が push(main) / PR / 手動で毎回走らせる（Linux）。
`nightly.yml` に Unity レーンは入っていない —— 重いレーンは PR で回るので、
nightly は「誰も push していない間に壊れること」だけを見る。
実測時間も想定より速い（`CLAUDE.md` の開発コマンド表を参照。ローカル Windows で
EditMode 約 27 秒、IL2CPP Player 約 54 秒。いずれもキャッシュが温まった状態）。
**ただしこの 2 つは Unity 6000.0.82f1・EditMode 10 件のときの値で、M3.5 で
6000.3.16f1・EditMode 16 件になった後は取り直していない**（通ることは実測した ——
下の M3.5 節の判定表）。

### CI/CD 戦略

public OSS リポジトリのため GitHub-hosted runner を無償で使える。これを前提に、**ローカルループと CI の役割を明確に分離する**。

| | 担当 | 原則 |
| --- | --- | --- |
| **ローカル（エージェントの TDD ループ）** | L0〜L3 のみ | **秒単位を死守する。**重い処理を一切持ち込まない |
| **CI（GitHub Actions）** | 上記すべて + マトリクス、sanitizer、Unity、実機、Web | **網羅性を担当する。**時間をかけてよい |

この分離から導かれる重要な帰結:

- **OpenCV は CI がビルドし、artifact として配布する。** エージェントもローカル開発者も OpenCV を自分でビルドしない（`tools/opencv.ps1 restore` が固定ハッシュの artifact を download するだけ）。M1 のビルドコスト（CI 実測: clone〜verify まで通しで 4 分 09 秒。`windows-2022` runner、run 32849957498。ローカルでの実測はまだ無い）が開発ループから完全に消える。
- **sanitizer レーンはローカルでは任意、CI では必須にする。** ローカルの毎編集ループは通常ビルドで秒単位を保ち、ASan / UBSan / Valgrind は push ごとに CI が全部回す。
- **マトリクスをケチらない。** platform × 構成 × Unity バージョンの組み合わせを削る理由がないため、削らない。
- **CI が唯一の正本の検証結果である。** ローカルの green は速さのための近似であり、merge 可否は CI が決める。

**ワークフロー構成**（各マイルストーンで段階的に追加）

| ワークフロー | トリガー | 内容 | 導入 |
| --- | --- | --- | --- |
| `ci-native.yml` | push(main) / PR / 手動 | L1 + L3、通常ビルド | M0 |
| `ci-sanitizers.yml` | push(main) / PR / 手動 | ASan / UBSan レーン | M0 |
| `build-opencv.yml` | 手動 + 構成変更時 | allowlist 構成の OpenCV をビルドし artifact 公開 | M1 |
| `ci-unity.yml` | push(main) / PR / 手動 | Unity EditMode (L4) + IL2CPP Player (L5)。**起草時は「PR / nightly」と書いていたが、実装は nightly ではない。** ubuntu で走るので、CI の L5 は Linux の IL2CPP Player である（**Windows で走らせない理由として記録していたものは 2026-08-29 に崩れた** —— 下記 M2 節） | M2 |
| ~~`ci-desktop-matrix.yml`~~ | — | **作らなかった。** 3 platform は `ci-native.yml` の job 追加（`macos` / `linux`）と `ci-sanitizers.yml` の `linux-asan` job で実現した。別ファイルにすると同じ手順が 2 箇所に分かれるため | M3 |
| ~~`ci-mobile.yml`~~ | —— | **作らなかった。** Android / iOS のクロスビルドは `ci-native.yml` の job として足し、実機 smoke test は CI では原理的に閉じないので `docs/m4-device-verification.md` の手順書に落とした | M4 |
| `ci-web.yml` | nightly | Unity 同梱 Emscripten での Wasm ビルドと browser E2E | M6 |
| `release.yml` | tag / **pull request**（空撃ち） / `workflow_dispatch` | **全部入りの UPM tarball（配る正）** と platform ごとの tarball、manifest / checksums / SBOM / third-party notices と `SHA256SUMS.txt` を GitHub Release へ。**staging した数を数え**、全部入りが名前で並んでいることも見る（**件数は platform が増えれば増えるので、実数は `CLAUDE.md` の workflow 表が持つ**）。**pull request でも走るようにしたのは M4 の後**で、tag でしか走らなかった間に欠陥が 3 件たまったためである（うち 1 件は「tag を打つと Release が 1 件も作られない」）。**全部入りには SBOM と build-manifest を付けない** —— どちらも復元済みの OpenCV artifact から作るので、束ねる job には元が無く、混ぜた版を捏造しない。**M3.5 が足した配線（全部入りの組み立て・17 件の staging・SHA256SUMS）は 2026-08-30 の空撃ちで初めて通した。** それまで空撃ちは publish job を丸ごと飛ばしており、**束ねる側は tag を打つまで 1 行も動かなかった** —— job を `assemble`（条件なし）と `publish`（job 単位で tag に限る）に割って直した。**実績は 2 つ**: run 33286928144 は条件を最後の step に降ろしただけの形（レビューで取り消した）、run 33289128197 が**いまの 2 job 構成**である。どちらも Release は作られていない。**tag で 2 回実行済み**（v0.1.0 = 2026-08-28、v0.1.1 = 2026-08-29。どちらも `--draft` で下書きを作り、人が点検してから公開した）。**M3 当時の空撃ち**（run 33156465235、3 platform とも success）は publish job ごと skip されていた —— **この形は 2026-08-30 に変えた**（上記）ので、いまの空撃ちは Release を作る job 以外を通る | M3 |
| `ci-lint.yml` | push(main) / PR / 手動 | actionlint / shellcheck / PSScriptAnalyzer / 文書の相対リンク検査の 4 job。**静的に読めば分かる誤りを、CI を 1 周（10〜20 分）回して確かめていた**のを埋める | M3 後 |
| `codeql.yml` | push(main) / PR / 週 1 / 手動 | C++ と C# の静的解析。sanitizer が「実際に踏んだ経路」を見るのに対し、CodeQL は経路を実行せずに探すので**重なっていない** | M3 後 |
| `nightly.yml` | 毎日 04:00 UTC / 手動 | 誰も push していない間に壊れることを見つける。Linux 成果物の移植性 / Windows・macOS の速いレーン / OpenCV artifact の期限切れ確認の **3 job 定義**（速いレーンは `lanes` という 2 runner の matrix なので、**実行時は 4 件**になる）。**schedule での実行実績はまだ無い**（下記） | M3 後 |

**M3 の後に足したもの**（マイルストーンの完了条件ではなく、CI/CD の監査で出た穴を塞ぐもの）

- `ci-lint.yml` / `codeql.yml` / `nightly.yml` の 3 workflow（上表）
- `.github/codeql/codeql-config.yml` の `query-filters` — P/Invoke していること自体への 2 規則（`cs/unmanaged-code` / `cs/call-to-unmanaged-code`）を外す。**このパッケージは native を P/Invoke で呼ぶために存在する**ので、この 2 規則の指摘は 1 件残らず設計どおりであり、ABI 関数を 1 本足すたびに増える。実測（2026-08-29）で open 107 件のうち 84 件がこれで、**その陰にこちらのコードに対する本物が 4 件埋もれていた**。埋もれた指摘は無いのと同じである。4 件の現在の扱いは `CLAUDE.md` のワークフロー節にある
- `.github/dependabot.yml` — `actions/*` と `tests/Managed` の NuGet を週 1 で追う。可変タグで固定しているので、**上流が変われば何もしていないのに壊れる**。その変化を差分として見える形にする
- `SECURITY.md` / `CONTRIBUTING.md` — OSS として欠けていた。前者は非公開の脆弱性報告先とこの境界で何が範囲内か、後者は貢献の手順と**CI が見ないもの**を明示する

**`nightly.yml` は schedule でまだ 1 度も走っていない。** 手動起動が 2 回あるだけで、
1 回目（run 33230097557、2026-08-29 02:54Z）は 4 job 中 3 job が
`API rate limit exceeded for installation` で失敗し、原因を直したあとの
2 回目（run 33233610215、同 04:21Z）が 4 job とも success だった
（上表のとおり 3 job 定義に対して実行は 4 件になる。数え方が違うだけで、
どちらの数字も同じ run のものである）。
**「workflow ファイルが存在する」は「CI で実行された」ではない** ——
M2 の条件 7 をその基準で未達と判定した以上、こちらにも同じ基準を当てる。
cron の経路そのものが動いたことは、まだ確かめられていない。

**上の表は「何が走るか」だけを書いている。「何が merge を止めるか」は
ここには書かない。** 走ることと止めることは別で、しかも止める側は GitHub の
branch protection の設定であってこのリポジトリのファイルではない。
**必須チェックと、その補集合（赤くても merge できるレーン）の記載場所は
`CLAUDE.md` の「機構として強制されていること」ただ 1 箇所**で、正本はさらに
その先の GitHub 側の設定である（同節に読み出しコマンドがある）。ここに
同じ事実を書き足すと、必須を 1 本増やしただけで両方が同時に古くなる。
**CI が「見ている」ことと「止める」ことは別である。**

**CI が満たすべき制約**（ハーネスと同じ理由で、これらは M0 で確立する）

- ワークフローはローカルと**同一のコマンド**（`tools/dev.ps1`）を呼ぶ。CI 専用の手順を作らない
- すべてのジョブに `timeout-minutes` を設定する。ハングしたジョブが枠を占有しない
- テスト結果を機械可読形式（JUnit XML）で artifact 化し、失敗時に読める状態にする
- 依存は hash / tag で固定し、`actions/*` も含めてバージョンを明示する

**これらは M0 で確立したが、後から足した job には自動では伝わらなかった。**
M3 で追加した `ci-native` の macOS / Linux job と `ci-sanitizers` の linux-asan job は、
**テスト結果の artifact 化（3 つ目の制約）を持たないまま走っていた** ——
Windows job には最初から在ったので、workflow のファイルを見るかぎり満たして
いるように読めた。M3 の後にこれを埋め（後から足した `nightly.yml` の速いレーンにも
同じものが無かったので、そちらも埋めた）、あわせて
`tools/tests/OpenCvConfig.Tests.ps1` の workflow 検査を **job 単位**に直した
（ファイル単位では「同じ workflow の別の job が満たしている」で通ってしまう）。
検査は「upload step が在るか」ではなく **`if: always()` が付いているか**まで見る
——付いていなければ成功時しか上がらず、目的（落ちたときに何が落ちたのかを読む）を
ちょうど果たさない形で緑になる。**制約を文書に書くことと、それが全 job に
掛かっていることは別である。**

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
計画書 §8.3 の依存 allowlist を**最初から**満たす。「後で依存を削る」は配布直前に破綻するため、最小構成を最初に確定させる。同時に、**OpenCV のビルドを CI に完全に追い出し**、開発ループからそのビルドコスト（CI 実測: 4 分 09 秒。ローカルは未計測）を消して M0 で得た反復速度を維持する。

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

**既知の欠陥（意図的に見送った検証。M3 が拾う — 同節の完了条件に入れた）**

`tools/opencv-config.psd1` が固定するのは**送信する** CMake flag であって、OpenCV のビルドが
それを**守ったか**ではない。両者の間には検証を置かないと決めた — 構成ハッシュは意図の一意性を
保証するが、成果物が意図どおりかは別問題として残る。

この隙間から実際に 2 件の欠陥が生まれた。どちらも自動検証があれば構成変更の時点で機械的に
検出できたはずで、代わりに人間が成果物を直接調べて発見した。

- **Task 4**: `check_language(ASM)` が PATH 上の MinGW アセンブラを拾い、静的ライブラリの
  命名規約が GNU 規約（`libX.a`）に倒れた。`-DCMAKE_ASM_COMPILER=NOTFOUND` で止めたが、
  「ASM を要求していないのに ASM 言語が有効になっていないか」を成果物から機械的に確認する
  検証は無い。
- **Task 7 / Task 8**: `BUILD_WITH_STATIC_CRT`（MSVC 既定 ON）が
  `CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL` の指定を黙って上書きし、要求した共有 CRT
  （/MD）ではなく embedded CRT（/MT）の成果物ができていた。`opencv_core500.lib` の
  `DEFAULTLIB` を人間が `grep` して発見した。`-DBUILD_WITH_STATIC_CRT=OFF` で止めたが、
  「CRT linkage が要求どおりか」を成果物から機械的に確認する検証は無い。

**担当は M3（2026-08-27 決定）。** 理由は 3 つある。

1. **M3 が同じ問題を 3 倍にする。** この欠陥は「送った指定が上流に黙って無視される」形で、
   Windows だけで既に 2 回起きた。macOS / Linux が加われば、ツールチェーンごとの既定値の
   違いで同種の欠陥が起きる面が 3 倍になる。1 プラットフォームで検査を作ってから広げる方が、
   3 つ分の未検証な成果物の上に後から載せるより安い。
2. **M3 の完了条件が既に成果物の検査を求めている。** artifact manifest / checksums / SBOM が
   条件に入っており、SBOM は「成果物に何が入っているか」の申告である。申告と実物を突き合わせる
   仕組みが無ければ、M1 と同じ穴が今度は SBOM に開く。同じ場所で作るのが自然である。
3. **M4 以降では遅い。** M4 の mobile では iOS の静的リンクと Android の ABI 差が入る。
   そこで初めて検査を作ると、既に 3 platform 分の未検証な成果物を土台にすることになる。

実装の形（M3 の完了条件に入れた項目の詳細）:
成果物の `.lib` / `.a` / `.dylib` から `DEFAULTLIB`・有効言語・リンク済みシンボルを実際に
読み取り、`opencv-config.psd1` の意図（CRT linkage、ASM 不使用、`WITH_CUDA=OFF` 等）と
突き合わせる。**allowlist 検証（依存の集合）とは別軸である** — 依存が正しくても linkage が
違えば今回のような欠陥になる。置き場所は `tools/verify-opencv-artifact.ps1` の隣か、
platform 別の実装を持つ新しい入口。プラットフォームごとに読み取り方が違う
（Windows は `DEFAULTLIB`、ELF は `readelf`、Mach-O は `otool`）。

**認識できなかったものは失敗側に落とすこと。** 「読み取れなかったら通す」はその一形態で
あって全部ではない。M1 が 8 回繰り返したのは「著者が列挙した形だけを見て、隣接する形が
枠外に落ちる」欠陥であり、`tools/verify-opencv-artifact.ps1` 冒頭のコメントが denylist を
allowlist と呼んでいた経緯としてそれを記録している。列挙を長くしても閉じない —
次に足されるものはその一覧に載っていない。手順は `prove-a-check-works` skill にある。

---

## M2 — Windows vertical slice

**目的**
API の広さを追わず、**ownership / stride / pixel format / エラー / IL2CPP の正しさ**を最小 API で確定する。ここで曖昧さを残すと、M5 の generator が誤った契約を大量に複製することになる。

**ゴール**
`Mat` のライフサイクルと少数の `imgproc` API が C# から動き、**Unity Editor (Mono) と Windows IL2CPP Player で同一結果**になる。

**完了条件**

- `ocvu_mat_*`（create / release / clone / get_info / copy_from_buffer / copy_to_buffer）と `cvtColor` / `resize` / `GaussianBlur` が C ABI にある
- 所有権契約が L3 で明示的にテストされている — handle は常に native 所有であること、二重解放、解放後アクセス、buffer 引数の長さ・stride・NULL の検証
- Texture2D / NativeArray からの入力と結果反映が動く
- ABI version / OpenCV version / build features を実行時に問い合わせられる
- vertical slice 全体が ASan レーンで clean
- Unity EditMode (Mono) と Windows IL2CPP Player の両方で同じ smoke test が通る（L4 / L5 の導入）
- `ci-unity.yml` が CI 上で L4 / L5 を実行する（Unity ライセンスを GitHub Secrets に登録し、アクティベーションを自動化する）
- ローカル参照可能な最小 UPM パッケージとして動作する

**非ゴール**
Windows 以外のプラットフォーム。API の拡張。generator。

**完了条件を変更した経緯（2026-08-26、M2 着手前）**

当初の完了条件は `ocvu_mat_wrap`（Unity 側の buffer を handle にする関数）を挙げ、
「Unity 側 buffer を wrap した際の lifetime」を L3 で検証することを求めていた。

M2 着手前に所有権の規約を決めた結果、**その関数を作らない**ことにした
（`docs/abi-ownership-and-versioning.md` §1）。Unity は自分の都合でメモリを捨てられ、
借用 handle がそれより長く生きると、即座には落ちず後から無関係な場所が壊れる。Windows の
AddressSanitizer は Unity のアロケータを見られないので、CI でも検出できない。規約で禁じても
機械的な強制が無い以上、**借用 handle を作らなければその誤りは表現できなくなる**方を選んだ。

したがって完了条件を次のように置き換えた。

| 旧 | 新 |
| --- | --- |
| `wrap` が C ABI にある | `copy_from_buffer` / `copy_to_buffer` が C ABI にある |
| wrap した際の lifetime を検証 | 借用 handle が存在しないこと、buffer 引数（長さ・stride・NULL）の検証 |
| borrowed と owned の区別 | 同左。ただし区別されるのは handle（常に owned）と buffer 引数（借用は呼び出し内で完結） |

**これは緩和ではない。** 検証すべき危険が消えたのではなく、危険な状態を作れなくしたので、
検証の対象が「その状態が作られていないこと」に変わった。

**実測による完了判定（2026-08-27、`milestone-complete` skill の手順で照合）**

| # | 完了条件 | 判定 |
| --- | --- | --- |
| 1 | 9 関数（`ocvu_mat_*` 6 本 + `cvtColor` / `resize` / `GaussianBlur`）が C ABI にある | 満たす |
| 2 | 所有権契約が L3 でテストされている（二重解放、解放後アクセス、buffer 引数の検証） | 満たす |
| 3 | Texture2D / NativeArray からの入力と結果反映 | 満たす |
| 4 | ABI version / OpenCV version / build features を実行時に問い合わせられる | 満たす |
| 5 | ASan レーンが clean | 満たす |
| 6 | Unity EditMode と Windows IL2CPP Player で同じ smoke test が通る | 満たす |
| 7 | `ci-unity.yml` が CI 上で L4/L5 を実行する | **満たす**（2026-08-29。Linux + game-ci） |
| 8 | ローカル参照可能な最小 UPM パッケージとして動作する | 満たす |

**条件 3 は達成した（判定は 2 度動いた）。** 経緯を残す。当初は「満たす」としたが、
レビューで「`NativeArray` を直接受ける API が無く、`ToArray()` で managed 配列へ写して
いるのでコピー 2 回になる」と指摘され「満たさない」に下げた。次に `IntPtr` 版を足して
再び「満たす」としたが、それも早かった — `IntPtr` は `NativeArray` ではなく、利用者側に
`allowUnsafeCode` とバイト長の自前計算を要求する形だったからである
（`NativeArray<T>.Length` は要素数であってバイト数ではない）。

現在の根拠は次のとおり:

- `Runtime/UnityIntegration/NativeArrayExtensions.cs` が `NativeArray<T>` を入力・出力の
  両方向で受ける。利用者に `unsafe` を要求しない。バイト長は `SizeOf<T>()` を掛けて
  こちらで算出する。
- **利用者所有の `NativeArray` を渡すテストが L4 / L5 の両方にある**
  （`UserOwnedNativeArray_RoundTripsWithoutGoingThroughAManagedArray`、
  `NativeArrayLength_IsElementsNotBytes`）。以前は `TextureConverter` 内部の
  テクスチャ生データしか無く、それは Texture2D 経路であって NativeArray 経路ではなかった。
- `TextureConverter` は両方向ともポインタ経路で、中間の managed 配列は無い。
- `SizeOf<T>()` を掛けるのをやめる変異、書き戻し先を 1 バイトずらす変異のいずれでも
  L4 が赤くなることを確認済み。IL2CPP でも 9/9 通る。

安全網を 1 つ外したことも記録する。`byte[]` 経路では Unity の `LoadRawTextureData` が
バイト数不一致を例外にしていたが、ポインタ経路はそこを通らない。実際、チャンネル数の
合わない Mat を `ToTexture` に渡すと成功が返り、テクスチャの先頭へ一部だけ書かれた
（実測: 48 バイト中 12 バイト、例外もログも無し）。`ToTexture` に形式検査とバイト数
一致検査を置き直して塞いだ。**安全網を外す変更をするときは、外した分を同じ層に
置き直すこと。**

**条件 7 は満たした（2026-08-29）。** `ci-unity.yml` が CI 上で L4 と L5 を実行し、
両方 green になった。

    ==> libopencv_unity_native.so: GLIBC<=2.34 (ceiling 2.35)
    ==> [EditMode]   10 passed
    ==> [Standalone] 10 passed

L5 は本物である。`UnityLinker --rule-set=Aggressive` が走り、`il2cpp --convert-to-cpp`
で実際に IL2CPP Player がビルドされ、その上でテストが通っている。**stripping が
有効な状態で P/Invoke 宣言が生き残ることを、CI が実証した。**

### どうやって成立させたか

残っていた 3 つのうち、資格情報の登録（ユーザーの操作）が済んだあと、
残り 2 つを実装した。

- **ランナーへの Unity 導入とアクティベーション**: game-ci に任せ、ubuntu で
  走らせた。当時ここには「Windows では成立しない」と書き、game-ci の Windows
  イメージが Windows Server 2019 向けで `windows-2022` では
  「container operating system does not match the host operating system」で
  落ちること（game-ci/unity-builder#542、game-ci/docker#213）を根拠に挙げていた。

  **この理由づけは 2026-08-29 に崩れた。** 挙げていた 2 つの issue はどちらも
  解決済みとして閉じており、**Windows で走らせる試みは一度もしていない。**
  Linux で走らせている事実は変えないが、理由は「不可能だから」ではなく
  「まだ試していないから」が正しい —— 経緯と残る障害は下記
  「担当が無かった制約」の Windows IL2CPP の節にまとめてある。
- **帰結として L5 は Windows ではなく Linux の IL2CPP Player である。**
  L5 が捕まえたいのは stripping が P/Invoke 宣言を消す問題で、これは IL2CPP
  全体の性質であり Windows 固有ではない。Windows の IL2CPP Player は
  ローカルのレーン（`dev.ps1 test-unity-player`）が引き続き担う。

### この作業が暴いたもの

**CI で Unity を動かして初めて、公開済み v0.1.0 の Linux 版が壊れていることが
分かった。**

    DllNotFoundException : Unable to load DLL 'opencv_unity_native'

ubuntu-24.04（glibc 2.39）でビルドした `.so` が GLIBC_2.38 を要求しており、
それより古い環境では読み込めなかった。**ビルドは成功し、linkage 検証も通り、
配布物も作れていた。** 読み込めないことは、Unity を実際に動かすまで誰も
知らなかった。「3 platform でビルドできた」と「3 platform で動く」を
取り違えていた。

直したものと、直した版（v0.1.1）を出し直すまでは M3 節の
「配布 その 2」に書いた。要点は 2 つ:

- Linux のビルドを `ubuntu:22.04` のコンテナに移した（要求は 2.38 → 2.34 に
  下がった）。コンテナ名は構成ハッシュに入るので、環境が変われば artifact も
  別物として扱われる
- `tools/verify-plugin-portability.ps1` が、要求する GLIBC / GLIBCXX の上限を
  ビルドの時点で見る。`readelf` に頼らないので Windows の開発機でも動く

**「CI はローカルと同一のコマンドを呼ぶ」との食い違いも記録しておく。**
この workflow は `dev.ps1` で Unity を起動せず、game-ci の action が起動する。
代わりに合否の判定を `tools/assert-unity-results.ps1` に出し、ローカルと CI の
両方がそれを通る。起動の仕方が分かれても判定が分かれなければ、「ローカルで
赤いものが CI で緑になる」は起きない。とくに「0 件で緑にしない」はこの
script が持っている。

**したがって M2 は完了である（8 件中 8 件）。** 実装計画
（[docs/superpowers/plans/2026-08-26-m2-windows-vertical-slice.md](./superpowers/plans/2026-08-26-m2-windows-vertical-slice.md)）
は Task 8 まで実施済みで、進行記録は
`.superpowers/sdd/2026-08-26-m2-windows-vertical-slice/progress.md` にある。

---

## M3 — Desktop 3 platform と配布の再現性

**目的**

M1 は「構成を固定すれば同じ成果物ができる」を Windows 1 つで成立させた。M3 はそれを
**3 platform に広げ、同時に「固定した構成が本当に守られたか」を機械が確かめる**状態にする。

なぜ 2 つを同じマイルストーンでやるか。platform が増えると、ツールチェーンごとの既定値が
こちらの指定を上書きする面が増える。M1 では Windows だけで 2 回起きた（PATH から拾われた
アセンブラ、黙って上書きされたランタイム設定）。**広げる作業と、広げた先で同じ欠陥が
起きていないか確かめる作業は、分けると後者が置き去りになる。**

**ゴール**

次の 3 つが同時に成り立つ状態。

1. Windows / macOS / Linux の native artifact が CI から生成され、それぞれ **platform を
   含む構成ハッシュ**で識別される（現在ハッシュに platform が入っておらず、別 platform の
   ビルドが同じハッシュを名乗れてしまう）
2. その artifact が Git URL または tarball から UPM として導入でき、manifest / checksums /
   third-party notices / SBOM が付く
3. **Linux レーンがリークを検出し、成果物の linkage が構成の意図と一致することを機械が確かめる**
   — どちらも現在は誰も見ていない。MSVC の ASan はリークを検出せず、送った CMake flag が
   守られたかを見る仕組みも無い

**完了条件**

- 3 platform の CI build と、platform / architecture 別の Plugin Import Settings
- Git URL または tarball から導入できる UPM パッケージ
- artifact manifest、checksums、`THIRD_PARTY_NOTICES.md`、SBOM
- **Linux レーンでのリーク検出**（LeakSanitizer / Valgrind）— MSVC の ASan は LeakSanitizer 非対応のため、リーク検出は Linux CI が担う
- **成果物の linkage・有効言語・リンク済み依存が構成の意図と一致することを機械的に検証する**（M1 からの持ち越し。M1 節の「既知の欠陥」に経緯がある）— 送った CMake flag ではなく、できた `.lib` / `.a` / `.dylib` を読んで確かめ、`opencv-config.psd1` の意図と食い違ったら CI を落とす。**`tools/verify-opencv-artifact.ps1` の allowlist 検証とは別軸である** — あちらは「どのファイルが在るか」、こちらは「そのファイルがどう作られたか」を見る。依存の集合が正しくても linkage が違えば M1 と同じ欠陥になる。
  - **まず Windows 分を成立させ、platform を足すのと同時に同じ検査を広げる。** 読み取り方が 3 系統ある（`DEFAULTLIB` / `readelf` / `otool`）ので、3 つ同時に立ち上げると この条件だけで M3 を食う。1 つで形を決めてから広げる方が安い。
  - **`prove-a-check-works` skill に従うこと。** 読み取れなかった場合・想定外の形だった場合に**落ちる**ことを実際に見るまで、満たしたと記録しない。M1 がこの隙間で 2 回踏んだのは 「著者が列挙した形だけを見て、隣接する形が枠外に落ちる」欠陥であり、「読み取れなかったら通す」はその一形態にすぎない。列挙を増やすのではなく、**認識できなかったものが失敗側に落ちる**形にする。
- Unity sample と最小 API reference

**非ゴール**
mobile / Web。optional profile。

**実測による完了判定（2026-08-28 更新、`milestone-complete` skill の手順で照合）**

| # | 完了条件 | 判定 |
| --- | --- | --- |
| 1 | 3 platform の CI build と、platform / architecture 別の Plugin Import Settings | **満たす**（留保あり。下記） |
| 2 | Git URL または tarball から導入できる UPM パッケージ | **満たす**（tarball 側。Git URL 側は成立し得ない。下記） |
| 3 | artifact manifest、checksums、`THIRD_PARTY_NOTICES.md`、SBOM | **満たす** |
| 4 | Linux レーンでのリーク検出（LeakSanitizer / Valgrind） | **満たす** |
| 5 | 成果物の linkage・有効言語・リンク済み依存の機械的検証 | **満たす** |
| 6 | Unity sample と最小 API reference | **満たす** |

初版の判定は「6 件中 1 件」だった。理由はコードの欠落ではなく、実装した
commit が一度も CI を通っていなかったことである（`ci-native.yml` /
`ci-sanitizers.yml` は `pull_request` か `main` への push でしか起動しない）。
PR #8 を出して 3 platform で実行し、そこで**実際に 3 件の欠陥が出た**ので、
それらを直したうえで再判定した。

**「まだ push していない」を判定の根拠にしない。** 初版はそう書いていたが、
push した瞬間に嘘になった。判定の理由は、一瞬で変わる状態ではなく、workflow の
trigger 条件のような変わらない事実に置くこと。

### CI が実際に見つけたもの（3 件）

この 3 件はいずれも**ローカルでは緑だった**。M3 を「CI に通す」だけの作業と
見なしていたら、そのまま配っていた。

1. **handle table の use-after-free。** L3 の
   `ImgprocTests.Resize_MapsWidthToColsAndHeightToRows` が Windows で 1 度だけ
   `Expected: 2, Actual: 1` を出した。table は `slots` を
   `std::vector<Slot>` で持ち、`Slot` が `cv::Mat` を**値で**抱えていたので、
   `mat_table_get` が返すのは配列内部を指すポインタだった。別スレッドの
   `ocvu_mat_create` で配列が伸びると、先に解決したポインタが全部ぶら下がる。

   **壊れるのは create した側ではなく、無関係な handle を使っている側である。**
   2 つのスレッドがそれぞれ自分の `Mat` だけを触るという、契約上まったく
   正しい使い方で壊れる。xUnit はテストクラスを並列に走らせるので、`resize` の
   書き込みが旧バッファへ、直後の `get_info` が引っ越し後の `Mat` へ向かい、
   `1x1` のまま残った `dst` を読んでいた。

   `Slot` を `std::unique_ptr<cv::Mat>` にして直し、
   `native/tests/test_mat_table_stability.cpp` で固定した（handle を 1 つ
   解決してから 1024 個作り、同じ handle を解決し直してアドレスが一致することを
   見る。単体で決定的に落ちるので、並列実行のタイミング頼みにならない）。
   **ローカル 3 回と直前 3 回の CI が緑だった。フレークとして再実行していたら
   残っていた。** 契約自体が未文書だったので
   [§1.5](./abi-ownership-and-versioning.md) を追加した。

2. **配布 tarball が UPM で導入できない。** `release.yml` は
   `tar -czf $name -C Packages com.ayutaz.opencv-unity-native` で固めていた。
   この形は package ID のディレクトリごと包むので、UPM が展開後の root に
   `package.json` を見つけられず
   `The file [<tmp>\package.json] cannot be found` で失敗する。
   **tag を打っていたら 3 platform 分の「導入できない」tarball を配っていた。**

3. **Release asset 名の衝突。** `package-release.ps1` は 3 platform とも同じ
   名前（`checksums.txt` 等）で出すので、そのまま `gh release create` に
   渡すと衝突する。platform 名を頭に付け、staging 後に件数を数えて確かめる形にした
   （当時は 15 件 = 3 platform × 5 ファイル。**M3.5 で全部入りの tarball とその
   `checksums.txt` が加わり 17 件になった**）。

### 条件ごとの根拠

- **条件 1（満たす。留保あり）**: `ci-native.yml` の 3 job（Windows /
  macOS / Linux）が commit `95fe30e` で揃って green になり、native plugin が
  3 platform でビルドされた。Plugin Import Settings は macOS
  （`libopencv_unity_native.dylib`、`OSXUniversal` / ARM64）と Linux
  （`libopencv_unity_native.so`、`Linux64` / x86_64）の `.meta` を追加した。
  どちらも `Any` を無効にし、自分の platform だけを有効にしてある。

  検査も直した。`PackageRelease.Tests.ps1` は「`.meta` が 1 つ以上追跡されて
  いる」しか見ておらず、**コメントは 3 platform の衝突を心配しているのに、
  Windows 分 1 つで満足していた。** 3 つを名指しし、中身まで見る形にした。
  壊して確かめた（`.meta` を消す / `Any` を有効にする / 他 platform も
  有効にする → いずれも FAIL。戻すと pass）。最初の 1 つは初版で素通りした
  ——`git ls-files` は追跡を報告し続けるので tracked 検査は通り、中身の検査は
  `continue` で飛ばされていた。存在検査を足して塞いだ。

  **Linux の `.meta` は実測で確かめた（2026-08-29）。** M2 の条件 7 を満たす
  過程で `ci-unity.yml` が Linux の Unity を CI で動かすようになり、
  `libopencv_unity_native.so` とその `.meta` が実際に読み込まれ、EditMode と
  IL2CPP Player の両方でテストが通った（各 10 件）。plugin の import 設定が
  意図どおり効いていることの直接の証拠である。

  **macOS の `.meta` は依然として実測ではない。** CI の macOS job は plugin を
  ビルドするが Unity を起動しない。形式は Unity 自身が生成した Windows 分の
  `.meta` に合わせてあり、Linux 分が実機で通ったことで同じ作り方の妥当性は
  上がったが、macOS そのもので確かめたわけではない。

- **条件 2（満たす。tarball 側のみ）**: `dev.ps1 test-unity-tarball` を
  追加し、**tarball だけを指した使い捨ての Unity プロジェクト**で
  EditMode テストを走らせる。実測（このマシン、Unity 6000.0.82f1）:
  tarball に native plugin 1 件、UPM が解決し 10/10 pass。

  既存の L4 はリポジトリ内の `file:` **ディレクトリ**参照なので、tarball の
  中身が壊れていても通る。どちらか一方で他方を代替できない——実際、この
  レーンを足して初めて上記の欠陥 2 が見つかった。

  作り方は `tools/pack-upm-tarball.ps1` に集約し、`release.yml` と
  このレーンの**両方**が通る。分けて書くと、導入を確かめた tarball と
  実際に配る tarball が別物になる。形の検査は
  `PackageRelease.Tests.ps1` にもあり、CI が 3 platform で走らせる
  （packer を昔の形に戻すと落ちることを確認済み）。

  **Git URL 側は、この構成では成立し得ない。** native plugin の binary は
  `.gitignore` で追跡から外してあるので、Git URL で参照した利用者に届くのは
  `.meta` だけで実体が入らない。完了条件は「または」なので満たすが、
  **Git URL では導入できない**ことは利用者向けに明記する必要がある。

  **配布そのもの（tag を打って Release を作る）は、この判定の後に行った**
  ——下の「配布 その 1 / その 2」の節にある。判定の時点では `release.yml` を
  `workflow_dispatch` で 1 回空撃ちしただけだった
  （run 33156465235、2026-08-28。3 platform とも package job が success、
  publish は tag でないため skip）。その成果物を実際に落として確かめた:

  | platform | tarball の中身 | 構成ハッシュ（この run 時点） |
  | --- | --- | --- |
  | windows-x64 | `x86_64/opencv_unity_native.dll` + `.meta` | `4785d98e9aad` |
  | macos-arm64 | `macOS/libopencv_unity_native.dylib` + `.meta` | `1ccdc7f9ab94` |
  | linux-x64 | `Linux/x86_64/libopencv_unity_native.so` + `.meta` | `c4e3c491d973` |

  **linux-x64 のハッシュはその後 `a5ecba918754` に変わった。** 上の値は
  run 33156465235（コンテナ化する前）の記録であって、現行の値ではない。
  M2 の条件 7 で Linux のビルドを `ubuntu:22.04` のコンテナへ移し、
  コンテナ名を構成ハッシュに入れたためである（ビルド環境が変われば成果物も
  別物なので、同じハッシュのまま古い artifact が再利用されては困る）。
  Windows / macOS の 2 つは変わっていない。現行の値は
  `./tools/opencv.ps1 status` か
  `Get-OpenCvConfigHash -Config (Get-OpenCvConfig -Platform linux-x64)` で読める
  ——**ここに書いた値を現行として読まないこと。**

  **各 tarball は自分の platform の binary と `.meta` だけを持ち、他 platform の
  ものが混入していない。** `.meta` を package の外へ移した変更が CI 上でも
  意図どおり効いている。SBOM の package 数は macOS だけ 10・他は 11 で、
  実物から生成されていることの傍証になる。

- **条件 3（満たす）**: `package-release.ps1` が 4 点
  （`checksums.txt` / `sbom.spdx.json` / `build-manifest.json` /
  `THIRD_PARTY_NOTICES.md`）を実物から生成する。`PackageRelease.Tests.ps1` が
  それを検証し、**`test-tools-slow` として 3 platform の CI で走る**。
  初版の未達理由は「Windows でしか実行されていない」だったが、macOS /
  Linux job でも green になったことで解消した。

- **条件 4（満たす）**: Linux の ASan レーンがリークを検出する。CI 実測
  （`Linux x64 ASan+LSan (L2)`）:

      Test #2: harness.probe_ok ..................... Passed
      Test #3: harness.segfault_is_detected ......... Passed
      Test #4: harness.hang_is_detected ............. Passed
      Test #5: harness.use_after_free_is_detected ... Passed
      Test #6: harness.leak_is_detected ............. Passed
      100% tests passed

  対照として Windows は 4 件で、`harness.leak_is_detected` は登録されない
  （MSVC の ASan は LeakSanitizer を含まないので、リークしてもプローブが 0 で
  終了し「落ちなかった」で赤くなる）。**expect-failure テストなので、通過は
  「意図的にリークするコードを走らせ、LeakSanitizer が検出し、報告文言まで
  一致した」ことを意味する。** M1 以来「Windows の ASan では見つけられない」と
  記録してきたものが、初めて検出可能になった。

- **条件 5（満たす）**: 3 platform とも、**実物の artifact に対して**
  `verify-artifact-linkage.ps1` が CI で走り green になった
  （`VerifyArtifactLinkage.Tests.ps1` 経由、`test-tools-slow`）。

  完了条件が明示する 3 項目のうち、**「有効言語」は Unix 分岐に無かった。**
  Windows は「MSVC のビルドに `.a` が現れたら GNU 言語が有効化された証拠」で
  判別できるが、Unix では `.a` が正常な形なので同じ手が使えず、そのまま
  欠けていた。archive の**メンバ名**を読む形で足した——CMake は object を
  元ソースの拡張子込みで名付けるので、ASM が有効なら `foo.S.o` が現れる。
  送った flag ではなく、できた archive を読んでいる。

  両方向とも実ツールで確認した: 実物の macOS / Linux archive では
  検査が通り、`jsimd_arm.S.o` を詰めた合成 archive では
  「落ちること」と「落ちる理由が正しいこと」の両方が CI で確認された
  （このマシンには `ar` が無いので、ローカルでは SKIP と表示される。
  SKIP は「確かめていない」であって「合格」ではない）。

  位置独立コードの検査も直した。**最初の 1 本しか見ておらず**、たまたま
  再配置を持たない archive が先頭に来ると偽陽性になっていた（CI の Linux が
  実際にこれで落ちた）。全 archive を走査する形にした。

- **条件 6（満たす）**: `Samples~/BasicUsage/BasicUsage.cs` と
  `docs/api-reference.md` が commit `19bc3c7` にある。呼び出している API を
  実際のシグネチャと突き合わせ、`tests/UnityProject/Assets/` へ一時的に
  コピーして `dev.ps1 test-unity-editmode` を実行——exit 0、10/10 pass で
  **サンプルが実際にコンパイルを通ることを確認した**。

### 配布 その 1 — v0.1.0（2026-08-28）

完了条件を満たしたあと、実際に配るところまで進めた。**配布は M3 の完了条件
ではない**（条件 2 が求めるのは「導入できる UPM パッケージ」で、公開の実行
ではない）が、workflow が動くことを実物で確かめる意味があった。

段取りは 3 段階に分けた。**一度に外へ出さない。**

1. **空撃ち**（`workflow_dispatch`、run 33156465235）。package job だけを 3
   platform で走らせ、publish は tag でないため skip。成果物を落として中身を
   検証した。**これは M3 当時の挙動である** —— 2026-08-30 に job を割ったので、
   いまの空撃ちは組み立てと staging まで通り、Release を作る job だけが止まる。
2. **下書き**（tag を打つ、run 33161268329）。`gh release create --draft` で
   非公開の Release を作り、実物を点検した。
3. **公開**。点検で出た欠陥を全部直してから、下書きを公開に切り替えた。

**この段取りが実際に効いた。** 空撃ちで 1 件、下書きの点検で 4 件、
合わせて 5 件の欠陥を「外に出す前に」捕まえている。

空撃ちで見つけた 1 件:

- `checksums.txt` は package の中身（native plugin）を対象にしており、
  **配る `.tgz` 自体を含まなかった**。利用者はダウンロードした物を展開する
  まで完全性を確認できない。Release の全 asset を覆う `SHA256SUMS.txt` を
  出すようにした。

下書きの点検で見つけた 4 件:

- **macOS の manifest に壊れた compiler version**（`== 15.0.0.15000309`）。
  抽出が「行が想定どおりの形をしている」ことを前提にしており、Windows と
  Linux は通って macOS だけ枠外に落ちた。数字とドットの並びを直接拾う形に
  直し、取れなければ止めるようにした。
- **リリースノートの `\n` が改行にならない。** PowerShell の二重引用符では
  改行はバッククォート n である。Markdown のつもりで書いた `\n` が文字として
  そのまま出る。**しかも CI は緑のまま通る**（`gh` は文字列を受け取っただけで
  成功する）。`.github/release-notes.md` に出して `--notes-file` で読む形に
  した——YAML の中の PowerShell の中の Markdown という三重のエスケープを
  人が正しく保つのは無理がある。
- **通知が 3 platform で完全に同一だった。** macOS の成果物に `clapack` が
  無い（Apple の Accelerate を使うため）のに、macOS の配布物は CLAPACK の
  ライセンス全文を含んでいた。SBOM は実物から生成され platform 差が出るのに、
  通知は固定で、両者が食い違っていた。SBOM と同じ証拠から platform 固有の
  ヘッダを生成して同梱するようにした。
- **「通知にハッシュを焼き込むな」の検査が意図とずれていた。** 配布物側を
  見ていたため、生成ヘッダに**正しい値**が入った途端に落ちた。古くなり得る
  場所（リポジトリの文書）だけを見る形に直し、配布物側は逆に「生きた構成の
  値が入っていること」を見るようにした。

公開後の実測（asset を落として利用者と同じ手順で検証）:

- `sha256sum -c SHA256SUMS.txt` → 15 件すべて OK、失敗 0 件
- 各 tarball の root は `package/`、中身はその platform の binary と `.meta` だけ
- binary の実体はマジックバイトで確認: PE/COFF x86-64 / Mach-O arm64 / ELF x86-64
- SBOM と通知ヘッダの component 一覧が 3 platform とも一致

**`release.yml` は下書きを作る。** 公開は人が Release ページで押す。tag を
打っただけでは外から見えない。中身が違っていたときに、誰かの手に渡る前に
捨てられる状態を保つためである。

### 配布 その 2 — v0.1.1（2026-08-29）

**この段取りをすり抜けたものが 1 つあった。** v0.1.0 の Linux tarball は
Ubuntu 22.04 で読み込めない。空撃ち・下書き・公開の 3 段階はどれも
「作れたか」「中身が想定どおりか」を見ていて、**「読み込めるか」は誰も
見ていなかった**。M2 の条件 7 で CI が Unity を動かして初めて分かった
（詳しくは M2 節「この作業が暴いたもの」）。

直したうえで **v0.1.1 として出し直した**。要点は 3 つ:

- Linux のビルドを `ubuntu:22.04` のコンテナへ移した。要求は
  **GLIBC 2.38 → 2.34** に下がった。runner のイメージは GitHub の都合で
  上がっていくので、runner を固定するだけでは同じ問題を数年後に繰り返す
- **コンテナ名を構成ハッシュに入れた。** ビルド環境が変われば成果物も別物
  なので、同じハッシュのまま古い artifact が再利用されては困る
  （linux-x64: `c4e3c491d973` → `a5ecba918754`。Windows / macOS は不変）
- `tools/verify-plugin-portability.ps1` が、要求する GLIBC / GLIBCXX の上限を
  **ビルドの時点で**見る。`readelf` に頼らず ELF を直接読むので Windows の
  開発機でも動く

**中身を差し替えず、新しい版として出した。** 一度配ったものを黙って
差し替えると、同じ版名で違う物が世の中に 2 つ存在することになる。代わりに
**v0.1.0 のリリースノートの冒頭に「この版の Linux 版は動かない」と明記し、
v0.1.1 へ誘導する**形にした（Windows / macOS はこの版でも問題ないことも
書いてある）。既に v0.1.0 を取った人に届く場所は、そこしかない。

公開後の実測（2026-08-29、公開済み asset を利用者と同じ手順で落として検証）:

- Release の asset は 16 件（3 platform × 5 + `SHA256SUMS.txt`）。
  `SHA256SUMS.txt` は残る 15 件を覆う
- 落とした Linux tarball は `sha256sum -c` で `OK`
- その中の `libopencv_unity_native.so` に
  `tools/verify-plugin-portability.ps1` を掛けて
  `GLIBC<=2.34, GLIBCXX<=3.4.29`（上限 2.35 / 3.4.30）、exit 0。
  **配った物そのものに対する測定である**——CI のビルド成果物ではない

**ただし、この検査が `release.yml` の中で走るようになったのは v0.1.1 の
後である。** それまで `verify-plugin-portability.ps1` が走るのは
`ci-unity.yml` と `nightly.yml` だけで、**tag を打ったときには走らなかった**。
v0.1.1 の Linux binary が上限に収まっているのは、Linux のビルドが
コンテナに固定されている構造の帰結であって、配る経路が検査した結果では
なかった。「構造で防げているから検査は要らない」は v0.1.0 が否定した論法
そのものなので、`release.yml` にも掛けるようにした。

---

## 差別化の穴（2026-08-29 の再調査）

**モバイルを対象に含めると決めたのを機に、競合の現況を取り直し、「差別化として
掲げているのに埋まっていないもの」を数え直した。** 調査の中身は
[競合調査](./unity-opencv-integration-research-and-plan.md) §4.6 にある。

**結論を先に書く。OpenCV 5 を土台にしている Unity 向けパッケージは、商用・OSS とも
本案以外に見つからない。** ただし本案が公開している API は `core` / `imgproc` /
`imgcodecs` / `objdetect` / `features` / `geometry` / `calib` の 18 本に留まる（M3.5 で `imgcodecs` の
2 本、M5 の module 拡張で `objdetect` / `features` / `geometry` の 4 本、続けて
カメラの歪み補正で `imgproc` / `objdetect` の 2 本、さらに `calib` の
`ocvu_calibrate_camera` 1 本が加わった。公開 ABI 全体は
18 → 27 本。**本数を数える正本は [API 対応表](./api-map.md) の冒頭である**）
—— **土台が 5 系なのは本案だけだが、使える機能の量では競合に遠く及ばない。**
商用（OpenCV for Unity 3.0.3 / OpenCV 4.13.0）も OSS（neon-izm 版 / OpenCV 4.11）も
4.x 系のままである。

**だがこれは時間で消える位置である。** 競合が 5 系へ上げた日に、残る差は「OSS で
あること」「独自 ABI」「ビルドの再現性」だけになる。**先行している間に何を積むかが
論点であって、先行していること自体は成果ではない。**

下表は、[計画書](./unity-opencv-integration-research-and-plan.md) §7 に掲げた差別化に
対して**実際には埋まっていない**もの、および競合が持っていて本案が持たないもののうち、
担当を決めるべきものである。

| # | 穴 | なぜ差別化に効くか | 担当 |
| --- | --- | --- | --- |
| 1 | ~~**1 つの package に 1 platform 分の binary しか入らない**~~ **M3.5 で解消** | Unity は同じ package ID を 1 つしか導入できない。「エディタは Windows、実機は Android」が表現できなかった | **M3.5 完了**。全部入り tarball（`com.ayutaz.opencv-unity-native.tgz`）が配る正になり、Desktop 3 platform が同居した状態で `test-unity-tarball` が 16 passed |
| 2 | ~~画像を encode / decode できない~~ **M3.5 で解消** | 比較した競合はいずれも画像の入出力を持つ（そちらはファイル経路まで含む）。**ここに「モジュールはリンク済みで、足りないのは ABI 関数だけ」と書いていたのは誤りで、実際は `imgcodecs` をリンクしていなかった**（下記 M5 節） | **M3.5 完了**（M5 から前倒し）。component を足し、`ocvu_imencode` / `ocvu_imdecode` を出した |
| 3 | OpenUPM に載っていない | OSS の Unity パッケージが探される場所。#1 に加えて asset 名と容量の条件がある | **M3.5（(c) が未了）**。(a) 版番号なしの asset 名と (b) 容量の検査は済んだ。**残るのは登録申請だけで、それは新しい asset 名を含む Release を公開した後になる**（[登録の準備](./openupm-registration.md)） |
| 4 | 検証している Unity が 1 版だけ | **M3.5 でその 1 版を 6000.0.82f1 → 6000.3.16f1 に載せ替えた**（6000.0 LTS の通常サポートが 2026-10 に終わるため。6.3 LTS は 2027-12 まで）。**版が 1 つしかないこと自体は変わっていない** | **M3.5 完了**（載せ替えのみ。複数版の検証は担当なし） |
| 5 | カメラ映像を受け取れない | Unity で OpenCV を使う最大の用途。今は `Texture2D` の RGBA32 のみ | **M4** |
| 6 | macOS で Unity に読み込ませたことがない | iOS のビルドに macOS runner が要るので、M4 で自然に埋まる | **M4** |
| 7 | Windows の IL2CPP を CI で回していない | **「game-ci では無理」の根拠に挙げていた issue は、使っていない別 action のものだった。動く根拠も動かない根拠も持っていない** | **M4** |
| 8 | 対応 CPU アーキテクチャが狭い | Android エミュレータ（x86_64）が無いと開発しづらい | **M4 で決める** |
| 9 | 「低コピー連携」を測っていない | §7 の 7 番目に掲げているのに実測が無い | **M7**（既存） |
| 10 | 新しい DNN エンジンを載せていない | OpenCV 5 最大の変更。ただし Unity には代替がある。**2026-08-30 の調査で、5.0 に固定して作り込めない根拠が付いた**（根拠と一次情報は M7 節。**ここに再掲しない** —— 根拠を直すと 2 箇所が同時に古くなる） | **M7**（位置づけと、そこから出た module 分離の決定は下記） |

### #1 を最優先に置く理由

**これは機能の不足ではなく、配布の形が現実を表現できていないという欠陥である。**

Unity の package は 1 つの ID につき 1 つしか導入できない。**M3.5 の前は**
`release.yml` が platform ごとに別の tarball を作るだけで、利用者はそのうち 1 つを
選ぶしかなかった。**そのため「エディタは Windows、ビルド対象は Android」という、
モバイル開発で常態の構成が、そもそも表現できなかった。**

当時の判断: **M4 の完了条件をすべて満たしても、その成果物を利用者に渡せない。** 実機で
smoke test が通る Android の `.so` を作れても、それを Windows のエディタと同じ package に
入れられないからである。したがって #1 は M4 の装飾ではなく**前提条件**であり、M4 の前に
置いた。**M3.5 でこの前提は解けた** —— 全部入り tarball が配る正になり、M4 に残るのは
その中へ mobile の binary を足すことだけである（M4 の完了条件を参照）。

**Desktop だけを見ていた間は表面化しなかった。** Windows の利用者が Windows 向けに
ビルドする限り、必要な binary は 1 つで足りたためである。

**ただし「条件に書いていなかった」ではない。** M3 の完了条件 1 は
「platform / architecture 別の Plugin Import Settings」を求めており、**振り分けが
意味を持つのは複数 platform の binary が同居するときだけ**である。つまり条件の文面は
同居する形を指していた。**満たしたと判定したときに、配布物が同居していないことを
見ていなかった。** 書いていなかったのではなく、読んでいなかった。

なお `Runtime/Plugins/` の中は既に platform ごとのディレクトリに分かれている
（`x86_64/` / `macOS/` / `Linux/x86_64/`）。**変えるのは固め方だけで、
package の構造ではない。** **この見立ては当たった** —— M3.5 が足したのは
`tools/assemble-plugins.ps1`（3 つの木を 1 つに重ねる）と
`tools/pack-upm-tarball.ps1 -AllPlatforms` だけで、`Runtime/Plugins/` の構造は
変えていない。

### サンプルと文書について

比較表（§4.6）で差が最も大きいのはサンプルの数だが、**これはマイルストーンにしない。**
機能を足すマイルストーンの中で、その機能のサンプルを一緒に足す。切り離すと、
「あとでまとめて書く」が永久に来ないためである。

---

## M3.5 — 配布の形と、実用に必要な最小の穴

**目的**
**M4 に進む前に、配布の形が複数 platform を表現できるようにする。** 理由は上記 #1 に
書いたとおりで、これが解けていないと M4 の成果物を利用者に渡せない。あわせて、
比較した競合がすべて持っていて本案だけが持たない最小の機能（画像の encode / decode）を
埋め、検証する Unity をサポート期限内の版に載せ替える。

**ゴール**
1 つの tarball に Desktop 3 platform の binary が入り、OpenUPM へ登録できる形になり、
メモリ上の画像 byte 列を encode / decode でき、サポート期限内の Unity で検証されている。

**完了条件**

- **全 platform の binary を 1 つに収めた tarball を `release.yml` が作る。** platform ごとの
  tarball を併せて出すかは任意だが、**全部入りを正**とする
- その tarball を使い捨ての Unity プロジェクトに導入して EditMode が通る
  （`dev.ps1 test-unity-tarball` を全部入りに対して走らせる）
- **全部入りの tarball の中で、Unity が自分の platform の binary だけを読み込むことを
  実測する。** `.meta` の内容そのものは既に検査済みである
  （`tools/tests/PackageRelease.Tests.ps1` が 3 platform 分について `Any` が無効で
  自分の platform だけが有効であることを見ており、壊して落ちることも確認してある。
  M3 完了条件 1 の根拠を参照）。**新しく要るのはその先** —— 3 platform 分の binary と
  `.meta` が同居した実物の tarball を Unity に読ませ、**意図した 1 つだけが
  読み込まれること**を確かめる。同居して初めて、取り違えという事故が起こりうる
- **OpenUPM へ登録できる形にする。** `trackingMode: githubRelease` で Release に
  添付した `.tgz` をそのまま公開できる（[OpenUPM の文書](https://openupm.com/docs/adding-upm-package.html)）。
  この条件が求めるのは**こちら側で閉じる範囲**である: (a) `githubReleaseAssetName` が
  想定する**版番号を含まない安定した接頭辞**の asset 名にする（現在は
  `com.ayutaz.opencv-unity-native-<version>-<platform>.tgz` と版番号入り）、
  (b) 全部入り tarball が **512 MB 未満**であることを検査する、
  (c) 登録申請を出す。

  **(b) は今は必ず通る回帰ガードである。** 現状の配布物は上限まで大きく余裕がある
  （実測値と内訳は[競合調査](./unity-opencv-integration-research-and-plan.md) §4.6）。
  **起草時は「壊して落ちるところを見られるのは profile を足す段階（M7）になってから」
  と書いたが、それは外れた** —— 上限を `pack-upm-tarball.ps1` の `-MaxBytes` 引数に
  したので、小さい値を渡せば今日そのまま落とせる（`tools/tests/PackageRelease.Tests.ps1`
  が `-MaxBytes 1000` で実際に落としている）。**検査の閾値を定数ではなく引数にすると、
  その検査が働くところを見られる。**
  **公開が成立するかは OpenUPM 側の受理によるので、この条件には含めない** ——
  他のすべての条件が自リポジトリで判定できるのに対し、ここだけが第三者に依存する
- **`imgcodecs` を C ABI に出す。** 中核は**メモリ上の byte 列を相手にする経路**
  （`imencode` / `imdecode` に相当するもの）とする —— ファイルパスを native へ渡す形は、
  Windows の文字コードの扱いが増えるうえ、**Android では `StreamingAssets` が APK の
  中にあってパスで開けない**ので、モバイルへ進む前提と噛み合わない
- **Unity 6.3 LTS（6000.3.x）で L4 / L5 が通る。** 現在検証している 6000.0 LTS は
  **2026-10 に通常のサポートが終わる**（[Unity 6 のサポート表](https://unity.com/releases/unity-6/support)。
  Enterprise / Industry 契約者向けの延長は 1 年ある）。載せ替え先の 6.3 LTS は
  2027-12 までサポートされる

**非ゴール**
モバイル platform の追加（M4）。カメラ入力（M4）。新しい画像処理関数。
Asset Store での配布。

**実測による完了判定（2026-08-30、`milestone-complete` skill の手順で照合）**

| # | 完了条件 | 判定 |
| --- | --- | --- |
| 1 | 全 platform の binary を 1 つに収めた tarball を `release.yml` が作る | **満たす（留保あり）**。`tools/assemble-plugins.ps1` と `pack-upm-tarball.ps1 -AllPlatforms` はローカルで実測（3 binary が同梱されていることを、作った archive の中を数えて確認）。**`release.yml` 側の配線も 2026-08-30 に通した**（run 33289128197、`workflow_dispatch`。いまの 2 job 構成での実績）—— 組み立て 3 binary、tarball 61 entries、staged 17 assets、`SHA256SUMS` 17 行（大きさは条件 4 の行にある）。Release は作られていない（publish job は tag に限る）|
| 2 | その tarball を使い捨ての Unity プロジェクトに導入して EditMode が通る | **満たす**。`dev.ps1 test-unity-tarball -PluginSource` に v0.1.1 の macOS / Linux を重ねて全部入りを作り、`==> UPM tarball install: 16 passed`（2026-08-30、このマシン）。**このレーンはどの workflow にも入っていない**（ローカル専用。M3 から変わっていない） |
| 3 | 全部入りの中で Unity が自分の platform の binary だけを読み込むことを実測する | **満たす**（2026-08-30。M3.5 時点では「満たすが未実証」だった —— 下の「条件 3 を閉じる」）。**CI が 3 platform を同居させた状態で `PluginGatingTests` を走らせ、`==> [EditMode] output says: native plugins present: 3 [` と gating 4 件の個別 Passed を出した**（PR #37、`c070923`、run 33290375806）。`PluginGatingTests`（EditMode 6 件）は書いたが、**自動で走る唯一の場所（`ci-unity.yml`）には 1 platform 分の binary しか無く、6 件が要素 1 個の集合を検査して緑になっていた**。`ci-unity` が他 2 platform を自分でビルドして重ねる形にし、gating が走ったことまで結果 XML で確かめるようにした（下記）。**この判定はその CI が緑になった時点で更新する** —— 「ファイルが存在する」は「CI で実行された」ではない |
| 4 | OpenUPM へ登録できる形にする | **(a)(b) は満たす、(c) は未了**。(a) asset 名から版番号を落とした（`com.ayutaz.opencv-unity-native.tgz`）。(b) `pack-upm-tarball.ps1 -MaxBytes`（既定 512 MB）が上限を見る —— 全部入りの実測は 9.6 MB（9,608,334 バイト）。(c) **登録申請を提出し、受理された**（openupm/openupm PR #6843、2026-08-30。`Data validation` が通り自動マージ）。**OpenUPM 側の受理はこの条件に含めていなかった**が、結果として通った —— `https://package.openupm.com/com.ayutaz.opencv-unity-native` が `0.2.0` を配信し、落とした tarball に 3 platform の binary が入っていることを実測した |
| 5 | `imgcodecs` を C ABI に出す（メモリ上の byte 列） | **満たす**。`ocvu_imencode` / `ocvu_imdecode`（公開 ABI 18 → 20 本、allowlist は 9 → 11 本）。L1 8 ケース / L3 8 ケース、C# は `CvCodecs`。**着手して初めて `imgcodecs` がリンクされていなかったことが分かった**（下記） |
| 6 | Unity 6.3 LTS（6000.3.x）で L4 / L5 が通る | **満たす**。`6000.3.16f1` で L4 が 16 passed、L5（IL2CPP Player）が 10 passed（2026-08-30、このマシン）。`package.json` の `unity` も `6000.3` にした。**L5 は最初に落ちた** —— 6.3 のエディタに IL2CPP モジュールが無く `Currently selected scripting backend (IL2CPP) is not installed` で Player のビルドが止まったので、Hub の CLI で入れてから通した |

### 条件 2・3 の証拠を、どうすれば再現できるか

**この 2 件の実測は「3 platform 分の binary が `Runtime/Plugins` に揃っている」
状態でしか成立しない。** そしてその状態は、**このリポジトリのどのコマンドも
自動では作らない** —— `dev.ps1 build` は実行中 platform の分しか置かず、
`Runtime/Plugins/` は git の追跡外だからである。

**手順を書いておかないと、証拠が「著者の機械にたまたま残っていたもの」に
なる。** 実際、それが原因で `test-tools-slow` が CI の Windows / macOS job で
落ちる欠陥を見落とした（レビューが再現して見つけた）。

```
# 公開済みの release から他 platform の実物を取る
gh release download --repo ayutaz/OpenCVUnityNative     --pattern "*macos-arm64.tgz" --pattern "*linux-x64.tgz" --dir /tmp/ocvu   # 版を固定しない = 最新
mkdir -p /tmp/ocvu/mac /tmp/ocvu/linux
tar -xzf /tmp/ocvu/*macos-arm64.tgz -C /tmp/ocvu/mac
tar -xzf /tmp/ocvu/*linux-x64.tgz   -C /tmp/ocvu/linux

# 重ねて全部入りとして検査する
./tools/dev.ps1 test-unity-tarball -PluginSource "/tmp/ocvu/mac/package;/tmp/ocvu/linux/package"
```

**後始末は自動では行われない。** `tools/assemble-plugins.ps1` は
`Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins` を直接書き換え、
消しはしない。単体 platform の状態に戻すには、他 platform のディレクトリを
手で消す（`Runtime/Plugins/` は追跡外なので git では戻らない）。

**この残骸があると、他のレーンの見え方が変わる。** `dev.ps1 test-unity-tarball`
は 3 つ揃っていれば全部入りとして扱い、`PackageRelease.Tests.ps1` は
単体 platform の検査で他 platform を退避する。どちらも残骸を前提にはして
いないが、**「自分の機械で緑だった」を証拠として書くときは、どちらの状態で
走らせたのかを併記すること。**

---

**M3.5 完了時点（2026-08-30、PR #34）の判定は 6 件中 4 件が満たし、1 件が
「満たすが未実証」、1 件が部分達成だった。** その後の 2 つで残りが閉じた:

- **条件 3** —— PR #37 が `ci-unity` に 3 platform を同居させ、CI が
  `native plugins present: 3` と gating 4 件の個別 Passed を出した（下の「条件 3 を閉じる」）
- **条件 4 (c)** —— v0.2.0 を公開し、openupm/openupm へ提出して受理された（下の「配布 その 3」）

**したがって M3.5 は 6 件すべてを満たし、完了した（2026-08-30）。**

**条件 3 を「満たす」に数えない理由を明記する。** 検査は書いたし、3 platform
同居の状態で壊すと落ちることも確かめた。だが**自動で走る場所ではその状況が
成立しない**ので、検査があることと検査されていることが一致していない。
これは M2 の条件 7 に当てたのと同じ基準である ——「ファイルが存在する」は
「CI で実行された」ではない。手作業でしか成立しない証拠を「実測で満たした」と
数えると、その基準が一貫しなくなる。

### 配布 その 3 — v0.2.0（2026-08-30、最新の公開版）

**M3.5 の成果を初めて配った版である。** v0.1.1 との差は 3 つ:

- **画像の encode / decode**（`CvCodecs.Encode` / `Decode`）
- **配る正が全部入りの tarball 1 つになった**（`com.ayutaz.opencv-unity-native.tgz`）
- **Unity の下限が 6000.0 → 6000.3 に上がった。** `package.json` の `unity` が `6000.3` なので、
  **6000.0 の利用者はこの版を導入できない** —— imgcodecs より影響が大きいので、
  リリースノートの冒頭に「前の版から変わったこと」として書いた

`OCVU_ABI_VERSION` は 1 のまま（関数の追加は bump しない規約）。

**段取りは v0.1.x と同じ 3 段階**（空撃ち → 下書き → 人が公開）だが、**空撃ちで通る範囲が
広がった** —— 以前は publish job ごと tag に限っていたので、全部入りの組み立て・asset の
staging・`SHA256SUMS` の生成が空撃ちでは 1 行も走らなかった。job を `assemble` と `publish` に
割って、**組み立てまでは tag でなくても通る**ようにした（PR #36）。

**公開後に、公開物そのものを検証した**（2026-08-30、このマシン）:

| 検査 | 結果 |
| --- | --- |
| asset | 18 件（3 platform × 5 + 全部入り 2 + `SHA256SUMS.txt`） |
| `SHA256SUMS.txt` | 落とした 5 件すべて `OK`（`sha256sum -c`） |
| 全部入りの中身 | 61 entries、3 platform の binary、`package/package.json` が root 直下 |
| Linux binary の移植性 | `GLIBC<=2.34, GLIBCXX<=3.4.29`（上限 2.35 / 3.4.30） |
| Unity への導入 | **公開物の binary**を使い捨てプロジェクトに入れて `16 passed`、gating 4 件が個別 Passed |
| 匿名取得 | `releases/latest/download/…` が v0.2.0 を返し、SHA-256 が一致 |

**1 回目の導入検証は無効だった。** パスの受け渡しに失敗して `-PluginSource` が空になり、
このマシンに元からある 3 platform の木で走っていた —— **公開物を検証したことにならない**ので、
ローカル分を退避してやり直した。

### 配布 その 4 — v0.3.0（2026-08-31。**下書きのまま止めてある**）

`v0.3.0` の tag を打ち、`release.yml` が **28 asset の下書きを作った**（run 33348283112、
`Publish the release` を含む全 job success）。**公開はしていない。**

| 検査 | 実測（公開される実物を落として） |
| --- | --- |
| asset の数 | 28 件（5 platform × 5 + 全部入り 2 + `SHA256SUMS.txt`）|
| `SHA256SUMS.txt` との一致 | 落とした 2 件とも OK |
| 全部入りの中身 | 5 platform 分の binary と `.meta` が揃っている（73 entries、28,063,346 バイト）|
| `package.json` | `version=0.3.0` / `unity=6000.3` |
| Linux の GLIBC 要求 | `GLIBC<=2.34, GLIBCXX<=3.4.29`（上限 2.35 / 3.4.30）|
| Android の page size | `PT_LOAD 3 件、最小 p_align = 16384` |
| iOS の `.a` | `!<arch>`、16,782,128 バイト |

**止めている理由。** この版の目玉（Android / iOS 対応）が**実機で一度も動いていない**。
M4 の完了条件 9 件のうち 4 件が閉じておらず、2 件が実機である。

**同じ形で一度失敗している** —— v0.1.0 は 3 platform ともビルドが成功し linkage 検証も
配布物生成も通ったのに、公開した Linux の `.so` は古い環境で読み込めなかった。
**Unity を実際に動かすまで誰も知らなかった。** いま出そうとしているのは、それと同じ
「クロスビルドは緑、実機は未確認」の状態のモバイル対応である。

このリポジトリは**一度配ったものを黙って差し替えない**（v0.1.1 がそうだった）ので、
実機で動かなければ v0.3.1 を出すことになる。公開すると OpenUPM も拾い始める。
**待っても失うものが無い** —— tag は push 済み、asset は添付済みで検証済み、期限も無い。

**公開の条件**: [実機検証の手順](./m4-device-verification.md) の §1 と §2 を実施し、
問題が無いこと。実施したら `gh release edit v0.3.0 --draft=false`。

**2026-09-01 に、利用者が「実機検証も v0.3.0 の公開もスキップする」と決めた。**
これは「まだやっていない」ではなく**やらないと決めた**である ——
次に読む人が調べ直さないよう、判断として記録する。帰結は 3 つある。

1. **M4 は 9 件中 5 件のまま止まる。** 条件 3・4 は実機が要り、条件 6・7 は
   2026-08-31 に「CI では閉じない」と結論済みなので、**この 4 件はどれも
   自然には閉じない。** 誰かが実機を用意して手順書を実施するまで動かない。
2. **Android / iOS は「CI がビルドするが、誰も動かしたことがない」まま残る。**
   コードは main に在り、CI は 5 platform 分をビルドし、`release.yml` は
   28 asset を作れる。**動くかどうかだけが未知である。**
3. **利用者に届く最新版は v0.2.0（3 platform）のままである。** OpenUPM が
   配信しているのもそれで、**モバイル対応は誰の手にも渡らない。**

**この下書きをそのまま公開してはならない。** 作った時点（2026-08-31T01:40Z）は
**M5 が main に入る前**で、asset の中の `.g.cs` も `docs/api-map.md` も
入っていない。**配ると決めたら、tag を打ち直して作り直すこと** ——
**その手順は下の「配布 その 5 — v0.4.0」にある。**
下書きを消す必要は無い —— 残っていても誰にも見えないし、期限も無い。

### 配布 その 5 — v0.4.0（**未着手。次にやること**）

**M4（5 platform）と M5（生成器と校正 API）の成果は、まだ誰にも届いていない。**
利用者が使えるのは v0.2.0（3 platform、M5 前の API）で、OpenUPM が配信しているのもそれである。

**v0.3.0 の下書きは使えない。** 作った時点（2026-08-31T01:40Z）は M5 が main に入る前で、
asset の中の `.g.cs` が M5 前のもの（というより、生成物が 1 つも無い）である。**tag を打ち直して作り直す。**

#### 何が変わるか（v0.2.0 → v0.4.0）

| 対象 | v0.2.0 | v0.4.0 |
| --- | --- | --- |
| platform | 3（Windows / macOS / Linux） | **5**（+ Android arm64-v8a / iOS arm64） |
| 公開 C ABI | 20 本 | **27 本**（本数の正本は [API 対応表](./api-map.md) の冒頭） |
| 境界の宣言 | 手書き | **`bindings/spec/*.json` から生成**（手書きの `[DllImport]` は 0 個） |
| OpenCV module | core / imgproc / imgcodecs | **+ objdetect / features / geometry / calib**（`geometry` は依存として推移的に引かれるが、`COMPONENTS` にも意図として明示してある） |
| 主な API | Mat / imgproc 3 本 / 画像の encode・decode | **+ QR / ORB / 射影変換 / カメラ校正 3 段** |

#### モバイルの扱い —— **配るが、実機未検証と明記する**（2026-09-03 に決定）

**Android / iOS は CI がビルドするが、実機で一度も動かしていない。** M4 の完了条件
9 件のうち 4 件が閉じておらず、うち 2 件は実機が要る（`docs/m4-device-verification.md`）。

**それでも配る。** ただし**黙って配るのではなく、知らせて配る**:

- **リリースノート**に「Android / iOS は CI がクロスビルドし、16 KB page size と
  静的リンクを機械的に検証しているが、**実機で動作確認していない**」と明記する
- **`README.md`** の platform 表にも同じ注記を付ける
- **`package.json` の説明**は変えない（そこに書くと OpenUPM の一覧で切れる）

**この判断は v0.1.0 の教訓と衝突する。** あのときは 3 platform ともビルドが成功し
linkage 検証も配布物生成も通ったのに、Linux の `.so` は古い環境で読み込めなかった ——
**Unity を実際に動かすまで誰も知らなかった。** いま出そうとしているのは同じ形である。

**衝突を承知で配る理由**: (a) 実機検証は 2026-09-01 に「スキップする」と決めており、
**待っても自然には閉じない**（誰かが端末を用意するまで動かない）。(b) desktop 3 platform
だけを配る形に戻すのは、全部入りの仕組みも gating の検査も 5 platform を前提にしている
ので**大きな後退**になる。(c) **明記すれば利用者が判断できる** —— v0.1.0 との違いは
そこである。あのときは「動く」と暗黙に主張していた。

**実機で動かないと分かったら v0.4.1 を出す。** このリポジトリは一度配ったものを
黙って差し替えない（v0.1.1 がそうだった）。

#### やること

1. **`.github/release-notes.md` を v0.4.0 の内容にする** ——
   **2026-09-03 に済ませた**（M5 の全部を足し、出していないものも明記した）
2. **`README.md` / `README.ja.md` にモバイルが実機未検証であることを書く** ——
   **2026-09-03 に済ませた**（「ビルドはされているが実機で動かしていない」の節）
3. **`Packages/com.ayutaz.opencv-unity-native/package.json` の `version` を上げる**
4. **その変更を main へ入れる。** main は保護されており直接 push できないので、
   PR を出して CI を通す。**`release.yml` は tag と `package.json` の版が一致する
   ことを検査する**ので、tag を打つ前に main に入っていなければならない
5. **tag を打つ**（`v0.4.0`）→ `release.yml` が 5 platform 分と全部入りを作り、`--draft` で止まる
6. **下書きを実物で検証する** —— 落として `SHA256SUMS.txt` と突き合わせ、全部入りの中に
   5 platform 分の binary と `.meta` が在ること、生成された `.g.cs` が入っていること、
   Linux の GLIBC 要求、Android の page size、iOS の `.a` を見る（**「配布 その 4」の表と同じ項目**）
7. **公開する**（`gh release edit v0.4.0 --draft=false`）
8. **OpenUPM が拾うことを確かめる。** 確かめ方:

   ```sh
   curl -s https://package.openupm.com/com.ayutaz.opencv-unity-native |
     python -c "import sys, json; print(json.load(sys.stdin)['dist-tags']['latest'])"
   ```

   これが `0.4.0` を返せば配信されている。**OpenUPM はビルドキューを持つので、
   公開した直後には反映されない** —— v0.2.0 のときも数時間かかった。
   **「登録済みだから自動で拾うはず」で終わらせない。**
9. **公開後に文書を更新する。** 「最新の公開版」を書いている場所は次のとおり:
   `docs/roadmap.md`（この節と「配布」の各節）、`CLAUDE.md`（現在地の段）、
   `docs/README.md`（Status）、`README.md` と `README.ja.md`（冒頭の Status と
   「導入」の節）、`docs/api-reference.md`（対象範囲）、
   `.github/release-notes.md`（次の版のために「前の版」を繰り上げる）。
   **7 ファイルある。** 1 つでも古いと、次に読む人が違う版を前提に動く。

#### 既存の v0.3.0 の tag と下書きをどうするか

**触らない。** tag は push 済み、下書きは誰にも見えず、期限も無い。**消す必要が無い。**

**再利用もしない** —— asset は M5 が main に入る前のもので、生成物が 1 つも入っていない。
v0.4.0 は新しい tag を打って作り直す。**版番号を飛ばすことになるが、それでよい** ——
v0.3.0 という名前の物が世に出ることはないので、誰も混乱しない。

#### 完了条件

- [ ] `v0.4.0` が公開され、28 asset が並んでいる
- [ ] 全部入りの tarball を落として、**5 platform 分の binary と `.meta`**、
      **生成された P/Invoke 宣言（`Runtime/Interop/NativeMethods.*.g.cs`）** が
      入っていることを実測する。**`docs/api-map.md` は package に入らない** ——
      あれはリポジトリの文書であって、配布物の一部ではない
- [ ] リリースノートと `README.md` / `README.ja.md` に**モバイルが実機未検証であること**が明記されている
- [ ] OpenUPM が `0.4.0` を配信する（**確かめるまでが作業**。「登録済みだから自動で拾うはず」で終わらせない）
- [ ] 公開後に「最新の公開版」の記述を更新する（**7 ファイル。一覧はやること 9 にある** —— ここに写すと 2 つが食い違う）

#### 非ゴール

- **実機検証**（2026-09-01 に「やらない」と決めた。この配布で覆さない）
- **M4 の残り 4 件を閉じること**（実機 2 件は端末が要り、CI の 2 件は「CI では閉じない」と結論済み）
- **v0.3.0 の下書きを再利用すること**（M5 前のものなので作り直す）

### OpenUPM への登録（条件 4 (c)）

**openupm/openupm PR #6843 として提出し、自動マージされた**（2026-08-30。`Data validation`
SUCCESS → `Rule: Automatic merge for adding new package`）。

**提出前に、用意してあった定義の誤りが 1 件見つかった。** `topics` に書いていた
`computer-vision` と `native` は**どちらも OpenUPM に存在しない slug** で（正本は
`data/topics.yml`）、そのまま出せば弾かれていた。有効な `integration` / `utilities` に直した。

**照合の仕様も、こちらの記述とは違った。** `docs/openupm-registration.md` は
「`githubReleaseAssetName` は安定した接頭辞で asset を選ぶ」と書いていたが、実際は
**完全一致が先で、無ければ「その値で始まる唯一の asset」にフォールバック**する
（[OpenUPM の文書](https://openupm.com/docs/adding-upm-package.html)）。
**こちらの `com.ayutaz.opencv-unity-native.tgz` は完全一致するので、同じ Release にある
platform 別 tarball 3 つとの取り違えは起きない** —— 版番号なしの裸の接頭辞にしていたら
4 つ全部に一致して曖昧になっていた。

**共有バリデータはローカルで走らせていない**（`openupm-next` のビルド済みチェックアウトが
要る）。**そのことは提出 PR の本文に明記した。** 代わりにローカルで確かめたのは、
ファイル名と `name` の一致、既存 3,895 件との重複なし、topics が実在する slug、
key の集合と順序が直近のマージ済み例と一致、`minVersion` が実在する非 draft の tag。

**受理は完了条件に含めていなかった**が、結果として通り、レジストリからの配信も実測した:
`https://package.openupm.com/com.ayutaz.opencv-unity-native` が `0.2.0` を `dist-tags.latest`
として返し、そこから落とした tarball（9,608,290 バイト）に 3 platform の binary が入っている。

### 条件 3 を閉じる

**閉じるには `ci-unity.yml` で 3 platform を組む必要がある。** Linux の CI は
自分の `.so` しかビルドしないので、他 2 つをどこかから持ってこなければならない。

**2026-08-30 に閉じた。** PR #37（`c070923`）が `ci-unity` に windows / macOS の
plugin をビルドする job を足し、`unity` job がそれを重ねてから走る形にした。
**CI で実測**（run 33290375806）: `==> present:` が 10 行（3 binary + それぞれの `.meta` +
ディレクトリの `.meta`）、gating の 4 件が個別に `passed (1 cases)`、
`==> [EditMode] output says: native plugins present: 3 [`、`16 passed`。
**要素 1 個の集合ではなく、3 つ揃った状態で検査されている。**

取ってくる先として 3 つを比べた:

| | やり方 | 引き換えに |
| --- | --- | --- |
| A | 公開済み Release から落とす | **merge を止めるチェックが外部の公開物に依存する。** Release を消す・名前を変えるだけで main が固まる |
| B | **`ci-unity` 自身が windows / macOS でビルドする**（採用） | CI 時間が増える（`ci-native` と同じビルドを重ねて行う）。依存は増えない |
| C | `nightly` に置く | **赤くても merge を止められない** —— このリポジトリが繰り返し踏んでいる穴 |

**合図の渡し方も変わった。** `OCVU_EXPECT_ALL_PLATFORMS` という環境変数は
**CI では届かない** —— game-ci がコンテナへ渡す環境変数は 34 個の固定一覧で、
任意の名前は入らない（`@v4` の `dist/index.js` で実測）。届かなければテストは
「合図が無い」分岐に落ち、**要素 1 個でも緑になる** —— 塞ごうとしている穴と
同じ壊れ方を合図の側がする。プロジェクト直下のファイル
（`ocvu-expect-all-platforms`）に替えた。ワークスペースはコンテナに mount
されるので、ローカルと CI で同じ経路になる。

残るもう 1 つは条件 4 の (c)（OpenUPM 登録申請）で、
**公開済みの Release が要るので PR の中では閉じない。**

**CI は 2026-08-29 に green になり、PR #34 として main に入った**（`41cda19`。PR 上のチェックは 14 本 —— 必須チェックに加えて、PR にだけ出る CodeQL の集約が 1 本ある。**必須チェックの一覧と本数は `CLAUDE.md` の「機構として強制されていること」が持つ**）。
Unity のレーンは **CI 上でも `==> [EditMode] 16 passed` / `==> [Standalone] 10 passed`**
（run 33264535794、Linux、6000.3.16f1）。上の判定のうち条件 5・6 は CI でも確定した。

**ただし CI が green になったことは、条件 3 が満たされたことを意味しない。**
**PR #34 の時点では** CI の EditMode は Linux の plugin 1 つだけで走ったので、
`PluginGatingTests` の 6 件は**要素 1 個の集合を検査して緑になっただけ**だった ——
これは予測どおりの結果で、「緑だから効いている」が成り立たない例そのものである。
（**2026-08-30 に `ci-unity` が 3 platform を自分で組む形にした。** 上の
「条件 3 を閉じる」を参照）

**M3 で「ローカルでは緑だった欠陥が CI で 3 件出た」ことを記録したが、M3.5 では
それが PR 前のレビューで 2 件出た**（`test-tools-slow` が CI の Windows / macOS で
落ちる状態、tag を打つと Release が作られない状態）。**どちらもローカルは緑だった。**
CI に投げる前に捕まえられたのは、レビューが clean checkout の状態を再現したからである。

**条件 3 で、鈍い検査を 2 つ捕まえた。** どちらも「通っているから効いている」が
成り立たない例である。

- **壊しても素通りしていた。** macOS の `.dylib` の `.meta` を Windows でも有効になるよう
  壊すと、**従来の EditMode（10 件）は 10 passed のまま緑だった。** 同じ壊し方で
  `PluginGatingTests` は 16 件中 3 件が落ちる。**同居させただけでは取り違えを見つけられず、
  「どう振り分けられたか」を Unity 自身に問うて初めて見える。**
- **`PluginImporter.GetCompatibleWithEditor()` は 3 つとも `true` を返す。** `.meta` は
  3 platform いずれもエディタを有効にしたうえで OS の下位設定で振り分けるので、
  **この flag だけを読む検査は常に真になり、何も検査しない。** 見るべきは
  `GetEditorData("OS")` である。

**`imgcodecs` は「入っている」と「リンクしている」を取り違えていた。** M3.5 の前、
このリポジトリは複数箇所で「モジュールはリンク済み」と書いていたが、**それは誤りで、
`cmake/FindOpenCvUnityDeps.cmake` は `COMPONENTS core imgproc` しか要求していなかった。**
実装を書いた時点で `cv::imencode` / `cv::imdecode` が未解決の外部シンボル（LNK2019）に
なり、リンカが証拠を出した。**誤解しやすい形だった** —— `tools/opencv-config.psd1` の
`Modules` には `imgcodecs` が入っており（= **OpenCV 自体はそれを含めてビルドされる**）、
`ocvu_get_build_information()` も `To be built: ... imgcodecs ...` と報告する。
**「OpenCV に入っている」と「このプラグインがリンクしている」は別である。**
component を足しただけでは何も変わらず（静的リンクは参照された object しか引かない）、
Windows の debug plugin が 8,831,488 → 10,177,536 バイト（+1.35 MB）に増えたのは
**関数を書いたからである。**

**ABI はファイルパスを受け取らない。** 扱うのはメモリ上の byte 列だけで、
理由は Windows の文字コードの扱いと、**Android の `StreamingAssets` が APK の中にあって
パスで開けない**ことである。したがって**「画像ファイルの読み書き」ではない** ——
ファイルを開くのは呼ぶ側の仕事のままである。`ocvu_imencode` は
**出力の大きさを呼ぶ側が事前に知りえない最初の ABI 関数**だが、native が確保した blob の
handle は導入せず、既存の 2 回呼びの形（`OCVU_STATUS_BUFFER_TOO_SMALL` +
`out_required_size`）に載せた。**bytes は最初から最後まで呼ぶ側の所有で、
buffer が足りないときは何も書かない。**

---

## M4 — Mobile

**目的**
独自 C ABI が Unity の**最も制約の強い実行環境**で成立することを確認する。ここで見つかる制約（stripping、static link、page size）は、M5 で生成するコードの形を規定する。

**ゴール**
Android arm64-v8a と iOS arm64 で実機 smoke test が通る。

**完了条件**

- Android arm64-v8a と iOS arm64 の native artifact を CI が生成する
- **Android の 16 KB page size を CI で検証する。**
  [Android 開発者向け文書](https://developer.android.com/guide/practices/page-sizes)（2026-08-29 に確認）は
  「Android 15 (API 35) 以降を対象とするアプリは Google Play 上で 16 KB に対応して
  いなければならない」と要件を現在形で書いたうえで、**それが公開の可否に効く日付を
  1 つだけ挙げている: 2027-02-01** —— その日から、対応していない更新は公開できなく
  なる。**要件は今あり、遮断は 2027-02-01 から**、という読みである。
  **止まるのは利用者のリリースである**（こちらが配る `.so` が利用者のアプリに入る
  ため）ので、**その日より前に満たしておく**
- iOS の `__Internal` static link と linker stripping 後も P/Invoke が解決することを実機で確認する
- lifecycle（background / foreground）と memory pressure を検証する
- **`WebCamTexture` から `CvMat` を作れるようにする**（穴 #5）。カメラ入力そのものは
  Unity 側から受ける方針を変えないが、**受け取る API が今は無い** ——
  `TextureConverter` は `Texture2D` の RGBA32 しか受け付けない
- **macOS の Plugin Import Settings を Unity で実測する**（穴 #6）。iOS のビルドには
  macOS runner が要るので、ここで初めて macOS 上で Unity を動かすことになる
- **`windows-2022` 上で `game-ci/unity-test-runner@v4` へ実際に投げ、その run の出力を根拠として
  記録したうえで、Windows の IL2CPP Player を CI で回すかどうかを結論として書く**
  （穴 #7）。やると決めるか諦めると決めるかは問わないが、**上流の issue を読んだ
  結果を根拠にしない** —— 今回崩れた判断がたどったのがその経路である
- **対応 CPU アーキテクチャの範囲を決める**（穴 #8）。少なくとも Android の
  x86_64（エミュレータ）を含めるかは、開発体験に直接効くので明示的に決める。
  **M3.5 の 6.3 載せ替えで、Unity 自身が最低要件を上げた** —— Android の minSdk が
  23 → 25、iOS の target が 13.0 → 15.0（`tests/UnityProject/ProjectSettings/ProjectSettings.asset`
  の差分）。この決定はその上で行う
- **モバイルの binary が全部入り package に入り、`dev.ps1 test-unity-tarball` が
  通る。** M3.5 が作るのは Desktop 3 platform 分なので、**platform を足す作業は
  ここに残る**（`tools/pack-upm-tarball.ps1` と `tools/assemble-plugins.ps1` の**両方**が
  未知の platform を明示的に拒むので、黙って抜けることはない —— **裏を返すと、
  platform を足すときはそこも直すことになる。直す場所の一覧は `add-a-platform` skill が持つ**）。**このレーンが示せるのは「入っていること」と「他を
  壊さないこと」までで、モバイルの binary が動くことは示せない** —— それは同じ M4 の
  実機 smoke test の担当である。ここまで通って初めて「エディタは Windows、実機は
  Android」が利用者の手元で成立する


### 対応 CPU アーキテクチャの決定（穴 #8）

**Android は arm64-v8a のみ。iOS は arm64（実機）のみ。**

**Android の x86_64（エミュレータ）は含めない。** 理由:

- **実機は事実上すべて arm64-v8a である。** x86_64 が要るのはエミュレータでの
  開発中だけで、配る成果物の対象ではない
- **含めると全部入りが大きくなる。** OpenCV を静的リンクした `.so` が 1 つ増える
  ぶん、OpenUPM の 512 MB 上限に対する余裕が減る（現在 9.6 MB。**モバイルを
  足した後の実測は下の表に入れる**）
- **エミュレータでの開発を止めるわけではない。** 利用者が自分でビルドする経路は
  残る —— `tools/opencv-config.psd1` の `Toolchains` に `android-x64` を足し、
  `CMakePresets.json` に preset を足せば通る

**この決定は覆せる。** M4 Task 1 で対象 platform を host から切り離してある。
直す場所の一覧は `add-a-platform` skill が持つ（**ここに数を再掲しない** ——
2 箇所に書けば 2 箇所が同時に古くなる）。`tools/tests/PackageRelease.Tests.ps1`
が packaging 側の一致を機械的に見る。

**iOS のシミュレータ（x86_64 / arm64-simulator）も含めない。** 別の sysroot
なので同じ `.a` では動かず、**実機で動かすためのパッケージ**である。
シミュレータで開発したい利用者は `cmake/toolchains/ios-arm64.cmake` を複製せず、
`CMAKE_OSX_SYSROOT` を `iphonesimulator` にして自分でビルドする。



### M4 の判定（2026-08-30 時点）

**9 件中 6 件を満たし、3 件は閉じていない。**（完了条件は 9 件ある —— 9 件目は
「モバイルの binary が全部入りに入り `dev.ps1 test-unity-tarball` が通る」で、
**以前は表の外の散文に落ちていた。表に無い条件は次に判定する人の目に入らない。**）

| # | 完了条件 | 判定 |
| --- | --- | --- |
| 1 | Android arm64-v8a と iOS arm64 の native artifact を CI が生成する | **満たす**（2026-08-31）。`build-opencv.yml` が 5 platform 分の OpenCV を作り、`ci-native.yml` の `mobile` job が両方の plugin をクロスビルドして CI で緑になった（run 33319185326）。iOS の `.a` は 424 member・16,782,128 バイト |
| 2 | Android の 16 KB page size を CI で検証する | **満たす**（2026-08-31）。合成 ELF の 4 通りに加え、**実物の `.so` で両方向を実測した** —— 対応時は `==> libopencv_unity_native.so: PT_LOAD 3 件、最小 p_align = 16384`（run 33319185326）、**linker flag の書き方を変えて効かなくしたときは `PT_LOAD[1] p_align = 4096（16384 以上が要る）` で赤くなった**（run 33323002468）。後者は事故だったが、**「16 KB 整列は NDK の既定ではなくこの flag が作っている」ことと「検査が実物で落ちる」ことを同時に証明した** |
| 3 | iOS の `__Internal` static link と stripping 後の P/Invoke を**実機で**確認 | **閉じていない。2026-09-01 に利用者がスキップと決めた**（下の「配布 その 4」に理由と帰結）。`native/CMakeLists.txt` が iOS で `STATIC` を作る分岐は入れたが、**実機が要る**（署名と端末）。**やらないと決めたのであって、調べ残しではない。** 手順は [実機検証](./m4-device-verification.md) §1 —— **実機を用意すればいつでも実施できる** |
| 4 | lifecycle / memory pressure | **閉じていない。同じくスキップと決めた**（2026-09-01）。同上、§2 |
| 5 | `WebCamTexture` から `CvMat` を作れる | **満たす**。`WebCamTextureConverter`（3 overload）。EditMode 9 件が通り、**上下反転をやめると `RowOrderIsFlippedSoTheMatOriginIsTopLeft` だけが落ちる**ことを実測した。Player でも 1 件通している（M4 のレビューで、この API が Editor しか通っていないと分かったため） |
| 6 | macOS の Plugin Import Settings を Unity で実測 | **閉じていない**（2026-08-31 に 4 回試して確定）。game-ci は macOS を支えない（`darwin-platform is not supported`）。Unity Hub の CLI で直接入れる経路も試し、**Editor は 14 分で入るところまで到達したが、ライセンスで止まる** —— `Found 0 entitlement groups and 0 free entitlements`。**認証を 2 系統（`-username`/`-password` と `.ulf`）とも試して同じ**なので、認証方法ではなく entitlement 自体が降りていない。**Editor の導入は障害ではなく、障害はライセンスである**（詳細は上記「担当が無かった制約」の節）|
| 7 | Windows IL2CPP を CI で回すかの結論 | **満たす**（2026-08-31）。**結論は「諦める」。** `windows-2022` に 2 回投げた —— EditMode は動いた（33 passed、run 33350726005）が、**`Standalone` は `ToolchainNotFoundException` で落ちた**（run 33352025223）。game-ci の Windows コンテナに、IL2CPP が生成した C++ をコンパイルする MSVC が無い。**このとき game-ci 自身は success を返しており、結果 XML の有無を別に見ていなければ逆の結論を書いていた。** 根拠は 2 回の実測で、他人の issue ではない（詳細は上記「担当が無かった制約」の節）|
| 8 | 対応 CPU アーキテクチャの決定 | **満たす**。Android arm64-v8a のみ / iOS 実機 arm64 のみ（上記「対応 CPU アーキテクチャの決定」） |
| 9 | モバイルの binary が全部入りに入り `dev.ps1 test-unity-tarball` が通る | **満たす**（2026-08-31、このマシン）。5 platform 分を束ねた tarball を使い捨ての Unity プロジェクトに導入して `==> UPM tarball install: 25 passed`。**ただしこのレーンはどの workflow からも走らない** —— game-ci の action の外で Unity を起動する必要があり、CI に載せるのは別作業である。**M4 でモバイルを足した時点からこのレーンは壊れており**（期待する binary の数が `3` と直書きされ、iOS の `.a` を binary と認めなかった）、無関係な作業の途中で 1 度手で回すまで誰も知らなかった |

**条件 1・2 は 2026-08-31 に「満たす」へ変えた。** この構成の CI が緑になり、
**実物の成果物に検査が当たった**からである（run 33319185326）。それまでは
M2 の条件 7 / M3.5 の条件 3 と同じ基準で「満たすが未実証」としていた ——
「ファイルが存在する」は「CI で実行された」ではない。

**条件 6 は「満たすが未実証」から「閉じていない」に下げた。** macOS runner で
クロスビルドはするが Unity を起動しないので、**この条件が言っていることは
何も確かめていない。** 「配線した」を「満たす」に数えていたのが誤りである。

**モバイルの binary が全部入りに入り `dev.ps1 test-unity-tarball` が通ること**
（roadmap の最後の条件）は **満たす**。5 platform 分を束ねた tarball を
使い捨ての Unity プロジェクトに導入して `==> UPM tarball install: 25 passed`
（2026-08-31、このマシン）。**ただしこのレーンはどの workflow からも走らない** ——
game-ci の action の外で Unity を起動する必要があり、CI に載せるのは別作業である。
`milestone-complete` の「CI では原理的に閉じない条件」と同じ扱いで、**人が回す**。
実際、M4 でモバイルを足した時点からこのレーンは壊れており（期待する binary の数が
`3` と直書きされ、iOS の `.a` を binary と認めなかった）、**無関係な作業の途中で
1 度手で回すまで誰も知らなかった。**


**非ゴール**
カメラ入力の独自実装。Web。**配布の形式そのものの変更**（全部入りにする方針は
M3.5 で決着させておく。M4 で足すのはその中身であって、形ではない）。

---

## M5 — binding specification と generator

**目的**
API 拡張を手書きから**レビュー可能な仕様からの生成**に切り替え、OpenCV の巨大な API 面を制御下で扱えるようにする。

**M4 の後に置く理由**: 生成されるコードの形は iOS static link と IL2CPP stripping の制約を満たす必要がある。制約を実機で確定してから大量生成するほうが手戻りが小さい。

**ゴール**
binding specification から C ABI 宣言 / C# P/Invoke / API 対応表 / conformance test が生成される（L0 の導入）。

**M4 で分かった、generator が満たさなければならないこと**（2026-08-31 追記）。

- **生成した P/Invoke を、IL2CPP の Player から実際に呼ぶところまで生成する。**
  M4 の点検で実測した: 手書きの 19 本のうち **7 本が Editor でも Player でも
  一度も呼ばれていなかった**（`imgcodecs` 全部を含む）。L1 と L3 は見ているが、
  **stripping で消えないことを確かめられるのは Player だけである。**
  **呼ばれない宣言は、消えても誰も気づかない。** 関数を N 本生成するなら、
  conformance test も N 本生成して Player レーンに載せること。
- **binary をファイル名や拡張子で見分けない。** linux-x64 と android-arm64 は
  どちらも `libopencv_unity_native.so` で、iOS は `.a` である。M4 では
  「拡張子で binary を判定する」欠陥を **3 箇所**踏んだ。
- **iOS は静的リンクである。** 生成物が動的読み込みを前提にできない
  （`DllImport("__Internal")`）。

**M7 の決定 1（module 分離）がここに食い込む。** `dnn` を足す前に C ABI を
module 単位に割ると決めたので、**generator が生成するのは単一ヘッダではなく
module ごとのヘッダになりうる。** どちらが先に着手されるかで設計が変わるので、
着手時に M7 節の決定 1 を読むこと。

**完了条件**

- spec を正本として生成物が作られ、golden test で一致が検証される
- `geometry` / `calib` / `features` / `objdetect` などを**利用例に基づいて**追加する
- **`imgcodecs` は M3.5 へ移し、そこで実装した**（2026-08-30 完了）。2026-08-29 に
  一度ここへ入れたが、同じ日の再調査で前倒しに変えている。**生成の仕組みを待つ理由が
  無かった** —— notice は揃っており、足りないのは手で書く数本の ABI 関数だけで、
  それは既存の関数と同じ書き方で足せた。**ただし前倒しの理由として「モジュールは
  リンク済み」と書いていたのは誤りである** —— `cmake/FindOpenCvUnityDeps.cmake` は
  `core imgproc` しか要求しておらず、`imgcodecs` はプラグインにリンクされていなかった
  （M3.5 節を参照）。M3.5 で component を足し、`ocvu_imencode` / `ocvu_imdecode` を
  書いた（公開 ABI は 20 本、うち allowlist は 11 本）。**M5 で扱うのは、そこで
  手書きした関数を spec の側へ寄せることである**
- API 対応表を生成し、「OpenCV 全対応」という曖昧な表現を使わない
- 生成された P/Invoke が IL2CPP stripping を生き延びることを L5 で確認する

**非ゴール**
OpenCV 全 API の網羅。

### M5 の判定（2026-09-02 更新。**5 件すべてを満たした**）

**5 件すべてを満たした。** 2026-09-01 時点では 4 件で、条件 2 が
「部分的に満たした」だった —— **`calib` module と `cv::calibrateCamera` を
2026-09-02 に出して閉じた**（条件 2 の欄の末尾）。

実装は 4 つの計画にまたがる:
`docs/superpowers/plans/2026-08-31-m5-binding-generator.md`（Task 1〜8。生成の仕組み）、
`objdetect` / `features` / `geometry` を足した続きの計画
（`.superpowers/sdd/2026-09-01-m5-modules-objdetect-features/`、Task 1〜8）、
`docs/superpowers/plans/2026-09-01-m5-calib-undistort.md`（歪み補正とチェスボード検出）、
`docs/superpowers/plans/2026-09-02-m5-calib-camera.md`（**`calib` を足して校正の輪を閉じた**）。

実測はすべてこのマシン（Windows、2026-08-31〜09-01）。`pwsh tools/dev.ps1 test` は
**exit 0**で、内訳は tools 3 本（`OpenCvConfig` / `ConfigInvalidation` /
`BindingGenerator` の 16 assertion）+ `verify-generated`（**生成物は spec と
一致しています（14 ファイル）**）+ L1（GoogleTest **78** / CTest **4**）+
L3（`CvUnity.Tests.Managed` **51** / `Ocvu.Generator.Tests` **91**）である。
Unity の 2 レーンも実行し、`objdetect` / `features` を足した後も
壊れていないことを確認した: EditMode は **34 passed**（`PluginGatingTests` の
4 件を含む）、IL2CPP Player は **19 passed**（`EveryEntryPointIsReachable` が
`Passed`）。**件数はどちらも足す前と同じ** —— 到達性テストは 1 件のままで、
その中で呼ぶ宣言が 22 → 25 に増えただけだからである。**この確認こそが今回の作業で
最も重要だった** —— 生成した 25 本の P/Invoke 宣言が IL2CPP の stripping を
生き延びて全部解決することを、実物の Player で実証した。
**公開 C ABI は 20 → 23 本、うち allowlist は 14 本、C# の P/Invoke 宣言は 25 本になった**
（内訳は `docs/abi-ownership-and-versioning.md` §3・§3.6）。

| # | 完了条件 | 判定 |
| --- | --- | --- |
| 1 | spec を正本として生成物が作られ、golden test で一致が検証される | **満たす（実証済み）**。`bindings/spec/*.json` → `dev.ps1 generate` が 18 ファイルを出す（**M5 完了時点は 14 ファイル**。その後 `geometry` と `calib` の module を足した分だけ増えた）。`verify-generated` は `dev.ps1 test` に入っており、**3 platform の `ci-native` が走らせる**（**PR #55 で実際に通った** —— 穴 6 参照）。壊して落ちることを見た: 生成された `.h` と `docs/api-map.md` を手で書き換えると `verify-generated` が非 0 で返り、戻すと通る（`BindingGenerator.Tests.ps1` がその往復をレーンの中で毎回やる） |
| 2 | `geometry` / `calib` / `features` / `objdetect` を利用例に基づいて追加 | **満たした（2026-09-02 更新）。4 module すべてを出した。** 判定を変えた根拠はこのセルの末尾にある —— **経緯は残してあるので、下へ読み進めること。** **ただし条件の後半「利用例に基づいて」は、厳密には 4 module のうち `calib` の 1 つでしか満たしていない。** 残る 3 つは「利用例を持つものの中から、リンクが安いものを選んだ」が正確である（各 module の欄に同じ正直さで書いてある）。**それでも「満たした」と判定するのは、条件の主眼が「module を足す仕組みが働き、実際に使える API が増えること」だと読むためである** —— 出した 7 本はどれも Unity での用途を持ち、飾りで足したものは 1 本も無い。**この読みが甘いと考えるなら、判定は「部分的に満たした」に戻る。** 当初の実装計画は冒頭で明示的に対象外にした —— 新しい OpenCV module は `cmake/FindOpenCvUnityDeps.cmake` の `COMPONENTS`・`tools/opencv-config.psd1` の `Modules`・`THIRD_PARTY_NOTICES.md`・成果物の大きさ・依存 allowlist が同時に動く**別の subsystem**で（M3.5 の `imgcodecs` で実際に全部動いた）、生成の仕組みと同時にやると「生成が壊れたのか module が壊れたのか」を切り分けられない。**続く計画（`.superpowers/sdd/2026-09-01-m5-modules-objdetect-features/`）で `objdetect`（QR コードの符号化・復号）と `features`（ORB 特徴点検出）の 2 module を実際に出した** —— C ABI は 20 → 23 本、うち allowlist は 11 → 14 本になった（内訳は `docs/abi-ownership-and-versioning.md` §3.6）。**さらに続く作業で `geometry` も出した**（`ocvu_find_homography`。C ABI は 24 本、allowlist は 15 本）。**そこで推測が実測になり、予想と違った** —— `geometry` は「リンクが安い」どころか**リンクの手間がゼロだった。** `flann` と `geometry` は `features` / `objdetect` の依存として **CMake が推移的に引いており**、`COMPONENTS` に足す前からリンク行に入っていた（実測: 足す前も後もライブラリは同じ 7 つで、`cv::findHomography` を参照する L1 テストは `COMPONENTS` を変えずに最初から通った —— **RED にならなかった**）。**それでも `COMPONENTS` には明示した**（意図の宣言であり、上流が依存を変えたときに黙って壊れないため。no-op であることは実測で確かめた）。**残るは `calib` だけである。****対して `calib` だけが高い** —— `tools/opencv-config.psd1` の `Modules` に無いため、足すと構成ハッシュが変わって 5 platform 分の OpenCV を作り直すことになる（実測: `4785d98e9aad` → `09fcbe260d87`。**この値は 2026-09-01 に測り直した** —— それまで書いてあった `a197bbcbdaf5` は `geometry` を足したときの値で、`calib` のものではなかった）。**「`geometry` はビルドされていない」と読める記述は、この文書のどこにも見当たらなかった**（確認のため roadmap 全体を検索した）ので、訂正すべき誤りは無い。**条件の「利用例に基づいて」について、正直に書いておく。** QR の読み取り（チケット・名刺・機器の識別）と ORB の特徴点（追跡・位置合わせ）は Unity で十分ありふれた用途だが、**この 2 つを選んだ実際の動機は 「新しい module を spec から生成できることを実証する」ほうが大きい** —— `objdetect` / `features` は OpenCV 側が既にビルドしており、リンクが安かった。**利用者の要望から選んだのではない。** `geometry` / `calib` を出さなかった理由（利用例が無い）は変わっていないので、**まだ「満たした」ではなく「部分的に満たした」に留める** **その後（2026-09-02）、カメラの歪み補正を出した**（`ocvu_undistort` / `ocvu_find_chessboard_corners`。計画は `docs/superpowers/plans/2026-09-01-m5-calib-undistort.md`。C ABI は 26 本、allowlist は 17 本になった。内訳は `docs/abi-ownership-and-versioning.md` §3.8）。**判定は変えない** —— 依然として「部分的に満たした」のままである。**理由は 2 つ。** (1) 条件が名指しする 4 module のうち **3 つ**（`objdetect` / `features` / `geometry`）を出し、`calib` は出していない。**`calib` module は使っていない** —— `ocvu_undistort` は `imgproc`、`ocvu_find_chessboard_corners` は `objdetect` にあり、どちらも既にリンク済みだった（実測。`native/tests/test_module_linkage.cpp` がその前提を固定している）。**構成ハッシュは変わっていない。** (2) **より重要なのは、欠けている場所である。** カメラ校正は 3 段ある —— 盤の格子点を見つける、そこから係数を解く、係数で歪みを補正する。**この作業は 1 段目と 3 段目を出し、2 段目を出していない。そして 2 段目こそが `calib` を要求する段である**（`cv::calibrateCamera`。足すと構成ハッシュが変わって 5 platform 分の OpenCV を作り直すことになる。実測: `4785d98e9aad` → `09fcbe260d87`）。帰結として、**利用者は係数を別の手段でどこかから得なければ、この 2 本を使えない。**「歪み補正という用途は出した」は正しいが、**校正の輪は閉じていない。** **費用が安かったことと届いた機能は別の軸である。** `undistort` と `findChessboardCorners` がどちらも既存のリンクで済んだのは構成ハッシュを変えずに済んだという**費用**の話であって、利用者に何が**届いたか**の話ではない。両者を混ぜると判定が実際より甘くなる。**この 2 つを選んだ実際の動機も、`geometry` のときと同じ問題を持つ。** 歪み補正とチェスボード検出は Unity での用途（AR 較正、レンズ補正）として成立するが、**選んだ理由の実際の比重は「`calib` の再ビルドを避けられるから」のほうが大きい**。同じ正直さで記録しておく —— `objdetect` / `features` のときに書いた「利用者の要望から選んだのではない」と同じ構造がここにもある。 **そして 2026-09-02、`calib` module を足して `cv::calibrateCamera` を出した**（計画は `docs/superpowers/plans/2026-09-02-m5-calib-camera.md`。C ABI は 27 本、allowlist は 18 本。内訳は `docs/abi-ownership-and-versioning.md` §3.9）。**ここで判定を「満たした」に変える。** 条件が名指しする 4 module がすべて出た。**校正の輪も閉じた** —— 上に書いた 3 段（格子点を見つける / 係数を解く / 係数で補正する）の 2 段目がこれで、**利用者は係数を別の手段で得る必要が無くなった。** **費用は前もって書いたとおりだった** —— 構成ハッシュが `4785d98e9aad` → `09fcbe260d87` に変わり、5 platform 分の OpenCV を作り直した（run 33589583504）。**予想していなかったことが 1 つある**: 最初のビルドは 4 platform とも**依存 allowlist で落ちた**。`calib` が `stereo` を推移的に引き込み、`tools/verify-opencv-artifact.ps1` の許可リストに無いとして拒否された。**検査が意図どおり働いた例である** —— 気づかずに通ることはなかった。`stereo` は OpenCV 本体の module で third-party ではなく、新しい bundled 依存も持ち込まない（同じビルドの install ログに `stereo` 由来の `etc/licenses` は 1 件も現れない）。このプラグインは `stereo` のシンボルを 1 つも参照しないので、静的リンクの性質上、配布する binary には入らない。**`geometry` のときと違い、`COMPONENTS` の追加は本物の RED を出した** —— `cv::calibrateCamera` を参照する L1 テストを先に書くと未解決の外部シンボルでリンクに失敗し、`COMPONENTS` に足すと通った。**この時点では binary は 1 バイトも増えず**（21,190,144 のまま）、増えたのは関数を実装したときである（21,464,576 バイト、+274,432）。**「満たした」と書くにあたって、出していないものを明記する。** `calib` module には `stereoCalibrate`（ステレオ校正）・`calibrateHandEye`・魚眼系があり、`geometry` 側の `solvePnP`（既知の係数から 1 枚ぶんの姿勢を求める）も出していない。**出したのは単眼カメラの校正 1 本である。**「`calib` を出した」は「`calib` の全部を出した」ではない。**選んだ動機についても、上に書いたのと同じ正直さを保つ。** ただし `calib` だけは他の 3 module と性質が違う —— これは「安くて実証に向くから」ではなく、**歪み補正を出したのに係数を求められないという、実際に閉じていない輪を閉じるために足した。** 費用が高いと分かったうえで足した唯一の module である。 |

**条件 2 に着手するとき、どこを読むか**（M5 完了時に書いた。**skill にはしていない** ——
実際に module を足すまで「壊して落ちることを見る」ができないので、手順を先に
固めると確かめられない規約が増える。`prove-a-check-works` の規律に従う）。

- **前例は M3.5 の `imgcodecs` である。** 同じことを全部やった 1 例が
  この文書の M3.5 節に在る。**そこで踏んだ罠が 1 つある** ——
  `tools/opencv-config.psd1` の `Modules` に足しても、
  `cmake/FindOpenCvUnityDeps.cmake` の `COMPONENTS` に足さなければ
  **リンクされない。** 「OpenCV に入っている」と「このプラグインが
  リンクしている」は別で、`ocvu_get_build_information()` は前者しか報告しない。
  気づいたのは CMake を読み直してではなく、リンカが未解決シンボルを出したからである。
- **同時に動く場所**: `cmake/FindOpenCvUnityDeps.cmake` の `COMPONENTS` /
  `tools/opencv-config.psd1` の `Modules`（構成ハッシュが変わるので **OpenCV を
  ビルドし直す**）/ `THIRD_PARTY_NOTICES.md` / 成果物の大きさ /
  `tools/verify-opencv-artifact.ps1` の依存 allowlist。
- **ABI 関数の足し方そのものは `add-abi-function` skill が持つ。**
  M5 以降、**宣言は `bindings/spec/*.json` に 1 エントリ書いて `generate` する** ——
  新しい module なら `bindings/spec/<module>.json` を作り、
  `native/include/opencv_unity_native.h` の `#include` に 1 行足す
  （**その 1 行だけは生成物ではない**）。
- **API allowlist の正本は `docs/abi-ownership-and-versioning.md` §3 である。**
  関数を足したらそこにも足す —— **allowlist に無い関数を出荷している状態は、
  正本が正本でなくなっているということである。**
- **`COMPONENTS` に足すだけでは binary は 1 バイトも増えない**（静的リンクは
  参照された object しか引かない）。大きさが増えるのは関数を書いたときである。
| 3 | M3.5 で手書きした関数を spec の側へ寄せる | **満たす（実証済み）**。`imgcodecs` の 2 本を含めて**手書きの宣言は 1 本も残っていない** —— `Runtime/` の `[DllImport]` は**全部が `.g.cs` の中にある（手書きは 0 個）**。逆向きも見る —— `native/src/**/*.cpp` の `extern "C" ocvu_*` を全部拾って spec と突き合わせ、実測で「**取り出せた数と `extern "C"` の総数が一致、spec に無い実装 0 件**」。ダミーの `extern "C" ocvu_dummy_probe` を足すと**逆向き検査だけ**が名指しで落ち、ブロック形 `extern "C" { … }` で足すと**帰属の数が合わない**ことで落ちた（空振りしない） |
| 4 | API 対応表を生成し、「OpenCV 全対応」という曖昧な表現を使わない | **満たす（実証済み）**。`docs/api-map.md`。**本数を数えるのはこの表の冒頭だけ**にし、他所からは数字を落とした。`ApiMapEmitter` は**自分が出した Markdown を読み直して**「全行が見出しと同じ列数」「本体の行数が spec の entry 数と一致」を見る。逃がしを外すと実際に落ちる（`区切りが 6 個であるべきところ 7 個`）。**この構造の門は入口の禁止文字の列挙とは独立で、著者が思いつかなかった文字にも効く** |
| 5 | 生成された P/Invoke が IL2CPP stripping を生き延びることを L5 で確認 | **満たす（実証済み）**。`AbiReachabilityChecks.g.cs` が **spec の宣言を 1 本残らず 1 回ずつ**呼び（除外は `ocvu_debug_crash` の 1 本だけ。呼ぶと戻ってこない）、EditMode と PlayMode の両方が 1 件のテストとして通す。実物の IL2CPP Player で `==> [player] 19 passed`。`NativeMethods.Infra.g.cs` の `ocvu_get_status_value` に存在しない `EntryPoint` を仕込むと **34 件中 1 件だけ**が `System.EntryPointNotFoundException` で落ちた —— **この関数は M5 の前は Editor でも Player でも一度も呼ばれておらず、同じ壊し方をしても 33 件が全部緑だった** |

**残る穴（隠さずに書く）。**

- **出口の構造検査があるのは `docs/api-map.md` だけである。** C ヘッダは
  下流のコンパイラが受けるので手書きの門を足しても弱いだけだが、
  **C# の XML doc はどちらでもない** —— `GenerateDocumentationFile` を
  有効にすればコンパイラが引き継ぐが、**有効にしていない**
  （`Runtime/Core` に `CS1591` が大量に出るので別判断）。
- **`csType` の照合は「一意に決まる組」までしか閉じていない。** `cType` の側は
  C++ コンパイラが閉じる（生成したヘッダと実装が食い違えばビルドが落ちる）が、
  `csType` は **M5 の最終レビューまで誰も見ていなかった** —— `int64_t` に `int` と
  書いても C も C# も `verify-generated` も到達性テストも全部緑になり、
  **実行時の marshalling だけが壊れる**（壊れるのは呼んだ場所ではなく後から
  無関係な場所で、`docs/abi-ownership-and-versioning.md` §1 が借用 handle を
  禁じたのと同じ形である）。いまは `SpecModel.AllowedCsTypes` が
  `cType` ごとに書いてよい `csType` を持ち、**知らない `cType` は拒む**ので
  表は定義上いつも完全である。**閉じていないのは byte 列を渡す 4 つと `ocvu_keypoint*` の計 5 つ**
  （`const uint8_t*` / `uint8_t*` / `const char*` / `char*`）と、M5 の module 追加で
  足した `ocvu_keypoint*` である。これらは `byte[]` / `OcvuKeyPoint[]`（managed 配列を
  marshal する版）と `System.IntPtr`（アドレスを直接渡す版）のどちらも正しい ——
  **その 2 つのうち取り違えても誰も落ちない。** 一意に決められないので強制していない。

  **ただし 5 つは同じ危険度ではない。** byte 列の 4 つには `_ptr` 系という実在の
  利用者があって両方許す必然があった。`ocvu_keypoint*` のほうは **`System.IntPtr` を
  使う entry が spec にまだ 1 つも無い**（対称性のために許してある）。
  **それでも外していないのは、低確保の入口を足すときの受け皿だからである** ——
  `CvFeatures.DetectOrb` はいま呼ぶたびに配列を 2 本確保するので、`WebCamTexture` を
  毎フレーム走査する用途では `System.IntPtr` 版が要る。許す綴りを先に削ると、
  そのとき型表を触り直すことになる。

  **サイズの不一致（`int64_t` に `int`）とは危険度が違う。** wrapper がある宣言なら
  C# のコンパイラが型で落とすので、素通りするのは wrapper の無い宣言に限られる
  —— **そして到達性テストの `default` は配列でも `IntPtr` でも通る**ので、
  そこでも誰も落とさない。
- **`reachableNote` には `pattern` が無く、素通しである。** 値が届くのは
  `docs/api-map.md` の箇条書き 1 箇所だけで、**表の外なので上の構造検査に
  掛からない**（C ヘッダにも C# にも届かない）。壊れても表は妥当なままである。
- **入口の禁止文字（`\r` `\n` `<` `>` `&` `*/`）は「思いついた範囲」のままである。**
  表については出口の構造検査が独立に効くようになったが、**列挙そのものは
  網羅ではない。**
- **`docs/api-reference.md` は手書きのままで、対応表と同期する仕組みは無い。**
  正しい本数が `api-map.md` に出るようになったので**数の食い違いは起きにくく
  なった**が、**説明が古くなることは防げない。** 関数を足したら手で直す。
- **`bindings/generated-checks/` は作っていない**（`docs/unity-opencv-integration-research-and-plan.md`
  §10 の想定にある）。一致検査は既存のレーン（L3 の solution と `tools/tests/`）に
  載せた —— **新しいディレクトリを作ると「どこからも走らない検査」を作りやすい**ためである。
- ~~**この判定はローカルの実測だけで、CI の run はまだ 1 度も無い。**~~
  **閉じた（2026-09-01、PR #55）。** 判定を書いた時点ではこれが穴だった ——
  「`ci-native` が走らせる」は**構造の事実**であって観測ではなく、
  **「ファイルが存在する」は「CI で実行された」ではない**（`nightly` の cron を
  判定したときと同じ基準）。PR #55 が**必須 21 本すべてを緑にし**、
  観測に変わった: **`==> [EditMode] 34 passed` / `==> [Standalone] 19 passed`**
  （**ローカルの実測と一致**。Standalone は stripping 済みの実物の IL2CPP Player で、
  **生成した 21 本の P/Invoke が全部解決した**）。`verify-generated` を含む
  `dev.ps1 test` は 3 platform とも通った（Windows 4m31s / macOS 2m15s /
  Linux 2m58s、run 33429400415）。**充足は成功件数ではなく名前で突き合わせた**
  —— GitHub は `skipped` と `neutral` も pass として通すので、
  数で見ると常に skip される job が数に入る（`milestone-complete` skill）。

**この計画の後に残るもの**（完了条件 2 のほかに 2 つ）。

- **M7 の決定 1 のうち、C# を別 assembly に割ること（決定 1 の 2）と
  OpenCV の版を跨げるようにすること（同 3）。** M5 が割ったのは **C ABI の
  ヘッダだけ**で、`Runtime/Interop` は 1 つの assembly のままである。
- **実装（`.cpp`）は生成しない。** spec は境界の**形**を持つが、中で何をするかは
  持たない。生成する価値が出るのは「`Mat` を 2 つ取って 1 つ返す」ような
  **型どおりの薄い関数が増えたとき**で、いま在る関数はどれも引数の検証や
  2 回呼びの作法を持っており、**生成しても薄くならない。**

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

### M4 / M5 の後に着手するとき、何が変わっているか（2026-09-03 に追記）

**この節は M0 の頃に書いた。着手する前に、その後で足場が変わったことを知っておくこと。**

- **platform を足す作業は 17 箇所に触る。** 一覧を持つ場所は語彙が違うので grep 1 回では
  揃わない。`add-a-platform` skill に、M4 で**クロスビルドが緑になってから CI で 8 回落ちた**
  罠が踏んだ順に並べてある。**Web は 6 つ目の platform になる。**
- **境界の宣言はもう手で書かない。** `bindings/spec/*.json` が正本で、C ヘッダ・C# の
  P/Invoke・到達性テスト・API 対応表が同時に生成される（M5）。**Web でも同じ経路を通る** ——
  `DllImport` の形が platform で変わるなら、生成器の側で扱うことになる。
- **依存 allowlist が新しい依存を捕まえる。** `calib` を足したとき、推移的に引かれた
  `stereo` で 4 platform とも最初のビルドが落ちた（2026-09-02）。**Emscripten でも
  同じ検査が働く** —— 落ちたら、引き込まれたものを確かめてから明示的に足す。
- **`OCVU_ABI_VERSION` は 1 のままである。** M5 は移設であって追加ではなく、
  module を足しても版は動いていない。

**そして、着手する前に配ること。** M4 と M5 の成果はまだ利用者に届いていない
（「配布 その 5」）。**Web を足しても、届かなければ差別化にならない。**

---

## M7 — Optional profiles と性能

**目的**
「小さな標準 build + opt-in profile」（計画書 §7）を、方針から**実際の配布形態**にする。

**ゴール**
DNN / contrib / 動画 codec / videoio が opt-in profile として追加でき、低コピー経路が評価済みになる。

**ここにある DNN は、差別化として最も大きくなりうる項目である**（穴 #10）。
根拠と、それでも前倒ししない理由は
[競合調査](./unity-opencv-integration-research-and-plan.md) §3 / §4.6 にある
（要約すると、競合はすべて書き直し前のエンジンを載せている一方、Unity 利用者に
とっては推論エンジンが OpenCV だけではない）。**前倒しの判断は利用例が集まってから
行う。**

**低コピー経路の実測もここが担当である**（穴 #9）。掲げている主張を支える実測が
まだ無い、という穴である。

**`imgcodecs` はここに含まれない。** **OpenCV 側の**標準ビルドに既に入っており
（`Modules`）、bundle される zlib / libpng / libjpeg-turbo の notice も揃っているので、
opt-in profile として足すものではない。**M3.5 で完了した** ——
`cmake/FindOpenCvUnityDeps.cmake` に component を足してリンクし
（**「残っているのは C ABI に出すことだけ」と書いていたが、リンクも残っていた**。
M3.5 節を参照）、`ocvu_imencode` / `ocvu_imdecode` を出した。ここで扱う「codec」は
動画のそれ（FFmpeg / GStreamer を引き込む videoio 系）を指す。

### 上流が動いている: OpenCV 5.1 の DNN / GPU（2026-08-30 に調査）

**確認済み事実**（一次情報をこちらで当たった。2026-08-30）

| 事実 | 出典 |
| --- | --- |
| **公式のポリシー: 5.x は API 互換を保つが、ABI 互換は保たない**（`Preserve API compatibility ✔️ / Preserve ABI compatibility ✖️`、本文にも `API compatibility must be preserved`） | [opencv wiki Branches](https://github.com/opencv/opencv/wiki/Branches) |
| **5.0 の新 DNN エンジンは CPU 専用**: *"The new engine currently runs on CPU only. GPU support will be added in subsequent releases. In the meantime, users who need GPU acceleration can either force the classic engine or build OpenCV with ORT and NVIDIA execution providers."* | [opencv wiki OpenCV-5](https://github.com/opencv/opencv/wiki/OpenCV-5) |
| **その classic エンジンが 5.x から削除された。** PR #29341 "Remove ENGINE CLASSIC, switching to ENGINE NEW as default engine"、merged `2026-07-29T07:30:29Z`、base `5.x`、milestone **5.1**、**61 ファイル / +307 −4698** | GitHub API `pulls/29341` |
| **`enum EngineType` の値が総入れ替えになった**（下表） | `modules/dnn/include/opencv2/dnn/dnn.hpp` を `5.0.0` と `5.x` で読み比べ |
| PR #29658 "Adding CUDNNJIT Support in OpenCV" が **`5.x` へ merge**（`2026-08-27T06:31:21Z`）、milestone **5.1**。**差分は 9 ファイル・+136 −8 で、ほぼ build system** —— `FindCUDNNJIT.cmake`（新規 71 行）、CUDA 検出 2 ファイル（+42）、`OpenCVMinDepVersions.cmake` 1 行（**`set(MIN_VER_CUDNNJIT 9.0)`** —— cuDNN 9.0 以上が要る）/ `cvconfig.h.in` 1 行、`modules/dnn/CMakeLists.txt`（+7 −7）、hook 1 行、`cuda4dnn/csl/cudnn/cudnn.hpp` **5 行**（唯一の C++ で、`HAVE_CUDNNJIT` のときに別ヘッダを include する条件分岐）。**推論のコードは含まれない** | GitHub API `pulls/29658` と同 `files` |
| PR #29451 "Extending CUDA support in UMat"、merged `2026-07-29T05:49:36Z`、3 ファイル・+429 −0 | GitHub API `pulls/29451` |
| Technical Committee 議事録（**2026-08-12 の回**）: *"PR #29658: CUDNN JIT: 9.3x speedup on Resnet 50 (RTX 6000 vs Intel Xeon)."* | [opencv wiki 2026](https://github.com/opencv/opencv/wiki/2026) |
| 同（**2026-07-29 の回**）: *"DNN engine classic removal is DONE and merged finally"* / *"ONNX coverage is 72.9% now"* | 同 wiki |
| **同型の 2 例目**: 5.0 は *"TFLite is still supported via the classic engine"* と案内しているが、その classic は削除された。5.x の `tflite_importer.cpp` は `ENGINE_AUTO` / `ENGINE_OPENCV` だけを受け、それ以外は warning を出す | [opencv wiki OpenCV-5](https://github.com/opencv/opencv/wiki/OpenCV-5) と `modules/dnn/src/tflite/tflite_importer.cpp@5.x` |
| 5.1 の milestone は **open、期日なし**（open / closed の内訳は変動するので記録しない） | GitHub API `milestones` |

**`enum EngineType` は値が付け替わっている**（`int` として C ABI を越える値なので、
**コンパイルは通り、意味だけが黙って変わる**）。

| | 5.0.0 | 現在の 5.x |
| --- | --- | --- |
| `ENGINE_AUTO` | **3** | **0** |
| `ENGINE_CLASSIC` | 1 | **削除** |
| `ENGINE_NEW` | 2 | **`ENGINE_OPENCV` に改名、値 1** |
| `ENGINE_ORT` | **4** | **2** |

これは `docs/abi-ownership-and-versioning.md` §2 が「bump する変更」に挙げている
**「既存 status code の数値または意味が変わる」と同じ形**である。

**同じ数字を `OPENCV_FORCE_DNN_ENGINE` という環境変数も使っている**（`OpenCV-5` が
`1` classic / `2` new / `3` auto / `4` ORT と案内している）。**こちらは再ビルドすら
要らない** —— 5.0 の手順書どおりに設定した利用者の環境で、5.1 は別のエンジンを引く。
5.x の `resolveOnnxEngine`（`modules/dnn/src/onnx/onnx_importer.cpp`）を読んで機械的に導いた:

| 5.0 で渡していた値 | 5.0 の意味 | 5.x での帰結 |
| --- | --- | --- |
| `1` | classic エンジン | **`ENGINE_OPENCV`**（classic は無いので、別物が動く） |
| `2` | 新エンジン | **`ENGINE_ORT`** —— **ONNX Runtime に切り替わる。最も危険** |
| `3` | auto | どの分岐にも当たらず無視され、既定の `ENGINE_OPENCV` に落ちる（**結果は同じ**） |
| `4` | ORT | 強制の条件（`1` か `2`）に当たらず**黙って無視される** —— ORT を頼んだのに組み込みエンジンが動く |

**`3` だけは壊れない。** 引数として `3` を渡した場合も warning 1 行で `ENGINE_OPENCV` に
落ちるだけである。**黙って変わるのは `1` / `2` / `4` のほうである。**

**判断に効いているのは 9.3 倍ではなく、この 3 つである。**

1. **公式が案内する 2 本の GPU 経路のうち、1 本が消えた。** 5.0 の案内は
   *"either **force the classic engine** or **build OpenCV with ORT and NVIDIA execution providers**"*
   の 2 本で、**前者の classic エンジンが 5.x から削除された**（#29341）。
   **後者は残っている**（`ENGINE_ORT` は 5.x の `dnn.hpp` に健在、`OpenCV-5` は
   `-DWITH_ONNXRUNTIME=ON -DDOWNLOAD_ONNXRUNTIME_GPU=ON` を案内している）。
   **残ったほうは決定 5 に直結する** —— ONNX Runtime GPU という別の再頒布物を引き込むからである。
2. **`OPENCV_FORCE_DNN_ENGINE` の値が、再ビルドすら要らないまま意味を変える。**
   `int` の列挙値だけでなく、**利用者が手元で設定する環境変数**が同じ数字を使っている（下表）。
   5.0 の手順書どおりに設定した利用者が、5.1 では別のエンジンを引く。
3. **公開列挙子が削除・改名された。** `ENGINE_CLASSIC` と `ENGINE_NEW` は 5.x の
   `dnn.hpp` に存在せず、互換 alias も無い（実測）。**`Branches` wiki は「5.x は API 互換を
   保つ」と明文で書いているが、#29341 はその明文を破っている** —— つまり
   **壊れるのはバイナリだけでなくソースもである。** 明文のポリシーを実測より強い保証として
   読んではいけない、という実例でもある。

**ABI 非互換の明言そのものは、この判断には効かない。** このプラグインは OpenCV を静的リンクして
`ocvu_` の C ABI だけを外に出すので、**上流の ABI はこの境界を越えない。** 5.0 → 5.1 で再リンクが
要るのは、tag ごとに毎回やっていることである。**効くのは版を跨ぐ話のほう**（決定 3）で、
そちらでは「構成ハッシュに tag を混ぜてある理由」として正しく効く。

**壊れるものと壊れないものは分けられる。** 壊れるのは **engine / backend の選択**（列挙子、
環境変数、GPU 経路）で、**壊れないのは推論の入口**（`readNetFromONNX` / `Net::forward` /
`blobFromImage` は 5.x にも同じ名前で在る）。

**9.3 倍が言っていないこと。** ここを取り違えると判断を誤る。

**まず、同じ議事録に留保がある。** 2026-08-19 の回で opencv.ai のメンテナが
*"experimenting with CUDNN JIT, have some troubles with building it"* と書いている
（生の `2026.md:130` で確認。**この行を最初は落としていた**）。

**そして、この数字を出した実装がどこにあるのかは追えていない。** 議事録は #29658 と
**#29656 "Added Backend Agnostic fusion in DNN"**（milestone 5.1、+1681 −47、**`open`**）を
並べて 3 回報告しているが、**#29656 は cuDNN JIT とは別の作業である** —— 17 ファイルの
どれも `cuda` / `cudnn` に触れておらず、PR 本文自身が *"only the third CPU-specific"* /
*"CPU implementations behind it"* と書いている。**並んでいるのは同じ寄稿者の作業項目だから**で
あって、一方が他方の本体だからではない。**「本体はこれだ」と結び付けない。**

- **GPU と CPU の比較である。** 「cuDNN JIT が既存の CUDA backend より 9.3 倍速い」ではない。
  **こちらが得られる差分の大きさは、この数字からは読めない。**
- 方法論が無い（batch size、精度、Xeon の型番、OpenCV の版、比較した backend）。**議事録の 1 行**である
- **merge されたのは検出と接続だけ**なので、この数字を出した実装がどこにあるのかは追えていない。
  「support が入った」は「実行経路が入った」ではない —— **`imgcodecs` で踏んだ「ビルドに入っている」と
  「リンクしている」の取り違えと同じ形**である（M3.5 節）

### 決定: native bridge を module 単位に分ける

**上の事実は「dnn 周辺はいま動いている最中である」ことを裏づける** —— 旧エンジンは
既に削除され、CUDA / UMat の統合は進行中で、期日も安定性の約束も無い。したがって
**5.0 に固定した DNN ラッパーを作り込まない。** 次を決める。

1. **C ABI を module ごとに分ける。** `core` / `imgproc` / `imgcodecs` は**安定 ABI として先行**し、
   `dnn` は別ヘッダ・別 `.cpp`・別 CMake target に置く。共通の型・status・version だけを
   `opencv_unity_native.h` に残す。**いま 20 本が 1 ヘッダにあるのを、足す前に割る**（この「20 本」は決定を書いた 2026-08-30 時点の値である）。
   → **M5 で済んだ（2026-09-01）。** 関数宣言は
   `native/include/ocvu/{infra,core,imgproc,imgcodecs,objdetect,features}.h` に分かれ、
   `opencv_unity_native.h` に残ったのは型・status・定数だけである。**ただし分けたのは
   ヘッダであって CMake target ではない** —— まだ 1 つの target が全 module を作る。
   `OCVU_ABI_VERSION` を単一の整数のままにする判断とその留保は
   [所有権と versioning](./abi-ownership-and-versioning.md) §2 に書いた（**正本はあちら**）。
2. **C# 側も別 assembly にする。** `Runtime/Core` / `Runtime/Interop` の分離
   （`UnityEngine` を参照しない）と同じ理由で、**dnn が入らないビルドで参照が壊れない**形にする。
   → **M5 では手を付けていない。** `Runtime/Interop` は 1 つの assembly のままで、
   生成された `NativeMethods.<module>.g.cs` は `partial class` で同じ型に入る。
3. **OpenCV の版を跨げるようにする。** 構成ハッシュには tag が入るので、tag を変えれば
   古い artifact は使われなくなる（tag は M1 から入っている。M3 Task 1 が足したのは
   `Platform` である）。**しかしこれは「2 つの版が同時に成立する」
   ではない** —— 現状は**同時に 1 つだけ**である。並走させるには次が要る:

   - `tools/opencv-config.psd1` の `Tag` は**単数**で、`Get-OpenCvConfig` は版の軸を持たない
   - `.github/workflows/build-opencv.yml` の job 名が `OpenCV 5.0.0 …` の直書き（matrix は platform だけ）
   - **版文字列を直に assert している 5 箇所**を書き換える必要がある ——
     `native/tests/test_opencv_link.cpp`、`tests/Managed/CvUnity.Tests.Managed/OpenCvInfoTests.cs`、
     `tests/UnityProject/Assets/Tests/EditMode/VerticalSliceTests.cs`、
     `tests/UnityProject/Assets/Tests/PlayMode/PlayerSmokeTests.cs`、
     `tools/tests/OpenCvConfig.Tests.ps1`

   **つまり「確認」ではなく、config に軸を 1 本増やす設計作業である。**
4. **`dnn` を allowlist に足すのは、上の 1〜3 が済んでから。** 現在の `Modules` は
   `core / imgproc / imgcodecs / objdetect / features / calib` で **dnn は入っていない**。足すと OpenCV 側の
   ビルド時間と成果物サイズが変わる。**あわせて `THIRD_PARTY_NOTICES.md` の作業が要る** ——
   同文書が明文で指示している: *"If a future `Modules` list adds `dnn` or `gapi`, re-run these
   searches — they will very likely start matching, and these two need to move up into the
   reproduced sections above."* dlpack と flatbuffers はいま「ライセンスディレクトリにあるが
   リンクされていない」側に分類されており、**`dnn` を足すとその分類が崩れる**（protobuf も入る）。
5. **CUDA / cuDNN を同梱するなら、2 つの前提条件を先に潰す。** どちらも技術判断ではない。

   - **再配布の可否（未確認）。** 「本体が Apache-2.0」と「binary 内の全依存が Apache-2.0」は
     別問題である（計画書 §8.2。ただし同節が扱うのは FFmpeg / JPEG / PNG 等で、**CUDA / cuDNN には
     触れていない**）。cuDNN は NVIDIA のライセンス条項の下にあるが、**その条項を読んでいない。**
     ここは「確かめていない」であって「配れない」ではない
   - **大きさ（ライセンスより先に効く）。** **実測（2026-08-30、PyPI の
     `nvidia-cudnn-cu12` 9.25.1.1）: 1 platform あたり 698〜772 MB**（win_amd64 698.4 /
     manylinux x86_64 716.4 / aarch64 772.1）。`tools/pack-upm-tarball.ps1` の上限は
     **512 MB** で、現在の全部入りは 9.6 MB である。**1 platform 分だけで既に上限を超える** ——
     ライセンスが解決しても、いまの形では配れない。同梱するのか、利用者側での導入を
     前提にするのかを決める必要がある。**ORT + NVIDIA execution provider の経路
     （根拠 1 で残ったほう）も同じ問いに突き当たる。**

   確かめるまで、CUDA backend を完了条件に入れない。

**まだ決めていないこと**（M5 / M7 で決める）

- **`OCVU_ABI_VERSION` は単一の整数のまま**である（正本は
  `docs/abi-ownership-and-versioning.md` §2 の「決定」。ここで再オープンしない）。
  module 分離がこの決定に影響しうるなら、**正本のほうに留保を書く**
- dnn を**別 package**（`…-dnn`）で配るか、同じ package の optional profile にするか。
  **全部入り tarball を配る正にしたのは M3.5 の決着**なので、dnn を足すことは
  **「中身を足す」ではなく「形を変える」**ことになりうる
- GPU backend を持つ版の platform matrix（CUDA の版 × OS）。現在の 3 platform × 1 構成が何倍になるか

**差別化としての位置づけは変えない。** 競合が書き直し前のエンジンを載せている点は
[競合調査](./unity-opencv-integration-research-and-plan.md) §3 / §4.6 のとおりで、
**Unity 利用者には推論エンジンの代替がある**という理由も変わらない。**変わったのは
「5.0 で作り込むと 5.1 で作り直しになる」という具体的な根拠が付いたこと**である。

**完了条件**

- profile ごとの native artifact、manifest、third-party notices
- RenderTexture / native texture pointer / AsyncGPUReadback を使う低コピー経路の評価
- package size、startup time、frame time、allocation の benchmark を公開
- **`dnn` を足す前に、C ABI と C# の module 分離が済んでいること**（上の 1〜2）
- **CUDA / cuDNN を同梱するなら、再配布条件の確認が済んでいること**（上の 5）。
  確認できないなら**同梱しない**と決めて記録する

---

## 担当が無かった制約（2026-08-29 に全件割り当て、うち 1 件は M3.5 で解消）

**M0〜M3 を完了し v0.1.1 を配ったあとで「できないこと」を数え直したときに見つかった
3 件。** どれも留保として本文には書かれていたが、**解消する担当がどこにも無かった。**
留保は「誰かがいずれ拾う」と読まれるので、拾う予定が無いなら無いと書く —— という
理由でこの節を作った。

**同じ日のうちに 3 件とも担当が付いた**（下記）。**節は残す。** 担当が付いたことより、
**「本文に書いてあるのに誰の担当でもない」状態が実際に起きたこと**のほうが、次に
同じことを防ぐうえで役に立つ記録だからである。

### 画像の encode / decode（当初は「画像ファイルの読み書き」と書いた）→ M3.5 で解消

**「呼ぶ関数が無く、誰の担当でもない」状態だった。** なお当初ここには「バイナリには
入っているが」と書いていたが、**それは誤りである** —— `imgcodecs` が入っていたのは
OpenCV 側のビルドツリーで、こちらのプラグインは `core imgproc` しかリンクして
いなかった（M3.5 で実装に着手し、リンカの未解決シンボルとして判明した。M3.5 節を参照）。
`imgcodecs` は **OpenCV 側の**標準ビルドに入っていて notice も揃っているのに、
M5 の完了条件は
`geometry` / `calib` / `features` / `objdetect` を名指しして `imgcodecs` を挙げず、
M7 の「codec」は**まだ入っていないものを profile として足す**話だった。両方の枠の
外に落ちていた。

いったん M5 の完了条件に加え、同じ日の再調査（上記「差別化の穴」#2）で **M3.5 へ
前倒しした。** 生成の仕組みを待つ理由が無く、比較した競合はすべて持っている機能で
あるためである。**M3.5 で実装した**（`ocvu_imencode` / `ocvu_imdecode`、C# は
`CvCodecs`。L1 8 ケース / L3 8 ケース）。

**あわせて、この節に書いていた評価を 1 つ訂正する。** ここには「実用上いちばん
大きい欠落であり、このパッケージ単体では何も入出力できない」と書いていたが、
**Unity の利用者にとっては言い過ぎだった。** Unity 自身が PNG / JPEG の読み書きを
持つので、`ファイル → Texture2D → CvMat` の経路は**今日すでに成立する**。
効いてくるのは、メインスレッド以外で読みたいときと、Unity が扱わない形式のときである
（**M3.5 が足したのはメモリ上の byte 列を相手にする経路**で、ABI はファイルパスを
受け取らない。ファイルを開くのは引き続き呼ぶ側の仕事である）。
**「無いと何もできない」ではなく「あると楽になる」** —— 前倒しの判断自体は
変えないが、理由を実態に合わせる。

### Windows の IL2CPP Player を CI で回す → M4 で結論を出す

M2 の完了条件 6 は「Unity EditMode と **Windows** IL2CPP Player で同じ smoke test が
通る」で、**ローカル実測で満たした**。条件 7（CI で L4 / L5 を実行する）は game-ci を
使って **Linux** で満たした。したがって **Windows の IL2CPP Player は、今もローカルの
`dev.ps1 test-unity-player` だけが担っている。**

**2026-08-29 に調べ直したところ、「無理だ」と書いていた根拠が、そもそも
このリポジトリの構成についての根拠ではなかった。**

理由として挙げていたのは
[game-ci/unity-builder#542](https://github.com/game-ci/unity-builder/issues/542) と
[game-ci/docker#213](https://github.com/game-ci/docker/issues/213) の 2 件で、
**どちらも 2023-11-15 に解決済みとして閉じている**（#542 は
"V4 is now released and uses windows-2022"、#213 は Server 2022 のイメージが
v3 で出たこと）。**しかしこのリポジトリは `unity-builder` を使っていない。**
`ci-unity.yml` が使うのは `game-ci/unity-test-runner` で、**別リポジトリの別 action、
版番号も独立している**（#542 の "V4" は unity-builder の v4、#213 の "v3" は docker
イメージの v3、こちらの `@v4` は test-runner の v4 —— **3 つの別物が同じ数字で
並んでいるだけである**）。

**2 件が外れる理由は、それぞれ別である。**

- **#542 は使っていない action の話。** `unity-builder` はこのリポジトリに
  1 度も出てこない
- **#213 は使っているイメージの話だが、使っていない系統について**である。
  `game-ci/docker` は action ではなく `unityci/*` イメージを作るリポジトリで、
  `ci-unity.yml` はそこの `unityci/editor:ubuntu-…-3` を使っている（末尾の `-3` が、
  #213 の閉じコメント "Images are now Server 2022 in v3" の言う v3 である）。
  **つまり無関係ではない。** ただし #213 が扱うのは Windows イメージの系統で、
  こちらが固定しているのは `ubuntu-` 版なので、こちらの構成については何も言わない

**どちらも「Windows でこの構成が動くか」の根拠にはならない。** この理由づけが
main に入ったのは 2026-08-29 11:23（`8c68fff`）で、崩れたのは同じ日の 17:14 である ——
**古くなったのではなく、書いた時点で既に別物の話だった。**

**では現状はどうか。使っている action 自身の文書には Windows について現在形の
記述がある**（[Test Runner の Caveats](https://game.ci/docs/github/test-runner)）:
"The test runner can only test packages on Linux runners - Windows runners are
currently not supported"。**ただしこれは package を対象にしたテストの話**で、
`ci-unity.yml` は `projectPath` を渡す project のテストなので、そのまま当てはまるとは
限らない。加えて
[GameCI の Windows イメージ文書](https://game.ci/docs/docker/windows-docker-images/)は
別の障害を挙げる: **IL2CPP のビルドに要る Visual Studio Build Tools は Microsoft の
制約でイメージに同梱できない**（ホストから注入するか独自イメージが要る）。Windows では
ビルドのたびにライセンスの取得と返却も要る。実務上は `ci-unity.yml` が `customImage`
に `unityci/editor:ubuntu-…` を直書きしているので、そこも書き換えになる。

**要するに、動く根拠も動かない根拠も、こちらでは持っていない。**

**M4 での担当は「決める」ではなく「試す」である。** まず `windows-2022` 上で
`game-ci/unity-test-runner@v4` に素直に投げ、何が起きるかを見る（`customImage` の
`ubuntu-` 直書きを外すところから）。落ちたらその出力を根拠として記録する ——
**他人の issue を読んだ結果ではなく、こちらで走らせた結果を根拠にする。**
そのうえで、独自イメージを作るか、self-hosted runner を立てるか、諦めるかを決める。

**2026-08-31 に投げた（第 1 回、run 33350726005）。動いた。**

```
==> Unity 6000.3.16f1 on windows-2022
==> [Windows] 33 passed
```

`game-ci/unity-test-runner@v4` は `windows-2022` で **EditMode を 33 件通した**。
`customImage` を渡さないだけでよく、独自イメージも self-hosted runner も要らなかった。
**「動く根拠も動かない根拠も持っていない」状態は、これで終わった。**

**ただしこれで条件が閉じたわけではない。** 第 1 回は EditMode で、
**条件が問うているのは IL2CPP Player（Standalone）の方である。**
EditMode が通ったことは IL2CPP が通る根拠にならない —— IL2CPP は別の
モジュールを要求する。ここを推測で埋めると、この節が禁じている
「他人の issue を読んだ結果を根拠にする」と同じ誤りになる。

**2026-08-31、第 2 回（run 33352025223）で `Standalone` を投げた。落ちた。**

```
error: Could not set up a toolchain for Architecture x64. Make sure you have
the right build tools installed for il2cpp builds.
IL2CPP C++ code builder is unable to build C++ code. In order to build C++ code
for Windows Desktop, you must have one of these installed: ...
Player build failed
TestLaunchFailedException: Player build failed
```

**game-ci の Windows コンテナには Unity の IL2CPP モジュールは在るが、それが
生成した C++ をコンパイルする MSVC のツールチェーンが無い。** `windows-2022` の
runner 自身には Visual Studio が入っているが、**Unity はコンテナの中で動いており、
ホストの toolchain は見えない。**

**注意すべき点が 1 つある。** この失敗のとき、**game-ci 自身は success を返した。**
落ちたことが分かったのは、結果 XML の有無を別に見ていたからである
（`==> game-ci の結果: success` の直後に `==> 結果 XML が無い`）。
**game-ci の成否をそのまま合否にしていたら、「Windows IL2CPP は CI で通る」と
誤って結論していた。**

### 結論: **諦める**（2026-08-31）

Windows の IL2CPP Player は **CI で回さない**。根拠は上の 2 回の実測である ——
他人の issue ではない。

- **EditMode は動く**（第 1 回、33 passed）。だが条件が問うているのは IL2CPP である
- **IL2CPP は toolchain が無くて落ちる**（第 2 回）。直すには MSVC を入れた独自の
  Windows イメージを作るか、コンテナを使わずに runner へ Unity を直接入れることに
  なる。**後者は macOS 側で試して 64 分かけても Editor が入り切らなかった**
  （run 33352025223、`mac-il2cpp` 込み）ので、Windows でも同種の費用が予想される
- **失うものが小さい。** Windows の IL2CPP Player は `dev.ps1 test-unity-player` が
  ローカルで担い続ける（実測 18 passed）。CI では **Linux の IL2CPP Player** が
  同じ smoke test を通しており、**stripping が P/Invoke を消さないこと自体は
  CI で実証されている**。Windows 固有の IL2CPP の欠陥だけが CI の外に残る

**この結論は覆せる。** 独自イメージを作る費用に見合う理由（Windows 固有の IL2CPP の
欠陥を実際に踏む、など）が出たら、そのときに作り直す。**そのときも根拠は実測にする。**

### macOS の Plugin Import Settings を Unity で実測する → M4

`.meta` の形式は Unity 自身が生成した Windows 分に合わせてあり、**Linux 分は M2 の
条件 7 で実測に変わった**（`ci-unity.yml` が Linux の Unity を動かし、`.so` とその
`.meta` が実際に読み込まれて EditMode / IL2CPP Player の両方で通った）。
**macOS 上で Unity を動かしたことは一度も無い** —— CI の macOS job は plugin を
ビルドするが Unity を起動しない。

**ただし M3.5 で状況が 2 つ動いた。** (1) macOS の `.meta` は、実物の dylib と
同居した package を Unity（Windows）に読ませて `PluginImporter` に解釈を問うた
ので、**書式が Unity に理解されることは確かめた**。(2) その一方で、macOS の
binary と `.meta` は**全利用者が導入する全部入りの package に入る**ように
なったので、**外したときの影響が大きくなった**。残っているのは
「macOS 上で動く Unity がそれをどう扱うか」である。

**M4 で自然に埋まる。** iOS のビルドには macOS runner が要るので、そこで初めて
macOS 上で Unity を動かすことになる。**「ついでに埋まる」に任せず M4 の完了条件に
書いた**のは、まさにこの節が生まれた理由がそれだからである。

**M3.5 でこの穴の重みが上がった。** 全部入りの tarball が配る正になったので、
**利用者が受け取る 1 つの package の中に、Unity に一度も読ませたことのない macOS の
binary と `.meta` が同居する。** Windows と Linux の利用者もそれを一緒に導入する。
M3.5 が足した `PluginGatingTests` は Windows と Linux でしか走らないので、
そこも埋まらない —— **緩んだのではなく、締まった。**

**2026-08-31 に試した（第 1 回、run 33350726005）。道具が対応していなかった。**

```
##[error]Currently darwin-platform is not supported
```

`game-ci/unity-test-runner@v4` は **macOS runner を支えていない**。
**設定では回避できない** —— action の対応範囲の問題である。同じ run の
Windows 側は動いたので、こちらの設定不備ではないことも同時に分かった。

**game-ci を経由しない経路も試した。3 回投げて、いずれも閉じなかった。**

| 回 | run | 結果 |
| --- | --- | --- |
| 第 2 回 | 33352025223 | 64 分で打ち切り |
| 第 3 回 | 33356182306 | 25 分の上限で打ち切り |
| 第 4 回 | 33358384921 | **Editor は 14 分で入った。** ライセンスで失敗 |
| 第 5 回 | 33361012965 | 同上（認証方法を変えても同じ） |

**64 分の待ちの正体は、ダウンロードではなく対話プロンプトだった。**

```
[hub] ? Please select preferred architecture:
[hub] ❯ Apple silicon / Intel
```

`--headless` を渡しても Unity Hub は architecture を聞いてくる。**最初の 1 分で
止まっており、残りは何もしていなかった。** `--architecture arm64` を渡し、
stdin を閉じたら **14 分で入った**（第 4 回）。

**そこから先はライセンスの壁だった。** 認証の 2 系統を両方試して、どちらも同じ:

```
[Licensing::Client] Error: Code 404 ... Found 0 entitlement groups and
                           0 free entitlements matching requested entitlement
[Licensing::Module] Error: 'com.unity.editor.headless' was not found.
```

- `-username` / `-password` による認証（第 4 回）
- `UNITY_LICENSE` の `.ulf` を `/Library/Unity/Unity_lic.ulf` に置く（第 5 回）

`.ulf` は **Linux のレーンが実際に使っているもの**である。それを macOS に置いても
entitlement が 0 件になる —— **ライセンスは環境に紐づいており、Linux で通る鍵が
macOS で通るわけではない。**

### 判定: **閉じない**（2026-08-31）

**条件 7 と違い、この条件は結論を書いても閉じない。** 文言が「macOS の Plugin
Import Settings を Unity で**実測する**」だからである。**実測していない以上、
満たしていない。** 部分的な達成を完了と呼ばない。

**分かったことは記録する。**

- **Editor の導入は障害ではない**（14 分。`--architecture` を渡せばよい）
- **障害はライセンスである。** この Unity アカウントの entitlement が
  macOS runner の headless 認証で 0 件になる。**認証方法の問題ではなく
  （2 系統とも同じ）、entitlement そのものが降りていない**
- したがって次に試す価値があるのは **別のライセンス種別**（Pro seat など）か、
  **手元の macOS で 1 回走らせて記録すること**である。後者なら CI は要らない

**探査の workflow（`.github/workflows/unity-probe.yml`）は残す。** ここまでの
5 回分の壁が step のコメントに書いてあるので、**次に同じ疑問を持った人が
ゼロから調べ直さずに済む。** `workflow_dispatch` のみなので費用は掛からない。

### 恒久レーンにはしない（2026-08-31 の決定）

**Windows も macOS も、Unity のレーンを CI に常設しない。** 実測で比べた:

| レーン | 実測 | 判断 |
| --- | --- | --- |
| Linux Unity（既存・必須） | EditMode / Standalone で 3〜7 分 | **維持** |
| Windows EditMode | 動く（33 passed） | **足さない** —— IL2CPP が動かない以上、Linux と重複するだけ |
| Windows Standalone | **動かない**（MSVC 不在） | 足せない |
| macOS EditMode | **動かない**（entitlement 0 件） | 足せない |

**Windows の EditMode は「動くが足さない」という珍しい判断である。** 足しても
Linux の EditMode と同じものを 2 回見るだけで、**Windows 固有の欠陥を捕まえるのは
IL2CPP の方**だからである。そちらが動かないのだから、EditMode だけ足しても
**「見ているが、見たいものは見ていない」レーンが 1 本増える。**

---

## マイルストーン間の依存

```text
M0 ハーネス ──> M1 OpenCV ビルド ──> M2 Windows slice ──> M3 Desktop 配布
（完了）          （完了）             （完了）              （完了 / v0.1.1）
                                                              |
                                                              v
                                                     M3.5 配布の形と最小の穴
                        （全部入り package / OpenUPM / 画像入出力 / Unity 6.3 LTS）
                          （6 件すべて達成 / v0.2.0 / OpenUPM）
                                                              |
                                                              v
                                                          M4 Mobile
                                            （9 件中 5 件 / 未公開 v0.3.0 の下書き）
                                                              |
                                                              v
                                                        M5 generator
                （5 件すべて達成。objdetect / features / geometry / calib）
                                                              |
                                                              v
                                                    配布 その 5 — v0.4.0
                （M4 と M5 の成果を初めて利用者に届ける。未着手）
                                                              |
                                                              v
                                                   M6 Web ──> M7 profiles
```

**配布はマイルストーンではないが、マイルストーンの間に必ず挟まる。** M3 が v0.1.0 /
v0.1.1、M3.5 が v0.2.0 を出した。**M4 と M5 の成果はまだ配っていない** ——
v0.3.0 の下書きは M5 が main に入る前のもので、**そのままでは公開できない**
（「配布 その 4」を参照）。**この段が計画のどこにも書かれていなかったので、
上の図と「配布 その 5」の節に足した。**

## 再評価のトリガー

次のいずれかが起きた場合、backend 言語の決定（C++）を再評価する価値がある。

- **Rust の AddressSanitizer / LeakSanitizer が stable 化する** — 言語評価 §4.4 の決定的な差が消える。Rust project goals の 2026 目標として進行中
- Web または iOS がスコープから外れる
- generator を採用せず bridge を大量に手書きする方針に変わる

再評価が安価であるために、**public C header と契約テスト（L1 / L3）は backend 実装から独立に保つ**。この不変条件は M0 で確立し、以降のすべてのマイルストーンで維持する。
