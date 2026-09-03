# Unity 向け OpenCV 統合の競合調査と初期計画

- 調査基準日: **2026-08-25**（§3 と §4.6 のみ **2026-08-29** に取り直し、§4.6 の配布と OpenUPM、§8.3 の `imgcodecs` は **2026-08-30**（M3.5）に更新した。それ以外の節の数字は 08-25 のまま）
- 対象プロジェクト: **OpenCV Unity Native**（仮称）
- 対象リポジトリ: `OpenCVUnityNative`
- 想定ライセンス: **Apache License 2.0**
- 文書の状態: 調査・企画段階

## 1. 要約

2026-08-25 時点では、Unity から OpenCV を利用する代表的な選択肢は存在するが、比較対象の中に次の条件を同時に満たす成熟した製品は確認できなかった。

- OpenCV 5.x を基盤にする
- Unity と IL2CPP を主要ターゲットとして設計する
- Desktop、Android、iOS、将来の Web を一貫した UPM パッケージで扱う（**2026-09-03 追記: Web は M6 で実装した。「将来の」ではなくなっている**）
- OpenCvSharp の再梱包ではなく、Unity 用に制御した C ABI を持つ
- ソース、ネイティブバイナリの生成手順、依存関係を公開する
- プロジェクト本体を Apache-2.0 で公開する

したがって、次の位置づけであれば新規 OSS を作る価値がある。

> OpenCV 5 C++ を、Unity / IL2CPP 向けの安定した独自 C ABI と C# API で提供する、再現可能なネイティブ UPM パッケージ。

単に OpenCvSharp4 を Unity 用に再梱包するだけでは、`neon-izm/OpenCV-plus-Unity` と役割が重なる。差別化の中心は **OpenCV 5、OpenCvSharp 非依存、Unity 専用 ABI、ビルド再現性、Unity データとの効率的な連携**に置くべきである。

## 2. 調査上の区分

本書では、情報の確度を次のように区別する。

- **確認済み事実**: 公式サイト、公式ドキュメント、公式リポジトリで 2026-08-25 に確認した内容。
- **プロジェクト自己申告**: 競合リポジトリの README に記載されたテスト件数や対応状況。こちらで実機再検証はしていない。
- **提案**: OpenCV Unity Native の設計・ロードマップ案。実装済み、検証済みという意味ではない。

価格、バージョン、対応プラットフォームは変わり得るため、リリース判断に使う際はリンク先を再確認する。

## 3. OpenCV 5.x / 4.x の状況

OpenCV 公式 Releases では、2026-06-06 公開の **OpenCV 5.0.0** が Latest、2026-07-19 公開の **OpenCV 4.14.0** が最新の 4.x リリースである。[OpenCV Releases](https://github.com/opencv/opencv/releases)

OpenCV は 4.x と 5.x をともに stable branch として扱い、新機能の中心を 5.x に置きながら、4.x で開発された最適化等を 5.x に継続的に取り込む方針を説明している。[OpenCV 5 overview](https://github.com/opencv/opencv/wiki/OpenCV-5)

| 系列 | 2026-08-25 時点の最新 | 位置づけ |
| --- | --- | --- |
| OpenCV 5.x | 5.0.0 | 最新メジャー。新規設計の主対象 |
| OpenCV 4.x | 4.14.0 | 並行保守される既存安定系列 |

OpenCV 5 の Unity 統合に影響する主な変更は次のとおりである。

- 最低 C++ 標準が **C++17** になった。
- レガシー OpenCV C API が完全に削除された。
- `calib3d` は `geometry` / `calib` / `stereo` / `ptcloud` へ、`features2d` は `features` へ再編された。
- ML と G-API、Haar/HOG 系の一部機能は contrib 側へ移動した。
- 0D/1D 配列の意味と `Mat` の型に変更がある。
- **DNN エンジンが書き直された。** 5.0 のリリース告知が最初に挙げる変更がこれで、ONNX の
  カバー率が 80% を超え、LLM / VLM を扱う経路が入り、Intel IPP / Arm KleidiCV /
  Qualcomm FastCV / RISC-V RVV 向けの最適化と新しいハードウェア抽象層が加わった。
  [OpenCV 5 release announcement](https://opencv.org/opencv-5/) /
  [Phoronix](https://www.phoronix.com/news/OpenCV-5.0-Released) /
  [CNX Software](https://www.cnx-software.com/2026/06/10/opencv-5-release-new-dnn-engine-with-enhanced-onnx-and-llm-vlm-support-intel-arm-and-risc-v-hardware-optimizations/)

  **この 1 点が競合との最大の差になりうる。** 下記 4.6 のとおり Unity 向けの既存製品は
  すべて 4.x 系で、そこに載っている DNN は書き直し前のエンジンである。ただし
  「差になりうる」であって「差になる」ではない —— Unity には推論の選択肢が別にあり
  （下記 4.6）、この判断は M7 の担当である。

詳細は [OpenCV 5 documentation](https://docs.opencv.org/5.0/) と [OpenCV 4 to 5 migration guide](https://github.com/opencv/opencv/wiki/OpenCV-4-to-5-migration) を参照する。

このため、削除済みの旧 C API に依存するのではなく、**OpenCV 5 C++ API の前にプロジェクト独自の C ABI を新設する**必要がある。OpenCV 4 互換を主目的にせず、5.x のモジュール構成を基準に API を設計する方が自然である。

## 4. 競合比較

### 4.1 概要

| 選択肢 | OpenCV 系列 | Unity への適合 | 配布・ライセンス | 主な強み | 本案から見た制約 |
| --- | --- | --- | --- | --- | --- |
| OpenCV for Unity / Enox | 4.13.0 | Unity 専用品 | $95、標準 Unity Asset Store EULA | 対応プラットフォーム、サンプル、運用実績が豊富 | OpenCV 5 ではない。Java API 互換を基準とする商用製品 |
| neon-izm/OpenCV-plus-Unity | 4.11 | Unity 6000.x 用 UPM | Apache-2.0 | OSS、CI ビルド、OpenCvSharp API、Desktop/mobile | OpenCvSharp4 依存、OpenCV 4.11、Web 非対応、開始直後の規模 |
| OpenCvSharp5 | 5.x | Unity 向けではない | Apache-2.0、NuGet | OpenCV 5 の広い .NET API | managed layer が .NET 8 / C# 12。公式移行文書も Unity には OpenCvSharp4 を案内 |
| OpenCvSharp4 | 4.13 | 工夫すれば利用可能 | Apache-2.0、NuGet | .NET Standard 2.0/2.1 と既存資産 | OpenCV 5 ではなく、Unity 用パッケージングと各プラットフォーム検証が別途必要 |
| Emgu CV | 4.13.0 | 4.10 から Unity 公式サポート終了 | GPLv3 または商用ライセンス | 成熟した .NET wrapper | Unity の新規採用先としてはライセンスと公式サポートが不利 |

この比較は「絶対的に競合が存在しない」という市場主張ではない。少なくとも本調査で比較した主要候補には、OpenCV 5、Unity 専用設計、Apache-2.0、UPM、モバイル、将来の Web 対応を一度に満たす選択肢がない、という判断である。（**2026-09-03 追記: 本案側の「将来の Web」は M6 で実装済みになった。ただし競合の状況はこの調査基準日のままで、取り直していない。**）

### 4.2 OpenCV for Unity / Enox Software

[OpenCV for Unity](https://assetstore.unity.com/packages/tools/integration/opencv-for-unity-21088?locale=ja-JP) は現時点で最も強い商用競合である。

2026-08-25 に確認できた内容は次のとおり。

- Asset Store の最新バージョンは **3.0.3**、リリース日は 2026-06-07。
- 価格は **$95**、標準 Unity Asset Store EULA、ファイルサイズは 655.4 MB。
- Enox の製品ページでは **OpenCV 4.13.0** ベース、**OpenCV Java 4.13.0 と同じ API** と説明される。
- Editor、Windows、macOS、Linux、Android、iOS、UWP、WebGL、ChromeOS、visionOS beta をサポートする。
- Texture2D / `Mat` 変換、WebCamTexture、AR/VR/MR、DNN、多数のサンプルを提供する。
- 3.0.3 では Unity Sentis と OpenCV DNN を切り替える `MultiBackendDnn` / `MultiBackendNet`、MediaPipe Landmarker の例などが追加された。

根拠: [Enox product page](https://enoxsoftware.com/opencvforunity/)、[support platforms/modules](https://enoxsoftware.com/opencvforunity/documentation/)、[3.0.3 release notes](https://enoxsoftware.com/opencv-for-unity-ver3-0-3-release/)

強みは、対応範囲、Unity 向け補助機能、サンプル、商用サポートをまとめて購入できる点にある。本案は初期段階で機能数を競うべきではない。

一方、API 範囲は OpenCV Java API 互換を基準とし、OpenCV 5 ではない。本案は **OSS、OpenCV 5、C++ API に近いモジュール設計、ビルドの透明性**で異なる価値を出す。

### 4.3 neon-izm/OpenCV-plus-Unity

[neon-izm/OpenCV-plus-Unity](https://github.com/neon-izm/OpenCV-plus-Unity) は、Gobra/OpenCV-Unity を元に、OpenCvSharp を現行 Unity 向けに再構成した OSS である。

README から確認できる構成は次のとおり。

```text
OpenCV 4.11
  -> OpenCvSharpExtern
  -> OpenCvSharp 4.11 managed layer
  -> Unity adaptation
  -> com.opencvplus.unity (UPM)
```

- OpenCV 4.11 と OpenCvSharp `4.11.0.20250507` を固定している。
- macOS / iOS / Android / Windows / Linux 用バイナリを CI で作る。
- iOS の `__Internal`、ネイティブ例外の伝達、asmdef、C# 12 から C# 11 への変換など、Unity 固有の適応を行う。
- Unity 6000.x を対象とし、README では Unity 2022 を非対応としている。
- 対象アーキテクチャは macOS arm64、iOS arm64、Android arm64-v8a、Windows x86_64、Linux x86_64。
- Web / WebGL は対象一覧にない。
- 2026-08-25 時点でリポジトリは 4 commits、Releases なし。
- README は EditMode テスト **53/53 green** と記載するが、本調査ではそのテストを再実行していない。
- 配布 UPM、OpenCV、OpenCvSharp はいずれも Apache-2.0 と説明される。

これは「OpenCvSharp4 を Unity で使える UPM にする」有力な OSS である。そのため、本案の存在意義を保つには **OpenCV 5 と独自 ABI**を中核にし、OpenCvSharp のコピーや再パッケージを目的にしないことが重要である。

### 4.4 OpenCvSharp

[OpenCvSharp](https://github.com/shimat/opencvsharp) は OpenCV の代表的な .NET wrapper で、Apache-2.0 で提供される。

2026-08-25 時点の最新 GitHub Release は **5.0.0.20260806** である。[OpenCvSharp latest release](https://github.com/shimat/opencvsharp/releases/latest)

ただし、OpenCvSharp5 の managed project は `net8.0`、C# 12 を対象とする。[OpenCvSharp.csproj](https://github.com/shimat/opencvsharp/blob/main/src/OpenCvSharp/OpenCvSharp.csproj) OpenCvSharp 自身の移行ガイドも、Unity など .NET 8 以前のランタイムでは `OpenCvSharp4` 系を使うよう案内している。[OpenCvSharp migration guide](https://github.com/shimat/opencvsharp/blob/main/docs/migration-4-to-5.md)

Unity 6 の managed plug-in サポート表では、.NET Standard と .NET Framework を対象にし、.NET Core 用 plug-in は非対応である。[Unity .NET profile support](https://docs.unity3d.com/6000.0/Documentation/Manual/dotnet-profile-support.html)

したがって、OpenCvSharp5 DLL を Unity に追加するだけで OpenCV 5 が利用できるわけではない。公式 package selection が示すとおり、OpenCvSharp4 は OpenCV 4.13 と .NET Standard 2.0/2.1 を対象にするため Unity と互換性を作りやすいが、OpenCV 5 を中核にする本案とは目的が異なる。[OpenCvSharp package selection](https://github.com/shimat/opencvsharp/blob/main/docs/docfx/articles/getting-started/package-selection.md)

### 4.5 Emgu CV

[Emgu CV](https://www.emgu.com/wiki/index.php/Main_Page) は成熟した cross-platform .NET wrapper である。現行 4.13.0 は OpenCV 4.13.0 ベースである。[Emgu CV version history](https://www.emgu.com/wiki/index.php/Version_History)

ただし同じ version history は、**Emgu CV 4.10.0 から Unity 3D を公式サポートしない**と明記している。理由は利用者数と Unity Pro ライセンス費用である。公式サイト内に古い Unity 対応説明が残っていても、新規採用判断では version history の「no longer officially supported」を優先して扱う。

ライセンスは GPLv3 の open-source option と商用ライセンスのデュアルモデルである。[Emgu CV licensing](https://www.emgu.com/wiki/index.php/Licensing%3A) Apache-2.0 の Unity 用ライブラリを目指す本案にとって、直接の再利用先というより、API 設計や成熟した wrapper の比較対象である。

### 4.6 2026-08-29 の再確認

**M0〜M3 を完了し v0.1.1 を配ったあとで、比較対象の現況を取り直した。** 4.1〜4.5 は
2026-08-25 の調査で、この節はその 4 日後の再確認である。**数字が動いていないことも
記録する** —— 動いていないと確かめたことと、確かめていないことは別である。

| 項目 | 2026-08-25 | 2026-08-29 | 判定 |
| --- | --- | --- | --- |
| OpenCV for Unity | 3.0.3 / OpenCV 4.13.0 | 変わらず | **OpenCV 5 へ移っていない** |
| neon-izm/OpenCV-plus-Unity | 4 commits / OpenCV 4.11 / Release なし | **6 commits**、他は変わらず | 依然 OpenCV 4.11、Release なし |
| OpenCvSharp | 5.0.0.20260806（managed は net8.0） | 変わらず | **README は「Unity では動かないので OpenCV for Unity 等を使え」と書いている** —— §4.4 の「Unity には 4.x 系を案内」は移行ガイド由来で、README の現行の言い方はより強い |
| Emgu CV | 4.13.0 / Unity 公式サポート終了 | 変わらず（NuGet の最新は 4.13.0.5924 / 2026-05-14） | 変化なし |

**結論は変わっていない: Unity 向けに OpenCV 5 を出している製品は、商用・OSS とも
見つからない。** 「OpenCV 5 first」は今も本案だけが持つ位置である。

**ただし、この位置は時間で消える。** 競合が 5 系へ上げれば、残る差は
「OSS であること」「独自 ABI」「ビルドの再現性」だけになる。**先行している間に
何を積むかがこの再調査の論点**であって、先行していること自体は成果ではない。

#### OpenCV for Unity が持っていて本案が持たないもの

[Enox のドキュメント](https://enoxsoftware.com/opencvforunity/documentation/)で確認した
2026-08-29 時点の対応範囲。**機能の総数で競わない**方針（§7）は変えないが、
**何が無いかを数えずに「競わない」と言うのは、単に知らないのと区別がつかない。**

| 種別 | OpenCV for Unity | 本案（**この表は M3.5 時点の記録である**。その後 v0.2.0 を公開し、M4 と M5 の成果は未公開のまま。**最新の公開版は `docs/roadmap.md` の「配布」の節が正本**） |
| --- | --- | --- |
| モジュール | **30 以上**（`dnn` / `photo` / `ml` / `video` / `videoio` / `tracking` / contrib 各種を含む） | OpenCV としてビルドしているのは 6（`core` / `imgproc` / `imgcodecs` / `objdetect` / `features` / `calib`）。**プラグインがリンクしているのは 7 つ**（この 6 つに、依存として推移的に引かれる `geometry` を足したもの）で、C ABI に出ているのはさらにその一部である（**本数を数える正本は [API 対応表](./api-map.md) の冒頭**） |
| platform | Windows / macOS / Linux / Android / iOS / WebGL / UWP / ChromeOS / visionOS beta | **この行は M3.5 時点の記録**（Windows / macOS / Linux）。**その後 M4 で Android / iOS、M6 で Web が加わった** —— 現況は [ロードマップ](./roadmap.md) が持つ |
| 配布 | Asset Store から 1 つ入れれば全 platform | **1 つの tarball に Desktop 3 platform 分**（M3.5 で解消。[ロードマップ](./roadmap.md)「差別化の穴」の 1 件目）。~~**モバイルはまだ入らない**（M4）~~ **2026-08-30 に入った** |
| カメラ | `WebCamTexture` の補助クラス群、WebGPU 対応の非同期読み出し | 無し（`Texture2D` のみ） |
| 推論 | OpenCV DNN と Unity Sentis を切り替える `MultiBackendDnn` | 無し |
| サンプル | 多数 | 1 つ（`Samples~/BasicUsage`） |

**推論について 1 点補足する。** Enox が Sentis との切り替えを用意しているのは、
**Unity 利用者にとって推論エンジンは OpenCV だけではない**からである。したがって
「OpenCV 5 の新しい DNN エンジンを載せれば勝てる」とは言えない。§3 に書いたとおり
差になり**うる**が、Unity の中では Sentis が代替になる領域であり、そこへ投資するかは
M7 で判断する。

#### 配布経路: OpenUPM

OSS の Unity パッケージは [OpenUPM](https://openupm.com/) 経由で探されることが多い。
**本案はまだ登録していない**（申請には公開済みのリリースが 1 つ要るので、次の版のあとに
なる）。**登録できる形にする作業は M3.5 で終わっている** —— 下記の 2 つの制約はどちらも
満たした。手順と残りの条件は [OpenUPM への登録](./openupm-registration.md) にある。

登録の障害になると考えていたのは「binary を git の追跡外に置いている」点だが、
[OpenUPM のドキュメント](https://openupm.com/docs/adding-upm-package.html)には
`trackingMode: githubRelease` があり、**Git tag からバージョンを見つけ、同名の
GitHub Release に付いた `.tgz` をそのまま公開する**経路が用意されている。
本案はすでに tag から Release を作り tarball を添付しているので、**この形は使える**。

**OpenUPM の側は、複数の asset があっても困らない。** `githubReleaseAssetName` に
名前のパターンを書けば、その 1 つを選んで公開できる。**困るのは利用者だった** ——
platform ごとの tarball のうち 1 つを選んで公開すれば、`openupm add` で入るのは
その platform 分の binary だけになる。**この前提は M3.5（2026-08-30）で消えた** ——
全部入りの tarball を正にしたので、`githubReleaseAssetName` が選ぶ 1 つに
Desktop 3 platform 分が入る。

実装時に効く細かい制約が 2 つあった。**どちらも M3.5（2026-08-30）で満たした。**

**(1) パッケージは 512 MB 未満であること。** `tools/pack-upm-tarball.ps1` が固めたあとの
バイト数を見て、超えていれば落とす（`-MaxBytes`。既定は 512 MB）。**上限を引数にしたのは、
落ちるところを見られるようにするためである** —— 既定値のままでは現状の配布物が上限まで
大きく余裕があり、この検査が働くところを誰も確かめられない。**検査は packer に置いた**
（呼ぶ側が `release.yml` と `dev.ps1 test-unity-tarball` の 2 つあり、片方に置くと
もう片方が素通しする）。**全部入りの tarball は 9.6 MB**（2026-08-30、CI 実測。内訳は下記）なので、
**効いてくるのは DNN や contrib を含む profile を配る段階（M7）である。**

**(2) 版番号を含まない安定した接頭辞の asset 名。** 全部入りの名前を
`com.ayutaz.opencv-unity-native.tgz` にした（版番号なし）。platform ごとの tarball は
`…-<version>-<platform>.tgz` のままで、OpenUPM が見るのは全部入りの 1 つだけである。

内訳の実測は次のとおり。**実際に配った v0.1.1 の tarball は 3 platform 合計で
8.0 MB** である（2026-08-29 に Release の asset サイズを実測: linux-x64 3,639,983 /
macos-arm64 1,931,691 / windows-x64 2,472,421 バイト）。**全部入りは 9.6 MB（9,608,334 バイト）**
（2026-08-30、CI が v0.2.0 の内容で組んだ物の実測）で、どちらも上限に対して 1 桁以上小さい。**具体的な倍率は書かない** —— 配布物が大きくなるたびに嘘になり、実際に一度そうなった。

**大きくなった理由も同じ run で測れた。** v0.2.0 の platform 別 tarball は
windows-x64 2,903,842 / macos-arm64 2,424,607 / linux-x64 4,311,381 バイトで、
v0.1.1 の同じ 3 本より **+431,421 / +492,916 / +671,398** である。3 platform とも
同じ桁で増えているので、差は `imgcodecs` をリンクして関数を足したぶんの
binary の成長で説明が付く（**全部入りが「3 本の合計」より大きいわけではない** ——
共通ファイルを 1 回しか含まないので、9,608,334 は 3 本の合計 9,639,830 より
わずかに小さい）。**モバイルを足した後の値は
測っていない** —— iOS は静的リンクなので共有ライブラリと同じ桁とは限らず、
Android で何 architecture を積むかも未定
（[ロードマップ](./roadmap.md)「差別化の穴」#8）。

## 5. 自作 OSS の価値

### 5.1 価値が成立する条件

本案は、次の条件を守る場合に価値がある。

1. **OpenCV 5 first**: 4.x wrapper の移植ではなく、5.x のモジュール再編と型を基準にする。
2. **Unity first**: Mono で偶然動く .NET wrapper ではなく、IL2CPP、AOT、iOS static link、Android、Web を設計条件に含める。
3. **独自の狭い C ABI**: C++ ABI や STL 型を外部境界へ出さず、バージョン管理可能な ABI を所有する。
4. **UPM first**: Unity Package Manager から導入でき、asmdef、Plugin Import Settings、Samples、Tests を同梱する。
5. **再現可能なバイナリ**: OpenCV の tag、build options、toolchain、patch、hash を固定し、CI から同じ成果物を再生成できる。
6. **Unity データ経路を最適化**: Texture2D、WebCamTexture、NativeArray、将来の RenderTexture / native texture 連携を主要 API にする。
7. **依存関係を最小化・可視化**: 初期リリースでは不要な codec/backend を外し、配布物ごとのライセンスと構成を公開する。

独自 C ABI は、native bridge の実装言語を C++ に固定する要求ではない。C++ または Rust のどちらを選んでも、Unity に公開する ABI、C# API、ownership contract、binding specification は同一に保つ。

### 5.2 作らないもの

- OpenCV アルゴリズム自体の再実装
- OpenCV の全 API を初回から手書きで包む巨大 wrapper
- OpenCvSharp の名前や managed API を互換目的で複製するもの
- 動画 codec、DNN、contrib、GPU backend を初期版にすべて詰め込んだ単一巨大バイナリ

## 6. 推奨アーキテクチャ

```text
Unity application
    |
    v
Unity integration layer
(Texture2D / WebCamTexture / NativeArray / lifecycle)
    |
    v
C# public API + generated P/Invoke declarations
    |
    v
Versioned, project-owned C ABI
(opaque handles / error codes / explicit ownership)
    |
    v
Selected native bridge
(direct C++ or Rust with a C++ binding layer)
    |
    v
OpenCV 5 C++ API
```

Unity は native plug-in を C# の `DllImport` / P/Invoke から呼び出せる。iOS では静的リンクした関数を `DllImport("__Internal")` で参照する。C++ 実装は name mangling を避けるため `extern "C"`、Rust 実装は明示的な C ABI と unmangled export を使う。[Unity native plug-ins](https://docs.unity3d.com/6000.0/Documentation/Manual/plug-ins-native.html)、[Unity iOS native plug-in](https://docs.unity3d.com/ja/current/Manual/ios-native-plugin-create.html)、[Rust Reference: external blocks and ABI](https://doc.rust-lang.org/reference/items/external-blocks.html)

この境界に合わせ、OpenCV の C++ クラスを直接公開せず、次の原則で C ABI を設計する。

- `cv::Mat*` などは外へ見せず、`ocvu_mat_handle` のような opaque handle を使う。
- `int32_t`、`uint64_t`、明示した struct など、サイズが固定できる型だけを ABI に出す。
- OpenCV / C++ 例外と Rust panic を ABI の外へ伝播させず、status code と thread-local error detail に変換する。
- create / retain / release、borrowed / owned をすべて API 仕様に明記する。
- ABI version、OpenCV version、build features を実行時に問い合わせられるようにする。
- 文字列の encoding と、どちらが確保・解放するかを固定する。
- IL2CPP stripping と AOT を前提に P/Invoke 宣言を保持・検証する。
- 毎フレームの細かな境界呼び出しを避け、必要に応じて処理をまとめた API も用意する。

C ABI と C# 宣言は、手書きの C++ header を無制限に解析して直接生成するのではなく、まずサポート対象 API を表す **レビュー可能な binding specification** を正本にする案を推奨する。そこから C ABI declaration、C# P/Invoke、API 対応表、最低限の conformance tests を生成すれば、OpenCV の巨大な API を段階的に扱える。

### 6.1 Native bridge を C++ / Rust のどちらで実装するか

OpenCV 自体は C++ ライブラリである。Rust 案は OpenCV を Rust で再実装する案ではなく、**Unity に公開する独自 C ABI を Rust で実装し、その内側から OpenCV C++ を呼ぶ案**である。

代表的な呼び出し経路は次のようになる。

```text
C++ 案:
Unity C# -> project-owned C ABI -> OpenCV C++

Rust 案:
Unity C# -> project-owned C ABI exported by Rust
          -> opencv-rust generated C++ bridge -> OpenCV C++
```

2026-08-25 時点で `opencv` crate 0.100.1 は OpenCV 5.x に対応し、OpenCV C++ header を libclang で解析して生成した C interface を Rust API で包む方式を採る。主な開発・テスト対象として Linux、macOS、Windows を挙げ、最低 Rust version は 1.88.0 である。一方、同プロジェクトは API を unstable / not very battle-tested と説明し、特に参照カウントされた `Mat` の共有可変性について、通常の Rust の安全性保証を期待しないよう注意している。[opencv-rust README](https://github.com/twistedfall/opencv-rust)、[opencv-rust changelog](https://docs.rs/crate/opencv/latest/source/CHANGES.md)

| 観点 | C++ bridge | Rust bridge |
| --- | --- | --- |
| OpenCV までの経路 | OpenCV C++ を直接呼ぶ | generated C++ bridge を介して OpenCV C++ を呼ぶ |
| 独自 C ABI | `extern "C"` で公開 | `extern "C"` と unmangled export で公開 |
| 所有権・handle table | 規約とテストで管理 | safe wrapper を構成しやすいが、FFI pointer と `Mat` は unsafe contract が残る |
| 例外・panic | C++ 例外を status code に変換 | OpenCV error と Rust panic の両方を C ABI の内側で止める |
| build toolchain | CMake と platform C/C++ toolchain | Cargo / rustc に加え、OpenCV、CMake、Clang、platform linker が必要 |
| upstream wrapper 依存 | 原則なし | `opencv` crate とその生成 C++ bridge に依存 |
| Desktop 初期実装 | 最短で低リスク | 十分実現可能だが依存固定と検証が増える |
| Mobile / Web | OpenCV / Unity の標準 toolchain に近い | Rust cross target と OpenCV toolchain の統合検証が追加で必要 |

Rust を採用する場合も、次の条件は変えない。

- `opencv` crate の型や ABI を public API に露出せず、`ocvu_` C ABI を唯一の native contract にする。
- OpenCV error、Rust `Result`、Rust panic を status code と last-error に正規化し、C ABI を越えて exception / unwind を伝播させない。FFI 境界を越える不正な unwind は未定義動作になり得る。[Rust Reference: panic across FFI boundaries](https://doc.rust-lang.org/reference/panic.html#unwinding-across-ffi-boundaries)
- raw pointer、stride、buffer length、alignment、borrowed lifetime は binding specification に明記し、Rust 側だけで安全と仮定しない。
- `opencv` crate、Rust toolchain、Clang、OpenCV の version と hash を artifact manifest に記録する。
- `opencv` crate の MIT license と transitive dependency を third-party notices / SBOM の対象に含める。

Rust 自体は Android arm64 と iOS arm64 の cross-compilation target を提供するが、`opencv` crate と OpenCV C++ を含む最終 native artifact の生成・リンク・実機テストは本プロジェクトが所有する必要がある。[Rust Android platform support](https://doc.rust-lang.org/rustc/platform-support/android.html)、[Rust iOS platform support](https://doc.rust-lang.org/rustc/platform-support/apple-ios.html)

Web は Rust 案の最大の事前検証項目とする。Unity が同梱する Emscripten version に合わせた Wasm object / archive が必要であり、Rust target、generated C++ bridge、OpenCV を同一条件でリンクできることを Phase 5 の開始条件にする。

#### Phase 0 の実装言語判断 spike

現時点では C++ / Rust のどちらも確定しない。Phase 0 で Rust による Windows x86_64 spike を行い、次をすべて確認してから Architecture Decision Record で採否を決める。

1. 固定した Rust / `opencv` crate / OpenCV 5 / MSVC toolchain から native library を再現可能に生成できる。
2. `ocvu_get_abi_version` と `ocvu_get_opencv_version` を C# P/Invoke から呼べる。
3. `Mat` の create / wrap / release と `cvtColor` を、明示した pointer、length、stride、lifetime contract で実行できる。
4. OpenCV error と意図的な Rust panic が C ABI の外へ伝播せず、status code と last-error に変換される。
5. native test、managed interop test、Unity Editor Mono、Windows IL2CPP Player の smoke test が通る。
6. build manifest、依存ライセンス、symbol、binary size、境界呼び出し overhead を記録できる。

この spike が成立し、追加 toolchain と upstream binding dependency の保守コストを許容できる場合は Rust を採用候補とする。再現性、例外境界、IL2CPP、または将来 platform の見通しを満たせない場合は direct C++ bridge を採用する。採用後は production backend を一つに絞り、同じ機能の C++ / Rust 二重実装を維持しない。

### 6.2 プラットフォーム方針

| Platform | Native 形態 | 主な注意点 |
| --- | --- | --- |
| Windows | `.dll` | x86_64 を初期対象。calling convention と CRT を固定 |
| macOS | `.dylib` または bundle | arm64 / x86_64 または universal。署名・rpath を検証 |
| Linux | `.so` | glibc baseline、rpath、依存 `.so` を管理 |
| Android | `.so` | arm64-v8a から開始。NDK/API level、16 KB page size を CI で検証 |
| iOS | static `.a` / source link | `__Internal`、`extern "C"`、arm64、linker stripping を検証 |
| Web | Wasm object を含む `.a` | Unity 同梱 Emscripten と一致させ、スレッド/SIMD 条件を分離 |

Unity は Web native plug-in について、Unity に同梱された Emscripten と一致する toolchain で `.o` を作り、`.a` にまとめる方法を推奨している。Unity のバージョンで Emscripten が変わる場合は再ビルドが必要である。[Unity Web native plug-ins](https://docs.unity3d.com/6000.0/Documentation/Manual/webgl-native-plugins-with-emscripten.html)

## 7. 差別化ポイント

優先順位は次の順とする。

1. **OpenCV 5.x**
2. **Apache-2.0 の OSS**
3. **OpenCvSharp 非依存の Unity 専用 C ABI**
4. **Mono / IL2CPP / AOT を同じ公開 API で検証**
5. **UPM で導入可能**
6. **CI から再現できる各プラットフォームの native binaries**
7. **Texture2D / NativeArray 等との低コピー連携**
8. **サポート API、platform、build feature、第三者ライセンスの機械可読 manifest**
9. **小さな標準 build と、contrib / DNN / 動画 codec 等の opt-in build profile**（画像の codec = `imgcodecs` は M3.5 で標準 build に入った。ここで言う codec は動画のそれである）
10. ~~**将来の Web / Wasm 対応**~~（**2026-09-03: M6 で実装した。「将来の」ではない**）

OpenCV for Unity には、完成度、対応機種、サンプル、商用サポートでは当面及ばない。比較軸を「機能の総数」ではなく「OpenCV 5、OSS、C++ に近いモジュール、ABI の透明性、再現可能なビルド」に置く。

neon-izm 版に対しては「OpenCvSharp4 の Unity 適応」を繰り返さず、「OpenCV 5 の Unity 専用統合」に集中する。

## 8. Apache-2.0 と第三者依存ライセンス

### 8.1 プロジェクト本体

OpenCV 4.5.0 以降は Apache License 2.0 であり、OpenCV 5.0.0 も同ライセンスである。[OpenCV license](https://opencv.org/license/)

したがって、独自に実装する native bridge、C# layer、generator、UPM integration を Apache-2.0 で公開する方針は成立する。ただし、Apache-2.0 で配布する際は少なくとも以下を管理する。

- `LICENSE` に Apache License 2.0 の全文を含める。
- 再配布する Apache-2.0 成果物のライセンス、copyright、attribution を保持する。
- upstream の `NOTICE` が存在する場合は、必要な notice を配布物へ引き継ぐ。
- upstream ファイルを変更して再配布する場合は変更した旨を明示する。
- Apache-2.0 の patent grant と patent litigation による termination を理解する。

根拠は [Apache License 2.0 section 3 and 4](https://www.apache.org/licenses/LICENSE-2.0) を参照する。

### 8.2 「本体が Apache-2.0」と「バイナリ内の全依存が Apache-2.0」は別

OpenCV の CMake には、FFmpeg、GStreamer、JPEG、PNG、TIFF、WebP、OpenEXR、protobuf、IPP など、多数の optional / bundled / system dependency がある。たとえば `WITH_FFMPEG` は既定で有効で、Windows では configure 時に prebuilt FFmpeg plug-in が取得される場合がある。[OpenCV configuration options](https://docs.opencv.org/5.0/tutorials/introduction/config_reference/config_reference.html)

したがって、プロジェクトのソースを Apache-2.0 にしても、最終バイナリに組み込んだ第三者コードの条件は消えない。配布 profile ごとに実際の build log とリンク結果から依存を確定し、それぞれのライセンス、notice、source-offer 等の要否を確認する。これは法的助言ではなく、公開前には配布対象地域と利用構成に応じた法務確認が必要である。

### 8.3 推奨する初期方針

- 初期 vertical slice は `core` と `imgproc` を中心にし、Unity の Texture / buffer を入力に使う。
- `videoio` と FFmpeg/GStreamer は初期標準 build から外す。
- `imgcodecs` は**標準 build に入れた**（M3.5、2026-08-30）。notice は既に `THIRD_PARTY_NOTICES.md` に揃っており、C ABI に出したのはメモリ上の byte 列を相手にする `imencode` / `imdecode` の 2 本である。**それ以前は「モジュールはリンク済み」と書かれていたが、実際には `cmake/FindOpenCvUnityDeps.cmake` が `core` と `imgproc` しかリンクしていなかった** —— OpenCV 側がその module を含めてビルドされていることと、こちらのプラグインがリンクしていることは別である。
- DNN、contrib、Tesseract、OpenEXR、GPU backend は個別 profile として後から追加する。
- CMake configure summary を保存し、期待していない dependency が有効なら CI を失敗させる。
- native artifact ごとに OpenCV tag、contrib tag、compiler、toolchain、CMake flags、依存 version、hash を manifest 化する。

公開前に用意するファイルの案:

```text
LICENSE
NOTICE
THIRD_PARTY_NOTICES.md
artifacts/<platform>/build-manifest.json
artifacts/<platform>/sbom.spdx.json
```

## 9. 初期ロードマップ

各段階の完了条件には、native 単体テストだけでなく、実際の Unity Player から C# -> P/Invoke -> C ABI -> OpenCV を通る smoke test を含める。

**この節は起草時（2026-08-25）のロードマップであり、実際に実行された計画は
[ロードマップ](./roadmap.md) の M0〜M7 である。** そのまま残してあるのは経緯の記録の
ためで、現在地の判断には使わないこと。特に Phase 0 の「Rust spike」は**実施していない**
—— C++ を選ぶ判断が spike 無しで確定した（理由は
[Native backend 実装言語の評価](./native-backend-language-tdd-evaluation.md)）。

### Phase 0: 方針・互換性契約

- OpenCV 5.0.0、Unity 6、Windows x86_64 を最初の基準として固定する。
- public C# API、C ABI naming、ownership、error model、semantic versioning を文書化する。
- Rust の Windows vertical-slice spike を実施し、C++ / Rust の native bridge 実装言語を Architecture Decision Record で確定する。
- 標準 build に含める OpenCV module / dependency の allowlist を決める。
- Apache-2.0 の `LICENSE`、`NOTICE`、第三者 notice の運用を決める。
- native、managed、Unity のテスト層を用意する。

### Phase 1: Windows vertical slice

- `Mat` の create / wrap / clone / query / release。
- `cvtColor`、`resize`、`GaussianBlur` など少数の `imgproc` API。
- Texture2D / NativeArray からの入力と結果反映。
- status code、last-error、ABI/version query。
- Unity Editor Mono と Windows IL2CPP Player の end-to-end test。
- ローカル参照できる最小 UPM package。

この段階では API の広さより、所有権、stride、pixel format、例外、IL2CPP、破棄漏れを正しくする。

### Phase 2: Desktop と配布の再現性

- Windows、macOS、Linux の CI build。
- platform / architecture 別の native artifact と Plugin Import Settings。
- Git URL または tarball から導入できる UPM package。
- artifact manifest、checksums、third-party notices、SBOM。
- Unity sample と最小 API reference。

### Phase 3: Mobile

- Android arm64-v8a と iOS arm64。
- Android 16 KB page size、iOS `__Internal` static link を含む実機 smoke test。
- カメラ入力はまず Unity の WebCamTexture / AR Foundation 側から受ける。
- lifecycle、background/foreground、memory pressure を検証する。

### Phase 4: API 拡張と generator

- binding specification から C ABI / P/Invoke / docs / conformance tests を生成する。
- OpenCV 5 の `geometry`、`calib`、`features`、`objdetect` などを利用例に基づき追加する。
- API 対応表を生成し、「OpenCV 全対応」という曖昧な表現を避ける。

### Phase 5: Web / Wasm

- Unity version と Emscripten version の対応 matrix を作る。
- single-thread / SIMD を先に、threads を別 profile で検証する。
- Web Player の起動、P/Invoke、メモリ転送、代表処理の browser E2E test を行う。

### Phase 6: Advanced / optional profiles

- DNN、contrib、codec/videoio、platform acceleration を opt-in で追加する。
- RenderTexture / native texture pointer / AsyncGPUReadback を使う低コピー経路を評価する。
- package size、startup time、frame time、allocation を benchmark として公開する。

## 10. 想定ディレクトリ構成

**これは起草時（2026-08-25）の想定であり、実物とは違う。** 実際の配置は
`CLAUDE.md` の「ファイル配置」の表が正本である。主な違い: `Runtime/` の下は
`Interop` / `Core` / `UnityIntegration` の 3 つで **`ImgProc/` は作らなかった**
（`CvOps` と `CvCodecs` は `Core` にある）。package の下の `Tests/` と
`Documentation~/` も無い（テストは `tests/` 以下、文書は `docs/` 以下）。
`bindings/` は **M5（2026-09-01）で実在するようになった** —— ただし `spec/` と
`generator/` の 2 つだけで、**`generated-checks/` は作っていない**（生成物の
一致検査は既存のレーンに載せた。理由は roadmap の M5 節）。**公開 C ABI の
ヘッダも 1 枚ではない** —— `native/include/opencv_unity_native.h` は型・定数・
status を持つ入口で、関数宣言は module ごとの `native/include/ocvu/*.h`
（いずれも spec からの生成物）にある。

```text
OpenCVUnityNative/
|-- .github/
|   `-- workflows/                 # native / Unity / packaging CI
|-- cmake/                         # toolchains and dependency policy
|-- native/
|   |-- include/
|   |   `-- opencv_unity_native.h  # public C ABI
|   |-- backend/                   # selected C++ or Rust implementation
|   |-- tests/
|   `-- build files                # CMake and, when selected, Cargo/build.rs
|-- bindings/
|   |-- spec/                      # reviewed supported-API specification
|   |-- generator/                 # C ABI / C# / docs generation
|   `-- generated-checks/          # generated-output consistency tests
|-- Packages/
|   `-- com.<owner>.opencv-unity-native/
|       |-- Runtime/
|       |   |-- Interop/
|       |   |-- Core/
|       |   |-- ImgProc/
|       |   |-- UnityIntegration/
|       |   `-- Plugins/
|       |-- Tests/
|       |-- Samples~/
|       |-- Documentation~/
|       |-- CHANGELOG.md
|       |-- LICENSE.md
|       |-- Third Party Notices.md
|       `-- package.json
|-- tests/
|   `-- UnityProject/              # Editor and Player end-to-end tests
|-- tools/                          # build, package, manifest, SBOM helpers
|-- docs/
|-- LICENSE
|-- NOTICE
|-- THIRD_PARTY_NOTICES.md
`-- README.md
```

`com.<owner>.opencv-unity-native` の `<owner>` は公開主体が決まってから置換する。package ID は公開後の変更コストが高いため、仮の組織名で確定しない。

`native/backend/` は Phase 0 の spike 中のみ候補別の作業領域を持ち得る。実装言語の決定後は選択した production backend だけを残し、public C header と binding specification は backend から独立させる。

## 11. 命名方針

### 11.1 推奨

| 用途 | 推奨名 | 理由 |
| --- | --- | --- |
| GitHub repository | `OpenCVUnityNative` | 検索時に Unity / OpenCV / native の目的が明確 |
| 表示名 | OpenCV Unity Native | 説明的で初見でも用途が分かる |
| ブランド候補 | `CvUnity` | 短く、namespace や将来の ecosystem 名に使いやすい |
| C# namespace 候補 | `CvUnity` | 簡潔で OpenCV for Unity の namespace と混同しにくい |
| native library | `opencv_unity_native` | OS ごとの dll/so/dylib 名に展開しやすい |
| C ABI prefix | `ocvu_` | 衝突しにくく、関数名を短く保てる |

推奨する二段構えは次のとおり。

- リポジトリと説明上の正式名: **OpenCVUnityNative / OpenCV Unity Native**
- public C# API と将来のブランド: **CvUnity**

例:

**この例は起草時（2026-08-25）の案であり、実装された API とは違う。** 実物は
[API リファレンス](./api-reference.md) にある。`CvMat.Wrap` は **M2 で意図的に捨てた**
（借用 handle を作らない決定。[所有権と versioning](./abi-ownership-and-versioning.md) §1）。
実装された形はこうなる:

```csharp
using CvUnity;

using var source = CvMat.Create(height, width, CvMatType.Bgra32);
source.CopyFrom(bgraPixels, stride);
using var gray = CvMat.Create(height, width, CvMatType.Gray8);
CvOps.CvtColor(source, gray, CvOps.Bgr2Gray);
```

避ける名前:

- `OpenCV for Unity` / `OpenCV-for-Unity`: Enox Software 製品とほぼ同名で混同する。
- `OpenCV-plus-Unity`: 既存 OSS と同名になる。
- `UnityCV`: 短いが一般的すぎて検索・商標・package namespace の衝突調査が難しい。

公開前には GitHub、UPM ecosystem、NuGet、ドメイン、商標の最新状況を別途確認する。

## 12. 初回実装前に決めること

**このうち決まったものは `CLAUDE.md` の「決定済みで、計画書 §12 の記述より新しいもの」の
表にある。以下は起草時の一覧をそのまま残したものである。**

- 対応する最小 Unity 6 version と、Unity 2022 LTS を初期対象に含めるか。
- 最初の package ID と公開 organization。
- OpenCV 5.0.0 を固定する期間と、5.x update policy。
- source build を consumer に要求するか、prebuilt binaries を正式配布するか。
- Phase 0 spike の結果に基づく C++ / Rust の native bridge 実装言語。
- Windows x86_64 の vertical slice で採用する compiler / Rust toolchain / runtime linkage。
- `Mat` が所有する memory と Unity が所有する NativeArray memory の lifetime contract。
- C ABI の versioning と backward compatibility policy。
- 初期 `core` / `imgproc` API の具体的な allowlist。
- 各 platform で必須とする Editor / Mono / IL2CPP / device test matrix。
- Apache-2.0 表示、third-party notice、SBOM の公開フロー。

## 13. 結論

このプロジェクトは、**OpenCV 5 を Unity へ持ち込むための独自 C ABI と UPM integration** に焦点を絞れば、既存候補と異なる価値を持つ。

初期成功条件は API 数ではない。Windows 上の小さな vertical slice で、Unity Editor と IL2CPP Player の両方から同じ C# API を通して OpenCV 5 が動き、memory ownership、error handling、native artifact、license manifest を再現できることが最初の到達点である。

native bridge の実装言語は現時点で確定しない。public C ABI と binding specification を言語中立な契約として先に定め、Phase 0 の Rust spike で再現性、FFI error boundary、Mono / IL2CPP、保守対象 toolchain を検証したうえで、C++ または Rust の production backend を一つ選ぶ。

そこから Desktop、mobile、generator、Web、optional profiles の順に広げることで、巨大な OpenCV API と複雑な第三者依存を制御しながら、Apache-2.0 OSS として持続可能な形にできる。

## 14. 主要情報源

2026-08-25 に確認した一次情報を中心に記載する。

- [OpenCV releases](https://github.com/opencv/opencv/releases)
- [OpenCV 5 overview](https://github.com/opencv/opencv/wiki/OpenCV-5)
- [OpenCV 5 documentation](https://docs.opencv.org/5.0/)
- [OpenCV 4 to 5 migration guide](https://github.com/opencv/opencv/wiki/OpenCV-4-to-5-migration)
- [OpenCV license](https://opencv.org/license/)
- [OpenCV configuration options](https://docs.opencv.org/5.0/tutorials/introduction/config_reference/config_reference.html)
- [Unity native plug-ins](https://docs.unity3d.com/6000.0/Documentation/Manual/plug-ins-native.html)
- [Unity iOS native plug-in](https://docs.unity3d.com/ja/current/Manual/ios-native-plugin-create.html)
- [Unity Web native plug-ins with Emscripten](https://docs.unity3d.com/6000.0/Documentation/Manual/webgl-native-plugins-with-emscripten.html)
- [Unity .NET profile support](https://docs.unity3d.com/6000.0/Documentation/Manual/dotnet-profile-support.html)
- [OpenCV for Unity - Asset Store](https://assetstore.unity.com/packages/tools/integration/opencv-for-unity-21088?locale=ja-JP)
- [OpenCV for Unity - Enox Software](https://enoxsoftware.com/opencvforunity/)
- [OpenCV for Unity documentation](https://enoxsoftware.com/opencvforunity/documentation/)
- [neon-izm/OpenCV-plus-Unity](https://github.com/neon-izm/OpenCV-plus-Unity)
- [OpenCvSharp](https://github.com/shimat/opencvsharp)
- [OpenCvSharp 4 to 5 migration guide](https://github.com/shimat/opencvsharp/blob/main/docs/migration-4-to-5.md)
- [OpenCvSharp package selection](https://github.com/shimat/opencvsharp/blob/main/docs/docfx/articles/getting-started/package-selection.md)
- [opencv-rust](https://github.com/twistedfall/opencv-rust)
- [opencv-rust changelog](https://docs.rs/crate/opencv/latest/source/CHANGES.md)
- [Rust Reference: external blocks and ABI](https://doc.rust-lang.org/reference/items/external-blocks.html)
- [Rust Reference: panic](https://doc.rust-lang.org/reference/panic.html)
- [Rust Android platform support](https://doc.rust-lang.org/rustc/platform-support/android.html)
- [Rust iOS platform support](https://doc.rust-lang.org/rustc/platform-support/apple-ios.html)
- [Emgu CV version history](https://www.emgu.com/wiki/index.php/Version_History)
- [Emgu CV licensing](https://www.emgu.com/wiki/index.php/Licensing%3A)
- [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0)
