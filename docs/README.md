# OpenCV Unity Native documentation

このディレクトリは、Unity 向け OpenCV 5 ネイティブ統合 OSS **OpenCV Unity Native**（仮称）の調査・設計資料をまとめる場所です。

## Documents

- [ロードマップ](./roadmap.md)
  - 確定事項（backend 言語、package ID、対象 Unity、OpenCV 入手方法、CI 方針、Windows のランタイムライブラリ linkage）
  - M0〜M7 の各マイルストーンの目的・ゴール・完了条件・非ゴール
  - ローカルループと CI の役割分担、GitHub Actions のワークフロー構成
  - 実装計画: [M0 自動 TDD ハーネス](./superpowers/plans/2026-08-25-m0-tdd-harness.md)（完了）、[M1 OpenCV ビルド](./superpowers/plans/2026-08-25-m1-opencv-build.md)（完了）、[M2 Windows vertical slice](./superpowers/plans/2026-08-26-m2-windows-vertical-slice.md)（完了。8 件中 8 件。条件 7 は game-ci + Linux で満たした — 詳細は roadmap の M2 節）、[M3 Desktop 3 platform と配布の再現性](./superpowers/plans/2026-08-28-m3-desktop-three-platforms.md)（6 件すべて達成。tag を打った Release はまだ無い——詳細は roadmap の M3 節）
- [C ABI の所有権と versioning](./abi-ownership-and-versioning.md)
  - **確定（M2 着手前）。** 借用 handle を作らない決定と、その理由・受け入れたコスト
  - `OCVU_ABI_VERSION` を bump する変更としない変更
  - M2 で公開する 9 本の API allowlist と、M2 で作らないもの
  - roadmap の M2 完了条件を書き換えた経緯（`wrap` を廃し copy に置き換えた件）
- [Unity 向け OpenCV 統合の競合調査と初期計画](./unity-opencv-integration-research-and-plan.md)
  - 2026-08-25 時点の OpenCV 5.x / 4.x の状況
  - OpenCV for Unity、OpenCV-plus-Unity、OpenCvSharp、Emgu CV の比較
  - 自作 Apache-2.0 OSS の価値、ライセンス上の注意、推奨アーキテクチャ
  - native bridge を C++ / Rust のどちらで実装するかの比較と Phase 0 判断基準
  - 差別化、初期ロードマップ、想定ディレクトリ構成、命名方針
- [Native backend 実装言語の評価（TDD・エージェント自動イテレーション観点）](./native-backend-language-tdd-evaluation.md)
  - 「実装はすべて Claude Code、TDD、自動イテレーション」を前提にした C++ / Rust の再評価
  - sanitizer の入手条件、Miri の FFI 制約、`opencv` crate の安定性表明とビルド要件
  - Unity を経由しないテスト層（素の .NET での P/Invoke 検証）を核にしたテストピラミッド案
  - C++ 開始の推奨と、判断を安価に覆すための条件

## Status

M0〜M3 はすべて完了しています。M2（Windows vertical slice）は 8 件、M3（Desktop 3 platform と配布の再現性）は 6 件の完了条件をすべて実測で満たし、v0.1.0 を公開しました。

M2 の最後に残っていた条件 7（CI 上で L4/L5 を実行）は、game-ci でランナーへの Unity 導入とライセンスのアクティベーションを行い、Linux で走らせることで満たしました。**その過程で、公開済み v0.1.0 の Linux 版が古い環境で読み込めない欠陥が判明しました** —— ubuntu-24.04 でビルドした `.so` が GLIBC_2.38 を要求していたためで、Unity を CI で実際に動かすまで誰も気づけませんでした。Linux のビルドを `ubuntu:22.04` コンテナへ移し、要求を 2.34 に下げたうえで、ビルド時点で上限を検査するようにしています。

M3（Desktop 3 platform と配布の再現性）は、roadmap の完了条件 6 件をすべて満たしました。3 platform で native plugin がビルドされ、L1 / L3 と slow tools テストが CI で green になり、Linux の LeakSanitizer レーンがリークを検出し、成果物の linkage・有効言語・リンク済み依存が実物の archive から検証されています。UPM tarball は使い捨ての Unity プロジェクトに実際に導入して 10/10 pass を確認しました。**v0.1.0 を公開済みです**（2026-08-28、3 platform 分の tarball と配布物 4 点 + SHA256SUMS.txt）。 また、macOS / Linux の Plugin Import Settings はその platform の binary が置かれた状態で Unity に読ませたことがなく、Git URL 経由では binary が git の追跡外にあるため導入できません（完了条件は「Git URL または tarball」なので tarball 側で満たしています）。PR #8 を CI に通した時点で、ローカルでは緑だった欠陥が 3 件出ています——handle table の use-after-free、UPM が導入できない tarball、Release asset 名の衝突で、いずれも修正済みです。詳細は roadmap の M3 節にあります。

本文中の「推奨」「目標」「案」のうち、まだ実装されていない部分は依然として設計提案であり、実装済み機能や動作確認結果ではありません。両者の区別は各文書内の記述を見て判断してください。競合製品のバージョンや対応状況は変わるため、実装開始時と公開前に再確認します。
