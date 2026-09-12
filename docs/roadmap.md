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
| ~~`ci-web.yml`~~ | — | ~~Unity 同梱 Emscripten での Wasm ビルドと browser E2E~~ | **作らなかった。** Wasm のクロスビルドは `ci-native.yml` のクロス job、browser E2E は `ci-unity.yml` の `web-e2e` job に置いた。**nightly でもない** —— pull request と push で走る。Player を建てる job を別にしたのは、**Unity Test Framework が WebGL の Player を batchmode から走らせられない**ためで、Unity のレーンとは起動の仕方が根本的に違う |
| `release.yml` | tag / **pull request**（空撃ち） / `workflow_dispatch` | **全部入りの UPM tarball（配る正）** と platform ごとの tarball、manifest / checksums / SBOM / third-party notices と `SHA256SUMS.txt` を GitHub Release へ。**staging した数を数え**、全部入りが名前で並んでいることも見る（**件数は platform が増えれば増えるので、実数は `CLAUDE.md` の workflow 表が持つ**）。**pull request でも走るようにしたのは M4 の後**で、tag でしか走らなかった間に欠陥が 3 件たまったためである（うち 1 件は「tag を打つと Release が 1 件も作られない」）。**全部入りには SBOM と build-manifest を付けない** —— どちらも復元済みの OpenCV artifact から作るので、束ねる job には元が無く、混ぜた版を捏造しない。**M3.5 が足した配線（全部入りの組み立て・17 件の staging・SHA256SUMS）は 2026-08-30 の空撃ちで初めて通した。** それまで空撃ちは publish job を丸ごと飛ばしており、**束ねる側は tag を打つまで 1 行も動かなかった** —— job を `assemble`（条件なし）と `publish`（job 単位で tag に限る）に割って直した。**実績は 2 つ**: run 33286928144 は条件を最後の step に降ろしただけの形（レビューで取り消した）、run 33289128197 が**いまの 2 job 構成**である。どちらも Release は作られていない。**tag で 2 回実行済み**（v0.1.0 = 2026-08-28、v0.1.1 = 2026-08-29。どちらも `--draft` で下書きを作り、人が点検してから公開した）。**M3 当時の空撃ち**（run 33156465235、3 platform とも success）は publish job ごと skip されていた —— **この形は 2026-08-30 に変えた**（上記）ので、いまの空撃ちは Release を作る job 以外を通る | M3 |
| `ci-lint.yml` | push(main) / PR / 手動 | actionlint / shellcheck / PSScriptAnalyzer / 文書の相対リンク検査の 4 job。**静的に読めば分かる誤りを、CI を 1 周（10〜20 分）回して確かめていた**のを埋める | M3 後 |
| `codeql.yml` | push(main) / PR / 週 1 / 手動 | C++ と C# の静的解析。sanitizer が「実際に踏んだ経路」を見るのに対し、CodeQL は経路を実行せずに探すので**重なっていない** | M3 後 |
| `nightly.yml` | 毎日 04:00 UTC / 手動 | 誰も push していない間に壊れることを見つける。Linux 成果物の移植性 / Windows・macOS の速いレーン / OpenCV artifact の期限切れ確認の **3 job 定義**（速いレーンは `lanes` という 2 runner の matrix なので、**実行時は 4 件**になる）。**2026-08-29 から schedule で毎日走っている**（下記） | M3 後 |

**M3 の後に足したもの**（マイルストーンの完了条件ではなく、CI/CD の監査で出た穴を塞ぐもの）

- `ci-lint.yml` / `codeql.yml` / `nightly.yml` の 3 workflow（上表）
- `.github/codeql/codeql-config.yml` の `query-filters` — P/Invoke していること自体への 2 規則（`cs/unmanaged-code` / `cs/call-to-unmanaged-code`）を外す。**このパッケージは native を P/Invoke で呼ぶために存在する**ので、この 2 規則の指摘は 1 件残らず設計どおりであり、ABI 関数を 1 本足すたびに増える。実測（2026-08-29）で open 107 件のうち 84 件がこれで、**その陰にこちらのコードに対する本物が 4 件埋もれていた**。埋もれた指摘は無いのと同じである。4 件の現在の扱いは `CLAUDE.md` のワークフロー節にある
- `.github/dependabot.yml` — `actions/*` と `tests/Managed` の NuGet を週 1 で追う。可変タグで固定しているので、**上流が変われば何もしていないのに壊れる**。その変化を差分として見える形にする
- `SECURITY.md` / `CONTRIBUTING.md` — OSS として欠けていた。前者は非公開の脆弱性報告先とこの境界で何が範囲内か、後者は貢献の手順と**CI が見ないもの**を明示する

**`nightly.yml` は schedule で毎日走っている。** 最初の手動起動は 2 回で、
1 回目（run 33230097557、2026-08-29 02:54Z）は 4 job 中 3 job が
`API rate limit exceeded for installation` で失敗し、原因を直したあとの
2 回目（run 33233610215、同 04:21Z）が 4 job とも success だった
（上表のとおり 3 job 定義に対して実行は 4 件になる。数え方が違うだけで、
どちらの数字も同じ run のものである）。

**その後 cron の経路も動いた**（2026-09-10 に `gh run list --workflow nightly.yml
--event schedule` で実測）—— **2026-08-29 から毎日、13 回**。うち 3 回
（2026-08-31 / 09-01 / 09-02）が failure で、**直近 8 回（09-03〜09-10）は
すべて success** である。

**リポジトリ内でこの件数を書いてあるのは、ここと `README.md` / `README.ja.md` のnightly の段落の 3 箇所だけである。** README の 2 つは利用者向けで、ここを指すわけにいかないので**日付つきの記録として**書いてある（必須チェックの本数とまったく同じ扱いで、`CLAUDE.md` がその例外を 1 箇所に書いている）。**「ここ 1 箇所に限る」と書いていたが、それは同じ branch の中で既に偽だった** ——**排他を主張する文は、主張した本人がいちばん破りやすい。**

**「workflow ファイルが存在する」は「CI で実行された」ではない** ——
M2 の条件 7 をその基準で未達と判定した以上、こちらにも同じ基準を当てた。
**この項目は、その基準を当てたまま解消した側の例である** ——
**逆向きの陳腐化に注意すること。** 「まだ動いていない」と書いた記述は、
動き始めた日から嘘になるのに、**赤くならない**（穴が埋まっても誰も知らせない）。
実際この 1 文は 2026-09-10 まで 4 箇所に残り、**毎日走っている検査を
「存在しない」ことにしていた。**

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
`imgcodecs` / `objdetect` / `features` / `geometry` / `calib` / `stereo` と、
opt-in profile の `dnn`（M7c）に留まる（**module 名も本数も写さない正本は
`bindings/spec/*.json` のファイル名と [所有権と versioning](./abi-ownership-and-versioning.md) §3 の冒頭である** —— ここに写すと 1 本増えた日にこの行だけが嘘になる）（M3.5 で `imgcodecs`、
M5 の module 拡張で `objdetect` / `features` / `geometry` / `calib`、そして
**2026-09 の API 拡張で姿勢・ArUco・imgproc の実用関数・core の基本演算・
記述子マッチング・ステレオ視差**が加わった。**本数を数える正本は
[API 対応表](./api-map.md) の冒頭である**）
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
| 3 | ~~**OpenUPM に載っていない**~~ **解消済み（2026-08-30）** | OSS の Unity パッケージが探される場所。#1 に加えて asset 名と容量の条件がある | **(a) 版番号なしの asset 名・(b) 容量の検査・(c) 登録申請のすべてが済んだ。** openupm/openupm PR #6843 が自動マージされ、`https://package.openupm.com/com.ayutaz.opencv-unity-native` が配信している（[登録の記録](./openupm-registration.md)）。**配信されている版は `0.3.0` である**（2026-09-04 に確認。下の「配布 その 5」）—— 登録と、新しい版が届くことは別で、`0.2.0` から `0.3.0` へ切り替わるのに公開の約 4 時間を要した |
| 4 | 検証している Unity が 1 版だけ | **M3.5 でその 1 版を 6000.0.82f1 → 6000.3.16f1 に載せ替えた**（6000.0 LTS の通常サポートが 2026-10 に終わるため。6.3 LTS は 2027-12 まで）。**版が 1 つしかないこと自体は変わっていない** | **M3.5 完了**（載せ替えのみ。複数版の検証は担当なし） |
| 5 | ~~カメラ映像を受け取れない~~ **M4 で解消** | `WebCamTextureConverter`（3 overload）が `WebCamTexture` から `CvMat` を作る。**新しい C ABI 関数は 1 本も増えていない** —— 既存の上に立つ純 C# である | **解消済み（2026-08-30）** |
| 6 | macOS で Unity に読み込ませたことがない | 「iOS のビルドに macOS runner が要るので M4 で自然に埋まる」と書いていたが、**埋まらなかった。** macOS runner は plugin をビルドするだけで Unity を起動しない | **未解消。2026-08-31 に 4 回試して「CI では閉じない」と確定した**（game-ci は macOS を支えず、Hub で直接入れる経路は Editor が 14 分で入るのにライセンスで止まる）。詳細は下の「担当が無かった制約」 |
| 7 | Windows の IL2CPP を CI で回していない | 「game-ci では無理」の根拠に挙げていた issue は、使っていない別 action のものだった —— **そこで実際に投げて根拠を作った** | **未解消。2026-08-31 に「CI で回さない」と結論した** —— `windows-2022` で EditMode は 33 件通ったが、`Standalone` は `ToolchainNotFoundException` で落ちた（game-ci の Windows コンテナに MSVC が無い）。**根拠は実測であって他人の issue ではない。** これは「まだ調べていない穴」ではなく**意図して CI の外に置いたもの**である |
| 8 | 対応 CPU アーキテクチャが狭い | Android エミュレータ（x86_64）が無いと開発しづらい | **M4 で決めた: arm64 のみ**（Android は arm64-v8a、iOS は実機の arm64）。**穴は塞いでいない —— 塞がないと決めた。** 増やすと platform が 2 つ増え、OpenCV のビルドも配布物も同じだけ増える（**数を写さない** —— 正本は `tools/dev.ps1` の `$AllPlatformBinaries` で、触る場所は `add-a-platform` skill にある） |
| 9 | 「低コピー連携」を測っていない | §7 の 7 番目に掲げているのに実測が無い | **M7a で着手し、部分的に解消（2026-09-06）。** 割り当ては L3 が機械で保証し（ポインタ経路 0 バイト）、時間は測って公開したが**assert していない**。**`RenderTexture` / `AsyncGPUReadback` の経路は Editor（Mono）でしか実行していない** —— ただし **2026-09-11 に CI へ配線した**（`ci-unity.yml` の `Graphics` レーン。下の「GPU 経路を CI に載せる」）ので、「そのレーンは CI に配線していない」という留保は失効した。**IL2CPP の Player でこの経路が動くかは依然として未実証である** —— game-ci が Player を `-nographics` で起動しており、そこはこちらから外せない。**native texture pointer は評価のみで実装していない**（やらないと決めた）。判定と根拠は下の「M7a の判定」節 |
| 10 | 新しい DNN エンジンを載せていない | OpenCV 5 最大の変更。ただし Unity には代替がある。**2026-08-30 の調査で、5.0 に固定して作り込めない根拠が付いた**（根拠と一次情報は M7 節。**ここに再掲しない** —— 根拠を直すと 2 箇所が同時に古くなる） | **M7c で部分的に解消（2026-09-10）。** ONNX をメモリから読んで forward を 1 回走らせる C ABI 4 本を、opt-in profile（`OCVU_PROFILE_DNN`）として出した。**ただし実機で 1 度も動かしておらず、推論の速さも測っていない**（`### M7c の判定`）。位置づけと、そこから出た module 分離の決定は下記 |

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
| 2 | その tarball を使い捨ての Unity プロジェクトに導入して EditMode が通る | **満たす**。`dev.ps1 test-unity-tarball -PluginSource` に v0.1.1 の macOS / Linux を重ねて全部入りを作り、`==> UPM tarball install: 16 passed`（2026-08-30、このマシン）。**当時このレーンはどの workflow にも入っていなかった**（ローカル専用。M3 から変わっていなかった）。**2026-09-11 に `ci-unity.yml` の `tarball` job として載せた**（下の「GPU 経路を CI に載せる」） |
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

### 配布 その 3 — v0.2.0（2026-08-30）

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

### 配布 その 4 — v0.3.0（2026-08-31 の下書き。**2026-09-04 に破棄して打ち直した** —— 経緯は「配布 その 5」）

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
M4 の完了条件 9 件のうち 3 件が閉じておらず、2 件が実機である（判定表が正本）。

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

1. **M4 は 9 件中 6 件のまま止まる。** 条件 3・4 は実機が要り、条件 6・7 は
   2026-08-31 に「CI では閉じない」と結論済みなので、**この 4 件はどれも
   自然には閉じない。** 誰かが実機を用意して手順書を実施するまで動かない。
2. **Android / iOS は「CI がビルドするが、誰も動かしたことがない」まま残る。**
   コードは main に在り、CI は 5 platform 分をビルドし、`release.yml` は
   28 asset を作れる。**動くかどうかだけが未知である。**
3. **利用者に届く最新版は v0.2.0（3 platform）のままである。** OpenUPM が
   配信しているのもそれで、**モバイル対応は誰の手にも渡らない。**
   **（この 3 番目は 2026-09-04 に失効した** —— v0.3.0 を公開し、OpenUPM も
   0.3.0 を配信している。**1 と 2 は今も真である。** 2026-09-01 時点の
   判断の記録として、消さずに残す。）

**この下書きをそのまま公開してはならない。** 作った時点（2026-08-31T01:40Z）は
**M5 が main に入る前**で、asset の中の `.g.cs` も `docs/api-map.md` も
入っていない。**配ると決めたら、tag を打ち直して作り直すこと** ——
**その手順は下の「配布 その 5 — v0.3.0」にある。**

**2026-09-03、その「配ると決めた」が来た。** 下書きは**消して作り直す**
（以前ここには「消す必要は無い」と書いてあったが、**同じ版番号を再利用する
ことにしたので消す必要が出た** —— 残すと新旧の asset が混ざる）。

### 配布 その 5 — v0.3.0（**2026-09-04 に公開し、完了条件 7 件をすべて満たした**）

> **公開済み（2026-09-04）。** https://github.com/ayutaz/OpenCVUnityNative/releases/tag/v0.3.0
>
> **M4（5 platform）・M5（生成器と校正 API）・M6（Web）の成果が、これで初めて
> 利用者に届いた** —— v0.2.0 以来である。**下の手順は実際に踏んだ記録である。**
>
> **実際に起きたことのうち、手順書に無かったもの:**
>
> - **既存の v0.3.0 の tag と下書きを破棄して打ち直した。** 当初の計画は
>   「v0.3.0 は飛ばして v0.4.0」だったが、**v0.3.0 という名前で世に出た物が
>   1 つも無いことを実測して覆した**（下書きは非公開、OpenUPM の**レジストリ**が
>   配信していたのは `0.2.0` だけ）
> - **OpenUPM は tag の移動を追随し、配信まで届いた。** レビューが「確かめるまで
>   分からない」とした点だが、**打ち直した直後に pipeline のレコードが
>   `cadd52f` → `03a4557` に更新され**（probe 回数も 16 → 5 にリセット）、
>   **公開の約 4 時間後に `dist-tags.latest = 0.3.0` になった**（`state=2` /
>   `buildId=75222`）。
> - **`state=3`（失敗）を見ても、すぐに問題と決めないこと。** 公開直後に見た
>   `state=3` / `reason=904`（asset が無い）は、**最後の probe が公開の
>   2 時間 45 分前だった**ためで、**古い probe の記録**にすぎなかった。
>   **「失敗している」と「まだ見ていない」は別である** ——
>   `githubReleaseAssetMissingLastProbeAt` を Release の `publishedAt` と
>   突き合わせれば区別が付く
>
> **更新（2026-09-03、M6 完了後）。この節はもう「いつかの手順書」ではない。**
> **待っていた条件（M6 が片づくこと）が満たされたので、2026-09-03 に着手した。**
> **platform は 5 つではなく 6 つになった。** 下の手順と表はそれに合わせて
> 直してある —— **読み替えに頼る形は残していない**（`milestone-complete` skill が
> 「チェック済みの印は語句の置換では直らない」と書いているのは、まさに
> ここで踏んだ形である）。asset の数は `CLAUDE.md` の `release.yml` の行が持つ。
>
> **2026-09-03、この時点では配らないと決めた。** 版を上げるのではなく、
> **次の区切り（M6）が片づいたところでまとめて配る。**
> **その M6 が片づいたので、いま配っている。**
>
> **帰結を承知で決めている**:
> **利用者に届く最新版は v0.2.0（3 platform、M5 前の API）のまま**で、
> **M4 の 5 platform も M5 の生成器と校正 API も、誰の手にも渡らない期間が
> M6 の分だけ延びる。** OpenUPM が配信するのも `0.2.0` のままである。
>
> **間違っていた場合のコスト**: M6 で platform が 1 つ増えるので、
> **配る形（全部入りの tarball・`.meta`・gating の検査）はもう一度動く。**
> 先に配っておけば「5 platform を配った実績」の上に Web を足せたが、
> 先送りしたので **6 platform 分を一度に初めて配ることになる。**
> **`release.yml` は PR で空撃ちしているので配線は緑のまま保たれる** ——
> M4 で 3 件たまったような欠陥は、たまる前に見つかるはずである。
>
> **版番号は 2026-09-03 に `v0.3.0` と決めた**（当初は「v0.3.0 は飛ばして
> v0.4.0 を打つ」と書いてあったが、覆した）。**理由**: v0.3.0 という名前で
> 世に出た物が 1 つも無いことを実測で確かめたためである ——
> 下書きは誰にも見えず、OpenUPM が持っているのは `0.2.0` だけだった
> （`curl https://package.openupm.com/com.ayutaz.opencv-unity-native` で確認）。
> **番号を飛ばす理由が無くなったので飛ばさない。**
> **内容は M6 まで反映してある** —— 上の「6 つになった」と同じで、
> 手順も表もこの時点の現実に合わせて直してある。


**この節を書いた時点では、M4（5 platform）・M5（生成器と校正 API）・M6（Web）の成果は
まだ誰にも届いていなかった** —— 利用者が使えるのは v0.2.0（3 platform、M5 前の API）だった。
**2026-09-04 に v0.3.0 を公開して解消した**（上のバナー）。

**2026-08-31 の v0.3.0 の下書きは使えなかった。** 作った時点（01:40Z）は M5 が main に
入る前で、asset の中の `.g.cs` が M5 前のもの（というより、生成物が 1 つも無い）だった。
**そこで tag を打ち直して作り直す。**

#### 何が変わるか（v0.2.0 → v0.3.0）

| 対象 | v0.2.0 | v0.3.0 |
| --- | --- | --- |
| platform | 3（Windows / macOS / Linux） | **6**（+ Android arm64-v8a / iOS arm64 / **Web wasm32**） |
| 公開 C ABI | 20 本 | **27 本**（本数の正本は [API 対応表](./api-map.md) の冒頭） |
| 境界の宣言 | 手書き | **`bindings/spec/*.json` から生成**（手書きの `[DllImport]` は 0 個） |
| OpenCV module | core / imgproc / imgcodecs | **+ objdetect / features / geometry / calib**（`geometry` は依存として推移的に引かれるが、`COMPONENTS` にも意図として明示してある） |
| 主な API | Mat / imgproc 3 本 / 画像の encode・decode | **+ QR / ORB / 射影変換 / カメラ校正 3 段** |

#### モバイルの扱い —— **配るが、実機未検証と明記する**（2026-09-03 に決定）

**Android / iOS は CI がビルドするが、実機で一度も動かしていない。** M4 の完了条件
9 件のうち 3 件が閉じておらず、うち 2 件は実機が要る（`docs/m4-device-verification.md`）。

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
だけを配る形に戻すのは、全部入りの仕組みも gating の検査も**全 platform**を前提にしている
ので**大きな後退**になる。(c) **明記すれば利用者が判断できる** —— v0.1.0 との違いは
そこである。あのときは「動く」と暗黙に主張していた。

**実機で動かないと分かったら v0.4.1 を出す。** このリポジトリは一度配ったものを
黙って差し替えない（v0.1.1 がそうだった）。

#### やること

1. **`.github/release-notes.md` を配る版の内容にする** ——
   **一度「済ませた」と書いたが、M6 がそれを無効にした。**
   2026-09-03 に M5 の分を書いた時点では 5 platform で、**Web が入って
   全部が古くなった**（platform の一覧・asset の数・Web にだけ在る制限）。
   **M6 完了時に書き直してある**が、**次に platform や API が動いたら同じことが
   起きる** —— この step を「済ませた」印で飛ばさないこと。
   **これは実際に配られる本文である**（`release.yml` がここを読む）ので、
   ここが古いまま tag を打つと、**中身と説明が食い違った Release が出る。**

   **書き直すときに必ず見る箇所:**

   - 「## 前の版（v0.X.Y）から変わったこと」の**版番号と中身**
   - 「## この版の範囲」の **platform 一覧と制限**
   - 「## この版で確かめていないこと」
   - 「## 検証」——**その版の tarball を導入した実測**なので、版ごとにやり直す
     （step 7 が対応する）
   - 「## 同梱物」の **asset 数**
   - **絶対 URL の版**（`blob/vX.Y.Z/...`）—— **tag に貼り付く**ので、
     直さないと公開した瞬間から 404 になる
   - **`README.md` / `README.ja.md` の「次の版から効く」と書いた箇所** ——
     **公開した瞬間に「次の版」が現在の版になるので、全部が嘘になる。**
     step 10 でも直すが、**step 1 で読むべき理由は別にある**: そこには
     「この版で変わったこと」が既に書かれていることがあり、
     **リリースノートから落ちていれば気づける。** 実際 v0.4.0 では
     `README` だけが PNG の ARM 加速喪失を「利用者全員に影響する」と
     書いており、**リリースノートには 1 文字も無かった**（別のセッションの
     指摘で気づいた）

   **この一覧をファイル側のコメントに置かないこと** —— `release.yml` は
   ファイルを丸ごと本文にするので、**HTML コメントも公開物に入る**（描画は
   されないが、API と編集画面には出る）。
2. **`README.md` / `README.ja.md` にモバイルが実機未検証であることを書く** ——
   **2026-09-03 に済ませた**（「ビルドはされているが実機で動かしていない」の節）
3. **`Packages/com.ayutaz.opencv-unity-native/package.json` の `version` を上げる**
4. **その変更を main へ入れる。** main は保護されており直接 push できないので、
   PR を出して CI を通す。**`release.yml` は tag と `package.json` の版が一致する
   ことを検査する**ので、tag を打つ前に main に入っていなければならない
5. **tag を打つ**（`v0.3.0`）→ `release.yml` が**全 platform 分**と全部入りを作り、`--draft` で止まる。
   **この tag は既に存在するので、動かすことになる**（下の「既存の v0.3.0 の tag と
   下書きをどうするか」）
6. **下書きを実物で検証する** —— 落として `SHA256SUMS.txt` と突き合わせ、全部入りの中に
   **全 platform 分**の binary と `.meta` が在ること（**数で確かめない。正本は
   `tools/dev.ps1` の `$AllPlatformBinaries`** —— 「5 つ揃っていれば合格」と読むと
   WebGL の欠落を見逃す）、生成された `.g.cs` が入っていること、
   Linux の GLIBC 要求、Android の page size、iOS の `.a` を見る（**「配布 その 4」の表と同じ項目**）
7. **配る tarball を、実際に Unity へ導入して確かめる。** **これは step 6 とは別である**
   —— step 6 は「中に何が入っているか」を見るが、**入っている物で Unity が
   導入できるかは見ない。** M3 でこのレーンを足して初めて「**UPM が導入できない
   tarball**」が見つかっており、v0.1.0 は「ビルドできた ≠ 動く」を踏んでいる。

   ```sh
   # **下書きの asset そのもの**を落として展開し、全 platform 分を材料に固め直して導入する
   # ★ <version> は必ず**これから配る版**に置き換える（下の警告を読むこと）
   gh release download v<version> -p 'com.ayutaz.opencv-unity-native.tgz' -D <dir>
   tar -xzf <dir>/com.ayutaz.opencv-unity-native.tgz -C <out>
   # 落とした物が本当にその版か、目で見る（asset 名に版番号が無いので名前では分からない）
   grep '"version"' <out>/package/package.json
   ./tools/dev.ps1 test-unity-tarball -PluginSource "<out>/package"
   ```

   > **⚠ ここに前の版の番号を書いたまま実行しても、落ちない。**
   > **無音で緑になる。** 全部入りの asset 名には**版番号が入っていない**
   > （OpenUPM が安定した接頭辞で選ぶため）ので、前の版の asset も
   > 同じ `com.ayutaz.opencv-unity-native.tgz` である。前の版は公開済みで
   > 現存し、中には全 platform が揃っているので
   > `native plugins present: N` まで通って **exit 0 になる。**
   > `dev.ps1 test-unity-tarball` は package の version を照合しない。
   > **だから上の `grep '"version"'` を飛ばさないこと** ——
   > これが「前の版を検証して合格した」と「この版を検証して合格した」を
   > 見分ける唯一の手段である。

   **`gh run download` で済ませないこと。** あれが取るのは workflow run の
   artifact であって、**配る Release の asset ではない** —— PR の空撃ちの
   成果物でも通ってしまい、**step 6 と別に step 7 が在る意味が消える。**
   （下書きの asset は write 権限があれば落とせる。）

   **`test-unity-tarball` は必ず固め直す**ので、**asset そのものを導入するのでは
   ない** —— 確かめられるのは「同じ配線が作った同じ中身の tarball が導入できる」
   ところまでである。**そこは正直に書くこと。**

   **2026-09-11 から、このレーンは CI にも在り、必須チェックでもある**
   （`ci-unity.yml` の `tarball` job。下の「GPU 経路を CI に載せる」。
   **同じ日のうちに配線と昇格の両方をやったので、「配線したが止めない」と
   書いた記述が数時間で失効した** —— ここもその 1 つだった）。
   **それでもここで人が回す理由が残る** ——
   CI が固めるのは PR 時点の binary であって**これから配る asset ではない**。
   **platform が増えた版では必ず回すこと** —— 新しい形の binary と
   `.meta` が初めて全部入りに入るのは、その版だからである。

   **予行は済んでいる**（完了条件を見よ。空撃ちの成果物で 2026-09-03 に通した）。
   **それとは別に、下書きの asset で必ず回すこと** —— 予行が見たのは
   「この配線が作る tarball は導入できる」で、**配る物そのものではない。**
8. **公開する**（`gh release edit v<version> --draft=false`）。
   直後に **Latest バッジが移ったか**を見る ——
   `gh api repos/ayutaz/OpenCVUnityNative/releases/latest --jq .tag_name` が
   新しい版を返すこと。**`--draft=false` が `make_latest` を送るかは確かめて
   いない**ので、返らなければ `gh release edit v<version> --latest` を足す。
9. **OpenUPM が拾うことを確かめる。** 確かめ方:

   ```sh
   curl -s https://package.openupm.com/com.ayutaz.opencv-unity-native |
     python -c "import sys, json; print(json.load(sys.stdin)['dist-tags']['latest'])"
   ```

   これが `0.3.0` を返せば配信されている。**OpenUPM はビルドキューを持つので、
   公開した直後には反映されない** —— v0.2.0 のときも数時間かかった。
   **「登録済みだから自動で拾うはず」で終わらせない。**

   **レジストリだけでは足りない。** v0.3.0 には**古いコミットに紐づいた失敗
   レコード**が既に在るので（上記）、**それが新しい tag を指し直したか**まで見る:

   ```sh
   curl -s https://api.openupm.com/packages/com.ayutaz.opencv-unity-native |
     python -c "import sys,json;print([r for r in json.load(sys.stdin)['releases'] if r['version']=='0.3.0'])"
   ```

   **`state` が 3（失敗）から 2（公開済み）に変わり、`commit` が新しい tag の
   指すコミットになること**を確かめる。変わらなければ OpenUPM 側で再ビルドを
   促すことになる。**「レジストリに出たから終わり」にしない** ——
   古いレコードが残ったままだと、次の版でも同じところで詰まる。
10. **公開後に文書を更新する。** 「最新の公開版」を書いている場所は次のとおり:
   `docs/roadmap.md`（この節と「配布」の各節）、`CLAUDE.md`（現在地の段）、
   `docs/README.md`（Status）、`README.md` と `README.ja.md`（冒頭の Status と
   「導入」の節）、`docs/api-reference.md`（対象範囲）、
   `.github/release-notes.md`（次の版のために「前の版」を繰り上げる）、
   `docs/openupm-registration.md`（「`0.2.0` を配信している」）、
   `docs/unity-opencv-integration-research-and-plan.md`（比較表の前書き。
   **ここは既に古い** —— M6 が抜けている）。
   **もう 1 つある: `docs/m4-device-verification.md`** ——
   実機で動かす人が最初に開く文書で、最新の公開版を前提に書かれている。
   **合わせて 10 ファイルある。** 1 つでも古いと、次に読む人が違う版を前提に動く。

   **README 2 本は「Status と『導入』の節」だけでは足りない。**
   版に依存する記述はもっと広く散っている（v0.4.0 の時点で
   `README.md` に 10 行、`README.ja.md` に 9 行）。
   **`v0.3.0` / `next release` / `次の版` で grep して全件洗うこと** ——
   とくに「**次の版から効く**」のような相対表現は、公開した瞬間に
   すべて嘘になるうえ、版番号で grep しても引っかからない。
   **この数も写しである** —— 増えたら一緒に直すこと（実際 2026-09-03 の
   レビューで 7 から 9 に増えた）。

#### tag を打ち直すときの順序（版によらない）

**`release.yml` は条件なしに `gh release create` を呼ぶ**ので、古い下書きを
残したまま打ち直すと、落ちるか、同じ tag 名の下書きが 2 つ並ぶ
（**どちらになるかは確かめていない**）。並んだ場合、古いほうを公開すると
**捨てたはずの本文と asset がそのまま世に出る。** 順序は:

```sh
gh release view v<version> --json assets --jq '.assets[].name'   # 何を捨てるか控える
gh release delete v<version> --yes
git push origin :refs/tags/v<version>
git tag -d v<version>
git checkout main && git pull
git tag -a v<version> -m "v<version>" && git push origin v<version>
git rev-list -n1 v<version>                                      # 意図した commit か
```

**打ち直したら step 6 と step 7 をやり直す。** asset は別物になる ——
native binary はバイト単位で再現しないので、**本文に実物の大きさを書いて
あるなら測り直しが要る**（そこで数字が動くと、本文を直して**もう 1 往復**
tag を打ち直すことになる。これは実際に起こりうる無限ループである）。

**そもそも打ち直すべきかを先に考えること。** 差が本文だけなら
`gh release edit v<version> --notes-file .github/release-notes.md` で足りる ——
**検証済みの asset を捨てずに済み、「この asset そのもので確かめた」という
主張も真のまま残る。** 代償は `blob/v<version>/.github/release-notes.md`
（tag 側の写し）と公開本文が食い違うことだが、**本文はそのファイルへの
リンクを張っていない**ので利用者が踏む経路は無い。
**v0.4.0 ではこちらを採った。**

#### 既存の v0.3.0 の tag と下書きをどうするか

**2026-09-03 に方針を覆した。** 以前ここには「触らない。再利用もしない。
v0.4.0 を新しく打つ」と書いてあったが、**再利用する**ことにした。

**再利用の前に、安全であることを実測した。** 「一度配ったものを黙って差し替えると、
同じ版名で違う物が世の中に 2 つ存在することになる」（v0.1.1 の教訓）が当てはまるのは
**配った物**だけである。v0.3.0 は配っていない:

| 確かめたこと | 結果 |
| --- | --- |
| Release は公開されているか | **下書きのまま。** GitHub の下書きは write 権限を持つ人にしか見えない |
| OpenUPM の**レジストリ**が配信しているか | **`0.2.0` だけ**（`package.openupm.com`。`dist-tags.latest` も `0.2.0`） |
| OpenUPM の**ビルド pipeline**は知っているか | **知っている。ただし失敗し続けている**（下記） |

**したがって `v0.3.0` という名前で世に出た物は 1 つも無く、番号を飛ばす理由が無い。**

**ただし「OpenUPM は何も知らない」ではない。** `api.openupm.com` を叩くと、
**tag を打った 5 分後（2026-08-31T01:45Z）に v0.3.0 を検出し、以来 16 回
probe して失敗している**ことが分かる（2026-09-03 に実測）:

```json
{"tag":"v0.3.0","version":"0.3.0","state":3,"reason":904,
 "commit":"cadd52fcba0b3d1c44442adc991d0b379ad09bed",
 "githubReleaseAssetMissingProbeCount":16}
```

`state:3` は失敗、`reason:904` は「Release の asset が取れない」（下書きなので当然）。
**注意すべきは `commit` が古い tag の指す先に紐づいていること**である ——
tag を打ち直した後に OpenUPM がそれを拾い直すかは、**確かめるまで分からない**
（step 9「OpenUPM が拾うことを確かめる」）。**まだ諦めずに probe し続けている**ので、公開すれば拾う見込みは高い。

**やること（この順で）:**

1. **古い下書きを消す**（`gh release delete v0.3.0 --yes`）。**asset 28 件は
   M5 が main に入る前のもので、生成物が 1 つも入っていない** —— 残すと
   `release.yml` が新しい asset を足したときに、**新旧が混ざった Release になる。**
   **`--cleanup-tag` を付けると remote の tag も一緒に消えるが、local は残る**
   ので、どちらにせよ次の step は要る
2. **tag を消して打ち直す**（**remote と local の両方**）。**片方だけ消すと、
   次の push で古いほうが復活する**

   ```sh
   git push origin :refs/tags/v0.3.0    # remote（step 1 で --cleanup-tag を使ったなら不要）
   git tag -d v0.3.0                    # local
   git checkout main && git pull        # ★ merge 済みの main を取り直す
   git tag -a v0.3.0 -m "..."           # ★ annotated で打つ
   git push origin v0.3.0
   ```

   **`-a` を忘れないこと。** 元の v0.3.0 は annotated tag だったので、
   `git tag v0.3.0` だけだと種類が変わる（`release.yml` は `github.ref_name`
   しか見ないので動作は変わらないが、揃えない理由も無い）。

   **どのコミットに打つかを間違えないこと。** step 4 で main へ入れた**後**の
   main の先端である —— **作業ブランチの先端に打つと、`package.json` は
   合っていても main に無いコミットを配ることになる。**

   **他所のクローンには古い tag が残る。** `git fetch` は取得済みの tag を
   更新しないので、別のクローンや fork では `git fetch --tags --force` が要る
   （CI は `actions/checkout` が毎回新規取得するので影響しない）。
   **tag protection も ruleset も無いことは確認済み**なので、削除と再作成は通る
3. tag を push すると `release.yml` が新しい下書きを作る

**これは取り消しにくい操作である。** 実行する前に人の確認を取ること ——
**下書きを消すと、その asset は戻らない**（作り直せるが、同じ物にはならない）。

#### 完了条件

- [x] **`v0.3.0` が公開され（2026-09-04）、asset が揃っている**（実測 33 件。`SHA256SUMS.txt` との突き合わせは自分自身を除く 32 件すべて OK）。**数をここに書かない** ——
      正本は `CLAUDE.md` の `release.yml` の行で、**platform が増えるたびに
      ここに書いた数だけが静かに嘘になる**（M6 で実際に 28 → 33 になった）
- [x] **実測した（2026-09-04）。** 全部入りの tarball を落として、**全 platform 分の binary と `.meta`**、
      **生成された P/Invoke 宣言（`Runtime/Interop/NativeMethods.*.g.cs`）** が
      入っていることを実測する。**「全 platform」を数で確かめない** ——
      正本は `tools/dev.ps1` の `$AllPlatformBinaries` である
      （**5 つ揃っていれば合格、という読み方をすると WebGL の欠落を見逃す**）。
      **`docs/api-map.md` は package に入らない** ——
      あれはリポジトリの文書であって、配布物の一部ではない
- [x] **配る全部入り tarball が、実際に Unity プロジェクトへ導入できる。**
      **本番を 2026-09-04 に通した** —— **公開する下書きの asset そのもの**を
      落として展開し、6 platform 分を材料に固め直して使い捨てのプロジェクトへ
      導入した: `native plugins present: 6` / `34 passed` /
      `PluginGatingTests` 4 件が個別に passed / exit 0。
      **予行（空撃ちの成果物）は 2026-09-03 に通してある** —— 下の内訳がそれで、
      **「予行が通った」を「配る物を確かめた」と読み替えないこと**が、この
      チェックボックスの役目だった。

      予行の内訳（このマシン、Windows）—— `release.yml` の**空撃ち**
      （run 33753353680、ブランチ `docs/refresh-all`）が作った
      `com.ayutaz.opencv-unity-native.tgz` を展開し、
      その 6 platform 分を材料に固め直して使い捨てのプロジェクトへ導入した:
      `==> [tarball] output says: native plugins present: 6 [` /
      `==> [tarball] 34 passed` / `PluginGatingTests` 4 件が個別に passed / exit 0。
      **これは「中に 6 つ入っている」とは別の主張である** —— 入っている物で
      Unity が導入でき、**自分の platform 向けだけを有効にする**ところまで見た。
      **5 platform までの実績しか無かった**（2026-08-31）ので、Web を含む形は
      これが初めてである。**確かめられたのは「同じ配線が作った同じ中身の
      tarball が導入できる」ところまで**で、**asset そのものを導入したのでは
      ない**（`test-unity-tarball` は必ず固め直す）
- [x] リリースノートと `README.md` / `README.ja.md` に**モバイルが実機未検証であること**が明記されている
- [x] **リリースノートに Web の制限（`imgcodecs` は JPEG のみ）が書いてある。**
      **これは他の platform に無い機能の欠落**なので、利用者が導入前に読める
      場所に無ければならない
- [x] **OpenUPM が `0.3.0` を配信する。2026-09-04 に確認した:**
      `dist-tags.latest = 0.3.0` / `versions = ['0.2.0', '0.3.0']`。
      pipeline も `state=2`（公開済み）/ `reason=0` / `commit=03a4557` /
      `publishedVersion=0.3.0` / `buildId=75222`。
      **レジストリだけでなく pipeline のレコードまで見た** —— 打ち直した tag に
      紐づいたまま公開されたことが、これで確かめられた
- [x] 公開後に「最新の公開版」の記述を更新する（**一覧はやること 10 にある** —— ここに写すと 2 つが食い違う）

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
  ぶん、OpenUPM の 512 MB 上限に対する余裕が減る（**3 platform 時点の実測で 9.6 MB。その後 platform が増えたが測り直していない**。**モバイルを
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
| 9 | モバイルの binary が全部入りに入り `dev.ps1 test-unity-tarball` が通る | **満たす**（2026-08-31、このマシン）。5 platform 分を束ねた tarball を使い捨ての Unity プロジェクトに導入して `==> UPM tarball install: 25 passed`。**当時このレーンはどの workflow からも走らなかった** —— game-ci の action の外で Unity を起動する必要があり、「CI に載せるのは別作業である」と書いて置いていた。**その別作業は 2026-09-11 に済んだ**（下の「GPU 経路を CI に載せる」。`ci-unity.yml` の `tarball` job）。**M4 でモバイルを足した時点からこのレーンは壊れており**（期待する binary の数が `3` と直書きされ、iOS の `.a` を binary と認めなかった）、無関係な作業の途中で 1 度手で回すまで誰も知らなかった —— **走らないレーンが腐るのはこれで 2 度目で**（M7a では Graphics の除外が抜けた）、CI に載せた直接の動機でもある |

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
（2026-08-31、このマシン）。**当時このレーンはどの workflow からも走らなかった** ——
game-ci の action の外で Unity を起動する必要があり、「CI に載せるのは別作業である」と
書いて置いていた。**その別作業は 2026-09-11 に済んだ**（下の
「GPU 経路を CI に載せる」）。
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
| 2 | `geometry` / `calib` / `features` / `objdetect` を利用例に基づいて追加 | **満たした（2026-09-02 更新）。4 module すべてを出した。** 判定を変えた根拠はこのセルの末尾にある —— **経緯は残してあるので、下へ読み進めること。** **ただし条件の後半「利用例に基づいて」は、厳密には 4 module のうち `calib` の 1 つでしか満たしていない。** 残る 3 つは「利用例を持つものの中から、リンクが安いものを選んだ」が正確である（各 module の欄に同じ正直さで書いてある）。**それでも「満たした」と判定するのは、条件の主眼が「module を足す仕組みが働き、実際に使える API が増えること」だと読むためである** —— 出した 7 本はどれも Unity での用途を持ち、飾りで足したものは 1 本も無い。**この読みが甘いと考えるなら、判定は「部分的に満たした」に戻る。** 当初の実装計画は冒頭で明示的に対象外にした —— 新しい OpenCV module は `cmake/FindOpenCvUnityDeps.cmake` の `COMPONENTS`・`tools/opencv-config.psd1` の `Modules`・`THIRD_PARTY_NOTICES.md`・成果物の大きさ・依存 allowlist が同時に動く**別の subsystem**で（M3.5 の `imgcodecs` で実際に全部動いた）、生成の仕組みと同時にやると「生成が壊れたのか module が壊れたのか」を切り分けられない。**続く計画（`.superpowers/sdd/2026-09-01-m5-modules-objdetect-features/`）で `objdetect`（QR コードの符号化・復号）と `features`（ORB 特徴点検出）の 2 module を実際に出した** —— C ABI は 20 → 23 本、うち allowlist は 11 → 14 本になった（内訳は `docs/abi-ownership-and-versioning.md` §3.6）。**さらに続く作業で `geometry` も出した**（`ocvu_find_homography`。C ABI は 24 本、allowlist は 15 本）。**そこで推測が実測になり、予想と違った** —— `geometry` は「リンクが安い」どころか**リンクの手間がゼロだった。** `flann` と `geometry` は `features` / `objdetect` の依存として **CMake が推移的に引いており**、`COMPONENTS` に足す前からリンク行に入っていた（実測: 足す前も後もライブラリは同じ 7 つで、`cv::findHomography` を参照する L1 テストは `COMPONENTS` を変えずに最初から通った —— **RED にならなかった**）。**それでも `COMPONENTS` には明示した**（意図の宣言であり、上流が依存を変えたときに黙って壊れないため。no-op であることは実測で確かめた）。**残るは `calib` だけである。****対して `calib` だけが高い** —— `tools/opencv-config.psd1` の `Modules` に無いため、足すと構成ハッシュが変わって 5 platform 分の OpenCV を作り直すことになる（実測: `4785d98e9aad` → `09fcbe260d87`。**この値は 2026-09-01 に測り直した** —— それまで書いてあった `a197bbcbdaf5` は `geometry` を足したときの値で、`calib` のものではなかった）。**「`geometry` はビルドされていない」と読める記述は、この文書のどこにも見当たらなかった**（確認のため roadmap 全体を検索した）ので、訂正すべき誤りは無い。**条件の「利用例に基づいて」について、正直に書いておく。** QR の読み取り（チケット・名刺・機器の識別）と ORB の特徴点（追跡・位置合わせ）は Unity で十分ありふれた用途だが、**この 2 つを選んだ実際の動機は 「新しい module を spec から生成できることを実証する」ほうが大きい** —— `objdetect` / `features` は OpenCV 側が既にビルドしており、リンクが安かった。**利用者の要望から選んだのではない。** `geometry` / `calib` を出さなかった理由（利用例が無い）は変わっていないので、**まだ「満たした」ではなく「部分的に満たした」に留める** **その後（2026-09-02）、カメラの歪み補正を出した**（`ocvu_undistort` / `ocvu_find_chessboard_corners`。計画は `docs/superpowers/plans/2026-09-01-m5-calib-undistort.md`。C ABI は 26 本、allowlist は 17 本になった。内訳は `docs/abi-ownership-and-versioning.md` §3.8）。**判定は変えない** —— 依然として「部分的に満たした」のままである。**理由は 2 つ。** (1) 条件が名指しする 4 module のうち **3 つ**（`objdetect` / `features` / `geometry`）を出し、`calib` は出していない。**`calib` module は使っていない** —— `ocvu_undistort` は `imgproc`、`ocvu_find_chessboard_corners` は `objdetect` にあり、どちらも既にリンク済みだった（実測。`native/tests/test_module_linkage.cpp` がその前提を固定している）。**構成ハッシュは変わっていない。** (2) **より重要なのは、欠けている場所である。** カメラ校正は 3 段ある —— 盤の格子点を見つける、そこから係数を解く、係数で歪みを補正する。**この作業は 1 段目と 3 段目を出し、2 段目を出していない。そして 2 段目こそが `calib` を要求する段である**（`cv::calibrateCamera`。足すと構成ハッシュが変わって 5 platform 分の OpenCV を作り直すことになる。実測: `4785d98e9aad` → `09fcbe260d87`）。帰結として、**利用者は係数を別の手段でどこかから得なければ、この 2 本を使えない。**「歪み補正という用途は出した」は正しいが、**校正の輪は閉じていない。** **費用が安かったことと届いた機能は別の軸である。** `undistort` と `findChessboardCorners` がどちらも既存のリンクで済んだのは構成ハッシュを変えずに済んだという**費用**の話であって、利用者に何が**届いたか**の話ではない。両者を混ぜると判定が実際より甘くなる。**この 2 つを選んだ実際の動機も、`geometry` のときと同じ問題を持つ。** 歪み補正とチェスボード検出は Unity での用途（AR 較正、レンズ補正）として成立するが、**選んだ理由の実際の比重は「`calib` の再ビルドを避けられるから」のほうが大きい**。同じ正直さで記録しておく —— `objdetect` / `features` のときに書いた「利用者の要望から選んだのではない」と同じ構造がここにもある。 **そして 2026-09-02、`calib` module を足して `cv::calibrateCamera` を出した**（計画は `docs/superpowers/plans/2026-09-02-m5-calib-camera.md`。C ABI は 27 本、allowlist は 18 本。内訳は `docs/abi-ownership-and-versioning.md` §3.9）。**ここで判定を「満たした」に変える。** 条件が名指しする 4 module がすべて出た。**校正の輪も閉じた** —— 上に書いた 3 段（格子点を見つける / 係数を解く / 係数で補正する）の 2 段目がこれで、**利用者は係数を別の手段で得る必要が無くなった。** **費用は前もって書いたとおりだった** —— 構成ハッシュが `4785d98e9aad` → `09fcbe260d87` に変わり、5 platform 分の OpenCV を作り直した（run 33589583504）。**予想していなかったことが 1 つある**: 最初のビルドは 4 platform とも**依存 allowlist で落ちた**。`calib` が `stereo` を推移的に引き込み、`tools/verify-opencv-artifact.ps1` の許可リストに無いとして拒否された。**検査が意図どおり働いた例である** —— 気づかずに通ることはなかった。`stereo` は OpenCV 本体の module で third-party ではなく、新しい bundled 依存も持ち込まない（同じビルドの install ログに `stereo` 由来の `etc/licenses` は 1 件も現れない）。このプラグインは `stereo` のシンボルを 1 つも参照しないので、静的リンクの性質上、配布する binary には入らない。**（この 1 文は 2026-09-05 に失効した —— `ocvu_compute_disparity` が `cv::StereoBM` / `cv::StereoSGBM` を参照するようになり、`stereo` は `COMPONENTS` に入って配布する binary にも入る。M5 時点の記録として残す。）****`geometry` のときと違い、`COMPONENTS` の追加は本物の RED を出した** —— `cv::calibrateCamera` を参照する L1 テストを先に書くと未解決の外部シンボルでリンクに失敗し、`COMPONENTS` に足すと通った。**この時点では binary は 1 バイトも増えず**（21,190,144 のまま）、増えたのは関数を実装したときである（21,464,576 バイト、+274,432）。**「満たした」と書くにあたって、出していないものを明記する。** `calib` module には `stereoCalibrate`（ステレオ校正）・`calibrateHandEye`・魚眼系があり、`geometry` 側の `solvePnP`（既知の係数から 1 枚ぶんの姿勢を求める）も出していない。**（`solvePnP` は 2026-09 の API 拡張で出した。M5 時点の記録として残す。）****出したのは単眼カメラの校正 1 本である。**「`calib` を出した」は「`calib` の全部を出した」ではない。**選んだ動機についても、上に書いたのと同じ正直さを保つ。** ただし `calib` だけは他の 3 module と性質が違う —— これは「安くて実証に向くから」ではなく、**歪み補正を出したのに係数を求められないという、実際に閉じていない輪を閉じるために足した。** 費用が高いと分かったうえで足した唯一の module である。 |

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
| 5 | 生成された P/Invoke が IL2CPP stripping を生き延びることを L5 で確認 | **満たす（実証済み）**。`AbiReachabilityChecks.g.cs` が **spec の宣言を 1 本残らず 1 回ずつ**呼び（除外は `ocvu_debug_crash` の 1 本だけ。呼ぶと戻ってこない）、EditMode と PlayMode の両方が 1 件のテストとして通す。実物の IL2CPP Player で `==> [player] 19 passed`（**M5 時点の実測である。** その後 2026-09 の API 拡張で EditMode / Player とも件数が増えたが、**当時の run が出した値なので書き換えない** —— 現在の件数の正本は `CLAUDE.md` のテストレーンの表である）。`NativeMethods.Infra.g.cs` の `ocvu_get_status_value` に存在しない `EntryPoint` を仕込むと **34 件中 1 件だけ**が `System.EntryPointNotFoundException` で落ちた —— **この関数は M5 の前は Editor でも Player でも一度も呼ばれておらず、同じ壊し方をしても 33 件が全部緑だった** |

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

Web を、**Unity 同梱 Emscripten と整合した形**で獲得する。

> **訂正（2026-09-03）。この節は長らく「競合が持たない Web 対応」と書いていたが、
> 誤りである。** 同じリポジトリの
> [競合調査](./unity-opencv-integration-research-and-plan.md) §4.2 が
> **Enox の OpenCV for Unity は WebGL に対応している**と書いており（$95、
> OpenCV 4.13.0、2026-08-25 時点）、比較表の platform 行にも WebGL が並んでいる。
> **有償の競合に対して、Web は差別化ではない —— 追いつく側である。**
>
> **持っていないのは OSS の側である。** 同 §4.3 の
> `neon-izm/OpenCV-plus-Unity`（OpenCV 4.11 / OpenCvSharp 依存）は
> **Web / WebGL を対象一覧に持たない。** したがって Web の位置づけは
> **「Apache-2.0 で、OpenCV 5 で、OpenCvSharp に依存せず、Web でも動く」
> という組み合わせが他に無い**ことであって、Web 単体ではない。
>
> **この訂正で M6 の価値が下がることは認める。** それでも順序を変えないのは、
> Web が**このリポジトリの構造をもう一度試す**からである（下記）。

**Web が構造を試すという意味**: Web は **platform を 1 つ増やす作業**であり、
**クロスビルドかつ静的ライブラリ**という iOS と同じ 2 つの性質を持つ。
M4 で「クロスビルドが緑になってから CI で 8 回落ちた」経路を、
**足場が変わった後（M5 で宣言が生成物になった後）にもう一度通る。**

**整合性の維持が継続的な作業になる理由**（M0 の頃は抽象論だったが、実測が付いた）:
**Unity 6000.3.16f1 が同梱するのは Emscripten 3.1.39-git、commit
`a2ee372fd4bf28c71c2bd8ab1bd74af016ff1bf9`（2023-05-15）である。**
**2 年以上前の toolchain に固定される**ということで、
LLVM はバージョン間のバイナリ互換を保証しないので、
**Unity を上げた日に、こちらの wasm が黙って合わなくなりうる。**

**ゴール**

Unity Web Player 上で、**他の platform と同じ検証本体が通る。**

- `tests/UnityProject/Assets/Tests/Shared/` の検証本体が Web Player で通る
  —— **EditMode / IL2CPP Player と同じものを使う。写して 3 つ目を作らない**
  （写すと「Editor と Player と Web で同じ結果」を確かめられなくなる）。
  **1 件だけ Web で経路が変わる** —— encode / decode の検査は PNG ではなく
  JPEG を使うので、**画素の一致までは主張しない**（下の「Web にだけ在る制限」）
- **`AbiReachabilityChecks.g.cs`** が spec の載せる宣言を Web でも 1 本残らず
  呼べる —— **stripping が消せるのは呼ばれない宣言なので、これを確かめられるのは
  Player だけである**
- 全部入りの package に WebGL が入り、**Unity が Web の物だけを有効にする**

**完了条件**

- Unity version と Emscripten version の対応表を作り、CI で不一致を検出する。
  **対応表は写しなので、それ 1 つでは足りない** —— 表の自己整合を見る検査と、
  **Unity が実際に同梱する版と突き合わせる検査**を対にする
- Unity 同梱 Emscripten で Wasm object (`.o`) を生成し `.a` にまとめる。
  **「まとめた」ことを実証する** —— **iOS ではこれを見る検査が 2 本とも空振り
  していた**（`ar t` は OpenCV ではなく自分の object に当たり、
  `nm -u | match 'cv::'` は nm が demangle しないので決して真にならない）
- single-thread / SIMD を先に成立させる。**flag を外すと落ちる**ことまで見る
  （M4 の 16 KB page size と同じ形）
- **全部入りに WebGL が入り、gating が Web の物だけを有効にする**
  （**2026-09-03 に足した条件。** M4 の判定で「ビルドできる／配れる／動く」は
  別物だと決めたのに、**Web だけ「配れる」の条件が無かった**）
- Web Player の起動、P/Invoke、メモリ転送、代表処理の browser E2E test。
  **「0 件で緑にしない」をここでも守る**

**Web にだけ在る制限**（2026-09-03 に実測して確定）

- **`imgcodecs` は JPEG のみ。PNG は持たない。** Unity の WebGL 支援は
  **自前の libpng を同梱している**ので、こちらが OpenCV の libpng を束ねると
  Player のリンク段でシンボルが衝突する（9 シンボル 27 件。
  `wasm-ld: error: duplicate symbol: png_get_eXIf`）。**束ねないほうも
  成立しない** —— Unity 同梱は古い部分集合で、OpenCV の PNG コードが要求する
  60 シンボルが未解決になる。**どちらの極端も通らないので、Web では
  PNG を外した。他の 5 platform は PNG / JPEG の両方を持つ。**
- **`DllImport` の名前が違う。** 静的リンクなので `__Internal` である
  （iOS と同じ）。**これは利用者には見えない**（生成物が扱う）。

**非ゴール**

- **threads profile**（別 profile として後続）
- **配ること** —— 2026-09-03 に「M6 の後にまとめて配る」と
  決めた（「配布 その 5」）。**M6 の完了条件に配布は含まれない**
- **`dnn`**（M7 の担当。**OpenCV 5.0 で作り込むと 5.1 で作り直しになる**根拠が
  M7 節にある）
- **新しい ABI 関数** —— platform を足すのであって API を足すのではない。
  `OCVU_ABI_VERSION` は 1 のままである

**実装計画**: [`docs/superpowers/plans/2026-09-03-m6-web-wasm.md`](./superpowers/plans/2026-09-03-m6-web-wasm.md)（Task 7 本）

### M6 の判定（2026-09-03。**5 件すべてを満たした**）

**PR #63 が main に入った（`1e68d27`）。根拠はすべて CI の実測である** ——
同じレーンをローカルでも回しているが、**merge 可否を決めるのは CI である**
（`CLAUDE.md` の不変条件）。**引用は run 33735249473（`ci-native`）と
run 33735249747（`ci-unity`）から取っている** —— どの実行かを書かない実測は、
後から確かめられない。

| # | 完了条件 | 判定 | 根拠（CI の実測） |
| --- | --- | --- | --- |
| 1 | Unity / Emscripten の対応表と、CI での不一致検出。**表の自己整合と、Unity の実物との突き合わせを対にする** | **満たした** | 対は成立している。自己整合は `tools/tests/EmscriptenVersion.Tests.ps1`（速いレーン）、実物との突き合わせは `Web browser E2E` job が `assert-emscripten-version.ps1` で行う: `OK: Unity 6000.3.16f1 が同梱する Emscripten は 3.1.39-git で、対応表 ('6000.3' = 3.1.39) と一致します。` **SKIP の経路を作っていない** —— WebGL の Player を建てられる時点で Unity と WebGL 支援は必ず在るので、「道具が無いから飛ばす」が構造的に生まれない |
| 2 | Wasm object を生成し `.a` にまとめる。**まとめたことを実証する** | **満たした** | `Web wasm32 (cross-build)`: `_ZN2cv を含む定義済み: 5547` / `同・未定義（member ごと）: 3967` / **`archive 内に定義が無い未定義: 0`** / `ocvu_ を含む定義済み: 27`。**iOS が踏んだ空振りを繰り返さない形にしてある** —— `nm` は archive の member ごとに未定義を報告するので「未定義が無い」は誤り。**定義の差集合**を見る。`ocvu_` の側も数えるのは、**docstring が主張する保護が実際には無かった**とレビューが実測したためで、実際にこの検査が「`.a` を 8 バイトのダミーで上書きした」事故を捕まえた |
| 3 | single-thread / SIMD。**flag を外すと落ちる**まで | **満たした** | 配る `.a`: `wasm module 数 461` / `target_features: mutable-globals, shared-mem, sign-ext, simd128` / `OK: 要求 [simd128] は在り、禁止 [atomics] は無い。` **和集合では弱い**ので、こちらの object だけの archive に**全 module 要求**でも当てる: `wasm module 数 14` / `Require を持たない module: 0 / 14`。**外部の道具に頼らず wasm の section を直接読む。****ただし条件の後半（「flag を外すと落ちる」）は、形そのものが変わった** —— `-msimd128` は選択ではなく**必要**だった（OpenCV の `intrin_wasm.hpp` が `always_inline function 'wasm_f32x4_add' requires target feature 'simd128'` で止まる）。したがって負の対照は「flag を外すと wasm から SIMD 命令が消える」ではなく「**flag を外すとコンパイルが通らない**」である。**SIMD 無しの wasm ビルドはこの構成では成立しない。** M4 の 16 KB page size（外すと検査が赤くなる）と同じ形にはならなかった —— **より強い形に落ちたが、同じ形ではないことは記録しておく** |
| 4 | 全部入りに WebGL が入り、gating が Web の物だけを有効にする | **満たした** | `Unity EditMode (Linux)`: `native plugins present: 6 [libopencv_unity_native.a, ...]` と `PluginGatingTests` 4 件が個別に passed。**`.meta` を自分で読むのではなく Unity に問う** —— M4 で `iPhone:` と書いて YAML としては正しいまま無効になった経験から、この形にしてある。**負の対照も取った** —— `WebGL:` を `iPhone:` に壊すと exit 2 で落ちる（row 3 と違い、こちらは M4 の 16 KB と同じ形になった）。`Unity Standalone (Linux)` も `Runtime/Plugins/WebGL/libopencv_unity_native.a` とその `.meta` の存在を出す |
| 5 | Web Player の browser E2E。**0 件で緑にしない** | **満たした** | `Web browser E2E`: `OCVU_WEB_RESULT: passed=8 failed=0 reachable=28` / `==> [web] 共有本体の検査 8 件がすべて走った` / `==> [web] OK`（**M6 時点の実測である。** その後 2026-09 の API 拡張で共有本体が 21 件に増え `reachable` も増えたが、**当時の run が出した値なので書き換えない**）。**下限だけを見ない** —— `passed` が**共有本体から数えた件数と完全一致**することを要求するので、**1 件でも消えれば緑にならない**（レビューの指摘で下限から一致に変えた。**件数を写さないので、共有本体が 8 件から 21 件に増えても検査は自動で追随した**） |

**このマイルストーンの価値は、Web が動いたことよりも、Web でしか出ない欠陥を
7 件捕まえたことにある。うち 1 件は `CLAUDE.md` の中核の不変条件が Web でだけ
黙って成立していなかったもの**である ——
Emscripten は既定で C++ 例外を無効にするので、`throw` は残るのに `catch` が
1 つも組み込まれない（`__cxa_throw` 244 件に対し `__cxa_begin_catch` 0 件）。
**L1 も L3 も host で走るのでこの形は出ず、ブラウザで OpenCV が実際に投げて
初めて出た。** `-fexceptions` を**投げる側（OpenCV）と捕まえる側（plugin）の
両方**に入れて 0 → 68 件になった。

**Web にだけ在る制限を 1 つ確定した**（上の「Web にだけ在る制限」）——
`imgcodecs` は JPEG のみで、PNG を持たない。**利用者が読む 3 文書**
（`README.md` / `README.ja.md` / `.github/release-notes.md`）に書いてある ——
**最後の 1 つは実際に配られる Release の本文**で、レビューが「利用者が最初に
読むのはそこなのに書いていない」と指摘するまで抜けていた。

**CI が 5 往復で欠陥を 9 件出した。9 件とも「手元では緑」である。**
レビュー 3 回（指摘 36 件）を通した後の差分に、である。内訳と、そこから
出た一般則は PR #63 の本文にある（**ここに再掲しない**）。**そのうち 1 件は
`release.yml` の「未知の platform は失敗させる」門が 2 箇所あり、後者にだけ
足して前者に足し忘れたもの**で、**`pack-upm-tarball.ps1` の switch・
`PackageRelease.Tests.ps1` の 3 つ目の一覧に続く 3 度目の
「同一ファイルの 2 つ目の一覧」だった。** `tools/tests/OpenCvConfig.Tests.ps1`
に検査を足してある（**一覧を持たず、正本から読んだ全 platform が
すべての門に現れることだけを見る**。壊して 2 通りで確かめた）。

**満たしていないもの / 意図してやっていないことを明記する。**

- **（解消済み）M6 が足した 3 本の check を必須にするかは、M6 の時点では決着していなかった**
  （`Web wasm32 (cross-build)` / `Web browser E2E` / `Package web-wasm`）。
  `CLAUDE.md` の規律は「**安定して緑になったのを見てから必須へ加える**」で、
  **モバイルの 2 本も M4 の直後は必須外で、後から昇格した。**
  **2026-09-10 に同じ手順で昇格させ、この項は解消した** —— #63 以降に merge された
  11 本の PR すべてで 3 本とも success だった（実測）。
  **現在どれが必須かをここには書かない** —— 記載場所は `CLAUDE.md` の
  「機構として強制されていること」の表 1 行だけで、正本はさらにその先の
  GitHub 側の設定である
- **配ることは M6 の完了条件に含まれない**（非ゴール）。**判定した時点では、
  利用者に届く最新版は v0.2.0 だった** —— M4 の 5 platform も、M5 の生成器と
  校正 API も、M6 の Web も、まだ誰の手にも渡っていなかった。
  **2026-09-04 に v0.3.0 として配って解消した**（「配布 その 5」）
- **threads profile / `dnn` / 新しい ABI 関数**は非ゴールのまま。
  `OCVU_ABI_VERSION` は 1 から動いていない

### M4 / M5 の後に着手するとき、何が変わっているか（2026-09-03 に追記）

> **この節は着手する前に書いた。M6 は済んだので、いまは「何が実際に起きたか」
> として読むこと。** 予想が当たった箇所と外れた箇所を、下に括弧で足してある。

**この節は M0 の頃に書き、M6 の着手前に書き足した。M6 は済んだので、いまは「何が実際に起きたか」として読む。**

- **platform を足す作業は 17 箇所に触る。** 一覧を持つ場所は語彙が違うので grep 1 回では
  揃わない。`add-a-platform` skill に、M4 で**クロスビルドが緑になってから CI で 8 回落ちた**
  罠が踏んだ順に並べてある。**Web は 6 つ目の platform になった。**
  **実際に触ったのは 17 箇所では足りず、CI が 5 往復して 9 件を出した**
  （内訳は PR #63 の本文）。
- **境界の宣言はもう手で書かない。** `bindings/spec/*.json` が正本で、C ヘッダ・C# の
  P/Invoke・到達性テスト・API 対応表が同時に生成される（M5）。**Web でも同じ経路を通る** ——
  **`DllImport` の形は実際に変わった** —— Web は静的リンクなので `__Internal` である
  （iOS と同じ）。**ただし生成器は触っていない** —— 名前は手書きの
  `NativeMethods.cs` が持つ 1 つの定数なので、そこの条件を 1 つ増やして済んだ。
  **その 1 行が抜けていたのが M6 の欠陥 #1 で、ビルドもリンクも Player の起動も
  通り、呼んだ瞬間に落ちた。**
- **依存 allowlist が捕まえるのは、artifact の中に独立したライブラリとして現れる依存だけである。**
  `calib` を足したとき、推移的に引かれた
  `stereo` で 4 platform とも最初のビルドが落ちた（2026-09-02）。**Emscripten でも
  同じ検査が働く** —— 落ちたら、引き込まれたものを確かめてから明示的に足す。
  **ただし限界がある**（M7c で実測）—— 別のライブラリの中へ静的に取り込まれた
  third-party は allowlist に何も見えない。`dnn` が引き込む MLAS / ONNX Runtime は
  `libopencv_dnn.a` の一部になっており、`protobuf` は捕まったのにこの 2 つは
  捕まらなかった（`### M7c の判定`）。
- **`OCVU_ABI_VERSION` は 1 のままである。** M5 は移設であって追加ではなく、
  module を足しても版は動いていない。

**配ることは、着手する前ではなく後になった。** M4 と M5 の成果はまだ利用者に
届いていないが（「配布 その 5」）、**2026-09-03 に「M6 が片づいたところで
まとめて配る」と決めた。** **M6 は、届いていない成果の上に
さらに積む形になった** —— Web を足しても届かなければ差別化にならない、という
懸念は**まだ消えていない。後払いの期限が来ただけである** ——
**次にやることは配ることである**（「配布 その 5」）。

→ **2026-09-04 に v0.3.0 として配った**（「配布 その 5」）。M4 / M5 / M6 の成果は
これで届き、この懸念は解消した。**同じ形は M7 で戻ってきている** —— **M7 の成果
（`dnn` を含む）はまだどの公開版にも入っていない。**

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
とっては推論エンジンが OpenCV だけではない）。~~**前倒しの判断は利用例が集まってから
行う。**~~ → **前倒しはしなかったが、M7 の中で M7c として実際に出した（2026-09-10）。**
着手の根拠は「利用例が集まったこと」でも「上流が安定したこと」でもなく、
**リポジトリ所有者が 5.1 での作り直しの費用を承知のうえで受け入れると判断したこと**
である（下の「この決定は解除された」）。**この節が挙げる上流の実測は、いまも
そのまま成立している。**

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
   → **M5 で済んだ（2026-09-01）。** 関数宣言は module ごとのヘッダ
   `native/include/ocvu/*.h` に分かれ（**module 名を写さない** —— 正本は
   `bindings/spec/*.json` のファイル名である）、
   `opencv_unity_native.h` に残ったのは型・status・定数だけである。**ただし分けたのは
   ヘッダであって CMake target ではない** —— まだ 1 つの target が全 module を作る。
   → **M7b で、target ではなく「その target に何を入れるか」を分けた（2026-09-06）。**
   `native/modules.cmake` の `OCVU_MODULES` が `OCVU_SOURCES` に組み込む module を選び、
   除いた module の関数は binary から消える —— `tools/verify-exported-symbols.ps1` が
   配布 binary の export 面と spec の完全一致を CI で見ており（3 platform とも `ocvu_`
   の export が spec の関数一覧と過不足なく一致した。**本数をここに写さない** ——
   検査の性質は数に依らないし、正本は `docs/api-map.md` の冒頭である）、
   `OCVU_MODULES` を意図的に絞ると外した
   module の関数が実際に export 面から消えることも確認済みである。**target はいまも
   1 つのままで、これは実装漏れではなく分けられないからである** —— `native/CMakeLists.txt`
   は同じソースを 2 回コンパイルする（配布物の `opencv_unity_native` に
   `OCVU_BUILDING_DLL`、L1 テストが DLL の非公開な内部シンボルへ届くための
   `ocvu_static` に `OCVU_STATIC` を PUBLIC）。CMake の OBJECT ライブラリは 1 回しか
   コンパイルできないので、この 2 target を 1 つの OBJECT で賄うことはできない。
   `OCVU_ABI_VERSION` を単一の整数のままにする判断とその留保は
   [所有権と versioning](./abi-ownership-and-versioning.md) §2 に書いた（**正本はあちら**）。
   profile と module 一覧の規約は同文書 §4 に書いた。
2. **C# 側も別 assembly にする。** `Runtime/Core` / `Runtime/Interop` の分離
   （`UnityEngine` を参照しない）と同じ理由で、**dnn が入らないビルドで参照が壊れない**形にする。
   → **M5 では手を付けていない。** `Runtime/Interop` は 1 つの assembly のままで、
   生成された `NativeMethods.<module>.g.cs` は `partial class` で同じ型に入る。
   → **M7b で機構を作った（2026-09-06）。ただし「dnn が分離できた」ではなく
   「分離する機構が働くことを確かめた」である。** spec の `profile`（既定 `standard`）
   が `dnn` なら、生成器は宣言を別クラス `NativeMethodsDnn`・別 assembly
   `CvUnity.Interop.Dnn`・別出力先 `Runtime/Interop.Dnn/` へ出す（規約は
   [所有権と versioning](./abi-ownership-and-versioning.md) §4 が正本）。Unity 側にも
   `CvUnity.Interop.Dnn`（`defineConstraints: ["OCVU_PROFILE_DNN"]`）と、その到達性
   テストを持つ `CvUnity.Tests.Shared.Dnn` を作り、define を実際に立てて Unity 自身に
   問うた —— 両 assembly が実際にコンパイルされ（`Library/ScriptAssemblies/` に両方の
   `.dll` が現れた）、define を外すとどちらも消えることを EditMode の
   `ProfileGatingTests`（4 件）で確かめた。**証明したのは「機構が働くこと」であって
   「dnn で働くこと」ではない** —— **~~`bindings/spec/dnn.json` はまだ無く、非 `standard`
   profile を宣言する module は現時点で 1 つも無いので、`CvUnity.Interop.Dnn` と
   `CvUnity.Tests.Shared.Dnn` はどちらも中身が空の assembly のままである。~~**
   → **M7c で本物の `dnn` が入った（2026-09-08〜10、`e1b0930`）。** `bindings/spec/dnn.json`
   が `"profile": "dnn"` を宣言し、C ABI 4 本が `NativeMethodsDnn` と `CvUnity.Dnn.CvDnn`
   まで通っている —— **両 assembly はもう空ではない**（`### M7c の判定`）。
   **取り消し線の 2 文を消さずに残してあるのは、同じ「まだ無い」という前提が別の場所に
   残っていないかを次に読む人が確かめられるようにするためである**（[所有権と versioning](./abi-ownership-and-versioning.md)
   §4 が同じ形で処理している）。
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
4. **`dnn` を allowlist に足すのは、上の 1〜3 が済んでから。** ~~現在の `Modules` に
   **dnn は入っていない**。~~ 足すと OpenCV 側のビルド時間と成果物サイズが変わる。
   **あわせて `THIRD_PARTY_NOTICES.md` の作業が要る** ——
   同文書が明文で指示している: *"If a future `Modules` list adds `dnn` or `gapi`, re-run these
   searches — they will very likely start matching, and these two need to move up into the
   reproduced sections above."* dlpack と flatbuffers はいま「ライセンスディレクトリにあるが
   リンクされていない」側に分類されており、**`dnn` を足すとその分類が崩れる**（protobuf も入る）。

   → **M7c で足した（2026-09-08）。** `tools/opencv-config.psd1` の `Modules` に `dnn` が
   入っている（**一覧をここに写さない。正本は同ファイルである**）—— 構成ハッシュが変わり、
   全 platform 分の OpenCV を作り直した。**予告した notice の作業も実際に起きた**:
   `protobuf` が新しく入り、**`flatbuffers` は「あるがリンクされていない」側から
   リンク済みの側へ移った**（`dnn` の TFLite importer が読む側で使う。実物の
   `opencv_dnn` を Windows / Linux の 2 つの名前修飾で grep して確かめてある）。
   **`dlpack` は移らなかった** —— どの `.a` にも 1 件も現れないので、いまも
   「あるがリンクされていない」側にある。**予告は「2 つとも崩れる」だったが、
   実際に崩れたのは 1 つだけである。**
5. **CUDA / cuDNN を同梱するなら、2 つの前提条件を先に潰す。** どちらも技術判断ではない。

   - **再配布の可否（未確認）。** 「本体が Apache-2.0」と「binary 内の全依存が Apache-2.0」は
     別問題である（計画書 §8.2。ただし同節が扱うのは FFmpeg / JPEG / PNG 等で、**CUDA / cuDNN には
     触れていない**）。cuDNN は NVIDIA のライセンス条項の下にあるが、**その条項を読んでいない。**
     ここは「確かめていない」であって「配れない」ではない
   - **大きさ（ライセンスより先に効く）。** **実測（2026-08-30、PyPI の
     `nvidia-cudnn-cu12` 9.25.1.1）: 1 platform あたり 698〜772 MB**（win_amd64 698.4 /
     manylinux x86_64 716.4 / aarch64 772.1）。`tools/pack-upm-tarball.ps1` の上限は
     **512 MB** で、全部入りは **69,565,901 バイト（66 MB。v0.3.0 の実物の release asset、
     6 platform、2026-09-06 に実測し直した ——「3 platform 時点の実測で 9.6 MB」は
     platform が増えて古くなっていた数字だった）**である。**1 platform 分だけで既に上限を超える** ——
     ライセンスが解決しても、いまの形では配れない。同梱するのか、利用者側での導入を
     前提にするのかを決める必要がある。**ORT + NVIDIA execution provider の経路
     （根拠 1 で残ったほう）も同じ問いに突き当たる。**

   → **決定した（2026-09-06）: CUDA / cuDNN は同梱しない。** 決め手は大きさであって
   ライセンスではない —— 上の再配布可否はいまも確かめていないままである（この文は
   弱めない。読んだ、許可が取れた、という事実は無い）。決められた理由は、ライセンスの
   答えを待たずとも、上で実測した 1 platform 分の大きさだけで `tools/pack-upm-tarball.ps1`
   の上限を単独で超えており、全部入り tarball という**いまの配布形態**には収まらないと
   分かるからである。**この決定が縛るのは「同梱」だけである。** 利用者が自分の環境へ
   CUDA / cuDNN を別途導入してこのプラグインと組み合わせること、あるいは native artifact
   をいまの全部入り tarball とは別の経路（`pack-upm-tarball.ps1` の上限に縛られない、
   大きな optional download 等）で配ることは、この決定の対象外であり、**どちらも
   再配布可否の確認をまだ経ていない**。配布の形自体を変えるかどうかは、下の
   「まだ決めていないこと」の 2 番目（dnn を別 package にするか）にかかっている。

   **再評価の条件は 1 つだけである**: 配布形態が変わり、CUDA / cuDNN を同梱しても
   配布物の上限に収まるようになったとき。そのとき、**大きさによる決着は失効し、
   読んでいない再配布条件の確認が再び必要になる。** それまでは、この決定を再検討する
   理由は無い。

   したがって CUDA backend は完了条件に含めない。

**この決定は解除された（gate lift、2026-09-08、リポジトリ所有者の依頼）。**
`docs/superpowers/plans/2026-09-05-m7c-dnn-profile.md` が着手の前提として掲げていた
2 つ —— (1) module 分離が済んでいること、(2) 利用者の要望か上流の安定を示す新しい
事実が出ていること —— のうち、(1) は `### M7b の判定` が 2026-09-06 に満たした。

(2) は、2026-09-08 にリポジトリ所有者とのやり取りで満たした。まず、所有者が
何を決めるべきかを尋ねた（原文のまま引用する）:

> 次に dnn を別 package で配るか、同じ package の optional profile にするか。M3.5 で「全部入り tarball が配る正」と決着したので、これは「中身を足す」ではなく形を変える判断になりえます。M7c の計画に検討はありますが、決定はしていません。の部分を決めて残りのタスクを進めたいです。これは何を決めたらいいですか？そのための判断として何を判断をしたらいいですか？

これに対し、上で挙げた 5.1 での作り直しリスク（旧エンジンの削除・`enum EngineType`
の再番号・`OPENCV_FORCE_DNN_ENGINE` の意味変化という上流の実測と、それに基づく
「5.0 で作り込むと 5.1 で作り直しになる」という帰結）を明示的に提示したうえで、
所有者は次のとおり答えた（これも原文のまま引用する）:

> 進めてください

**この 2 つの発言は、順序があって初めて意味を持つ。** 所有者はまず何を決めるべきか
を尋ね、作り直しの費用を提示されたうえで許可した——文脈を欠いた「進めてください」
だけを引用したのでは、リスクを見ずに出た指示なのか、承知のうえでの指示なのかが
区別できない。

**この経緯の記録は、この commit にしか無い。** やり取りは所有者との会話で行われ、
紐づく issue も ticket も、外部の記録も存在しない。ここに引用した 2 つの発言と
commit のメタデータ以外に、後から確かめる手立ては無い。

**元の決定を支えていた根拠は、これによって否定されてはいない。** 旧エンジンの
削除、`enum EngineType` の再番号、`OPENCV_FORCE_DNN_ENGINE` の意味変化という上流の
実測はいまも成立したままで、**上流の安定を示す新しい証拠は出ていない。** 変わった
のはただ 1 点 —— **リポジトリ所有者が、その作り直しの費用を承知のうえで受け入れる
と判断したこと**である。**したがって、5.0 の DNN API に対して作るコードは、5.1 が
来たときに作り直しが要ると見込んでよい。** 後でこれに驚く読み手が出るなら、この文を
ここに見つけられるようにしてある。

**まだ決めていないこと**（M5 / M7 で決める）

- **`OCVU_ABI_VERSION` は単一の整数のまま**である（正本は
  `docs/abi-ownership-and-versioning.md` §2 の「決定」。ここで再オープンしない）。
  module 分離がこの決定に影響しうるなら、**正本のほうに留保を書く**
- ~~dnn を**別 package**（`…-dnn`）で配るか、同じ package の optional profile にするか。~~
  **2026-09-10 に、隣接するもう 1 つの問い（全部入り tarball を 1 つの artifact の
  ままにするか）も決まり、2 つとも決定になった** —— native binary を分けない
  （2026-09-08 決定）ことに加え、**全部入り tarball もそのまま 1 つの artifact
  でよい**と決めた。詳細と理由、間違っていた場合のコストは下の「dnn の配布の形」
- GPU backend を持つ版の platform matrix（CUDA の版 × OS）。現在の platform × 1 構成が何倍になるか（**platform 数をここに書かない。正本は `tools/opencv-config.psd1` の `Toolchains`**）。**「CUDA / cuDNN は同梱しない」と決めている間（上の決定 5）、この問いに答える対象が無い** —— 決定が再評価されて同梱する方向に変われば、この行がまた意味を持つので、消さずに残してある

**dnn の配布の形**（2 つの問いのうち 1 つだけ決まった。2026-09-08）

**決まった: native binary を profile ごとに分けない。1 つの binary を配り、gate は
C# 側が持つ。** 好みではなく構造上の理由による —— `Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.cs`
は iOS と WebGL で `DllImport("__Internal")` を選ぶ（`#if (UNITY_IOS || UNITY_WEBGL) && !UNITY_EDITOR`）。
この 2 platform では plugin が Player の binary へ静的にリンクされ、**切り替える
対象のライブラリ名がそもそも存在しない。** したがって native binary を 2 本配り
`DllImport` に選ばせるという形は、6 platform のうち 2 つで成立しない。**費用も
記録しておく** —— dnn のコードは、profile を一度も有効にしない利用者にも配られる
ことになる。

**決定（2026-09-10）: 全部入り tarball は 1 つの artifact のままにする。** 増分を
測ったところ `release.yml` の「Assemble the release assets」が実際に落ちた
（run 34319553823、PR #72: `package が上限を超えた: 124101923 > 104857600`。
約 18 MB の超過）。**当初は下の 3 択で比較する想定だったが、原因を実測したら
どれも要らなかった。**

ELF のセクションを直接読んで超過の内訳を調べたところ、**犯人は dnn ではなく
Android の `.so` に前から積もっていた DWARF デバッグ情報だった。** dnn を足す前の
v0.3.0 の Android `.so`（99,463,016 バイト）を同じ方法で測っても、既に
**82%（81,220,732 バイト）が `.debug_*` セクション**で、実行に要る部分は
1 割強しか無い。dnn を足した後の実物（同じ run の実測、258,995,040 バイト）は
**86%（約 224 MB）がデバッグ情報**まで悪化しており、dnn は原因ではなく
**閾値を越えさせた側**だった。Windows は `.pdb` に分離するので実行体は増えず、
macOS の `.dylib`（29 MB）と Linux の `.so`（デバッグ情報は総量の 7% 程度）は
問題にならない。iOS / Web は Unity 側が最終リンクする**静的アーカイブ**を配る
ため話が違い、この決定では触っていない。

**対応: Android の `.so` だけ、リンク後に `llvm-strip --strip-unneeded` を掛ける**
（`native/CMakeLists.txt`、`CMAKE_SYSTEM_NAME STREQUAL "Android"` に限定した
POST_BUILD）。**置き場所を選んだ理由**: `tools/opencv-config.psd1` の構成ハッシュ
（`Get-OpenCvConfigHash`）は同ファイルの内容だけを見ており `cmake/toolchains/*.cmake`
は対象外なので、toolchain file に書くと変更が構成ハッシュに反映されず、**復元済みの
OpenCV artifact がそのまま使われて flag が効かない**（16 KB page size の教訓と
同じ罠）。ここは OpenCV のビルドではなく**このプラグイン自身の最終リンク**を
変えるので、`native/CMakeLists.txt` に置けば済む。**安全性の実測**: strip 前後で
`.dynsym`（P/Invoke が解決に使う動的エクスポート）の `ocvu_` シンボルは 57 個
すべて一致し、`tools/verify-android-page-size.ps1` が見る PT_LOAD の `p_align`
も 16384 のまま変わらない。**実測（このマシン、実際に CI が生成した run
34319553823 の 6 platform artifact を材料に、`assemble-plugins.ps1` /
`pack-upm-tarball.ps1` / `measure-package-size.ps1` を実際に流して再現）**:
Android `.so` は 258,995,040 → 24,385,832 バイト、全部入り tarball は
124,102,343 → 77,528,652 バイト（上限 104,857,600 に対して約 27 MB の余裕）。
CI 自身での確認は `.superpowers/sdd/2026-09-05-m7c-dnn-profile/task-6-report.md`
にある。

**当初の 3 択（比較のため記録を残す。どれも選ばなかった）**:

1. **上限を上げる。** 倍増を捕まえるために約 1.5 倍で意図的に設定した余裕
   （`tools/pack-upm-tarball.ps1` の行）を弱めることになる
2. **別の `-dnn` tarball を配る。** 「配る正は全部入り 1 tarball」という M3.5 の
   決着を覆すことになり、利用者は 2 つの package の版を揃える必要が生じる
3. **dnn を全部入りに入れない。** `pack-upm-tarball.ps1` の上限に縛られない経路へ
   持ち出すことになる —— これは上の「決定: native bridge を module 単位に分ける」5 が
   CUDA / cuDNN について名指しした**まさにその形**である。**したがって、あの決定が
   「まだ確認していない」と明記した再配布可否の確認が、dnn 自身の配布物についても
   未解決のまま戻ってくる**（`### CUDA / cuDNN 同梱の判定` の「穴を隠さず書く」
   1 つ目の箇条）

**間違っていた場合のコスト**:

- **strip は無償ではない。** `.symtab` / `.strtab` を落とすので、利用者の実機で
  `opencv_unity_native.so` の内部で native crash が起きても、この binary 単体
  からは関数名を復元できない（symbolicate 用の debug package をどこにも
  発行していない）。**これは `PNG_ARM_NEON=off` と同じ形の取引であって、
  無条件の勝ちではない** —— 直すなら「配布物と対になる debug 情報の別経路
  （例えば Play Console 向けの native debug symbol table）を用意する」ことになる
- **原因が別にある将来の増加には、この対応は効かない。** デバッグ情報の比率を
  下げただけなので、dnn や他の module が実行に要るコード自体を大きく増やせば
  上限に再び当たりうる。そのときは上の 3 択が改めて選択肢に戻る
- iOS / Web の静的アーカイブは今回 measure しただけで対応していない
  （54 MB / 63 MB、いずれもリンクする側の事情が変わるため別判断）。
  そちらが将来ボトルネックになれば、この決定はその 2 platform には及ばない

**差別化としての位置づけは変えない。** 競合が書き直し前のエンジンを載せている点は
[競合調査](./unity-opencv-integration-research-and-plan.md) §3 / §4.6 のとおりで、
**Unity 利用者には推論エンジンの代替がある**という理由も変わらない。**変わったのは
「5.0 で作り込むと 5.1 で作り直しになる」という具体的な根拠が付いたこと**である。

**完了条件**

- profile ごとの native artifact、manifest、third-party notices（**2026-09-08: 「artifact」は
  profile ごとに分かれた binary を意味しない** —— native binary は分けないと決めた。上の
  「dnn の配布の形」参照）
- RenderTexture / native texture pointer / AsyncGPUReadback を使う低コピー経路の評価
- package size、startup time、frame time、allocation の benchmark を公開
- **`dnn` を足す前に、C ABI と C# の module 分離が済んでいること**（上の 1〜2）
- **CUDA / cuDNN を同梱するなら、再配布条件の確認が済んでいること**（上の 5）。
  確認できないなら**同梱しない**と決めて記録する

### M7a の判定（2026-09-06。**完了条件 5 件のうち 2 件を扱う**）

**M7 は当初 3 つの計画に分ける想定だった**（`docs/superpowers/plans/2026-09-05-m7-profiles-and-performance.md`。M5 で「生成の仕組みと module 追加を同時にやると切り分けられない」と判断したのと同じ理由）—— **3 つとも実行され（M7a / M7b は `be5615f`、M7c は `e1b0930`）、条件 5 だけが計画を経ないドキュメント上の決定として閉じた**（**この文はこの節を書いた 2026-09-06 の時点では「実行されたのは 2 計画」だった。M7c が 2026-09-10 に実行されて古くなり、直した** —— 判定節どうしの散文の参照が腐る、というこの branch が繰り返し踏んだ形の 4 例目である）。**M7a が担当するのは完了条件 2（低コピー経路の評価）と 3（benchmark の公開）だけである** —— 条件 1（profile ごとの native artifact 等）は当時まだどの計画の担当にもなっておらず、条件 4（C ABI / C# の module 分離）は M7b、条件 5（CUDA / cuDNN の再配布確認）は `### CUDA / cuDNN 同梱の判定` が担当する。**この節はその 2 件だけの判定であって、M7 全体の判定ではない** —— 条件 1・4・5 がそれぞれ何本閉じているかは、この節ではなく担当する計画・節自身の判定にある（条件 4 は `### M7b の判定`、条件 5 は `### CUDA / cuDNN 同梱の判定`、条件 1 は `### M7c の判定`）。ここに残数を書かないのは、担当する計画が閉じるたびにその数だけがこの節に取り残されて古くなるからである。

実装は `.superpowers/sdd/2026-09-05-m7a-low-copy-and-benchmarks/`（Task 1〜6）。実測はすべてこのマシン（Windows 10.0.22631、X64、Unity 6000.3.16f1、2026-09-05〜09-06）。詳細な数字と読み方は [性能](./performance.md) が正本で、ここには写さない。

| # | 完了条件 | 判定 |
| --- | --- | --- |
| 2 | `RenderTexture` / native texture pointer / `AsyncGPUReadback` を使う低コピー経路の評価 | **満たした。ただし実証の範囲は限定的である。** `RenderTextureConverter.ToMat`（同期）と `RequestMat`（`AsyncGPUReadback` を使う非同期）はどちらも実装し、実測した——`-nographics` の下では `RenderTexture.Create()` が true を返すのに読んだ画素が `205,205,205` になる（作れたが読めない）という落とし穴を実際に踏み、上下反転だけを行う `FillFlipped` を GPU 非依存の純粋関数として切り出して既存レーンで検証できる形にした。**残る 2 つの経路（`ToMat` / `RequestMat` そのもの）は Editor（Mono、グラフィックス有効）でしか実行したことがない。** **2026-09-11 にこの経路を CI へ配線した**（`ci-unity.yml` の `Graphics` レーン。実測 run 34612557397 で 7 passed）ので、「CI に配線しておらず、赤くても merge を止めない」という当時の記述と、それを支えていた `CiVisibilityTests` の位置づけも変わった —— **「CI から見えないテスト」の台帳から「必須レーンに居ないテスト」の台帳になった**（`Unity Graphics (Linux)` は非必須なので、**「赤くても merge を止めない」の半分はいまも真である**）。経緯は下の「GPU 経路を CI に載せる」。**`AsyncGPUReadback` は IL2CPP の Player で 1 度も走っていない** —— game-ci は Standalone Player を `-nographics` で起動しており（`run_tests.sh`）、**その指定は action 側にあってこちらからは外せない。****native texture pointer は評価のみで、実装していない**（やらないと決めた—— `GetNativeTexturePtr()` を CPU から読むにはレンダースレッドからグラフィックス API を呼ぶ必要があり、6 platform 分の分岐を持つ新しい subsystem になる。得られるはずのものと再評価の条件は [性能](./performance.md) にある） |
| 3 | package size、startup time、frame time、allocation の benchmark を公開 | **満たした。ただし性質が 2 つに分かれる。** package size（`PackageSize.Tests.ps1`）と allocation（L3 の `AllocationTests`）は**機械が assert し、CI が守り続ける**——ポインタ経路は 0 バイト、`byte[]` 経路はそれ以上であることを毎回確かめ、tarball が上限を超えれば落ちる。**frame time（境界のコピーと `RenderTexture`）と startup time は、公開したが assert していない**（設計 D1: 共有 CI ランナー上で時間を assert すると必ずフレークになる）。**startup time にはさらに留保がある** —— `BenchmarkRunner.MeasureFirstPInvoke` が実測した 1 µs は、同じ Player 実行内で他の PlayMode テストが先に P/Invoke を呼んでいる可能性が高く、**native ライブラリの真の初回ロードを捉えていない**（測れるものを測っただけで、測れていないものを測れたことにはしていない）。**`RenderTexture` の 2 経路は run をまたぐと大小が入れ替わることを実測した**（run A: sync 2562 / async 2841、run B: sync 1756 / async 1643）——「非同期のほうが速い／遅い」はどちらも主張できず、**時間を assert しない設計判断の裏づけになっている** |

**穴を隠さず書く。**

- **M7a は roadmap の差別化の穴 #9（「低コピー連携」を測っていない）を「部分的に解消」にした。** 「解消済み」としなかった理由は、上の 2 経路のうち `RenderTexture` / `AsyncGPUReadback` が実機で動く実行形態（IL2CPP Player）で 1 度も検証されておらず、`test-unity-graphics` が当時 CI に配線されていなかったため——（**後者は 2026-09-11 に解消した**。下の「GPU 経路を CI に載せる」）**満たしたことと実証されたことは同じではない**（`milestone-complete` skill）。
- **`test-unity-player` はこのマシンで、Player の後始末段階（`Stop-UnityTestPlayers` 内の `Get-CimInstance` 呼び出し）がハングする既知の欠陥を持つ。** テスト自体は完走し結果 XML も書かれるが、レーン全体が無音で固まる（`CLAUDE.md` が書く「Unity のレーンではクラッシュもハングも赤いテストにならない」という形そのもの）。M7a の変更が原因ではない（`git diff` でこの箇所に差分は無い）ので、この作業では直していない——本番の測定は、ハングしたプロセスを終了させたうえで `tools/assert-unity-results.ps1` を結果 XML に直接掛けて確認した（35 passed / exit 0）。
- **`BenchmarkRunner` の `Report` ヘルパーが `BenchmarkRunner.cs` と `GraphicsBenchmarkRunner.cs` に複製されている。** このリポジトリは「本体はここにしか無い」を繰り返し記録しており、片方だけ直る壊れ方をする。M7a では直していない。
- **この計画（M7a）が触れているのは条件 2・3 だけである。** dnn を opt-in profile として足す前提（C ABI / C# の module 分離、条件 4）にも、CUDA / cuDNN の再配布確認（条件 5）にも、条件 1（profile ごとの native artifact 等）にも触れていない。**それぞれの現在の状態は、この節ではなく担当する計画自身の判定にある**（条件 4 は `### M7b の判定`、条件 5 は `### CUDA / cuDNN 同梱の判定`、条件 1 は `### M7c の判定`）。

### M7b の判定（2026-09-06。**完了条件 5 件のうち 1 件を扱う**）

**M7b が担当するのは完了条件 4（C ABI と C# の module 分離）だけである**（M7a の節が担当割りを説明している）。実装は `.superpowers/sdd/2026-09-05-m7b-module-separation/`（Task 1〜5）。実測はすべてこのマシン（Windows 10.0.22631、X64、Unity 6000.3.16f1、2026-09-06）。

| # | 完了条件 | 判定 |
| --- | --- | --- |
| 4 | `dnn` を足す前に、C ABI と C# の module 分離が済んでいること（上の決定 1〜2） | **満たした。ただし「機構が通っている」であって「dnn を分離した」ではない。** native 側は `native/modules.cmake` の `OCVU_MODULES` が module 単位でソースを選べる形になり、`tools/verify-exported-symbols.ps1` が binary の export 面を spec と完全一致で照合する（desktop 3 platform とも `ocvu_` の export が spec の関数一覧と過不足なく一致。当時は 53 本で、**その後 M7c の `dnn` が加わって増えた —— 本数の正本は `docs/api-map.md` の冒頭である**。`ci-native.yml` で実測。**配る経路（`release.yml`）にも配線してあるが、そちらの実測はこの PR の CI が初回である**）。C# 側は spec の `profile` が非 `standard` の module を別 assembly（`CvUnity.Interop.Dnn` / `NativeMethodsDnn` / `Runtime/Interop.Dnn/`）へ出す生成器の分岐と、それを Unity に問う EditMode の `ProfileGatingTests` を作った——define（`OCVU_PROFILE_DNN`）を立てて両 assembly（`CvUnity.Interop.Dnn` と、その到達性テストを持つ `CvUnity.Tests.Shared.Dnn`）が実際にコンパイルされ、外すと両方消えることを Unity 自身に実測した。**さらに、合成した `profile: "dnn"` の spec から生成した実物のファイル 2 つ（`NativeMethods.Dnnprobe.g.cs` と `AbiReachabilityChecks.Dnn.g.cs`）が、define を立てた Unity で実際にコンパイルされることまで実測した**（2026-09-06。`Library/ScriptAssemblies/` に両 dll が現れた）—— **この一段は最終レビューで足した。** それまで確かめられていたのは「`defineConstraints` が**手書きの**コードを切る」ことまでで、**生成物を誰もコンパイルしていなかった**（その穴を通って欠陥が 1 件入っていた。下の「穴を隠さず書く」を参照）。**dnn の spec も実装もまだ無い**（**2026-09-06 時点の話である。M7c が 2026-09-10 に `bindings/spec/dnn.json` と C ABI 4 本を入れたので、いまは在る —— `### M7c の判定`**）—— 当時は `bindings/spec/dnn.json` が存在せず、非 `standard` profile を宣言する module は 0 個で、`CvUnity.Interop.Dnn` / `CvUnity.Tests.Shared.Dnn` はどちらも commit された状態では中身が空だった。決定の詳細は上の「決定: native bridge を module 単位に分ける」1・2、規約は [所有権と versioning](./abi-ownership-and-versioning.md) §4 |

**穴を隠さず書く。**

- **CMake target は 1 つのままである。** `modules.cmake` が組み立てるのは**ソースの一覧**であって、コンパイル済みの中間物ではない。`native/CMakeLists.txt` は同じソースを `opencv_unity_native`（`OCVU_BUILDING_DLL`）と `ocvu_static`（L1 テスト用、`OCVU_STATIC` を PUBLIC で持つ）へ **2 回コンパイルする**ので、1 度だけコンパイルして両方へ配る形は取れない —— 分けなかったのは実装漏れではない。
- **`-DOCVU_MODULES=...` は CMake キャッシュに sticky である。** 一度絞ると、`-UOCVU_MODULES` で明示的に外すかビルド木を作り直すまで既定へ戻らない。configure 時の `message`（既定でないときは `WARNING`）で状態を毎回可視化しているが、ローカルの速いレーンはこれを捕まえない —— 実物 binary の公開面を見るのは CI（`ci-native.yml` と `release.yml`）だけである。
- **非既定 profile の生成物は、2026-09-06 までコンパイルできなかった。** `[DllImport(LibraryName, ...)]` の `LibraryName` は手書きの `Runtime/Interop/NativeMethods.cs` にある `internal const` で、既定 profile はそれと同じ型の `partial` だから見えていた。**非既定 profile は別 assembly・別型なので見えず、CS0103 になる。** 最終レビューが合成 spec から生成してコンパイルし、実測して見つけた。**この branch の検査はどれも捕まえなかった** —— `ProfileTests` は出力の**文字列**、`BindingGenerator.Tests.ps1` は `--list-outputs` が返す**パス**、Task 4 の Unity 側の正の対照は**手書きの probe** を見ており、**生成物をコンパイルする経路が 1 本も無かった。** 直した形（生成器が `LibraryName` を `#if` 分岐ごと複製し、写し 2 つを `ProfileTests` が読み比べる）と、切り出さなかった理由は [所有権と versioning](./abi-ownership-and-versioning.md) §4 にある。
- **`ProfileGatingTests` が自動で見られるのは「切れている」方向だけである。** define を立てれば現れることは、define を変えて Unity をもう一度走らせないと確かめられない —— 1 回の EditMode 実行では原理的に届かないので、**正の方向は人が手で確かめる**（手順と最後の実測日は同テストの docstring にある）。綴り間違いだけは機械が塞いである（asmdef が実際に綴っている値と、テストが使う定数を突き合わせる）。
- **native の module 選択と C# の profile は別の軸で、互いを自動では決めない。** ある module を `OCVU_MODULES` に足しても、対応する spec の `profile` を書き換えない限り、その宣言は `standard` の assembly に出続ける。
- **この節が閉じたのは条件 4 だけである。** 条件 2・3 の状態は `### M7a の判定`、条件 5 の状態は `### CUDA / cuDNN 同梱の判定`、条件 1 の状態は `### M7c の判定` にある。**ここに残数を書かないのは、`### M7a の判定` が「残る 3 件」と書いて M7b がそれを 1 件消した瞬間に古くなったのと同じ壊れ方を、この節自身が再生産しないようにするためである。**

### CUDA / cuDNN 同梱の判定（2026-09-06。**完了条件 5 件のうち 1 件を扱う**）

**この節が担当するのは完了条件 5（CUDA / cuDNN の再配布確認）だけである。** 条件 2・3 の状態は `### M7a の判定`、条件 4 の状態は `### M7b の判定`、条件 1 の状態は `### M7c の判定` にある。**条件 1（profile ごとの native artifact、manifest、third-party notices）はこの節が触れていない。** 実装は伴わない —— 上の「決定: native bridge を module 単位に分ける」5 に決定を書き加えた、文書のみの変更である。

| # | 完了条件 | 判定 |
| --- | --- | --- |
| 5 | CUDA / cuDNN を同梱するなら、再配布条件の確認が済んでいること（上の 5）。確認できないなら**同梱しない**と決めて記録する | **満たした。** 上の「決定: native bridge を module 単位に分ける」5 で **CUDA / cuDNN は同梱しないと決定した**。決め手は大きさである —— 1 platform 分の cuDNN の実測値が `tools/pack-upm-tarball.ps1` の上限を単独で超えるため、**再配布条件（ライセンス）を確認するまでもなく**、いまの配布形態（全部入り 1 tarball）には収まらないと分かる。**ライセンス条項はいまも読んでいない** —— この判定は「読んで問題無いと分かった」からではなく「読まなくても大きさだけで結論が出た」からで、条件が求める 2 つの経路（確認が済んでいる／確認できないので同梱しないと決める）のうち後者を選んだ形である |

**穴を隠さず書く。**

- **この決定が縛るのは「同梱」だけである。** 利用者が自分の環境へ CUDA / cuDNN を別途導入してこのプラグインと組み合わせて使うこと、あるいは native artifact をいまの全部入り tarball とは別の経路（`tools/pack-upm-tarball.ps1` の上限に縛られない配布形態）で配ることには、この決定は及ばない。**そちらを選ぶ日が来たら、読んでいない再配布条件の確認がそのまま未解決で戻ってくる** —— 大きさが理由の決定は、大きさの制約が外れた瞬間に理由を失う。再評価の条件は決定本文（上の「決定: native bridge を module 単位に分ける」5）に書いてある。
- **「CUDA / cuDNN のライセンスは確認済み」と読んではいけない。** 確認したのは大きさだけで、ライセンス条項は今回も「確かめていない」側のままである。
- **この節が閉じたのは条件 5 だけである。** 条件 1 の状態は `### M7c の判定` にある。
- **判定節どうしの相互参照は散文であり、何も検査していない。** `ci-lint.yml` の documentation link check が見るのは通常の markdown リンク記法（角括弧の直後に丸括弧でリンク先を書く形）だけで、見出し名を backtick で引用しただけの参照（`M7c 自身の判定` のような文言）は対象外——実際、この節を新設した際に `### M7a の判定` と `### M7b の判定` の末尾がそれぞれ「条件 1・5 は M7c 自身の判定」と書いたまま古くなっているのを見つけて手で直した（本節を書いたコミットの直後）。**この警告を書いたその branch の中で、さらに 1 件（`### M7a の判定` 冒頭段落、末尾 2 箇所とは別の 3 箇所目）を見逃した** —— 人が 2 人がかりで洗ってなお取りこぼした実例であり、「原理的に壊れやすい」という一般論ではなく、この branch で実際に起きたことである。**次に判定節を足す・条件を閉じる人は、既存の判定節にある名指しの参照を自分で洗って直す必要があり、それを見落としても機械は気づかない。**

### M7c の判定（2026-09-10。**完了条件 5 件のうち 1 件を扱う**）

**この節が担当するのは完了条件 1（profile ごとの native artifact、manifest、third-party notices）だけである。** 条件 2・3 の状態は `### M7a の判定`、条件 4 の状態は `### M7b の判定`、条件 5 の状態は `### CUDA / cuDNN 同梱の判定` にあり、いずれもこの節では触れない（条件 5 は既に閉じており、ここで二重に判定しない）。実装は `.superpowers/sdd/2026-09-05-m7c-dnn-profile/`（Task 1〜6）。実測はすべてこのマシン（Windows 10.0.22631、X64、2026-09-08〜09-10）と、参照する CI run による。

| # | 完了条件 | 判定 |
| --- | --- | --- |
| 1 | profile ごとの native artifact、manifest、third-party notices | **満たした。ただし artifact の「profile ごと」は native binary の分割を意味しない**（上の「dnn の配布の形」で 2026-09-08 に決定済み——native は 1 本、gate は C# 側）。native artifact: `dnn` は `tools/opencv-config.psd1` の `Modules` に足した 7 つ目の module で（構成ハッシュが `4785d98e9aad` 系から変わり 6 platform 分を作り直した）、`cmake/FindOpenCvUnityDeps.cmake` の `COMPONENTS` にも足したのでリンク済み module は 8 → 9 になった。manifest: 実際に CI が生成した `build-manifest.json`（run 34319553823、android-arm64）を読んで確認済み——`requestedModules` / `builtModules` の両方に `dnn` が現れる。third-party notices: `protobuf`（`WITH_PROTOBUF=ON` / `BUILD_PROTOBUF=ON`）を allowlist と notices の両方に足した（`ea5697e` / `81dbba9`）。**配布物としては、この Task 6 まで存在しなかった**——全部入り tarball が `Assemble the release assets`（必須チェック）で `package が上限を超えた: 124101923 > 104857600` として落ちており、**profile ごとの artifact を満たす前提である「配れること」自体が欠けていた。** 原因は dnn ではなく Android `.so` に前から積もっていた DWARF デバッグ情報（詳細は上の「dnn の配布の形」）で、`native/CMakeLists.txt` に Android 限定の `llvm-strip --strip-unneeded` を足して解消した——実測は同じ節にある。 |

**満たしたが、実証はしていない。**

- **実機で `dnn` を動かしたことは 1 度も無い。** M4 が残した「Android / iOS は CI がビルドするが誰も動かしたことがない」という穴は、`dnn` についても同じ形のまま変わっていない。
- **Web での `dnn` の動作は CI の browser E2E に任せており、手元では確かめていない。**
- **推論の速さを測っていない。** `dev.ps1 benchmark` の対象に `dnn` の項目は無く、`OCVU_BENCH:` 行を `dnn` の forward 呼び出しから出したことも無い。

**穴を隠さず書く。**

- **`ocvu_dnn_net_forward` の `.clone()` は必須だと実証されていない。** `native/src/ocvu_dnn.cpp` の当該行は「返す `cv::Mat` が net 内部バッファを指したままだと 2 回目の forward が 1 回目の出力を書き換える」という前提で書かれているが、Task 5 が実物の ONNX（Identity 1 ノード、2 層 Relu）で 2 回 forward を呼ぶ負の対照を試みたところ、`.clone()` を外しても検知できなかった。当初の説明（`cv::Mat` の参照カウントが外側の参照を守るため再割り当てが起きる）はレビューで「`cv::Mat::create()` の早期リターン経路は参照カウントを見ない」と指摘されほぼ確実に誤りと分かり、いまの主説は「OpenCV 5 の新しい dnn engine が `forward()` のたびに新しく確保したバッファを返している」（機構として否定はされていないが未確認）に変わっている。**確定できない理由は、`./tools/opencv.ps1 restore` が復元する木がヘッダと lib だけで、`cv::dnn::Net::forward()` の実装ソースを含まないため**——読んで確定させる経路がこのリポジトリの構成上無い。`.clone()` は「念のための安全装置」ではなく「返した handle が独立したメモリを持つという契約を成立させている唯一のもの」として残してあるが、**その必要性を示す再現テストはまだ無い。**
- **MLAS / ONNX Runtime のソースは依存 allowlist から見えない。** `tools/verify-opencv-artifact.ps1` の allowlist は artifact の中の**独立したライブラリ**を検査する作りで、`protobuf` はそれで捕まえられたが、MLAS / ONNX Runtime は `libopencv_dnn.a` の一部として静的に取り込まれており、独立したライブラリとして現れないので**allowlist には何も見えていない**。ライセンスディレクトリにも該当するものが無い。
- **`WITH_CAROTENE` と `WITH_KLEIDICV` は既定 ON のまま、監査していない。** どちらも `OCV_OPTION` の既定が ON で、`WITH_IPP` / `WITH_ITT` のようにこのプロジェクトが明示的に OFF にしている他の optional 依存とは扱いが違う。macOS の実際のリンクには `libtegra_hal.a` / `libkleidicv_hal.a` / `libkleidicv_thread.a` / `libkleidicv.a` が含まれることを実測済みだが、ライセンス・再配布条件は確認していない。
- **third-party のライセンス集合は platform ごとに実際に違うが、notices はそれを反映していない。** `clapack-lapack_LICENSE` は Linux / Windows / Android / Web には存在するが macOS / iOS には無い（`THIRD_PARTY_NOTICES.md` は 1 通の文書で全 platform を代表している）。
- **`PNG_ARM_NEON=off` は取引であって、無条件の勝ちではない。** `cb250c2` で android-arm64 / ios-arm64 / macos-arm64 の 3 platform に限定して立てた。原因は上流 OpenCV 5.0.0 の vendoring 欠陥——`3rdparty/mlas/lib/compute.cpp` の `MlasGQASupported<MLAS_FP16>` が `MlasHGemmSupported()` を無条件に呼ぶが実体が vendor されておらず、macOS arm64 のリンクが `MlasHGemmSupported` 未定義で落ちる。その ASM 有効化の真因を辿ると `3rdparty/libpng/CMakeLists.txt` の ARM NEON 向け `enable_language(ASM)` に行き着き、`PNG_ARM_NEON=off` はこれを止める代わりに `arm/filter_neon.S` だけでなく同じ分岐にある `arm_init.c` / `filter_neon_intrinsics.c` / `palette_neon_intrinsics.c` も道連れにする——**PNG は arm64 3 platform で ARM 加速を丸ごと失う。** 上流には intrinsics だけ残す形（QNX 向け）があるが、このプロジェクトからは触れない。5.1 で上流が直せば見直す価値がある。
- **dnn の到達性テストは、レビューまでどこからも呼ばれていなかった。** 生成物 `AbiReachabilityChecksDnn.CallEveryEntryPoint()`（`tests/UnityProject/Assets/Tests/Shared.Dnn/`）は spec の dnn 4 関数を 1 回ずつ呼ぶために存在するが、標準 profile の同じ仕組み（`AbiSurfaceTests.cs` / `AbiSurfacePlayerTests.cs` / `WebSmokeRunner.cs` の 3 箇所から呼ばれる）と違い、呼び出し元が 1 つも無かった。**呼ばれない宣言そのものが IL2CPP の stripping の対象になる**ので、この検査は「無い」以上に悪い状態だった——M4 が手書きの 19 本のうち 7 本で実際に踏んだのと同じ形の穴が、dnn の 4 本に開いたまま気づかれずにいた。レビューで指摘され、`tests/UnityProject/Assets/Tests/PlayMode/AbiSurfaceDnnPlayerTests.cs`（`#if OCVU_PROFILE_DNN` で自分を守る、`CvUnity.Tests.PlayMode` の asmdef に `CvUnity.Tests.Shared.Dnn` への参照を足した）を追加して閉じた。**手で 1 回、`OCVU_PROFILE_DNN` を立てて `test-unity-player` を実際に走らせ、stripping が dnn の 4 宣言を消していないことを確認した**（`ProfileGatingTests` が確立した「正の方向は人が手で確かめる」規約と同じ形。実測の日付と結果はこの節の下、または `tools/dev.ps1` 実行ログを参照）。**CI はどのレーンも `OCVU_PROFILE_DNN` を立てないので、この確認は一度きりであり、次に dnn の ABI が変わったときに自動では再検証されない。**

### M7 の判定（2026-09-10。**5 件すべてを満たした**）

**M7 はこのリポジトリで最後のマイルストーンである。** この文書の `## M` 見出しは
M0 から M7 までで、M8 は無い。**帰結を先に書く: ここで「次のマイルストーンへ送る」
と書いた留保は、行き先が存在しない。** 送るのではなく、担当が無いなら無いと書く
（下の「満たしたが、実証していないこと」と「担当が無い」）。

**判定が 1 節にまとまっていないのは、M7 だけである。** M0〜M6 は 1 つの節が
その全条件を判定しているが、M7 は 3 つの計画と 1 つの文書上の決定に割れたため、
**5 件の判定が 4 節に分かれている。** この節はその索引であって、判定の本文では
ない —— **各条件の判定と根拠は担当する節にあり、ここには写さない**（写すと、
どちらかが直された日にもう一方だけが古くなる）。

| # | 完了条件 | 判定の本文 | 満たした | 実証した |
| --- | --- | --- | --- | --- |
| 1 | profile ごとの native artifact、manifest、third-party notices | `### M7c の判定`（2026-09-10） | はい | **いいえ** —— `dnn` を実機で動かしたことは 1 度も無く、推論の速さも測っていない |
| 2 | `RenderTexture` / native texture pointer / `AsyncGPUReadback` を使う低コピー経路の評価 | `### M7a の判定`（2026-09-06） | はい | **部分的** —— `ToMat` / `RequestMat` の画素を運ぶ経路は Editor でしか走らない。**2026-09-11 に CI へ配線した**ので「レーンが CI に無い」という留保は失効したが（下の「GPU 経路を CI に載せる」）、**Player（IL2CPP）側は依然として走らない** —— game-ci が Player を `-nographics` で起動する。native texture pointer は評価のみで実装していない |
| 3 | package size、startup time、frame time、allocation の benchmark を公開 | `### M7a の判定`（2026-09-06） | はい | **半分** —— package size と allocation は機械が assert し CI が守る。frame time と startup time は公開するが assert しない（設計 D1）。startup time は「native ライブラリの真の初回ロード」を捉えていない |
| 4 | `dnn` を足す前に、C ABI と C# の module 分離が済んでいること | `### M7b の判定`（2026-09-06） | はい | はい —— ただし当時証明したのは「機構が働くこと」で、`dnn` で働くことは条件 1 の側（M7c）が示した |
| 5 | CUDA / cuDNN を同梱するなら、再配布条件の確認が済んでいること。確認できないなら**同梱しない**と決めて記録する | `### CUDA / cuDNN 同梱の判定`（2026-09-06） | はい | —— **ライセンス条項は読んでいない。** 条件が用意した 2 経路のうち「確認できないので同梱しないと決める」を選んだ形である |

**「満たした」と「実証した」を同じ列に並べないのは、この 2 つが M7 では実際に
食い違うからである。** 5 件とも「満たした」だが、そのうち **1 件は実機で 1 度も
動かしておらず、2 件は CI が見ていない経路を含み、1 件は根拠となる文書を読んで
いない。** 完了条件は「作ってあること」を問うており、「動くと確かめてあること」
までは問うていない —— その差が M7 では M4 以来いちばん大きい。

**満たしたが、実証していないこと**（本文は各判定節の「穴を隠さず書く」にある。
**ここは索引であって、詳細を写さない**）

- **`dnn` は実機で 1 度も動いていない。** M4 が残した「Android / iOS は CI が
  ビルドするが誰も動かしたことがない」という穴が、そのまま `dnn` にも当てはまる。
  Web は CI の browser E2E に任せており、手元では確かめていない
- **`ocvu_dnn_net_forward` の `.clone()` を要ると示す再現テストが無い。**
  外しても検知できず、しかも**確定させる経路がリポジトリの構成上存在しない**
  （復元する OpenCV の木にヘッダと lib はあるが `Net::forward()` の実装ソースが無い）。
  「負の対照が取れない」の 3 例目であり、これまでで最も弱い形である
- **MLAS / ONNX Runtime は依存 allowlist から見えない。** allowlist が検査するのは
  artifact の中の独立したライブラリで、`libopencv_dnn.a` に静的に取り込まれたものは
  現れない。`protobuf` は捕まったが、この 2 つは捕まらない
- **`WITH_CAROTENE` と `WITH_KLEIDICV` は既定 ON のまま監査していない。**
  実際にリンクされていることは実測済みだが、ライセンス・再配布条件は確認していない
- **third-party のライセンス集合は platform ごとに実際に違うのに、`THIRD_PARTY_NOTICES.md`
  は 1 通で全 platform を代表している**（`clapack-lapack_LICENSE` は macOS / iOS に無い）
- **CUDA / cuDNN の再配布条件は読んでいない。** 大きさだけで結論が出たので読まずに
  済んだ、という形である —— **配布形態が変われば、この宿題はそのまま戻ってくる**
- ~~**`dnn` の到達性は人が手で 1 回確かめたきりである。**~~ **2026-09-11 に閉じた**
  （下の「GPU 経路を CI に載せる」と同じ作業）。`ci-unity.yml` の
  `DnnEditMode` / `DnnStandalone` レーンが `ProjectSettings.asset` に
  `OCVU_PROFILE_DNN` を書いてから Unity を走らせる。**stripping 済みの
  IL2CPP Player で `AbiSurfaceDnnPlayerTests.EveryDnnEntryPointIsReachable` が
  通ることを CI が要求する**ので、次に dnn の ABI が変われば自動で再検証される

**担当が無い。** 上の各項目は、M8 が無い以上「次のマイルストーンで拾う」ことが
できない。**拾う予定は無い** —— 拾うなら、そのときに新しい計画を立てることになる。
**実機の検証だけは手順書がある**（[実機での検証手順](./m4-device-verification.md)。
ただし `dnn` の項は無い）。

**M7 で新しく分かった、記録に値する形が 4 つある。**

1. **1 つのマイルストーンを複数の判定節に割ると、節どうしの名指し参照が腐る。**
   `ci-lint` の documentation link check は通常の markdown リンクしか見ないので、
   見出しを backtick で引用しただけの参照は対象外である。**警告を書いたその branch の
   中で、さらに 1 件を 2 人がかりで見落とした**（`### CUDA / cuDNN 同梱の判定`）。
   だから 4 節とも「ここに残数を書かない」を明文にしてある
2. **検査が当たっていた対象が、本番の物ではなく代用物だったことが 2 件。**
   `verify-exported-symbols.ps1` は「配布 binary の公開面」を主張しながら
   `ci-native` にしか配線されておらず、当たっていたのは開発用の binary だった
   （`release.yml` にも配線して閉じた）。profile の gating を Unity に問う正の対照は
   **手書きの probe** で満たされており、生成物を 1 度もコンパイルしていなかった ——
   その穴を通って `[DllImport(LibraryName, ...)]` が CS0103 になる欠陥が入った
3. **「binary に入っている」と「C# 側がコンパイルする」は別である。**
   `dnn` の native 実装は既定の binary に必ず入っており、切っているのは C# の
   assembly だけである。M3.5 で踏んだ「OpenCV に入っている」と「このプラグインが
   リンクしている」の取り違えと同じ形が、1 段上の層で再現した
4. **生成物が増えても検知範囲が自動で広がった実例。** M7c の新しい生成物 3 つは、
   `check-generated-file-edit.sh` を 1 行も触らずに検知範囲へ入った（生成物が
   先頭 5 行で名乗る規約を見る設計）。**対照的に、一覧を写していた
   `check-unityengine-leak.sh` は M7c で守備範囲が 2 → 4 フォルダになったのに
   2 のままで、2026-09-10 に正本から読む形へ直した**（実測: 直す前は
   `Runtime/Interop.Dnn` と `Runtime/Dnn` が素通りした）

---

### GPU 経路を CI に載せる（2026-09-11）

**M7 が終わった後、「CI が何を見ていないか」を洗い直したところ、
穴の 1 つは穴ではなかった。**

この文書と `CLAUDE.md` と [性能](./performance.md) の 3 つが、同じことを
書いていた —— 「CI のレーンは `-nographics` で走るので、`RenderTexture` の
画素を運ぶ経路は CI では確かめられない」。**そう書いた根拠は
`tools/dev.ps1` の側の実測**（`-nographics` の下で `graphicsDeviceType` が
`Null` になり、`RenderTexture.Create()` が true を返すのに `ReadPixels` が
205,205,205 を返す）であって、**CI の側は 1 度も測っていなかった。**

実物はこうだった。`game-ci/unity-test-runner` がコンテナの中で呼ぶ
`unity-editor` は、game-ci/docker の `images/ubuntu/editor/Dockerfile` が
こう書いている:

```sh
xvfb-run -ae /dev/stdout "$UNITY_PATH/Editor/Unity" -batchmode "$@"
```

**`-batchmode` は付くが `-nographics` は付かない。** 仮想 X の下で起動する
ので、コンテナに GL の実装さえ在れば graphics device は在る。
**そして在るかどうかは Dockerfile からは決まらなかった** ——
`unityci/base` は `--no-install-recommends` で `libglu1` しか入れておらず、
Mesa の実装が依存で入るかどうかは解決次第である。

**だから推測で書かず、レーンを足してそれ自体を実測に使った。**
`ci-unity.yml` の matrix に `Graphics` レーン（`-testCategory Graphics`）を
足し、ブランチ上で `workflow_dispatch` した。

**結果（run 34612557397、2026-09-11）: 7 passed。**
`GraphicsTests.AGraphicsDeviceIsPresent` が通ったので **graphics device は
実在し**、`SyncReadbackProducesTheExpectedPixels` と `VerticalFlipIsApplied` が
通ったので **画素が実際に読める**。`AsyncMatchesSync` も通ったので
**`AsyncGPUReadback` も動く**。`GraphicsBenchmarkRunner` も `OCVU_BENCH:` を
出した（**数値はここに写さない。正本は [性能](./performance.md) である**）。

**残り 2 つの実測は別の run である。** `tarball` job は **run 34613947274**
（`resolved from file:../../upm/com.ayutaz.opencv-unity-native.tgz` まで出て
いる）、`benchmarks` job は **run 34615630480** で初めて走った ——
34612557397 の時点ではどちらの job もまだ存在しない。**1 本の run で全部を
主張しない。**

**この作業で CI に載ったものは、下の表のとおりである。**

| 足したもの | それまでの状態 |
| --- | --- |
| `Graphics` レーン | **ローカル専用**。`[Category("Graphics")]` のテストは CI から完全に見えなかった |
| `DnnEditMode` / `DnnStandalone` レーン | **どの workflow も `OCVU_PROFILE_DNN` を立てていなかった**。Unity の中で dnn の assembly がコンパイルされ、IL2CPP の stripping を生き延びることは人が手で 1 回確かめたきりだった |
| `tarball` job | `dev.ps1 test-unity-tarball` は M3 から在るのに、**どの workflow からも走っていなかった** |
| `benchmarks` job | `dev.ps1 benchmark` も同じ。しかも唯一 Unity を持つ開発機では内部の `test-unity-player` がハングするので**完走しない** |

**1 度消して、レビューで戻した検査が 1 つある。**
`CiVisibilityTests`（「`[Category("Graphics")]` が付いたテストの台帳」）は、
その class 自身の docstring が「graphics レーンを **CI に配線できたら**、
この一覧は空にでき、そのとき検査ごと消してよい」と書いていた。配線したので
消した —— **が、削除の条件はそれでは足りなかった。**

`Unity Graphics (Linux)` は**必須チェックではない**ので、
`[Category("Graphics")]` を付ける行為は「CI から完全に消える」から
**「必須レーンから、赤くても merge を止めないレーンへ無言で移る」**に
変わっただけで、**守るべき性質は残っている。** 正しい削除の条件は
**「そのレーンが merge を止めるようになること」**である。
docstring をそう書き換えたうえで、検査は戻した。

**この誤りは条件文の読み違えであって、実測の誤りではない** ——
配線されたことは本当である。**「CI が見ている」と「CI が止める」を
取り違えると、こういう形で守りが 1 段落ちる。**

**必須チェックへ昇格した（2026-09-11、所有者の判断）。**

足した 5 本（`Unity Graphics (Linux)` / `Unity DnnEditMode (Linux)` /
`Unity DnnStandalone (Linux)` / `UPM tarball install (Linux)` /
`Publish the benchmarks`）を必須チェックにした。必須は **24 → 29 本**、
必須でないものは **18 → 13 本**になる（残るのは `Plugin` 5 本・
`Publish the release`・集約 `CodeQL`・game-ci の結果 check 6 本）。

**これはこのリポジトリの手順からの逸脱である。それを記録しておく。**
これまでの昇格はすべて「安定して緑になったのを見てから」で、Web の 3 本は
#63 から #74 まで 11 本の PR で緑を見てから昇格した。**今回の実績は
1 ブランチ上で多くても 3 run である**（`Graphics` と dnn の 2 レーンが
3 run、`tarball` が 2 run、`benchmarks` は 1 run）。**所有者がその差を
承知のうえで、いま昇格させると決めた。** 見込める帰結は 2 つ:

- **良い側**: 足したレーンが赤ければ merge が止まる。**これが昇格の目的で
  ある** —— `tarball` が赤ければ「導入できない tarball」は入らないし、
  `DnnStandalone` が赤ければ stripping が dnn の宣言を消した状態は入らない
- **悪い側**: **これらのレーンがフレークなら、main が固まる。**
  実績が浅いぶん、そのときの原因切り分けは「新しいレーンが不安定なのか、
  本当の欠陥なのか」から始まる。そうなったら、**必須から外すのは
  `gh api ... /protection/required_status_checks` の 1 回の PATCH で戻せる**

**game-ci の結果 check（`* results`）は昇格させない。** PR では `neutral` に
なり、**GitHub は neutral を合格として通す**ので、必須にしても止める力は
増えない（`EditMode results` / `Standalone results` を必須にしていない
のと同じ理由である）。

**`benchmarks` job に `if: ${{ !cancelled() }}` を足した。** 昇格と同じ
commit で入れてある —— 素の `needs: unity` だと、依存が落ちた瞬間に
この job は **skip** になり、**skip は required check を通す。**
必須にしたまま素の `needs:` を残すと、「依存が落ちているのに緑と同じ
意味を持つ」状態を自分で作ることになる。

**昇格の順序に注意が要る。** 必須にした 5 本は**この変更が入った
workflow でしか作られない**ので、**この PR が main に入る前に main から
切った branch には現れず、その PR は永久に待たされる。**
（`CLAUDE.md` が「PR で起動しない workflow は必須にできない —— 当たらない
PR では check が現れず、必須にすると永久に merge できない」と書いている
のと同じ形である。）今回は開いている PR が 1 本だけで、そこでは 5 本とも
緑だったので踏んでいない。

**閉じなかったものも書く。**

- **Player（IL2CPP）側の GPU 経路は閉じていない。** game-ci の
  `run_tests.sh` は Standalone Player を
  `xvfb-run -a -e /dev/stdout ... -batchmode -nographics` で起動しており、
  **`-nographics` は action の中に書かれていてこちらからは外せない。**
  したがって `AsyncGPUReadback` が IL2CPP で動くかは、いまの構成では
  確かめる術が無い（Editor では動くことが分かった、が上限である）
- **実機は変わらず 1 度も動かしていない。** Android / iOS / dnn のいずれについても、
  実機で動かした実績は無いままである

**この 1 件から取れる一般的な教訓は、`prove-a-check-works` skill に
「『原理的に無理』と書いた前提を、誰も測っていないことがある」として
入れてある。** 個別の経緯はこの節が持つので、そちらには再掲しない。

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
                                            （9 件中 6 件 / v0.3.0 で配った）
                                                              |
                                                              v
                                                        M5 generator
                        （5 件すべて達成。objdetect / features / geometry / calib）
                                                              |
                                                              v
                                                          M6 Web
                                            （5 件すべて達成。ブラウザで実測）
                                                              |
                                                              v
                                                       配布 v0.3.0
                     （M4 / M5 / M6 の成果をまとめて届けた。2026-09-04 に公開し、
                      OpenUPM も 0.3.0 を配信している。「配布 その 5」を参照）
                                                              |
                                                              v
                                                     API 拡張（A〜F）
                        （マイルストーンではない。26 本を 4 つの計画に分けて出す。
                          OpenCV の再ビルドは起きない。計画は
                          docs/superpowers/plans/2026-09-05-api-surface-expansion.md）
                                                              |
                                                              v
                                                        M7 profiles
                     （5 件すべて達成。判定は M7a / M7b / CUDA / M7c の 4 節に分かれ、
                      索引は「M7 の判定」。M7 が最後のマイルストーンで、後続は無い。
                      成果はまだどの公開版にも入っていない）
```

**配布はマイルストーンではないが、マイルストーンの間に必ず挟まる。** M3 が v0.1.0 /
v0.1.1、M3.5 が v0.2.0、そして **M4 / M5 / M6 の成果をまとめた v0.3.0 を
2026-09-04 に公開した**（「配布 その 5」を参照。**その前に作った下書きは
M5 が main に入る前のもので、破棄して打ち直した** ——「配布 その 4」）。
**この段が計画のどこにも書かれていなかったので、上の図と「配布 その 5」の節に足した。**

**API 拡張（A〜F）も同じ位置づけである** —— マイルストーンではないが、
M6 と M7 の間に挟まる。**26 本を 4 つの計画に分けて出す**もので、
**既にリンク済みの module だけを使うので OpenCV の再ビルドは起きない**
（唯一の例外が `stereo` で、そちらも `Modules` ではなく `COMPONENTS` を触る）。
全体設計は
[API 拡張（A〜F）](./superpowers/plans/2026-09-05-api-surface-expansion.md) にあり、
**実装前の前提検証で覆った決定は
[実測で覆った前提と、その決定](./superpowers/plans/2026-09-05-api-expansion-corrections.md)
にある（そちらが 5 本の計画すべてに優先する）。**

## 再評価のトリガー

次のいずれかが起きた場合、backend 言語の決定（C++）を再評価する価値がある。

- **Rust の AddressSanitizer / LeakSanitizer が stable 化する** — 言語評価 §4.4 の決定的な差が消える。Rust project goals の 2026 目標として進行中
- Web または iOS がスコープから外れる
- generator を採用せず bridge を大量に手書きする方針に変わる

再評価が安価であるために、**public C header と契約テスト（L1 / L3）は backend 実装から独立に保つ**。この不変条件は M0 で確立し、以降のすべてのマイルストーンで維持する。
