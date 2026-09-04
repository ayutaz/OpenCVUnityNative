<!-- 配られる Release の本文。いまの中身は v0.3.0（2026-09-04 公開）。
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

## 検証

**この全部入りパッケージを、使い捨ての Unity プロジェクトへ導入して
確かめてある** —— **公開前にこの asset そのものを落として**展開し、
6 platform 分を材料に、同じ script（`pack-upm-tarball.ps1`）で固め直して導入した。6 つ入った状態で Unity が読み込み、
**自分の platform 向けだけを有効にする**ところまで見ている
（`native plugins present: 6` / EditMode 34 件 pass）。
**「中に 6 つ入っている」とは別の主張である。**

全 asset の SHA-256 は `SHA256SUMS.txt` にある。

```sh
sha256sum -c SHA256SUMS.txt        # Linux
shasum -a 256 -c SHA256SUMS.txt    # macOS
```

落としていないファイルは missing と出る（想定どおり）。落としたものが `OK` であればよい。

全部入りの `checksums.txt`（接頭辞なし）と、各 platform の `<platform>-checksums.txt` は
package の**中身**を対象にしているので、展開後に使う。`SHA256SUMS.txt` は
ダウンロードする物そのものを対象にしている。

## 前の版（v0.2.0）から変わったこと

- **Web / WebGL に対応した（6 つ目の platform）。** 静的ライブラリを IL2CPP の
  wasm に静的リンクし、`DllImport("__Internal")` で解決する（iOS と同じ形）。
  Unity 同梱の Emscripten と版を合わせてビルドする。**PNG は使えない**（下記）
- **Android と iOS に対応した。** 全部入りの tarball に `Android/arm64-v8a` の `.so` と
  `iOS/libopencv_unity_native.a` が入る。iOS は静的ライブラリで、Unity が IL2CPP の
  バイナリへ静的リンクし、P/Invoke は `DllImport("__Internal")` で解決する
- **Android の 16 KB page size に対応した。** Google Play は 2027-02-01 から、
  対応していないアプリの更新を受け付けなくなる。**止まるのは利用者のリリースである**
  （この `.so` が利用者のアプリに入るため）ので、その日より前に満たしてある。
  CI が実物の `.so` の `p_align` を毎回検査している
- **`WebCamTexture` から `CvMat` を作れるようになった**（`CvUnity.Unity.WebCamTextureConverter`、
  3 overload）。**新しい C ABI 関数は増えていない** —— 既存の上に立つ C# である。
  **既定で上下を反転する**（Unity は左下原点、OpenCV は左上原点）ので、
  `TextureConverter.ToTexture` へ往復させるときは `flipVertically: false` を使うこと
- **境界の宣言を手で書かなくなった。** `bindings/spec/*.json` が正本で、そこから
  C ABI 宣言・C# の P/Invoke・全 entry point を 1 回ずつ呼ぶ到達性テスト・API 対応表が
  同時に生成される。**手書きの `[DllImport]` は 0 個である。** 生成物と spec の一致は
  CI が 3 platform で毎回検査する
- **QR コードを読み書きできる**（`CvQrCode`）。符号化と復号の 2 本
- **ORB の特徴点を取れる**（`CvFeatures`）
- **射影変換を推定できる**（`CvGeometry.FindHomography`）。**解が求まらないのは
  誤りではない**ので、例外ではなく `false` で返る
- **単眼カメラの校正 3 段が揃った**（`CvCalibration`）—— 盤の格子点を見つけ
  （`FindChessboardCorners`）、そこから係数を解き（`CalibrateCamera`）、
  その係数で歪みを補正する（`Undistort`）。**各画像の姿勢も返る**（回転は
  Rodrigues の軸角ベクトル、座標系は OpenCV のもの。**Unity 座標系への変換は
  この package が持っていない**）
- **Unity の下限は 6000.3 のまま。** 検証しているのは 6000.3.16f1 の 1 版だけである

**公開している C ABI の本数は [API 対応表](https://github.com/ayutaz/OpenCVUnityNative/blob/v0.3.0/docs/api-map.md) の冒頭が数える**（この表は
リポジトリにあり、**パッケージには入らない**）。
`OCVU_ABI_VERSION` は **1 のまま変わっていない**（関数の追加は bump しない変更である）。

**出していないもの**も書いておく: ステレオ校正（`stereoCalibrate`）、魚眼、
ステレオの平行化（`stereoRectify`）、視差から 3D への復元（`reprojectImageTo3D`）、
`knnMatch` / `radiusMatch`、FLANN ベースの照合、輪郭の階層、`connectedComponents`、
`remap`、`equalizeHist`、`calcHist`、描画関数、Haar / HOG（OpenCV 5 で contrib へ移った）、
動画入出力、DNN、GPU backend。

## この版で確かめていないこと

**正直に書いておく。** M4 の完了条件のうち、いくつかは閉じていない。

**ここに件数を書かない。** 「完了条件が N 件閉じていない」と「確かめていないことが
N 個ある」は別の数え方で、混ぜると両方が信用できなくなる。**件数の正本は
リポジトリの `docs/roadmap.md` の M4 判定表である。** 下は「何を確かめていないか」
の一覧であって、条件の数え上げではない。

- **iOS の実機で動かしていない。** クロスビルドは CI で緑で、`.a` に OpenCV が
  束ねられていること（こちらの object が要求する `cv::` シンボルをその archive が
  定義していること）も CI が毎回確かめている。**しかし実機で読み込んで動かした
  実績は無い** —— 署名と端末が要り、CI では原理的に閉じない
- **Android の実機でも動かしていない。** 同上
- **lifecycle（background / foreground）と memory pressure を検証していない**
- **macOS 上で Unity を起動していない。** macOS の binary と `.meta` は
  全部入りに入って全利用者に届くが、Unity に読ませているのは Windows と Linux 上だけ
  である（`.meta` の解釈自体は `PluginImporter` に問うて確認済み）
- **Web は 1 つのブラウザでしか動かしていない。** CI は Linux の headless
  Chromium で実際に Player を起動し、P/Invoke とメモリ転送と代表処理を通して
  いる（**「ビルドできた」で止めていない**）。**しかし他のブラウザ・実機・
  モバイルのブラウザでは動かしていない**

実機で確かめる手順は `docs/m4-device-verification.md` にある。

## この版の範囲

- **対応 platform**: Windows x64 / macOS arm64 / Linux x64 / **Android arm64-v8a** /
  **iOS arm64** / **Web (WebGL)**
- **Web にだけ在る制限: 画像の encode / decode は JPEG のみで、PNG を持たない。**
  Unity の WebGL 支援が**自前の libpng を同梱している**ため、こちらが OpenCV の
  libpng を束ねると Player のリンク段でシンボルが衝突する。束ねないほうも成立
  しない（OpenCV の PNG コードが要求するシンボルが未解決になる）。**どちらの
  極端も通らないので、Web では PNG を外した。他の 5 platform は両方持つ。**
  `".png"` を渡すと失敗が返る
- **CPU アーキテクチャ**: Android は arm64-v8a のみ（x86_64 エミュレータは非対応）、
  iOS は実機の arm64 のみ（シミュレータは非対応）
- **公開 API**: `Mat` のライフサイクル（create / release / clone / get_info /
  copy_from_buffer / copy_to_buffer）、`cvtColor` / `resize` / `GaussianBlur`、
  画像の encode / decode（`CvCodecs`）、QR コード（`CvQrCode`）、ORB の特徴点
  （`CvFeatures`）、射影変換の推定（`CvGeometry`）、単眼カメラの校正 3 段
  （`CvCalibration`）、`Texture2D` と `WebCamTexture` の連携。
  **本数は [API 対応表](https://github.com/ayutaz/OpenCVUnityNative/blob/v0.3.0/docs/api-map.md) の冒頭が数える。**
  **API の広さではなく、所有権・stride・エラー処理・IL2CPP・platform の正しさを
  固めることを優先している**
- **encode / decode が扱うのはメモリ上の byte 列だけで、ファイルパスは受けない。**
  ファイルを開くのは呼ぶ側の仕事である（Windows の文字コードの扱いを境界に持ち込まない
  ため、そして Android の `StreamingAssets` は APK の中にあってパスでは開けないため）
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

**Android は third-party が 2 件多い**（`cpufeatures` の LICENSE と README。Android NDK
由来、BSD-3-Clause）。**Web は逆に 2 件少ない**（`libpng` の LICENSE と README。
上の PNG の制限と同じ理由で、**そもそも入っていない**）。
`THIRD_PARTY_NOTICES` に全文がある。

## OpenUPM

全部入りの asset 名に版番号を含めていないのは、OpenUPM の `githubReleaseAssetName` が
**安定した接頭辞**で asset を選ぶためである。**登録済み**
（`https://package.openupm.com/com.ayutaz.opencv-unity-native`）。
