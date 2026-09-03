---
name: add-a-platform
description: Use when adding, removing, or changing a target platform for the native plugin - a new OS, a new architecture, a cross-compiled target, or a new Unity build target. Enumerates every place the platform set is repeated, the traps that only surface in CI or inside Unity, and why one round of fixes is never enough. Triggers on touching cmake/toolchains, CMakePresets.json, tools/opencv-config.psd1, tools/plugin-meta, or any workflow matrix over platforms.
---

# platform を足す

**「ビルドが通った」は作業の 3 割である。** M4 で Android と iOS を足したとき、
plugin のクロスビルドが緑になってから **CI で 8 回落ちた。** 落ちたのは
いずれもビルドではなく、**platform の集合を持っている別の場所**である。

このリポジトリには「対象 platform の一覧」が **17 箇所**ある。名前で持つ所、
ファイルのパスで持つ所、Unity の `BuildTarget` で持つ所、YAML の matrix で
持つ所があり、**語彙が違うので grep 1 回では揃わない。**

## 先に決めること

この 3 つで、以下の手順のどの分岐に入るかが決まる。**決めずに書き始めると、
最後まで書いてから作り直しになる。**

| 問い | 分岐 |
| --- | --- |
| **実行中の OS でビルドできるか** | いいえ → クロス。toolchain ファイルが要り、`find_package` の探索が sysroot に閉じ込められ、**L1 は走らない**（クロスした GoogleTest は host で実行できない） |
| **共有ライブラリを配れるか** | いいえ → 静的ライブラリ。**依存アーカイブは自分で束ねる**（下記）。P/Invoke は `DllImport("__Internal")` |
| **OpenCV のインストール配置は既存と同じか** | いいえ → `cmake/FindOpenCvUnityDeps.cmake` の候補と `tools/verify-opencv-artifact.ps1` の配置に足す |

**「クロスでない」と即断しない。** Android は Linux ランナーで、iOS は macOS
ランナーでビルドするので「host は同じ OS 系統」に見えるが、どちらもクロスである。

## 直す場所

**実測（M4 で Android / iOS を足したときに触ったもの）。** 順序は依存関係順で、
上から埋めると途中で戻らずに済む。

| # | 場所 | 何を |
| --- | --- | --- |
| 1 | `tools/opencv-config.psd1` | `Toolchains`（generator / architecture）と `PlatformCMakeArgs` |
| 2 | `cmake/toolchains/<platform>.cmake` | クロスなら新規。**platform 固有の linker flag はここに置く**（下記の 16 KB の罠） |
| 3 | `tools/opencv.ps1` | `[ValidateSet(...)]` と、toolchain ファイルへの対応表 |
| 4 | `CMakePresets.json` | configure / build preset 各 2 構成。**クロスなら `toolchainFile` を指す** —— 指さないと host 向けにビルドされ、**成功したように見えて中身が別物になる** |
| 5 | `cmake/FindOpenCvUnityDeps.cmake` | 配置が違うなら候補に足す。クロスなら `CMAKE_FIND_ROOT_PATH` |
| 6 | `native/CMakeLists.txt` | ライブラリ種別（静的なら依存の束ね） |
| 7 | `tools/verify-opencv-artifact.ps1` | インストール配置、third-party の allowlist、ライセンスファイルの一覧 |
| 8 | `THIRD_PARTY_NOTICES.md` | 新しく引かれる third-party のライセンス**全文** |
| 9 | `tools/dev.ps1` | `$script:AllPlatformBinaries`、`-Platform` の受理、`$NativeLibraryName`、`Copy-NativePluginForUnity` の出力先 |
| 10 | `tools/plugin-meta/<platform>/**` | `.meta`（**キー名と GUID**。下記の罠） |
| 11 | `tools/pack-upm-tarball.ps1` | `$PlatformBinaries` と `$AllowedPluginFiles` |
| 12 | `tools/assemble-plugins.ps1` | `$Allowed` |
| 13 | `tests/UnityProject/.../PluginGatingTests.cs` | `Slots`（**パスの断片で引く。ファイル名では引かない**） |
| 14 | `.github/workflows/build-opencv.yml` | matrix |
| 15 | `.github/workflows/ci-native.yml` | ビルド job（クロスならテストは走らない） |
| 16 | `.github/workflows/ci-unity.yml` | plugin matrix（全部入りの材料） |
| 17 | `.github/workflows/release.yml` | matrix と **asset の数** |

加えて `tools/tests/OpenCvConfig.Tests.ps1` と `tools/tests/PackageRelease.Tests.ps1`
が、上のいくつかの一致と数を見ている。**そちらの数も一緒に増える。**

**この表を短くする方法が 1 つだけある: 写すのをやめて導出する。**
M4 のレビューで 18 番目が見つかった —— `.github/workflows/nightly.yml` の
「Check every platform's artifact」が 3 platform を直書きしており、**step の
名前が "every platform" と言っているのに 5 中 3 しか見ていなかった。**
artifact が黙って期限切れになっても気づかない状態である。

直し方は表に足すことではなく、**正本から読ませて表から外すこと**だった:

```powershell
$platforms = @((Import-PowerShellDataFile ./tools/opencv-config.psd1).Toolchains.Keys | Sort-Object)
if ($platforms.Count -lt 3) { Write-Error '...'; exit 1 }   # 読めなければ落とす
```

**写している場所は「直す場所」を 1 つ増やし、導出に変えれば 1 つ減る。**
新しく platform 一覧を書きたくなったら、まず正本から読めないかを考えること。

**hook が見えない一覧が、まだ 3 つある。** `check-platform-list-drift.sh` は
**binary の相対パス**で判定するので、次の形は構造的に見えない:

| 形 | 実例 |
| --- | --- |
| platform **名**のリスト | `.github/workflows/release.yml` に 2 つ（matrix と合わせて同一ファイルに 3 つ） |
| Unity の `BuildTarget` | `PluginGatingTests.cs` の `Slots` |
| workflow の matrix | 各 `.yml` |

**M4 では、この見えない側から 3 件出た** —— `nightly.yml` の 3 platform 直書き、
`pack-upm-tarball.ps1` の中の 2 つ目の一覧（`switch` の 3 分岐）、
`package-release.ps1` の拡張子による binary 判定。**後ろ 2 つは
`release.yml` の空撃ちでしか見つからなかった。**

**だから platform を足したら、機械に頼らず上の表の場所を自分で開くこと。**

**意図して一部の platform だけを扱う場合は、逃げ道がある。**
`check-platform-list-drift.sh` hook は正本の 3 件以上を名指ししているファイルに
全件を要求するので、`tools/verify-artifact-linkage.ps1` のように「desktop だけ
実装し、未知は既定で落とす」形は近くに `PLATFORM_LIST_OK:` と理由を書いて許す。
**理由を書かせるのが目的**で、黙って除外できる形にはしていない。

**数を信用しない。** この表の「17」も、次に platform を足す人にとっては古い。
`git grep -c -E '<既存の platform 名>'` で数え直すこと。**文書に書かれた数は、
足したときに一緒に増えるとは限らない** —— roadmap は長らく「2 か所」と書いて
いたが実際は 3 か所で、M4 で判明した。

## 罠

**M4 で実際に踏んだ順に並べる。上ほど高価だった。**

### 1. `.meta` の platform キーは、YAML として正しくても Unity が知らなければ黙って無効になる

iOS の `.meta` に `iPhone:` と書いた。**これは Unity 2019 以前の名前で、
Unity 6 では `iOS:` である。**

- YAML として正しい
- `.meta` を**自分でパースする**検査（`PackageRelease.Tests.ps1`）は通った
- 落としたのは **Unity に読ませた結果を読む**検査（`PluginGatingTests`）だけ

**CI 8 往復目の最後の 1 件がこれだった。** 現行のキーは既存の `.meta` から
写す（`tools/plugin-meta/*/`）。既存に無い platform なら、**Unity に
`GetCompatibleWithPlatform` を問う検査を先に赤くしてから**書く。

**GUID は既存と重複させない。** 重複すると Unity が片方を無視し、
**どちらが無視されるかは決まっていない。**

### 2. ファイル名は platform 間で衝突する

**Android と Linux はどちらも `libopencv_unity_native.so` である。**
ファイル名で plugin を引いていた検査は、Android を足した瞬間に
「同じ物が 2 つある」と誤る。**パスの断片で引く**
（`/Android/arm64-v8a/lib...` と `/Linux/x86_64/lib...`）。

同じ形で、**拡張子で binary を見分ける検査**も破れる。
`(dll|dylib|so)` で判定していた packer は、iOS の `.a` を
「binary ではない知らないファイル」として扱った。

### 3. クロスでは `find_package` が sysroot の中に閉じ込められる

NDK の toolchain と CMake の iOS platform module は、どちらも
`CMAKE_FIND_ROOT_PATH` を sysroot に設定し探索モードを `ONLY` にする。
**こちらの OpenCV は sysroot の外**にあるので、`PATHS` で明示しても見えない。

```
Could not find a package configuration file provided by "OpenCV"
```

**成果物は正しく、探し方だけが間違っている。** 探索の根に自分の木を足し、
**package の探索だけ** `BOTH` に緩める（library / include まで緩めると
host の `.a` やヘッダを拾う経路が開く）。

**`find_package` だけではない。** `find_file` / `find_program` にも同じことが
起きる。M6 で踏んだ形（2026-09-03）—— toolchain が置いた変数から
`emar.py` を探そうとして:

```
CMake Error at native/CMakeLists.txt (find_file):
  Could not find OCVU_EMAR_PY using the following files: emar.py
```

**cache には正しい値が入っていた。** つまり値ではなく探し方の問題で、
`PATHS ... NO_DEFAULT_PATH` でも sysroot の外は見てもらえない。

**在り処が分かっているなら探さない。** 組み立てて `EXISTS` で確かめ、
無ければその場で `FATAL_ERROR` にする。`NO_CMAKE_FIND_ROOT_PATH` を足す手も
あるが、**探索の設定に依存しないほうが読んで分かる。**

### 3.5 toolchain file は try_compile の中でもう一度実行される

**`-D` で toolchain に渡した変数は、既定では入れ子の try_compile に届かない。**
届くのは `CMAKE_TRY_COMPILE_PLATFORM_VARIABLES` に載せたものだけである。

M6 で踏んだ形（2026-09-03）: toolchain file が「Emscripten の根が未設定なら
`FATAL_ERROR`」と書いてあり、**外側では渡っているのに入れ子で発火した。**
表に出るのはこれである:

```
CMake Error: CMAKE_CXX_COMPILER not set, after EnableLanguage
CMake Error at cmake/OpenCVUtils.cmake:513 (TRY_COMPILE):
  Failed to configure test project build system.
```

**原因が 2 段隠れている** —— 「コンパイラが無い」と読めるが、実際には
自分の toolchain が入れ子で止めている。**エラーの本文を遡ると、自分が書いた
FATAL_ERROR の文言が Call Stack の上のほうに出ている**ので、
**要約ではなく本文を読むこと。**

直し方は 1 行:

```cmake
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES OCVU_EMSCRIPTEN_ROOT)
```

**toolchain に外から変数を渡す設計にしたら、必ずこれを書く。**
環境変数での受け取りを併用しておくと保険になる（プロセスは引き継がれる）。

### 4. 静的ライブラリを配るなら、依存アーカイブは自分で束ねる

**CMake は STATIC ライブラリに依存アーカイブを取り込まない。** 記録するのは
usage requirement だけである。出来た `.a` は自分の object しか含まず、
`cv::cvtColor` などは未解決のまま残る。

**ビルドは成功する。** 壊れるのは Unity が Xcode プロジェクトへ足して
リンクする段 —— **「ビルドできた ≠ 動く」の最も遠い形**で、レビューの
読解で見つかった（CI は最後まで緑だった）。

同じ理由で、**iOS は `SHARED` のままでもビルドが成功する。**

### 5. 新しい platform は新しい third-party を連れてくる

Android の OpenCV は `libcpufeatures.a`（NDK 由来）を引く。
**依存の allowlist が拒否して初めて存在を知った** —— これは allowlist が
意図どおり働いた形である。

ライセンスは**一次情報で確認**し（`android.googlesource.com` を読む）、
`THIRD_PARTY_NOTICES.md` に**全文**を足す。名前を allowlist に足して
緑に戻すだけで済ませない —— **利用者が読む文書は何も赤くならない。**

### 6. 「N 件」の一覧は置いていかれる

3 platform 用に書かれた一覧が、5 platform になっても 3 件のまま残る。
M4 では **3 件**見つかった（うち 1 件は、一度直したのに `git checkout --`
で巻き戻して再発した）。

**特に危ないのは、正本を写した一覧である。** `VerifyOpenCvArtifact.Tests.ps1`
がライセンス名 13 件を直書きし、検証器側は 15 件になっていた —— **テストが
古い側を主張して、正しい実装のほうが落ちた。** 写さずに**正本から読む**
（読めなければ落とす）。

### 7. OpenCV の構成を変えた PR では、artifact より先に他のレーンが走る

`build-opencv` と他のレーンは同時に起動する。artifact ができる前に
`restore` が動くので、**「この構成でまだビルドしていない」と出る** ——
しかし取るべき行動は逆で、待って再実行すればよい。

M4 では `Plugin ios-arm64` がこれで落ち、**artifact は 20 分後に正しく
公開された。** `tools/opencv.ps1` は現在この 2 つを区別して別の文言を出す。
**同じ文言で違う状態を報告する検査は、読む人を間違った方向へ送る。**

### 8. platform 固有の linker flag は、効く場所に置く

16 KB page size の flag を `tools/opencv-config.psd1` に書いていたが、
**OpenCV は共有ライブラリを 1 つも作らないので何にも当たっていなかった。**
当てたいのはこちらの `.so` なので、**toolchain ファイル側**に、しかも
**NDK の toolchain を include した後に**追記する（先に書くと上書きされる）。

## OpenCV は CI にビルドさせる。手元で回さない

**これは新しい platform を足すときに最も破りたくなる規則である。**

`CLAUDE.md` は 3 箇所で「OpenCV はローカルでビルドしない」と書いているが、
**新しい platform では CMake flag が一発で決まらない**ので、
「CI に投げて 20〜40 分待つ」より「手元で回す」ほうが速く見える。

**見えるだけである。** 2026-09-03、M6（Web / Wasm）でそれをやった結果:

| 回 | 落ちた理由 |
| --- | --- |
| 1 | Emscripten の cache が Unity の導入先へ書けず **15 分停止** |
| 2 | Windows に Ninja が無い |
| 3 | `try_compile` の入れ子で自分の toolchain が `FATAL_ERROR` |
| 4 | OpenCV の wasm 実装が `simd128` を要求する |
| 5 | SIMD を足したら **SSE 互換ヘッダの経路**に入った |

**1 回 10〜40 分で 5 回。CI 5 往復と変わらない。** しかも:

- **手元の環境は CI と違う。** 上の 1 と 2 は**手元にしか無い問題**で、
  CI では起きない。**手元で潰した時間の一部は、CI に何も貢献しない**
- **手元で通っても CI で通る保証にならない。** 逆も同じで、
  「手元で落ちるから CI でも落ちる」とは限らない
- **ローカルループが秒単位でなくなる。** これは
  `CLAUDE.md` が「他の何よりも先に固定する」と書いた土台である

**だから、新しい platform の OpenCV は最初から CI に作らせる:**

1. `tools/opencv-config.psd1` に `Toolchains` / `PlatformCMakeArgs` を足す
2. `.github/workflows/build-opencv.yml` の matrix に足す
3. **push して CI に作らせる**
4. artifact が出たら `./tools/opencv.ps1 restore` で取ってくる
5. flag が違ったら 1 に戻る —— **その往復が、この作業の既定の形である**

**`opencv.ps1 build` は「CI の結果を検証するとき」と「CI 側の切り分け」の
ためにある。** flag 探しのために使わない。
**hook（`.claude/hooks/block-local-opencv-build.sh`）が止める** ——
本当に必要なら `OCVU_ALLOW_LOCAL_OPENCV_BUILD=1` を明示すること
（**意図して回したことが履歴に残る形にしてある**）。

## CI 往復を前提に計画する

**M4 の後半は、ローカルで緑・CI で赤が 8 回続いた。** 内訳は
OpenCV のビルド 3 回、依存検証 2 回、自分が起こした回帰 1 回、
クロスの configure 1 回、Unity の gating 1 回である。

**これは失敗ではなく、この作業の既定の形である。** 理由は単純で、
**手元に無い OS・無い SDK・無い Unity がやることを、手元では試せない**
から。1 往復が 20〜40 分かかるので、次を守ると回数が減る:

- **1 コミット 1 原因**にする。まとめて直すと、どれが効いたか分からない
- **仮説のまま直さない。** M4 の最後の 1 件で「iOS の build support
  モジュールが CI に無いのだろう」と考えたが、ログを測ると
  `StandaloneOSX` も `StandaloneLinux64` も同じく `supported=False` なのに
  assertion は通っていた。**仮説は反証され、原因は `.meta` のキーだった**
- **落ちた job のログを、要約ではなく本文で読む。** 8 件中 5 件は、
  エラーの 1 行下に原因が書いてあった

## 完了の判定

新しい platform について、**次の 3 つは別物**である。判定表で混ぜない。

| | 何が言えるか | どこで確かめるか |
| --- | --- | --- |
| **ビルドできる** | リンクまで通った | CI |
| **配れる** | 全部入りに入り、Unity が自分の platform の物だけを有効にする | CI（`PluginGatingTests`） |
| **動く** | 実機で C# → P/Invoke → OpenCV が通る | **実機。CI では原理的に閉じない** |

3 つ目を CI で閉じられないなら、**人が実行する手順書に落とす**
（`docs/m4-device-verification.md`）。**判定表への書き方は
`milestone-complete` skill の「「対象」と「実行環境」が一致しない条件を
見分ける」に従う。**

## 参照

- `.claude/skills/prove-a-check-works/SKILL.md` — 足した検査が本当に見ているかを示す手順
- `.claude/skills/milestone-complete/SKILL.md` — 完了条件との照合
- `cmake/toolchains/` — クロス toolchain の実例（Android / iOS）
- `tools/plugin-meta/` — `.meta` の正本。キー名はここから写す
- `docs/m4-device-verification.md` — CI で閉じない条件を人が確かめる手順
