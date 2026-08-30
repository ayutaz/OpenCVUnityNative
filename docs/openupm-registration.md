# OpenUPM への登録

- 状態: **準備済み。まだ提出していない。**
- 提出できる条件: **新しい名前の asset が付いた公開済みリリースが 1 つあること**（下記）

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

## 提出前に満たす必要があること

- [ ] **新しい名前で公開済みのリリースが 1 つあること。**
      現在の最新 v0.1.1 の asset は旧命名なので、**M3.5 をマージしてタグを打った後**でないと
      OpenUPM のビルドが asset を見つけられない
- [x] `package.json` の `version` をそのタグに合わせて上げること（**`0.2.0` に上げた**。tag は `v0.2.0`)
- [ ] 全部入りの tarball が 512 MB 未満であること
      （`tools/pack-upm-tarball.ps1` が既定で検査する。実測 9.6 MB（9,608,334 バイト））

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
minVersion: ''
# **binary は git の追跡外にあるので、tag からソースを固める既定の経路では
# 実体が入らない。** Release に添付した tarball をそのまま公開してもらう。
trackingMode: githubRelease
# 版番号を含まない安定した接頭辞。全部入りの tarball の名前と一致する。
githubReleaseAssetName: com.ayutaz.opencv-unity-native.tgz
readme: 'main:README.md'
```

`minVersion` は、**新しい asset 名で出す最初のタグ**を書くのが正しい。
それより前のタグには全部入りの asset が無く、OpenUPM のビルドが失敗するためである。
タグを決めてから埋めること。

## 受理は完了条件に含まない

[ロードマップ](./roadmap.md)の M3.5 は、**こちら側で閉じる範囲**（asset 名・容量・申請）
までを条件にしている。**OpenUPM 側が受理するかどうかは第三者の判断**であり、
このリポジトリの CI もレビューも判定できない。

**提出は外向きの操作なので、人が実行する。**
