# OpenCV Unity Native documentation

このディレクトリは、Unity 向け OpenCV 5 ネイティブ統合 OSS **OpenCV Unity Native**（仮称）の調査・設計資料をまとめる場所です。

## Documents

- [ロードマップ](./roadmap.md)
  - 確定事項（backend 言語、package ID、対象 Unity、OpenCV 入手方法、CI 方針、Windows のランタイムライブラリ linkage）
  - M0〜M7（2026-08-29 に足した **M3.5** を含む）の各マイルストーンの目的・ゴール・完了条件・非ゴール
  - **差別化の穴**（2026-08-29 の再調査。競合が全員 OpenCV 4 系のままであること、差別化の穴 10 件（掲げている差別化のうち達成していないものと、競合が持っていて本案が持たないものの合算）と、その担当。**うち 3 件は M3.5 で解消し、1 件が部分達成になった**）
  - **M7 の上流調査**（2026-08-30。OpenCV 5.1 に向けて `dnn` がどう動いているかを一次情報で確かめ、`dnn` を足す前に native bridge を module 単位に分ける決定を入れた）
  - ローカルループと CI の役割分担、GitHub Actions のワークフロー構成（M3 の後に `ci-lint` / `codeql` / `nightly` と Dependabot を追加。**`nightly` は schedule でまだ 1 度も走っていない**）
  - 実装計画: [M0 自動 TDD ハーネス](./superpowers/plans/2026-08-25-m0-tdd-harness.md)（完了）、[M1 OpenCV ビルド](./superpowers/plans/2026-08-25-m1-opencv-build.md)（完了）、[M2 Windows vertical slice](./superpowers/plans/2026-08-26-m2-windows-vertical-slice.md)（完了。8 件中 8 件。条件 7 は game-ci + Linux で満たした — 詳細は roadmap の M2 節）、[M3 Desktop 3 platform と配布の再現性](./superpowers/plans/2026-08-28-m3-desktop-three-platforms.md)（6 件すべて達成。v0.1.0 と v0.1.1 を公開済み——詳細は roadmap の M3 節）、[M3.5 配布の形と最小の穴](./superpowers/plans/2026-08-30-m3.5-distribution-shape.md)（全部入り tarball / `imgcodecs` / Unity 6.3。**6 件すべて達成。v0.2.0 を公開し OpenUPM にも登録済み**——詳細は roadmap の M3.5 節）、[M4 Mobile](./superpowers/plans/2026-08-30-m4-mobile.md)（Android / iOS のクロスビルドと `WebCamTexture` 対応。**9 件中 6 件を満たし、3 件は閉じていない** —— iOS 実機 / lifecycle / macOS 上の Unity（**Windows IL2CPP は「結論を出す」ことが条件だったので満たしている**）。実機が要る 2 件は [実機検証の手順](./m4-device-verification.md) に落としてある）、[M5 binding specification と generator](./superpowers/plans/2026-08-31-m5-binding-generator.md)（spec を正本にして C ヘッダ・C# の P/Invoke・到達性テスト・[API 対応表](./api-map.md) を生成する。**5 件中 4 件を満たし、条件 2 は計画の側で意図的に外してある** —— 詳細は roadmap の M5 節）、[M5 条件 2 の前半 objdetect / features](./superpowers/plans/2026-09-01-m5-modules-objdetect-features.md)（QR コードの符号化・復号と ORB の特徴点検出を出し、条件 2 を「部分的に満たした」にした。続けて `geometry`（射影変換の推定）も出した）、[M5 条件 2 の最後 カメラの歪み補正](./superpowers/plans/2026-09-01-m5-calib-undistort.md)（`ocvu_undistort` / `ocvu_find_chessboard_corners` を `calib` module を足さずに出した。**この時点では係数を求める `cv::calibrateCamera` が無く、条件 2 は「部分的に満たした」のままだった**）、[M5 条件 2 の完了 カメラ校正](./superpowers/plans/2026-09-02-m5-calib-camera.md)（**`calib` module を足し、`cv::calibrateCamera` を出して校正の輪を閉じた。構成ハッシュが変わり 5 platform 分の OpenCV を作り直した**（`4785d98e9aad` → `09fcbe260d87`）—— 詳細は roadmap の M5 節）、[M6 Web / Wasm](./superpowers/plans/2026-09-03-m6-web-wasm.md)（**6 つ目の platform。クロスビルドかつ静的ライブラリ**で、**ブラウザで実際に走らせて初めて出る欠陥を 7 件捕まえた** —— そのうち「例外バリアが wasm で成立していなかった」が最も重い。**完了条件 5 件すべてを満たした** —— 詳細は roadmap の M6 節）
- [API リファレンス](./api-reference.md)
  - allowlist に載っている C ABI 関数（M2 の `Mat` のライフサイクルと buffer 転送 + `cvtColor` / `resize` / `GaussianBlur`、**M3.5 の `imencode` / `imdecode`**、**M5 の `qr_encode` / `qr_decode` / `orb_detect` / `find_homography` / `undistort` / `find_chessboard_corners` / `calibrate_camera`**）と、その上に立つ C# の公開 API
  - **allowlist の本数は公開 ABI の総数ではありません。** 残りは M0 / M1 由来の診断用 API（ABI version の取得、last-error の取得、status 表の照会、OpenCV version / build information）と `ocvu_debug_crash` です。**どちらの数も [API 対応表](./api-map.md) の冒頭と [所有権と versioning](./abi-ownership-and-versioning.md) §3 が持ちます** —— ここには写しません。
  - **まだ無い機能は書きません。** 範囲は M2 で確定し、M3.5 の `imgcodecs` と M5 の module 拡張が加わった allowlist に一致します
- [API 対応表](./api-map.md)
  - **生成物です。** `bindings/spec/*.json` が正本で、`./tools/dev.ps1 generate` が書き出します。手で編集すると `verify-generated` が赤くなります
  - spec に載っている entry を 1 行ずつ並べます。**本数は表の冒頭が数えます** —— C ABI と C# の P/Invoke 宣言は別に数えており、差は同じ C の entry point へ別の引数の形で入る C# 側の入口です（C ABI を増やしません）。**ここに数字を書かないのは、ABI が 1 本増えるとこの行だけが静かに嘘になるからです**
  - **「OpenCV 全対応」とは書きません。** ここに無い関数は**まだ無い**のであって、隠れているのではありません。上の [API リファレンス](./api-reference.md) との違いは、あちらが**使い方**を書く手書きの文書であるのに対し、こちらは**何が在るか**を spec から機械的に出す一覧であることです（関数を足したときに古くなりようがない側）
- [C ABI の所有権と versioning](./abi-ownership-and-versioning.md)
  - **確定（M2 着手前）。** 借用 handle を作らない決定と、その理由・受け入れたコスト（M3 で §1.5 のスレッド規約、M3.5 で §1.6 の blob の規約を追記）
  - `OCVU_ABI_VERSION` を bump する変更としない変更
  - API allowlist（M2 で確定し、M3.5 の `imencode` / `imdecode` と M5 の module 拡張が加わった。**本数は同文書 §3 の冒頭が数えます**）と、まだ作らないもの
  - roadmap の M2 完了条件を書き換えた経緯（`wrap` を廃し copy に置き換えた件）
- [Unity 向け OpenCV 統合の競合調査と初期計画](./unity-opencv-integration-research-and-plan.md)
  - OpenCV 5.x / 4.x の状況（2026-08-25 時点。**§3 と §4.6 は 2026-08-29 に取り直し、§4.6 の配布と OpenUPM、§8.3 の `imgcodecs` は M3.5（2026-08-30）で更新した** —— 5.0 の目玉が DNN エンジンの書き直しであること、競合の現況、OpenUPM という配布経路）
  - OpenCV for Unity、OpenCV-plus-Unity、OpenCvSharp、Emgu CV の比較
  - 自作 Apache-2.0 OSS の価値、ライセンス上の注意、推奨アーキテクチャ
  - native bridge を C++ / Rust のどちらで実装するかの比較と Phase 0 判断基準
  - 差別化、初期ロードマップ、想定ディレクトリ構成、命名方針
- [Native backend 実装言語の評価（TDD・エージェント自動イテレーション観点）](./native-backend-language-tdd-evaluation.md)
  - 「実装はすべて Claude Code、TDD、自動イテレーション」を前提にした C++ / Rust の再評価
  - sanitizer の入手条件、Miri の FFI 制約、`opencv` crate の安定性表明とビルド要件
  - Unity を経由しないテスト層（素の .NET での P/Invoke 検証）を核にしたテストピラミッド案
  - C++ 開始の推奨と、判断を安価に覆すための条件
- [OpenUPM への登録](./openupm-registration.md)
  - **提出し、受理されました**（openupm/openupm PR #6843、2026-08-30 に自動マージ）。提出できる条件（新しい名前の asset が付いた公開済みリリースが 1 つあること）と、提出したものの中身。**「準備済み。まだ提出していません」と書いていた記述は 2026-08-30 の時点で古くなっており、この一覧だけが M3.5 の完了時に直し漏れていました**（同じファイルの下の Status 節は当時から「受理された」と書いています）
  - **受理されるかどうかは第三者の判断なので、こちらの完了条件には含めていません**

## リポジトリ直下の文書

設計資料ではありませんが、読む順序としてはここから辿れる必要があります。

- [README](../README.md) — 導入手順、対応 platform、開発コマンド、CI が何を見ているか（英語）
- [CONTRIBUTING](../CONTRIBUTING.md) — 貢献の手順と、**CI が見ないもの**（文書の陳腐化・スコープ超過・完了の過大申告）（英語。M3 の後に追加）
- [SECURITY](../SECURITY.md) — 非公開の脆弱性報告先と、この境界で何が範囲内か（buffer の長さ・stride、handle の寿命、例外の漏出）（英語。M3 の後に追加）
- [CLAUDE.md](../CLAUDE.md) — AI エージェント向けの正本。リポジトリの現状・不変条件・ファイル配置・ワークフロー構成
- [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md) — OpenCV が bundle する third-party のライセンス全文

## Status

M0〜M3.5 は完了しました（**M3.5 は完了条件 6 件すべてを 2026-08-30 に満たしました**。判定は roadmap の M3.5 節が正本）。M2（Windows vertical slice）は 8 件、M3（Desktop 3 platform と配布の再現性）は 6 件の完了条件をすべて実測で満たし、**v0.1.0（2026-08-28）と v0.1.1（2026-08-29）を公開しました**（**その後 v0.2.0 を公開しており、そちらが現在の最新です** —— 下の M3.5 の段落）。**M3.5 の成果はまだリリースに載っていません** —— 次の版で初めて利用者に届きます。

M2 の最後に残っていた条件 7（CI 上で L4/L5 を実行）は、game-ci でランナーへの Unity 導入とライセンスのアクティベーションを行い、Linux で走らせることで満たしました。**その過程で、公開済み v0.1.0 の Linux 版が古い環境で読み込めない欠陥が判明しました** —— ubuntu-24.04 でビルドした `.so` が GLIBC_2.38 を要求していたためで、Unity を CI で実際に動かすまで誰も気づけませんでした。Linux のビルドを `ubuntu:22.04` コンテナへ移し、要求を 2.34 に下げたうえで、ビルド時点で上限を検査するようにしています。

M3（Desktop 3 platform と配布の再現性）は、roadmap の完了条件 6 件をすべて満たしました。3 platform で native plugin がビルドされ、L1 / L3 と slow tools テストが CI で green になり、Linux の LeakSanitizer レーンがリークを検出し、成果物の linkage・有効言語・リンク済み依存が実物の archive から検証されています。UPM tarball は使い捨ての Unity プロジェクトに実際に導入して 10/10 pass を確認しました（M3 時点のこれは **platform ごとの** tarball です。全部入りに対する実測は下の M3.5 の段落にあります）。**配布まで踏んでいます** —— v0.1.0（2026-08-28）と、上記の Linux の欠陥を直した v0.1.1（2026-08-29）。どちらも 3 platform 分の tarball と配布物 4 点 + `SHA256SUMS.txt` で、asset は 16 件でした（**M3.5 で 18 件、M4 で 5 platform になってから 28 件です。現在の数は roadmap の「配布」の節が持ちます**）。**v0.1.0 は中身を差し替えず、リリースノートの冒頭に「この版の Linux 版は動かない」と明記して v0.1.1 へ誘導しています**（一度配ったものを黙って差し替えると、同じ版名で違う物が 2 つ存在することになるため）。また、Git URL 経由では binary が git の追跡外にあるため導入できません（完了条件は「Git URL または tarball」なので tarball 側で満たしています）。**macOS の** Plugin Import Settings は M3 時点では「その platform の binary が置かれた状態で Unity に読ませたことがない」状態でした（Linux 分は M2 の条件 7 で実測に変わりました）。M3.5 で何がどこまで実測に変わったかは下の段落にあります。PR #8 を CI に通した時点で、ローカルでは緑だった欠陥が 3 件出ています——handle table の use-after-free、UPM が導入できない tarball、Release asset 名の衝突で、いずれも修正済みです。詳細は roadmap の M3 節にあります。

M3.5（配布の形と、実用に必要な最小の穴）は、roadmap の完了条件 **6 件すべてを満たしました**（2026-08-30）。**v0.2.0 を公開し、OpenUPM にも登録されています。****CI は green で main に入りました**（PR #34、`41cda19`、2026-08-29。チェックの内訳と Unity レーンの実測は roadmap の M3.5 節にあります）。

**最後に閉じたのは条件 3 と、条件 4 の (c)（OpenUPM の登録申請）です。** 条件 3 について: M3.5 の時点では「満たすが未実証」で、**自動で走る唯一の場所（`ci-unity.yml`）に Linux の plugin 1 つしか無く、6 件が要素 1 個の集合を検査して緑になっていました**。PR #37 で `ci-unity` が windows / macOS の plugin も自分でビルドして重ねる形にし、**CI が 3 platform 同居の状態で `native plugins present: 3` と gating 4 件の個別 Passed を出しました**（run 33290375806）。条件 4 の (c) は **v0.2.0 を公開し、openupm/openupm へ提出して受理されました**（PR #6843。`https://package.openupm.com/com.ayutaz.opencv-unity-native` が `0.2.0` を配信しています）。

以下のローカルの数字はこのマシン（Windows）での 2026-08-30 の実測です。

配る正は **全 platform 分の binary が 1 つに入った `com.ayutaz.opencv-unity-native.tgz`** になりました（M3.5 の時点では 3 platform、M4 で 5 platform、**M6 以降は 6 platform**）（版番号を含まない名前。OpenUPM の `githubReleaseAssetName` が安定した接頭辞で asset を選ぶためです）。platform ごとの tarball も補助として引き続き出します。その全部入りを使い捨ての Unity プロジェクトに導入して **16/16 pass**（EditMode が 10 件から 16 件に増えたのは `PluginGatingTests` を足したためです）。**この tarball のレーンはどの CI workflow でも走りません** —— ローカルだけです。

`PluginGatingTests` は `PluginImporter` に問う形で「自分の platform 向けがちょうど 1 つ」「`Any` が立っていない」「他 platform の Standalone で有効になっていない」を見ます。**macOS の `.meta` を「Windows でも有効」に壊すと 3 件落ちます**（M3.5 時点の実測） —— 壊しても 10/10 で素通りしていた M3 までの状態から変わりました。もう 1 つ記録に値するのは、**`GetCompatibleWithEditor()` がどのプラグインでも true を返す**ことです。`.meta` は Editor を 3 platform とも有効にしたうえで、その下の `settings: OS:` で振り分けているので、**そのフラグだけを見る検査は常に true で無感**です。振り分けを見るには `GetEditorData("OS")` を読む必要があります（最初にそう書かずに落とし、直しました）。

**macOS 上で動く Unity は依然として未実測です。** M3.5 はこの穴を緩めるのではなく鋭くしました —— macOS の binary と `.meta` が、Windows と Linux の利用者も導入する正の package の中に同居するようになったからです。実測できたのは「Windows 上の Unity が、**全 platform 分が同居した中から** Windows 向けの 1 つだけを有効にする」ところまでで、macOS 上の Unity が実際にその `.dylib` を読み込むことは確かめていません（M4 の担当）。

`imgcodecs` は **M3.5 で初めてリンクされました**。それまで `cmake/FindOpenCvUnityDeps.cmake` は `COMPONENTS core imgproc` だけで、リポジトリ内の複数箇所にあった「モジュールはリンク済み」という記述は**誤り**でした。誤解の出どころも記録しておきます: `tools/opencv-config.psd1` の `Modules` には `imgcodecs` が入っているので **OpenCV 自体はそれを含めてビルドされており**、`ocvu_get_build_information()` も `To be built: … imgcodecs …` と報告します。**「OpenCV に入っている」と「このプラグインがリンクしている」は別です。** 気づいたのは CMake を読んだからではなく、実装を書いた時点で `cv::imencode` / `cv::imdecode` が未解決の外部シンボルになったからです。C ABI に `ocvu_imencode` / `ocvu_imdecode` が加わり、公開 ABI は 18 本から 20 本、allowlist は 9 本から 11 本になりました。**扱うのはメモリ上の byte 列だけで、ファイルパスは受けません**（理由は [所有権と versioning](./abi-ownership-and-versioning.md) §1.6）。

検証する Unity は 6000.0 から **6000.3 LTS（6000.3.16f1）** へ載せ替えました（6000.0 の通常サポートが 2026-10 に終わるためです）。6.3 で EditMode 34 件、IL2CPP Player 19 件が通っています（M3.5 時点では 16 / 10、M4 で 33 / 18、M5 で到達性テストが 1 件ずつ加わりました） —— **IL2CPP モジュールは Hub の CLI で先に入れる必要がありました**（入っていない状態では Player のビルドが「Currently selected scripting backend (IL2CPP) is not installed」で落ちます）。OpenUPM への登録は**提出し、受理されました**（openupm/openupm PR #6843、2026-08-30 に自動マージ。`https://package.openupm.com/com.ayutaz.opencv-unity-native` が 0.2.0 を配信しています。詳細は [OpenUPM への登録](./openupm-registration.md)）。詳細は roadmap の M3.5 節にあります。

M5（binding specification と generator）は**完了条件 5 件すべてを満たしました**（2026-09-02。判定表は roadmap の M5 節が正本）。境界の宣言を手で書く経路が無くなり、`bindings/spec/*.json` の entry から **C ABI 宣言 / C# の P/Invoke / 全 entry point を呼ぶ到達性テスト / [API 対応表](./api-map.md)** が `./tools/dev.ps1 generate` で出るようになりました（**本数は上に書いたとおり対応表の冒頭が数えます**）。**手書きの `[DllImport]` は 0 個です。** 一致は `./tools/dev.ps1 verify-generated` が見て、これは `dev.ps1 test` に入っているので 3 platform の CI が走らせます。**条件 2（`geometry` / `calib` / `features` / `objdetect` の追加）は当初は次へ送りましたが、続く 3 つの計画で閉じました** —— `objdetect`（QR の符号化・復号）と `features`（ORB 検出）、`geometry`（射影変換の推定。**リンクは無料でした** —— 既に推移的に引かれていました）、カメラの歪み補正、そして **`calib` module と `cv::calibrateCamera`**（2026-09-02）。**最後の 1 つだけが高く**、構成ハッシュが変わって 5 platform 分の OpenCV を作り直しました。**これでカメラ校正の 3 段（格子点を見つける / 係数を解く / 係数で補正する）が揃っています。** 詳細は roadmap の M5 節。**M4（Mobile）は依然として完了していません**（9 件中 5 件。詳細は roadmap の M4 節）。

M6（Web / Wasm）は**完了条件 5 件すべてを満たしました**（2026-09-03。判定表は
roadmap の M6 節が正本）。**Web は 6 つ目の platform で、クロスビルドかつ静的
ライブラリ**（iOS の 2 つの性質を同時に持ちます）。**このマイルストーンの価値は、
Web でしか出ない欠陥を 7 件捕まえたことにあります** —— うち 1 件は
**「例外を ABI の外へ伝播させない」という中核の不変条件が、Web でだけ黙って
成立していなかった**もので、**ブラウザで OpenCV が実際に投げるまで誰も
知りませんでした**（Emscripten は既定で C++ 例外を無効にするので、`throw` は
残るのに `catch` が 1 つも組み込まれません）。**Web にだけ在る制限が 1 つ
あります: 画像の encode / decode は JPEG のみで、PNG を持ちません**（Unity の
WebGL 支援が自前の libpng を同梱しているためです。他の 5 platform は両方
持ちます）。CI は Linux の headless Chromium で実物の Player を起動し、**共有の検証本体が
1 件残らず走ったこと**と、**spec が載せる宣言に全部到達できたこと**を確かめます
（**数はここに写しません** —— ABI が 1 本増えるたびに動くので、roadmap の
M6 節が持ちます）。**ただし動かしているブラウザはそれ 1 つだけ**です。

**利用者に届いているのは v0.3.0 です（2026-09-04 公開）。**
**M4（5 platform）・M5（生成器と校正 API）・M6（Web）の成果が、これで初めて
届きました** —— v0.2.0 以来です。**版番号は当初「v0.3.0 を飛ばして v0.4.0」と
決めていましたが覆しました** —— v0.3.0 という名前で世に出た物が 1 つも無いことを
実測したためで、2026-08-31 の下書き（生成物が 1 つも入っていない）と tag は
破棄して打ち直しました。配布の記録は
[ロードマップ](./roadmap.md) の「配布 その 5」にあります。

本文中の「推奨」「目標」「案」のうち、まだ実装されていない部分は依然として設計提案であり、実装済み機能や動作確認結果ではありません。両者の区別は各文書内の記述を見て判断してください。競合製品のバージョンや対応状況は変わるため、実装開始時と公開前に再確認します。
