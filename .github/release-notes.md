<!-- 配られる Release の本文。いまの中身は v0.4.0。
     次の版を出すときは、まずここを書き直す。手順は docs/roadmap.md の
     「配布」の step 1 にある（**このコメントは公開物に入るので短くしてある**）。 -->

OpenCV 5.0.0 を Unity 6000.3 以降向けに、独自の C ABI と C# API で提供する native UPM パッケージ。

## 導入

**全部入りの tarball を 1 つ入れる。** `com.ayutaz.opencv-unity-native.tgz` に
**Windows x64 / macOS arm64 / Linux x64 / Android arm64-v8a / iOS arm64 / Web (WebGL)**
の binary が **6 つとも**入っており、**Unity は自分の platform 向けだけを読み込む**
（Plugin Import Settings がそう決めている）。

`manifest.json` に同じ package ID は 1 回しか書けないので、**platform ごとに分かれた
tarball では「エディタは Windows、実機は Android」が表現できない**。これが全部入りを
正にした理由である。

> **Android と iOS は実機で一度も動かしていない。** CI はクロスビルドし、16 KB page
> size と束ねたシンボルを機械的に検査しているが、**どの端末もこの binary を読み込んだ
> ことがない。** 詳しくは下の「この版で確かめていないこと」を読むこと。

```jsonc
// Packages/manifest.json
{
  "dependencies": {
    "com.ayutaz.opencv-unity-native": "file:../ThirdParty/com.ayutaz.opencv-unity-native.tgz"
  }
}
```

platform ごとの tarball（`com.ayutaz.opencv-unity-native-<version>-<platform>.tgz`）も
引き続き付けてあるが、**1 platform 分だけでよい場合の補助**であって正ではない。

相対パスは `Packages` フォルダからの解決になる。絶対パスでもよい。詳しくは README の
Installing を参照。

**Git URL では導入できない。** native plugin の binary は git の追跡外にあるため、
Git URL で参照しても `.meta` しか届かず、`DllImport` が実行時に全部失敗する。
この tarball を使うこと。

### DNN を使う場合（この版で追加）

**ONNX の推論は opt-in である。** 既定では C# の API が存在しない。使うには
**Project Settings → Player → Other Settings → Scripting Define Symbols** に
`OCVU_PROFILE_DNN` を足す。

**native の binary は既定で `dnn` を含んでいる** —— 切っているのは C# 側の
assembly（`CvUnity.Interop.Dnn` / `CvUnity.Dnn`）だけである。したがって
**define を足しても binary を差し替える必要は無く、逆に足さなければ
`CvDnn` / `CvNet` は利用者のビルドから丸ごと消える**（参照が壊れた状態は
残らない）。

> **この経路は実機で一度も動かしていない。** 下の「この版で確かめていないこと」を読むこと。

## 検証

**この全部入りパッケージを、使い捨ての Unity プロジェクトへ導入して
確かめてある** —— **公開前にこの asset そのものを落として**展開し、
6 platform 分を材料に、同じ script（`pack-upm-tarball.ps1`）で固め直して導入した。6 つ入った状態で Unity が読み込み、
**自分の platform 向けだけを有効にする**ところまで見ている
（`native plugins present: 6` と EditMode が緑になるところまで）。
**件数はここに書きません** —— この本文は次のリリースでも読まれるので、
検査を 1 件足した日にこの行だけが嘘になります。
**「中に 6 つ入っている」とは別の主張である。**

**この版から、同じ検証を CI も毎回行う。** pull request のたびに、配る形の
tarball を使い捨ての Unity プロジェクトへ導入し、UPM が**ディレクトリ参照ではなく
`.tgz` で解決したこと**まで確かめている。**それでも公開前に人が 1 回回すのは、
CI が固めるのが「その時点の binary」であって**これから配る asset ではない**からである。

全 asset の SHA-256 は `SHA256SUMS.txt` にある。

```sh
sha256sum -c SHA256SUMS.txt        # Linux
shasum -a 256 -c SHA256SUMS.txt    # macOS
```

落としていないファイルは missing と出る（想定どおり）。落としたものが `OK` であればよい。

全部入りの `checksums.txt`（接頭辞なし）と、各 platform の `<platform>-checksums.txt` は
package の**中身**を対象にしているので、展開後に使う。`SHA256SUMS.txt` は
ダウンロードする物そのものを対象にしている。

## 前の版（v0.3.0）から変わったこと

**公開している C ABI は 27 本から 57 本になった。** 内訳は下のとおりで、
**`OCVU_ABI_VERSION` は 1 のまま変わっていない**（関数の追加は bump しない変更である）。

- **画像処理が 8 本増えた**（`CvOps`）—— 2 値化（`Threshold`）、Canny のエッジ検出、
  モルフォロジー（`MorphologyEx`）、射影変換の適用（`WarpPerspective`）、
  テンプレート照合（`MatchTemplate`）、輪郭抽出（`FindContours`）、
  確率的 Hough 直線（`HoughLinesP`）、コーナーの副画素精度化（`CornerSubPix`）
- **基本演算が 8 本増えた**（`CvCoreOps`）—— channel の取り出しと差し込み、
  最小・最大とその位置、範囲内判定（`InRange`）、正規化、ビット演算、
  ルックアップテーブル（`Lut`）、余白の追加（`CopyMakeBorder`）
- **姿勢推定が入った**（`CvGeometry`）—— `SolvePnP`、`ProjectPoints`、
  Rodrigues の相互変換 2 本、4 点対応からの射影変換行列（`GetPerspectiveTransform`）。
  **前の版で入った校正（内部パラメータと歪み係数）と合わせて、
  「校正して、姿勢を求めて、投影する」までが繋がった**
- **ArUco マーカーを読み書きできる**（`CvAruco`）—— 生成と検出の 2 本
- **特徴量の記述子と照合**（`CvFeatures`）—— `DetectAndCompute` と `MatchDescriptors`
- **ステレオの視差**（`CvStereo.ComputeDisparity`）。**新しい module である**
  （OpenCV の `stereo` をこの版から実際にリンクしている）
- **ONNX の推論（opt-in）**（`CvDnn` / `CvNet`）—— ONNX をメモリから読み、
  blob を作り、forward を 1 回走らせる 4 本。**`OCVU_PROFILE_DNN` を立てた
  ときだけ C# 側に現れる**（上の「導入」を参照）

**Unity 連携が 1 つ増えた。**

- **`RenderTexture` から `CvMat` を作れる**（`CvUnity.Unity.RenderTextureConverter`）。
  同期の `ToMat` と、`AsyncGPUReadback` を使う非同期の `RequestMat` がある。
  **新しい C ABI 関数は使っていない** —— 既存の上に立つ純 C# である。
  `WebCamTextureConverter` と同じ規約で**既定で上下を反転する**
  （Unity は左下原点、OpenCV は左上原点）

**公開している C ABI の本数は [API 対応表](https://github.com/ayutaz/OpenCVUnityNative/blob/v0.4.0/docs/api-map.md) の冒頭が数える**（この表は
リポジトリにあり、**パッケージには入らない**）。

**出していないもの**も書いておく: ステレオ校正（`stereoCalibrate`）、魚眼、
ステレオの平行化（`stereoRectify`）、視差から 3D への復元（`reprojectImageTo3D`）、
`knnMatch` / `radiusMatch`、FLANN ベースの照合、輪郭の階層、`connectedComponents`、
`remap`、`equalizeHist`、`calcHist`、描画関数、Haar / HOG（OpenCV 5 で contrib へ移った）、
動画入出力、GPU backend（CUDA / cuDNN は**同梱しないと決めてある**）。

## この版で確かめていないこと

**正直に書いておく。**

**ここに件数を書かない。** 「完了条件が N 件閉じていない」と「確かめていないことが
N 個ある」は別の数え方で、混ぜると両方が信用できなくなる。**件数の正本は
リポジトリの `docs/roadmap.md` の判定表である。** 下は「何を確かめていないか」
の一覧であって、条件の数え上げではない。

- **iOS の実機で動かしていない。** クロスビルドは CI で緑で、`.a` に OpenCV が
  束ねられていること（こちらの object が要求する `cv::` シンボルをその archive が
  定義していること）も CI が毎回確かめている。**しかし実機で読み込んで動かした
  実績は無い** —— 署名と端末が要り、CI では原理的に閉じない
- **Android の実機でも動かしていない。** 同上
- **DNN は実機で一度も動かしていない。上の 2 つがそのまま当てはまる。**
  推論の速さも測っていない。CI が確かめているのは、C ABI の契約（L1）、
  素の .NET から実物の binary を叩けること（L3）、Unity の中で
  `OCVU_PROFILE_DNN` を立てた assembly がコンパイルされ、**IL2CPP の
  stripping を生き延びること**までである
- **lifecycle（background / foreground）と memory pressure を検証していない**
- **macOS 上で Unity を起動していない。** macOS の binary と `.meta` は
  全部入りに入って全利用者に届くが、Unity に読ませているのは Windows と Linux 上だけ
  である（`.meta` の解釈自体は `PluginImporter` に問うて確認済み）
- **Web は 1 つのブラウザでしか動かしていない。** CI は Linux の headless
  Chromium で実際に Player を起動し、P/Invoke とメモリ転送と代表処理を通して
  いる（**「ビルドできた」で止めていない**）。**しかし他のブラウザ・実機・
  モバイルのブラウザでは動かしていない**
- **`RenderTexture` の経路は Editor でしか動かしていない。** CI は
  グラフィックス装置が在る Editor で `ToMat` / `RequestMat` を実際に走らせ、
  画素が正しく運ばれることを確かめている。**しかし IL2CPP の Player では
  走らせていない** —— Player は `-nographics` で起動され、その指定は
  CI が使う道具の側にあって変えられない
- **`dnn` が使う数値カーネル（MLAS / ONNX Runtime 由来）は、依存の allowlist
  からは見えない。** allowlist が検査するのは成果物の中の独立したライブラリで、
  `libopencv_dnn.a` に静的に取り込まれたものは現れない。`THIRD_PARTY_NOTICES` は
  1 通で全 platform を代表しており、**platform ごとに実際の集合は違う**

実機で確かめる手順は `docs/m4-device-verification.md` にある。

## この版の範囲

- **対応 platform**: Windows x64 / macOS arm64 / Linux x64 / Android arm64-v8a /
  iOS arm64 / Web (WebGL)
- **Web にだけ在る制限: 画像の encode / decode は JPEG のみで、PNG を持たない。**
  Unity の WebGL 支援が**自前の libpng を同梱している**ため、こちらが OpenCV の
  libpng を束ねると Player のリンク段でシンボルが衝突する。束ねないほうも成立
  しない（OpenCV の PNG コードが要求するシンボルが未解決になる）。**どちらの
  極端も通らないので、Web では PNG を外した。他の 5 platform は両方持つ。**
  `".png"` を渡すと失敗が返る
- **CPU アーキテクチャ**: Android は arm64-v8a のみ（x86_64 エミュレータは非対応）、
  iOS は実機の arm64 のみ（シミュレータは非対応）
- **公開 API**: `Mat` のライフサイクル、`cvtColor` / `resize` / `GaussianBlur` と
  この版で増えた画像処理 8 本（`CvOps`）、基本演算（`CvCoreOps`）、
  画像の encode / decode（`CvCodecs`）、QR コード（`CvQrCode`）、
  ArUco（`CvAruco`）、特徴点と記述子（`CvFeatures`）、
  射影変換と姿勢（`CvGeometry`）、単眼カメラの校正 3 段（`CvCalibration`）、
  ステレオの視差（`CvStereo`）、ONNX の推論（`CvDnn`、**opt-in**）、
  `Texture2D` / `WebCamTexture` / `RenderTexture` の連携。
  **本数は [API 対応表](https://github.com/ayutaz/OpenCVUnityNative/blob/v0.4.0/docs/api-map.md) の冒頭が数える。**
  **API の広さではなく、所有権・stride・エラー処理・IL2CPP・platform の正しさを
  固めることを優先している**
- **encode / decode と ONNX の読み込みが扱うのはメモリ上の byte 列だけで、
  ファイルパスは受けない。** ファイルを開くのは呼ぶ側の仕事である（Windows の
  文字コードの扱いを境界に持ち込まないため、そして Android の `StreamingAssets` は
  APK の中にあってパスでは開けないため）
- **Unity**: **6000.3 以降**（2022 LTS 非対応）。**検証しているのは 6000.3.16f1 の
  1 版だけ**である
- **スレッド**: 別々の `Mat` を別々のスレッドから同時に使ってよい。同じ `Mat` を
  複数スレッドから同時に使うこと、使用中に `Dispose()` することは支えない

## 同梱物

**全部入りの UPM tarball 1 つと、その `checksums.txt`。** これが正である。

あわせて platform ごとに UPM tarball 1 つと、`checksums` / `sbom` / `build-manifest` /
`THIRD_PARTY_NOTICES` の 4 点。通知の先頭に、**その platform の成果物に実際に
入っている component の一覧**がある（本文は全 platform 共通で、一覧に無い節も含む）。

**全部入りには `sbom` / `build-manifest` / `THIRD_PARTY_NOTICES` を付けていない。**
いずれも復元済みの OpenCV の成果物（= その job の platform のもの）から作るので、
束ねる側には元が無い。**統合版をでっち上げず**、中身の説明は platform ごとの 4 点に任せる。

asset は全部で 33 件（6 platform × 5 + 全部入りの 2 + `SHA256SUMS.txt`）。

`build-manifest.json` には OpenCV のタグ、構成ハッシュ、generator、compiler、
ビルドしたモジュール、依存バージョン、CMake flags が実測で入っている。

**`dnn` を足したぶん、third-party が増えている**（protobuf）。
**Android は third-party がさらに 2 件多い**（`cpufeatures` の LICENSE と README。
Android NDK 由来、BSD-3-Clause）。**Web は逆に 2 件少ない**（`libpng` の LICENSE と
README。上の PNG の制限と同じ理由で、**そもそも入っていない**）。
`THIRD_PARTY_NOTICES` に全文がある。

## OpenUPM

全部入りの asset 名に版番号を含めていないのは、OpenUPM の `githubReleaseAssetName` が
**安定した接頭辞**で asset を選ぶためである。**登録済み**
（`https://package.openupm.com/com.ayutaz.opencv-unity-native`）。
