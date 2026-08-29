OpenCV 5.0.0 を Unity 6000.3 以降向けに、独自の C ABI と C# API で提供する native UPM パッケージ。

## 導入

**全部入りの tarball を 1 つ入れる。** `com.ayutaz.opencv-unity-native.tgz` に
Windows x64 / macOS arm64 / Linux x64 の binary が 3 つとも入っており、**Unity は
自分の platform 向けの 1 つだけを読み込む**（Plugin Import Settings がそう決めている）。

`manifest.json` に同じ package ID は 1 回しか書けないので、**platform ごとに分かれた
tarball では「エディタは Windows、実機は別の platform」が表現できない**。これが
全部入りを正にした理由である。

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

全 asset の SHA-256 は `SHA256SUMS.txt` にある。

```sh
sha256sum -c SHA256SUMS.txt        # Linux
shasum -a 256 -c SHA256SUMS.txt    # macOS
```

落としていないファイルは missing と出る（想定どおり）。落としたものが `OK` であればよい。

全部入りの `checksums.txt`（接頭辞なし）と、各 platform の `<platform>-checksums.txt` は
package の**中身**を対象にしているので、展開後に使う。`SHA256SUMS.txt` は
ダウンロードする物そのものを対象にしている。

## この版の範囲

- **対応 platform**: Windows x64 / macOS arm64 / Linux x64。**mobile と Web は未対応**
- **公開 API**: `Mat` のライフサイクル（create / release / clone / get_info /
  copy_from_buffer / copy_to_buffer）、`cvtColor` / `resize` / `GaussianBlur`、
  **画像の encode / decode（`CvCodecs.Encode` / `CvCodecs.Decode`）**。
  API の広さではなく、所有権・stride・エラー処理・IL2CPP の正しさを固めた版である
- **encode / decode が扱うのはメモリ上の byte 列だけで、ファイルパスは受けない。**
  ファイルを開くのは呼ぶ側の仕事である（Windows の文字コードの扱いを境界に持ち込まない
  ため、そして Android の `StreamingAssets` は APK の中にあってパスでは開けないため）
- **Unity**: **6000.3 以降**（`package.json` の下限が `6000.3`。2022 LTS 非対応）。
  **検証しているのは 6000.3 LTS（6000.3.16f1）の 1 版だけ**である
- **スレッド**: 別々の `Mat` を別々のスレッドから同時に使ってよい。同じ `Mat` を
  複数スレッドから同時に使うこと、使用中に `Dispose()` することは支えない

## 同梱物

**全部入りの UPM tarball 1 つと、その `checksums.txt`。** これが正である。

あわせて platform ごとに UPM tarball 1 つと、`checksums` / `sbom` / `build-manifest` /
`THIRD_PARTY_NOTICES` の 4 点。通知の先頭に、**その platform の成果物に実際に
入っている component の一覧**がある（本文は 3 platform 共通で、一覧に無い節も含む）。

**全部入りには `sbom` / `build-manifest` / `THIRD_PARTY_NOTICES` を付けていない。**
いずれも復元済みの OpenCV の成果物（= その job の platform のもの）から作るので、
3 platform を束ねる側には元が無い。**統合版をでっち上げず**、中身の説明は platform
ごとの 4 点に任せる。

asset は全部で 18 件（3 platform × 5 + 全部入りの 2 + `SHA256SUMS.txt`）。

`build-manifest.json` には OpenCV のタグ、構成ハッシュ、generator、compiler、
ビルドしたモジュール、依存バージョン、CMake flags が実測で入っている。

## OpenUPM

全部入りの asset 名に版番号を含めていないのは、OpenUPM の `githubReleaseAssetName` が
**安定した接頭辞**で asset を選ぶためである。**登録はまだしていない。**
