# OpenUPM への登録

- 状態: **提出済み。2026-08-30 に受理された**（openupm/openupm PR #6843。`Data validation` が
  通り自動マージ）。`https://package.openupm.com/com.ayutaz.opencv-unity-native` が配信している
  （**版番号をここに書かない** —— 出すたびにこの行だけが古くなる）。
  **OpenUPM は Release より遅れる** —— 自前のビルドキューを持つので、
  公開してからレジストリに現れるまで数時間かかる（**v0.3.0 は約 4 時間**）。
  **その間 `openupm add` で入るのは 1 つ前の版である**
- **`description` は platform を名指しで列挙している。** つまり**この定義も
  platform 一覧を持つ場所の 1 つ**で、**このリポジトリを grep しても見つからない。**
  2026-09-04 に 3 platform のまま残っていたのを見つけ、6 platform に直した
  （openupm/openupm#6866）。**platform を足したらここも直すこと**
  （`add-a-platform` skill にも書いてある）
- **2026-09-04 に定義を 1 度直した** —— `description` が 3 platform のままだったので
  6 platform にした（openupm/openupm#6866）。**fork が古かったので `gh repo sync` から
  始めた。**
- **この文書は記録として残す。** 次に定義を変えるとき（platform を足す、`minVersion` を上げる）に
  同じ検査を繰り返せるようにするためである

## なぜ登録するか

OSS の Unity パッケージは [OpenUPM](https://openupm.com/) 経由で探されることが多い。
GitHub Release の tarball を配っているだけでは、**探している人に見つからない。**

これは [ロードマップ](./roadmap.md)「差別化の穴」の #3 である。

## なぜ今までできなかったか、なぜできるようになったか

**binary を git の追跡外に置いている**ので、Git tag からソースを固める通常の経路では
実体が入らない。しかし OpenUPM には `trackingMode: githubRelease` があり、
**Git tag からバージョンを見つけ、同名の GitHub Release に付いた `.tgz` を
そのまま公開する**経路が用意されている（[OpenUPM の文書](https://openupm.com/docs/adding-upm-package.html)）。

M3.5 で 2 つの前提が揃った。

1. **全部入りの tarball ができた。** OpenUPM が公開するのは tag ごとに 1 つなので、
   platform ごとに分かれていると、どれを選んでも 1 platform 分しか届かなかった。
2. **その名前から版番号を落とした。** `githubReleaseAssetName` は安定した接頭辞で
   asset を選ぶ。以前の `com.ayutaz.opencv-unity-native-<version>-<platform>.tgz` は
   版が変わるたびにパターンが合わなくなる。

## 提出前に満たす必要があったこと（**すべて満たして提出し、受理された**）

- [x] **新しい名前で公開済みのリリースが 1 つあること。**
      v0.1.1 までの asset は旧命名だったので、**`v0.2.0` を打って公開して満たした**（2026-08-30）
- [x] `package.json` の `version` をそのタグに合わせること。
      `0.2.0` で tag を打ち、突き合わせが済んだ
- [x] 全部入りの tarball が 512 MB 未満であること。
      **空撃ちが既定の `-MaxBytes` で実際に通した**（run 33286928144、2026-08-30。実測 9.6 MB）

## 提出するもの

`openupm/openupm` リポジトリへ、`data/packages/com.ayutaz.opencv-unity-native.yml` を
足す pull request を出す。

```yaml
name: com.ayutaz.opencv-unity-native
displayName: OpenCV Unity Native
description: OpenCV 5 for Unity through a project-owned C ABI. Apache-2.0.
repoUrl: 'https://github.com/ayutaz/OpenCVUnityNative'
parentRepoUrl: null
licenseSpdxId: Apache-2.0
licenseName: Apache License 2.0
topics:
  - computer-vision
  - native
hunter: ayutaz
image: null
gitTagPrefix: 'v'
gitTagIgnore: null
minVersion: '0.2.0'
# **binary は git の追跡外にあるので、tag からソースを固める既定の経路では
# 実体が入らない。** Release に添付した tarball をそのまま公開してもらう。
trackingMode: githubRelease
# 版番号を含まない安定した接頭辞。全部入りの tarball の名前と一致する。
githubReleaseAssetName: com.ayutaz.opencv-unity-native.tgz
readme: 'main:README.md'
```

**提出の直前に、`minVersion` が実在するタグかを確かめること。** リリース前に
修正が入って `v0.2.1` から出すことになれば、この値は静かに誤りになり、OpenUPM 側では
「存在しない版を最小とする定義」になる。`gh release view v<minVersion>` が引ければよい。

`minVersion` は、**新しい asset 名で出す最初のタグ**を書くのが正しい。
それより前のタグ（v0.1.0 / v0.1.1）には全部入りの asset が無く、OpenUPM の
ビルドが失敗するためである。**`0.2.0` を埋めてある** —— 全部入りの asset を
持つ最初のタグがこれになる。

## 受理は完了条件に含まない

[ロードマップ](./roadmap.md)の M3.5 は、**こちら側で閉じる範囲**（asset 名・容量・申請）
までを条件にしている。**OpenUPM 側が受理するかどうかは第三者の判断**であり、
このリポジトリの CI もレビューも判定できない。

**提出は外向きの操作なので、人が実行する。**
