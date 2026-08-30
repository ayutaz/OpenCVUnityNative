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
