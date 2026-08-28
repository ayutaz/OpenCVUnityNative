OpenCV 5.0.0 を Unity 6000.x 向けに、独自の C ABI と C# API で提供する native UPM パッケージ。

## 導入

**platform ごとに 1 つの tarball を選ぶ。** 1 つの Unity プロジェクトが受け取れるのは
1 platform 分の binary だけである（`manifest.json` に同じ package ID は 1 回しか書けない）。

```jsonc
// Packages/manifest.json
{
  "dependencies": {
    "com.ayutaz.opencv-unity-native": "file:../ThirdParty/com.ayutaz.opencv-unity-native-0.1.0-windows-x64.tgz"
  }
}
```

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

各 platform の `<platform>-checksums.txt` は package の**中身**を対象にしているので、
展開後に使う。`SHA256SUMS.txt` はダウンロードする物そのものを対象にしている。

## この版の範囲

- **対応 platform**: Windows x64 / macOS arm64 / Linux x64。**mobile と Web は未対応**
- **公開 API**: `Mat` のライフサイクル（create / release / clone / get_info /
  copy_from_buffer / copy_to_buffer）と `cvtColor` / `resize` / `GaussianBlur`。
  API の広さではなく、所有権・stride・エラー処理・IL2CPP の正しさを固めた版である
- **Unity**: 6000.x のみ（2022 LTS 非対応）
- **スレッド**: 別々の `Mat` を別々のスレッドから同時に使ってよい。同じ `Mat` を
  複数スレッドから同時に使うこと、使用中に `Dispose()` することは支えない

## 同梱物

platform ごとに UPM tarball 1 つと、`checksums` / `sbom` / `build-manifest` /
`THIRD_PARTY_NOTICES` の 4 点。通知の先頭に、**その platform の成果物に実際に
入っている component の一覧**がある（本文は 3 platform 共通で、一覧に無い節も含む）。

`build-manifest.json` には OpenCV のタグ、構成ハッシュ、generator、compiler、
ビルドしたモジュール、依存バージョン、CMake flags が実測で入っている。
