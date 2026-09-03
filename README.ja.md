# OpenCV Unity Native

OpenCV 5 を、このプロジェクトが所有する C ABI 越しに Unity へ持ち込む、再現可能な native UPM パッケージです。

[English](README.md)

> **現状: 公開済みの最新版は v0.2.0 で、リポジトリはそれより大きく先に進んでいます。** あの版は desktop のみで、M0 から M3.5 までが入っています。その後リポジトリには Android と iOS のクロスビルド（M4）と、生成される binding 層およびカメラ校正（M5）が加わりましたが、**どれもまだ公開されていません。** Windows x64 / macOS arm64 / Linux x64 は CI がビルド・テスト・パッケージ化しており、Unity 自身が Mono（EditMode）と実物の IL2CPP Player の両方でプラグインを動かしています。**Android arm64 と iOS arm64 は CI がクロスビルドしますが、公開版には入っておらず、実機で一度も動かしていません。** Web（M6）は未着手です。**以下に書いてあることは「リポジトリの現状」であって「落とせるもの」ではありません** —— v0.2.0 に入っているのは `Mat` のライフサイクルと buffer 転送、`cvtColor` / `resize` / `GaussianBlur`、メモリ上の画像 encode / decode、そして desktop 3 platform を 1 つにまとめたパッケージまでです。**公開している C ABI はどちらにせよ意図的に狭くしてあります** —— 面積を覆うことではなく、所有権・stride・エラー処理・IL2CPP を正しくすることを目的にしているからです。**Linux では v0.1.1 以降を使ってください** —— v0.1.0 の Linux プラグインは glibc 2.38 を要求し、Ubuntu 22.04 では読み込めませんでした。

## これは何か

既存の .NET ラッパーを再パッケージするのではなく、**このプロジェクトが所有し自分で版を付ける狭い C ABI** を中心に据えた、Unity 向けの OpenCV 5 統合です。

- **OpenCV 5 が前提。** 5.x のモジュール構成に対して設計しており、4.x のラッパーからの移植ではありません。
- **Unity が前提。** IL2CPP、AOT、iOS の静的リンク、Android、Web は後付けではなく設計上の制約です。
- **プロジェクト所有の C ABI。** C++ や STL の型は境界を越えません。不透明ハンドル、固定サイズ型、明示的な所有権、例外は status code へ変換します。
- **再現可能な binary。** OpenCV の tag、ビルド設定、toolchain、ハッシュを固定し、CI から再生成します。
- **Apache-2.0。**

## やらないこと

OpenCV のアルゴリズムを実装し直すこと。OpenCV の API 全面を先回りして手で包むこと。互換のために OpenCvSharp の managed API を複製すること。あらゆる codec・DNN・GPU backend を有効にした 1 つの大きな binary を配ること —— `imgcodecs` はリンクしていますが PNG と JPEG だけで、TIFF / WebP / OpenEXR / JPEG 2000 はビルドから外してあります。動画入出力（FFmpeg、GStreamer）、DNN、GPU backend も同様です。

## 対応 platform

**いま配っているもの**: Windows x64、macOS arm64、Linux x64。いずれも CI がビルド・テスト・パッケージ化し、Linux と Windows のプラグインは Unity 自身が動かしています（Mono の EditMode と実物の IL2CPP Player）。

macOS のプラグインはパッケージに入っており、Unity 自身が Plugin Import Settings を読むところまでは確かめてあります —— EditMode のテストが、全 platform の binary を置いた状態で Unity の `PluginImporter` に「その `.meta` をどう解釈したか」を問います。**ただし macOS のライブラリは一度も読み込まれておらず、macOS 上で Unity を起動したこともありません。** あの platform は「ビルドされ、gating されている」であって「動かした」ではないと考えてください。

**ビルドはされているが、実機で一度も動かしていないもの**: Android arm64-v8a と iOS arm64。CI は両方をクロスコンパイルし、Android の `.so` については**実物の ELF program header を読んで** 16 KB page 整列を確かめ、iOS の `.a` については**このプラグインが参照する OpenCV のシンボルを実際に束ねているか**を確かめます。**しかしそれは、電話機の上で動かすこととは別です。** Android / iOS のどの端末も、これらの binary を読み込んだことがありません。リポジトリには入っており次の版に含まれますが、[実機検証の手順](docs/m4-device-verification.md)を誰かが実施するまでは未検証として扱ってください。

**Web / Wasm はリポジトリに入っており、実際にブラウザで動きます** —— headless の
Chromium が本物の WebGL Player を読み込み、EditMode と IL2CPP Player が走らせるのと
同じ検証本体を走らせます（**写しではなく同じ関数**です）。**そのうち 1 件だけ Web で経路が変わります** ——
encode / decode の検査が PNG ではなく JPEG を使うので、**画素の一致までは主張できません**。
ただし **他の platform には無い制限が 1 つあります:
`imgcodecs` が扱えるのは JPEG だけで、PNG は扱えません。** Unity の WebGL 支援は
自前の libpng を同梱しているため、OpenCV の libpng を束ねると Player のリンクが
シンボルの重複で失敗し、束ねないと OpenCV の PNG コードが未解決で失敗します。
どちらの極端も通らないので、Web のビルドでは PNG を外してあります。
**他の 5 platform は PNG / JPEG の両方を扱えます。**

全体を通して Unity 6000.3 以降が必要です。

## 導入

リリースは [github.com/ayutaz/OpenCVUnityNative/releases](https://github.com/ayutaz/OpenCVUnityNative/releases) にあります。

**公開済みの版（v0.2.0）は desktop のみで、意図的に小さく作ってあります**: `Mat` のライフサイクル、`cvtColor` / `resize` / `GaussianBlur`、そしてメモリ上の byte 配列との間で PNG と JPEG を encode / decode する機能です。**この ABI はファイルパスを一切受け取りません** —— byte buffer だけです。これは意図したもので、Android の APK に入った `StreamingAssets` のファイルには開けるパスが存在せず、境界を越えるパスは Windows の文字コードの問題を引きずり込むためです。

**リポジトリにはその版より多くのものが入っており**、次の版がそれを運びます: Android と iOS の binary、QR コードの符号化・復号、ORB の特徴点、射影変換の推定、そして単眼カメラ校正の 3 段（盤の格子点を見つける / 係数を解く / その係数で歪みを補正する）。全体像と**意図的に出していないもの**は [API リファレンス](docs/api-reference.md)に、本数そのものは [API 対応表](docs/api-map.md)の冒頭にあります。Web は未対応です。

**Linux では v0.1.1 以降を使ってください。** v0.1.0 の Linux プラグインは glibc 2.38 に対してビルドされており、それより古い環境（Ubuntu 22.04 を含む）では `DllNotFoundException` で読み込めません。v0.1.1 以降、Linux の成果物は Ubuntu 22.04 のコンテナでビルドしており、要求するのは glibc 2.34 だけです。

各リリースには、**全 platform 分をまとめた tarball が 1 つ**（こちらを取ってください）と、1 platform 分だけが欲しい人のための platform ごとの tarball が入っています:

```
com.ayutaz.opencv-unity-native.tgz                        # 全 platform 分 — これを取る
com.ayutaz.opencv-unity-native-<version>-windows-x64.tgz  # 1 platform だけが欲しいとき
com.ayutaz.opencv-unity-native-<version>-macos-arm64.tgz
com.ayutaz.opencv-unity-native-<version>-linux-x64.tgz
com.ayutaz.opencv-unity-native-<version>-android-arm64.tgz
com.ayutaz.opencv-unity-native-<version>-ios-arm64.tgz
```

platform ごとの一覧は platform が増えれば増えます。**どれが実在するかは、
落とすリリースそのものが正本です。**

全部入りの tarball のファイル名に版番号が入っていないのは意図的です。OpenUPM は安定した名前の接頭辞でリリース asset を選ぶので、名前に版が入っているとリリースのたびにその pattern を書き換えることになります。platform ごとの tarball は版番号を保持します。**このパッケージは OpenUPM に登録済みで**（2026-08-30 に受理）、`https://package.openupm.com/com.ayutaz.opencv-unity-native` が v0.2.0 を配信しています（[docs/openupm-registration.md](docs/openupm-registration.md)）。

`com.ayutaz.opencv-unity-native.tgz` を落とし、プロジェクトの中か隣に置いて、パッケージの manifest から指します:

```jsonc
// Packages/manifest.json
{
  "dependencies": {
    "com.ayutaz.opencv-unity-native": "file:../ThirdParty/com.ayutaz.opencv-unity-native.tgz"
  }
}
```

相対パスは `Packages` フォルダから解決されます。絶対パスでも動きます。**Unity 6000.3 以降が必要です** —— 2022 LTS は非対応で、6000.0 LTS も検証対象から外しました（通常サポートが 2026 年 10 月に終わるためです）。Unity のレーンはローカルでも CI でも 6000.3.16f1 に固定しており、その版はテストプロジェクトから読み取ります（数字の写しを別に持ちません）。

### 落としたものを検証する

各リリースには `SHA256SUMS.txt` も入っており、そのリリースの**他のすべての** asset の SHA-256 が並んでいます（自分自身は載せられません）。落としたファイルと一緒に取得して、まとめて検査してください:

```sh
sha256sum -c SHA256SUMS.txt        # Linux
shasum -a 256 -c SHA256SUMS.txt    # macOS
```

落としていないファイルは missing として報告されます。それは想定どおりです。**取ったファイルの行がすべて `OK` であること**を確かめてください。

リリースには、落とし物とは関係のない checksum ファイルも入っています: 全部入りパッケージ用の `checksums.txt`（binary 1 つにつき 1 行）と、platform ごとのパッケージ用の `<platform>-checksums.txt` です。これらはパッケージの**中身**を対象にしているので、展開した後にしか使えません。**落とした asset そのものを対象にしているのは `SHA256SUMS.txt` のほう**です。

### Git URL では導入できない理由

**Git URL では動きません。これは意図的です。** native プラグインの binary（`.dll` / `.dylib` / `.so` / `.a`）は git で追跡していません —— 全 platform 分の binary を履歴に持つと、際限なく肥大するためです。したがって Git URL で参照すると C# のコードと Plugin Import Settings は届きますが**実際のライブラリが入らず**、すべての `DllImport` が実行時に失敗します。リリースの tarball（`com.ayutaz.opencv-unity-native.tgz`）を使ってください。

### 1 つのパッケージに全 platform

導入するパッケージには全 platform 分の binary が一緒に入っています（v0.2.0 では Windows / macOS / Linux、次の版から Android と iOS が加わります）。Unity は 1 つのパッケージ ID につき 1 つしかパッケージを許さないので、**エディタと build target の platform が違うプロジェクト**は、それらを 1 つのパッケージに入れる必要があります。以前のリリースは platform ごとの tarball を配っており、それを表現できませんでした。platform ごとの tarball は引き続き配りますが、それは 1 platform 分だけが欲しいプロジェクトのための便宜です。

各 binary の Plugin Import Settings は自分の platform でのみ有効になります。**これは主張ではなく実測です** —— EditMode のテストが、全 platform の binary を置いた状態で Unity 自身の `PluginImporter` に「その `.meta` をどう読んだか」を問います。自分で設定を覗くつもりなら、この実測で分かった 2 点を知っておく価値があります。

第 1 に、**`GetCompatibleWithEditor()` はどのプラグインでも `true` を返します。** エディタでの振り分けはそのフラグではなく、下にある `OS` の sub-setting が持っています。**フラグだけを見る検査は常に通り、何も証明しません。**

第 2 に、この検査には歯があります。macOS のライブラリが Windows でも有効だと主張するように `.meta` を意図的に壊すと、**古い 10 件のテスト群は 10/10 のまま通り**（`DllImport` の解決はファイル名の時点で分岐するので、そこでは誰も気づきません）、**gating のテストが 3 件落ちます。**

全部入りの tarball を使い捨てのプロジェクトに導入して EditMode を走らせると通ります（このマシンでの実測）。**CI は全 platform の binary を置いた状態で同じ EditMode 群を走らせる**ので、これらの検査が存在する理由である「複数 platform が同居する場合」を、CI がまさに実際に確かめています —— EditMode のテストが、全部揃っているのを見るまで緑になりません。現在の件数やサイズは[ロードマップ](docs/roadmap.md)にあります（リリースのたびに動くので、ここには写しません）。

### リリースの作り方

`v*` の tag を打つと、全 platform をビルドし、ビルドしたものの linkage を検証し、Linux のライブラリが「支える最も古い環境」より新しい glibc や libstdc++ を要求していないかを確かめ、全 platform のプラグイン木を 1 つのパッケージへ重ね、すべてをパッケージ化して、**下書き**のリリースを作ります。glibc の検査はビルド済み `.so` の中の version レコードを読むもので、ライブラリを読み込むわけではありません —— **binary が host に何を要求しているかについての主張**であって、そこで動く証明ではありません。

**この移植性の検査は、いまはリリースの経路でも走ります。以前は走っていませんでした。** これは v0.1.0 の欠陥を受けて書かれたのに、走るのは Unity と nightly のレーンだけで、そのどちらも tag では起動しません —— **つまり実際に誰かが落とす binary には一度も当たっていませんでした。** Linux を固定したコンテナでビルドすることで構造的には防げていますが、「構造で防げているから検査は要らない」は、まさに v0.1.0 が否定した論法です。

その後 workflow は、staging したものを数え、全部入りの tarball が名前で並んでいることを確かめてからアップロードします —— 名前が衝突すると、ファイルが黙って上書きされ、しかも成功したように見えるためです（`SHA256SUMS.txt` は後から書かれるので、公開されたリリースは staging した数より 1 つ多いファイルを持ちます）。**人が中身を見てから公開します。** tag を打っただけではリリースは見えません —— これは意図的で、間違ったリリースを誰かの手に渡る前に捨てられるようにするためです。

## 必要なもの

- Visual Studio 2022（C++ デスクトップ ワークロード）
- CMake 3.25 以降
- .NET 8 SDK 以降
- PowerShell 7 以降
- [GitHub CLI](https://cli.github.com/)（`gh`、認証済み）—— `tools/opencv.ps1 restore` がビルド済み OpenCV の artifact を落とすのに使います
- **Web（Wasm）のビルドにだけ要るもの:** [Ninja](https://ninja-build.org/) と Unity の WebGL Build Support。Emscripten は Visual Studio generator では駆動できないので、**Windows で Ninja が要るのはこの platform だけ**です。`PATH` の外に置いているなら `OCVU_NINJA` で渡せます。他の platform には要りません。

## 開発

**OpenCV はローカルでビルドしません。** まず固定された artifact を取得します:

```powershell
./tools/opencv.ps1 restore
```

これは、現在の構成ハッシュ（`tools/opencv-config.psd1`）に対して CI が公開しているビルド済み OpenCV 5.0.0 の artifact を落とします。`tools/opencv.ps1 build` は同じビルドをローカルで再現しますが、**CI が作ったものを検証するときだけ**使ってください。実測: CI 自身のビルド step（clone + configure + build + install + verify）は `windows-2022` の GitHub Actions runner で 4 分 09 秒でした（[run 32849957498](https://github.com/ayutaz/OpenCVUnityNative/actions/runs/32849957498)）。ローカルの所要時間は計測しておらず、ハードウェアとネットワークによって変わります。

その後のローカル開発はすべて `tools/dev.ps1` を通します:

```powershell
# tools の速いテスト、生成物の一致検査、native の 2 レーン
# （L1 GoogleTest + L3 managed P/Invoke）。**レーンは 1 つずつ走らせること** ——
# 各レーンは artifacts/test-results/ を共有し、開始時に消すためです。
./tools/dev.ps1 test

# 個別のレーン
./tools/dev.ps1 build
./tools/dev.ps1 test-native
./tools/dev.ps1 test-managed

# bindings/spec/*.json から C ヘッダ・C# の P/Invoke 宣言・到達性テスト・
# docs/api-map.md を書き出し、最新かどうかを確かめる。
# **宣言は手で書きません。** verify-generated は `test` に入っています。
./tools/dev.ps1 generate
./tools/dev.ps1 verify-generated

# AddressSanitizer のレーン（L2）
./tools/dev.ps1 test-asan

# Unity EditMode（L4）と Windows の IL2CPP Player のビルド + 実行（L5）。
# ローカルに Unity 6000.3.16f1 が要ります（Player のレーンには IL2CPP モジュールも）
./tools/dev.ps1 test-unity-editmode
./tools/dev.ps1 test-unity-player

# UPM tarball を使い捨ての Unity プロジェクトへ導入し、そこでテストを走らせる。
# -PluginSource を渡さないとこのマシンの platform 分だけを固め、**そう述べます**
# —— 全部入りのふりはしません。他 platform のプラグイン木（';' 区切り。
# 例えば公開済みリリースから展開したもの）を渡すと全部入りとして固めて検証します。
./tools/dev.ps1 test-unity-tarball
./tools/dev.ps1 test-unity-tarball -PluginSource "<mac>/package;<linux>/package"

# ビルド出力を消す
./tools/dev.ps1 clean
```

CI は Unity のレーン以外、すべて同じ `tools/dev.ps1` を呼びます。Unity のレーンでは [GameCI](https://game.ci/) がエディタの導入とライセンスのアクティベーションを行います。**この分岐は意図的で、範囲が限られています** —— **合否の判定は共有されており**、`tools/assert-unity-results.ps1` をローカルのレーンも CI も通ります。特に「テストが 0 件実行なら合格ではない」はそこにあるので、ローカルで成立して CI で黙って失効する、ということが起きません。

**ローカルが緑なのは速さのための近似で、merge の可否は CI が決めます。**

### CI が見ているもの

| | Windows x64 | macOS arm64 | Linux x64 | Android arm64 | iOS arm64 | Web wasm32 |
| --- | --- | --- | --- | --- | --- | --- |
| L1 契約テスト + L3 P/Invoke | あり | あり | あり | クロスビルドのみ | クロスビルドのみ | クロスビルドのみ |
| L2 sanitizer | ASan | — | ASan + **LeakSanitizer** | — | — | — |
| 成果物の linkage と有効言語 | あり | あり | あり | 16 KB page size | 束ねたシンボル | 束ねたシンボル + SIMD |
| Unity EditMode（L4） | ローカルのみ | ローカルのみ | **あり** | — | — | — |
| Unity IL2CPP Player（L5） | ローカルのみ | — | **あり** | — | — | — |
| **ブラウザでの端から端まで** | — | — | — | — | — | **あり** |

**Web の列だけ性質が違います** —— CI が本物の WebGL Player を建てて
**headless の Chromium で実際に走らせる**ので、EditMode と IL2CPP Player が
走らせるのと同じ検証本体がブラウザでも走ります。
**sanitizer のレーンはありません**（クロスした sanitizer は host で走らせられません）。

モバイルの列が「クロスビルドのみ」なのは、それが CI にできることの全部だからです —— コンパイルして成果物を検査しますが、**どの実機もそれらを読み込んだことがありません。**

UPM tarball を使い捨てのプロジェクトへ導入するレーン（`test-unity-tarball`）がこの表に無いのは、**どの workflow からも走らない**ためです。ローカル専用で、上に書いた「導入できて通る」という結果は手で測ったものです。

Unity のレーンは Linux で走り、Windows の IL2CPP Player はローカルのレーンだけが担います。**これはいまや推測ではなく実測に基づく結論です。** 以前ここに書いてあった理由は、実際には別の action と別のイメージ系統についての上流 issue を挙げていました。2026-08-31 に `windows-2022` で実際に試したところ、**EditMode は動いて 33 件通りました。Standalone は動きませんでした** —— IL2CPP は C++ を生成し、GameCI の Windows コンテナにはそれをコンパイルする MSVC が無いため、`ToolchainNotFoundException` でビルドが落ちます。**したがって Windows 固有の IL2CPP の欠陥は、見落としではなく設計上 CI に映りません。** macOS は同じ時期に 4 回試し、さらに手前で失敗します —— GameCI は darwin を支えず、エディタを直接入れる経路はライセンスが「entitlement 0 件」を返すところで止まります。ロードマップに両方の試行が記録されています。

**Linux の成果物は Ubuntu 22.04 のコンテナの中でビルドします**（runner のイメージ上ではありません）。共有ライブラリは、それをビルドした環境と同じかそれより新しいシステムでしか読み込めず、runner のイメージは前へ進み続けます。固定したコンテナでビルドすることで下限を意図した場所（glibc 2.35）に保ち、`tools/verify-plugin-portability.ps1` が、出てきたものがそれより新しいものを要求していればビルドを落とします。

表の外では、すべての pull request が `actionlint` / `shellcheck` / `PSScriptAnalyzer` とリポジトリ内リンクの検査を走らせ、CodeQL が C++ と C# を解析します。nightly の workflow は Linux 成果物の glibc の下限を再確認し、Windows と macOS で速いレーンを走らせ、固定した OpenCV の artifact が期限切れでないことを確かめます —— **誰も push していない間に壊れるもの**です。**この nightly はまだ schedule で起動したことがありません**。手で 2 回起動しただけで、1 回目は失敗（API のレート制限）、2 回目は緑でした。

**pull request で走るレーンのほとんどが merge を止めます。** 必須チェックは 21 本です: desktop 3 platform の契約・P/Invoke・sanitizer、Android と iOS のクロスビルド、lint の 4 job、CodeQL の 2 つ、Unity の 2 レーン、そして 5 platform 分の配布物をビルド・組み立てる release の 6 job。5 本は意図的に必須にしていません。うち 4 本は Unity のレーンが消費する platform ごとのプラグインをビルドするもので、**どれかが失敗すると Unity のレーンは走ったうえで材料が無いことで赤くなり**、それが merge を止めます。**skip された必須チェックは合格として通る**ので、その守りなしにそれらへ依存すると、壊れたビルドが通ってしまいます。**レーンは安定して緑になってから必須にします** —— 過去 2 回、早すぎる昇格が「赤いのに merge できる」隙間を作りました。2026-08-29 までは Unity・lint・CodeQL の workflow がすべての pull request で走りながら必須ではなく、**赤いまま merge できました。CI が見ていることと CI が止めることは別で、ゲートなのは後者だけです。** 残る 3 つの workflow（`build-opencv`、`nightly`、`unity-probe`）は pull request では起動しないので、そもそも必須にできません。`release` は 2026-08-31 までその一覧にありました —— いまは pull request でも走ります。tag でしか走らなかった間に配布の経路に欠陥が 3 件たまり、**うち 1 件は「tag を打つとリリースが 1 件も作られない」というものでした。** その `Publish the release` job だけは必須にしません —— pull request では設計上 skip され、**skip は合格として通る**ので、必須にしても何も止まらないからです。

## 貢献とセキュリティ

- [CONTRIBUTING.md](CONTRIBUTING.md) —— 変更がどう入るか、変更に何が必要か、そして **CI が見ていないもの**。
- [SECURITY.md](SECURITY.md) —— 脆弱性を非公開で報告する方法と、この境界で何が範囲内か。

## ライセンス

このリポジトリ自身のソースは Apache License 2.0 です。**それだけでは、配布される binary にリンクされる third-party のコードの条件は決まりません** —— 固定した OpenCV のビルドが bundle するもののライセンスは [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) にあります。同ファイルは成果物が運ぶすべてのライセンスを列挙し、component ごとに **OpenCV 自身のどの静的ライブラリにコンパイルされているか**を述べます。SoftFloat・annoylib・MSCR の chi table・Rubik フォントが、zlib・libpng・libjpeg-turbo・libclapack と並んでリンクされています（**ライセンスファイルは入っているがリンクされていないもの**もいくつかあります）。**Rubik フォントは BSD 系ではなく SIL Open Font License なので、この集合は一様ではありません。** 依存は allowlist（`tools/verify-opencv-artifact.ps1`）で縛られ、ビルド profile ごとに文書化されています。

**そのうちどれが、あなたが再配布するプラグインに実際に届くかは、このプラグインがどの OpenCV module をリンクするかで決まり、それは何度か変わってきました。** いまは `core` / `imgproc` / `imgcodecs` / `objdetect` / `features` / `geometry` / `calib` をリンクしています（`imgcodecs` の前は `core` と `imgproc` だけでした）。**静的リンクは参照されたものしか引き込まない**ので、その module に入る関数が書かれるまで、その module のコードは配布ライブラリに 1 バイトも届きません。**書くことが引き込みます** —— Windows の debug ライブラリは encode / decode の関数が入ったときに 8,831,488 から 10,177,536 バイトへ（zlib / libpng / libjpeg-turbo が一緒に来ました）、QR と ORB が入ったときに 20,136,960 バイトへ（`annoylib` と MSCR の chi_table が `features` と一緒に来ました）増えました。いまは 21,464,576 バイトで、そのうち最後の 274,432 バイトは `calibrateCamera` 1 本ぶんです（QR / ORB を測った時点からの残りの増分は、他の校正・幾何の関数によるものです）。**ビルドシステムに module を足すだけでは何も変わりません** —— `calib` をリンクしても、実際にそこへ入る関数が書かれるまで、ライブラリの大きさはちょうど 0 バイトしか動きませんでした。

**この区別は失われやすく、このリポジトリも一時期それを失っていました。** 固定した OpenCV のビルドは最初から `imgcodecs` を含む構成で、`ocvu_get_build_information()` も「To be built」にそれを並べます —— **それは「OpenCV がその module を含めてビルドされた」であって「このプラグインがそれにリンクしている」ではありません。** リンクしていなかったのですが、決着をつけたのはリンカでした —— `cv::imencode` への最初の呼び出しが未解決の外部シンボルになったのです。

通知・SBOM・build manifest は **platform ごと**に、別々のリリース asset として公開されます。全部入りの tarball が持つのは checksum の一覧だけです —— 他の 2 つは 1 つの platform の復元済み OpenCV artifact から導かれるもので、全 platform を束ねる job にはその元がありません。**統合版は導出できず、捏造することになります。** 配る platform ごとに `<platform>-THIRD_PARTY_NOTICES.md` の asset を取ってください。

Windows では、実行時ライブラリを埋め込まず共有する形でリンクしています。**このパッケージを組み込む開発者が、自分のゲームに何を同梱するかを自分で決められる**ようにするためで、パッケージ側が選択肢を奪いません。

## ドキュメント

設計と調査の文書は `docs/` にあります:

- [ロードマップ](docs/roadmap.md)
- [M0 実装計画](docs/superpowers/plans/2026-08-25-m0-tdd-harness.md)
- [M1 実装計画](docs/superpowers/plans/2026-08-25-m1-opencv-build.md)
- [M2 実装計画](docs/superpowers/plans/2026-08-26-m2-windows-vertical-slice.md)
- [M3 実装計画](docs/superpowers/plans/2026-08-28-m3-desktop-three-platforms.md)
- [M3.5 実装計画](docs/superpowers/plans/2026-08-30-m3.5-distribution-shape.md)
- [M4 実装計画](docs/superpowers/plans/2026-08-30-m4-mobile.md)
- [M5 実装計画](docs/superpowers/plans/2026-08-31-m5-binding-generator.md)
- [実機検証の手順](docs/m4-device-verification.md) —— CI では閉じないもの
- [API リファレンス](docs/api-reference.md)
- [API 対応表](docs/api-map.md) —— binding spec から生成
- [OpenUPM 登録](docs/openupm-registration.md)
- [C ABI の所有権と versioning](docs/abi-ownership-and-versioning.md)
- [Unity / OpenCV 統合の調査と計画](docs/unity-opencv-integration-research-and-plan.md)
- [native backend の言語評価と TDD 設計](docs/native-backend-language-tdd-evaluation.md)
