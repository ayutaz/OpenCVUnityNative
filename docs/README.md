# OpenCV Unity Native documentation

このディレクトリは、Unity 向け OpenCV 5 ネイティブ統合 OSS **OpenCV Unity Native**（仮称）の調査・設計資料をまとめる場所です。

## Documents

- [ロードマップ](./roadmap.md)
  - 確定事項（backend 言語、package ID、対象 Unity、OpenCV 入手方法、CI 方針、Windows のランタイムライブラリ linkage）
  - M0〜M7（2026-08-29 に足した **M3.5** を含む）の各マイルストーンの目的・ゴール・完了条件・非ゴール
  - **差別化の穴**（2026-08-29 の再調査。競合が全員 OpenCV 4 系のままであること、掲げている差別化のうち埋まっていない 10 件と、その担当）
  - ローカルループと CI の役割分担、GitHub Actions のワークフロー構成（M3 の後に `ci-lint` / `codeql` / `nightly` と Dependabot を追加。**`nightly` は schedule でまだ 1 度も走っていない**）
  - 実装計画: [M0 自動 TDD ハーネス](./superpowers/plans/2026-08-25-m0-tdd-harness.md)（完了）、[M1 OpenCV ビルド](./superpowers/plans/2026-08-25-m1-opencv-build.md)（完了）、[M2 Windows vertical slice](./superpowers/plans/2026-08-26-m2-windows-vertical-slice.md)（完了。8 件中 8 件。条件 7 は game-ci + Linux で満たした — 詳細は roadmap の M2 節）、[M3 Desktop 3 platform と配布の再現性](./superpowers/plans/2026-08-28-m3-desktop-three-platforms.md)（6 件すべて達成。v0.1.0 と v0.1.1 を公開済み——詳細は roadmap の M3 節）
- [API リファレンス](./api-reference.md)
  - **M2 で公開した** C ABI 9 関数（`Mat` のライフサイクルと buffer 転送の 6 本、`cvtColor` / `resize` / `GaussianBlur` の 3 本）と、その上に立つ C# の公開 API
  - **この 9 本は公開 ABI の総数ではありません。** 現在の公開 ABI は 18 本あり、残りは M0 / M1 由来の 8 本（ABI version の取得、last-error の取得、status 表の照会、OpenCV の version と build information）と、L3 のクラッシュ・ハング耐性を実証する `ocvu_debug_crash` 1 本です。この文書が「9 関数」と限定しているのは、**M2 で確定した allowlist の範囲**を指すためで、18 との差は数え漏れではありません（version / last-error / status 表は文書内で必要に応じて触れています）。全 18 本の内訳は [CLAUDE.md](../CLAUDE.md)、所有権と allowlist の正本は [C ABI の所有権と versioning](./abi-ownership-and-versioning.md) にあります
  - **まだ無い機能は書きません。** 範囲は M2 で確定した allowlist に一致します
- [C ABI の所有権と versioning](./abi-ownership-and-versioning.md)
  - **確定（M2 着手前）。** 借用 handle を作らない決定と、その理由・受け入れたコスト
  - `OCVU_ABI_VERSION` を bump する変更としない変更
  - M2 で公開する 9 本の API allowlist と、M2 で作らないもの
  - roadmap の M2 完了条件を書き換えた経緯（`wrap` を廃し copy に置き換えた件）
- [Unity 向け OpenCV 統合の競合調査と初期計画](./unity-opencv-integration-research-and-plan.md)
  - OpenCV 5.x / 4.x の状況（2026-08-25 時点。**§3 と §4.6 は 2026-08-29 に取り直した** —— 5.0 の目玉が DNN エンジンの書き直しであること、競合の現況、OpenUPM という配布経路）
  - OpenCV for Unity、OpenCV-plus-Unity、OpenCvSharp、Emgu CV の比較
  - 自作 Apache-2.0 OSS の価値、ライセンス上の注意、推奨アーキテクチャ
  - native bridge を C++ / Rust のどちらで実装するかの比較と Phase 0 判断基準
  - 差別化、初期ロードマップ、想定ディレクトリ構成、命名方針
- [Native backend 実装言語の評価（TDD・エージェント自動イテレーション観点）](./native-backend-language-tdd-evaluation.md)
  - 「実装はすべて Claude Code、TDD、自動イテレーション」を前提にした C++ / Rust の再評価
  - sanitizer の入手条件、Miri の FFI 制約、`opencv` crate の安定性表明とビルド要件
  - Unity を経由しないテスト層（素の .NET での P/Invoke 検証）を核にしたテストピラミッド案
  - C++ 開始の推奨と、判断を安価に覆すための条件

## リポジトリ直下の文書

設計資料ではありませんが、読む順序としてはここから辿れる必要があります。

- [README](../README.md) — 導入手順、対応 platform、開発コマンド、CI が何を見ているか（英語）
- [CONTRIBUTING](../CONTRIBUTING.md) — 貢献の手順と、**CI が見ないもの**（文書の陳腐化・スコープ超過・完了の過大申告）（英語。M3 の後に追加）
- [SECURITY](../SECURITY.md) — 非公開の脆弱性報告先と、この境界で何が範囲内か（buffer の長さ・stride、handle の寿命、例外の漏出）（英語。M3 の後に追加）
- [CLAUDE.md](../CLAUDE.md) — AI エージェント向けの正本。リポジトリの現状・不変条件・ファイル配置・ワークフロー構成
- [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md) — OpenCV が bundle する third-party のライセンス全文

## Status

M0〜M3 はすべて完了しています。M2（Windows vertical slice）は 8 件、M3（Desktop 3 platform と配布の再現性）は 6 件の完了条件をすべて実測で満たし、**v0.1.0（2026-08-28）と v0.1.1（2026-08-29、最新）を公開しました**。

M2 の最後に残っていた条件 7（CI 上で L4/L5 を実行）は、game-ci でランナーへの Unity 導入とライセンスのアクティベーションを行い、Linux で走らせることで満たしました。**その過程で、公開済み v0.1.0 の Linux 版が古い環境で読み込めない欠陥が判明しました** —— ubuntu-24.04 でビルドした `.so` が GLIBC_2.38 を要求していたためで、Unity を CI で実際に動かすまで誰も気づけませんでした。Linux のビルドを `ubuntu:22.04` コンテナへ移し、要求を 2.34 に下げたうえで、ビルド時点で上限を検査するようにしています。

M3（Desktop 3 platform と配布の再現性）は、roadmap の完了条件 6 件をすべて満たしました。3 platform で native plugin がビルドされ、L1 / L3 と slow tools テストが CI で green になり、Linux の LeakSanitizer レーンがリークを検出し、成果物の linkage・有効言語・リンク済み依存が実物の archive から検証されています。UPM tarball は使い捨ての Unity プロジェクトに実際に導入して 10/10 pass を確認しました。**配布まで踏んでいます** —— v0.1.0（2026-08-28）と、上記の Linux の欠陥を直した v0.1.1（2026-08-29）。どちらも 3 platform 分の tarball と配布物 4 点 + `SHA256SUMS.txt` で、asset は 16 件です。**v0.1.0 は中身を差し替えず、リリースノートの冒頭に「この版の Linux 版は動かない」と明記して v0.1.1 へ誘導しています**（一度配ったものを黙って差し替えると、同じ版名で違う物が 2 つ存在することになるため）。また、**macOS の** Plugin Import Settings はその platform の binary が置かれた状態で Unity に読ませたことがなく（Linux 分は M2 の条件 7 で実測に変わりました）、Git URL 経由では binary が git の追跡外にあるため導入できません（完了条件は「Git URL または tarball」なので tarball 側で満たしています）。PR #8 を CI に通した時点で、ローカルでは緑だった欠陥が 3 件出ています——handle table の use-after-free、UPM が導入できない tarball、Release asset 名の衝突で、いずれも修正済みです。詳細は roadmap の M3 節にあります。

本文中の「推奨」「目標」「案」のうち、まだ実装されていない部分は依然として設計提案であり、実装済み機能や動作確認結果ではありません。両者の区別は各文書内の記述を見て判断してください。競合製品のバージョンや対応状況は変わるため、実装開始時と公開前に再確認します。
