# OpenCV Unity Native documentation

このディレクトリは、Unity 向け OpenCV 5 ネイティブ統合 OSS **OpenCV Unity Native**（仮称）の調査・設計資料をまとめる場所です。

## Documents

- [ロードマップ](./roadmap.md)
  - 確定事項（backend 言語、package ID、対象 Unity、OpenCV 入手方法、CI 方針）
  - M0〜M7 の各マイルストーンの目的・ゴール・完了条件・非ゴール
  - ローカルループと CI の役割分担、GitHub Actions のワークフロー構成
  - 実装計画: [M0 自動 TDD ハーネス](./superpowers/plans/2026-08-25-m0-tdd-harness.md)
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

現在は調査・企画段階です。本文中の「推奨」「目標」「案」は設計提案であり、実装済み機能や動作確認結果ではありません。競合製品のバージョンや対応状況は変わるため、実装開始時と公開前に再確認します。
