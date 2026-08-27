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

- **OpenCV は CI がビルドし、artifact として配布する。** エージェントもローカル開発者も OpenCV を自分でビルドしない（`tools/opencv.ps1 restore` が固定ハッシュの artifact を download するだけ）。M1 のビルドコスト（CI 実測: clone〜verify まで通しで 4 分 09 秒。`windows-2022` runner、run 32849957498。ローカルでの実測はまだ無い）が開発ループから完全に消える。
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
| 7 | `ci-unity.yml` が CI 上で L4/L5 を実行する | **満たさない** |
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

**条件 7 は未達である。** `ci-unity.yml` は書かれ、ローカルでは `dev.ps1 test-unity-editmode` /
`dev.ps1 test-unity-player` の両方が green だが、CI 上では一度も実行されていない
（`gh run list --workflow=ci-unity.yml` は default branch に存在せず 404）。

**残作業は 3 つあり、うち 2 つはエージェントが書ける。**「資格情報を登録すれば動く」は
事実ではなかったので訂正する:

1. **CI ランナーへの Unity 導入。** `ci-unity.yml` は GitHub ホストの `windows-2022` で
   `dev.ps1 test-unity-editmode` を直接呼ぶが、このイメージに Unity は含まれない。
   `Get-UnityEditorPath` は Unity Hub の既定の配置を決め打ちで探し、無ければ失敗する。
   導入する action も入れていない。
2. **ライセンスのアクティベーション実装。** `UNITY_LICENSE` / `UNITY_EMAIL` /
   `UNITY_PASSWORD` を env に置いてあるが、`tools/` 内にそれらを読むコードは 1 行も無い
   （`grep -rn UNITY_LICENSE tools/` の結果は 0 件）。完了条件の文言自体が
   「アクティベーションを自動化する」を含んでいる。
3. **GitHub Secrets への資格情報登録。** これだけがユーザーの操作である。

現在この workflow の trigger は `workflow_dispatch` のみに絞ってある。push で走らせると
成功し得ない job が全 push で赤くなり、「赤い CI は直すもの」という前提が壊れるためで、
上の 1 と 2 が揃った時点で戻す。

完了条件は「workflow ファイルが存在すること」ではなく「CI 上で L4/L5 を実行すること」
であり、両者を取り違えないよう最初から実行の有無で判定した（M1 の条件 6 判定で同じ
取り違えが一度起きている）。

**したがって M2 は「8 件中 7 件達成」であって「完了」ではない。** 実装計画
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
