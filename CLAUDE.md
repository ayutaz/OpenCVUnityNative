# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## リポジトリの現状

**M0（自動 TDD ハーネス）と M1（OpenCV 5.0.0 の再現可能ビルド）は完了している。** ビルドシステム、C ABI の骨格、テストレーン 3 本（L1 / L2 / L3）に加え、CI がビルドし artifact 配布する allowlist 構成の OpenCV 5.0.0 が全レーンにリンクされた状態で、ローカルでも CI でも green になる。

**M2（Windows vertical slice）は完了した（8 件中 8 件、2026-08-29）。** `Mat` のライフサイクル（create / release / clone / get_info / copy_from_buffer / copy_to_buffer）と `imgproc` 3 関数（cvtColor / resize / GaussianBlur）が C ABI にあり、所有権契約（二重解放・解放後アクセス・buffer の長さ/stride/NULL 検証）が L3 でテストされ、Unity Editor (Mono) と IL2CPP Player の両方で同じ smoke test が通る。

最後まで残っていた条件 7（「`ci-unity.yml` が CI 上で L4/L5 を実行する」）は、**ランナーへの Unity 導入とアクティベーションを game-ci に任せ、Linux で走らせることで満たした**（`==> [EditMode] 10 passed` / `==> [Standalone] 10 passed`。**これは当時の値である** —— M3.5 で EditMode は 16 件になり Unity も 6000.3.16f1 に上がった。**その構成でも CI は green である**（run の詳細は `docs/roadmap.md` の M3.5 節））。L5 は `UnityLinker --rule-set=Aggressive` を通した実物の IL2CPP Player で、stripping が有効な状態で P/Invoke が生き残ることを CI が実証している。

**CI の L5 は Linux の IL2CPP Player** で、Windows 版はローカルのレーンが担う。**理由として「game-ci は Windows ランナーでは使えない」と書いていたが、2026-08-29 にその根拠が崩れた** —— 挙げていた 2 つの issue のうち 1 つは使っていない別 action のもので、もう 1 つは使っているイメージ群の**別系統（Windows 版）**についてだった。**2026-08-31 に実際に投げたところ、`windows-2022` で動いた** —— `game-ci/unity-test-runner@v4` が EditMode を 33 件通した（run 33350726005。`customImage` を渡さないだけでよく、独自イメージも self-hosted runner も要らなかった）。**ただし条件が問うているのは IL2CPP Player の方で、そちらはまだ投げていない** —— EditMode が通ったことは IL2CPP が通る根拠にならない。経緯と実測は `docs/roadmap.md`「担当が無かった制約」の Windows IL2CPP の節に 1 箇所だけ書いてある。この workflow は `dev.ps1` で Unity を起動しない（game-ci が起動する）が、**合否の判定は `tools/assert-unity-results.ps1` をローカルと CI の両方が通る** —— 「0 件で緑にしない」もそこが持つ。

**この作業が公開済み v0.1.0 の欠陥を暴いた。** ubuntu-24.04 でビルドした Linux の `.so` が GLIBC_2.38 を要求しており、それより古い環境では `DllNotFoundException` になっていた。ビルドも linkage 検証も配布物生成も通っていたので、**Unity を実際に動かすまで誰も知らなかった**。Linux のビルドを `ubuntu:22.04` コンテナへ移して 2.34 に下げ、`tools/verify-plugin-portability.ps1` がビルド時点で上限を見るようにした。判定の詳細は `docs/roadmap.md` の M2 / M3 節にある。

**M3（Desktop 3 platform と配布の再現性）は、6 件の完了条件をすべて満たし、配布まで踏んだ。** 3 platform（Windows / macOS / Linux）で native plugin がビルドされ、L1 / L3 と `test-tools-slow` が CI で green になり、Linux の LeakSanitizer レーンがリークを検出し、成果物の linkage・有効言語・リンク済み依存が実物の archive から検証されている。UPM tarball は使い捨ての Unity プロジェクトに実際に導入して 10/10 pass を確認済み（**M3 時点の件数**。現在の件数はこのレーンの行にある）。

**配った実績は 3 つある: v0.1.0（2026-08-28）、v0.1.1（2026-08-29）、v0.2.0（2026-08-30、最新の公開版）。加えて v0.3.0 の下書きが 2026-08-31 から止めてある**（理由は下記）。 どちらも tag から `release.yml` が 3 platform 分を作り、`--draft` で下書きにしてから人が公開している。v0.1.1 は上に書いた Linux の欠陥を直した版で、**中身を差し替えず新しい版として出した** — 一度配ったものを黙って差し替えると、同じ版名で違う物が世の中に 2 つ存在することになる。asset は 16 件（3 platform × 5 + `SHA256SUMS.txt`）。**これは v0.1.1 までの形で、M3.5 以降は 18 件になる**（内訳は下の `release.yml` の行）。**公開された物を落として実測した（2026-08-29、このマシン）**: Linux の tarball は `SHA256SUMS.txt` と一致し、中の `libopencv_unity_native.so` は `GLIBC<=2.34, GLIBCXX<=3.4.29`（上限 2.35 / 3.4.30）だった。

**PR #8 を CI に通したことで、ローカルでは緑だった欠陥が 3 件出た。** これは記録に値する: M3 を「書いたコードを CI に通すだけ」と見なしていたら、そのまま配っていた。

1. **handle table の use-after-free。** `slots` が `std::vector<Slot>` で `Slot` が `cv::Mat` を値で持っており、`mat_table_get` が返すのは配列内部を指すポインタだった。別スレッドの `ocvu_mat_create` で配列が伸びると、先に解決したポインタが全部ぶら下がる。**壊れるのは create した側ではなく、無関係な handle を使っている側**で、2 つのスレッドがそれぞれ自分の `Mat` だけを触るという正しい使い方で壊れる。`Slot` を `std::unique_ptr<cv::Mat>` にして直し、`native/tests/test_mat_table_stability.cpp` が決定的に固定している。**ローカル 3 回と直前 3 回の CI が緑で、1 度だけ落ちた。フレークとして再実行していたら残っていた。** スレッド契約自体が未文書だったので `docs/abi-ownership-and-versioning.md` §1.5 を追加した。
2. **配布 tarball が UPM で導入できない。** package ID のディレクトリごと固めていたため、UPM が展開後の root に `package.json` を見つけられない。tag を打っていたら 3 platform 分の壊れた tarball を配っていた。`tools/pack-upm-tarball.ps1` に集約し、npm と同じく `package/` の下に入れる形にした。
3. **Release asset 名の衝突。** 3 platform が同じ `checksums.txt` 等を出すので、そのまま渡すと上書きされる。platform 名を頭に付け、staging した数を数えて確かめる（当時 15 件 = 3 × 5。現在は 17 件で、内訳は下の `release.yml` の行）。

**留保が 2 つある。** (a) **macOS の `.meta` は M3.5 で実測に変わったが、「macOS 上で動く Unity」は依然として実測が無い。** M2 の条件 7 で Linux 分が実測になり（`ci-unity.yml` が Linux の Unity を動かし、`libopencv_unity_native.so` とその `.meta` が実際に読み込まれて EditMode / IL2CPP Player の両方で通った）、M3.5 の全部入りで macOS 分も実測になった —— 実物の `libopencv_unity_native.dylib` とその `.meta` を含む package を Unity に読ませ、`PluginImporter` に解釈を問う EditMode の検査が通った（2026-08-30、ローカルの Windows）。**残るのは macOS 上で Unity を起動すること**で、CI の macOS job は plugin をビルドするが Unity を起動しない。**M3.5 はこの穴を狭めるどころか深刻にした** —— macOS の binary と `.meta` は、いまや Windows / Linux の利用者が導入する package の中にも入って配られる。(b) **Git URL では導入できない** — native plugin の binary は `.gitignore` で追跡から外してあるので、Git URL で参照した利用者に届くのは `.meta` だけで実体が入らない。完了条件は「Git URL **または** tarball」なので満たすが、利用者向けに明記が要る（`README.md` の "Why not a Git URL" とリリースノートに書いてある）。判定の詳細は `docs/roadmap.md` の M3 節にある。

**M3.5（配布の形と、実用に必要な最小の穴）は実装が済み、CI も green で main に入った**（PR #34、`41cda19`、2026-08-29。**内訳は `docs/roadmap.md` の M3.5 節**）。**完了条件 6 件をすべて満たし、2026-08-30 に完了した**（判定表は `docs/roadmap.md` の M3.5 節。条件 3 は PR #37 で閉じた —— CI が 3 platform 同居で gating を走らせ、`native plugins present: 3` を出した）。 成立させたのは 3 つ: (1) **3 platform 分の binary を 1 つに束ねた tarball `com.ayutaz.opencv-unity-native.tgz` を配る正にした**（版番号を名前に入れない —— OpenUPM の `githubReleaseAssetName` が安定した接頭辞で asset を選ぶため。**実測 9.6 MB**（正確な値と run は `docs/roadmap.md` の M3.5 節））。platform ごとの tarball も引き続き出すが、そちらは便宜であって正ではない。(2) **`imgcodecs` の encode / decode を C ABI に出した**（下記）。(3) **Unity を 6.3 LTS へ載せ替えた**（`tests/UnityProject` は 6000.3.16f1、`package.json` の `"unity"` も 6000.3）。**実測はこのマシンで 2026-08-30**: 全部入りの tarball が導入できて `==> UPM tarball install: 16 passed`、Unity 6.3 の EditMode が 16 passed、IL2CPP Player が 10 passed（**IL2CPP モジュールが入っておらず Player が "Currently selected scripting backend (IL2CPP) is not installed" で落ちたので、Hub の CLI で入れてから走らせた**）。**OpenUPM への登録も済んだ**（openupm/openupm PR #6843、2026-08-30 に自動マージ）—— `https://package.openupm.com/com.ayutaz.opencv-unity-native` が `0.2.0` を配信している。**提出前に、用意してあった定義の `topics` が 2 つとも存在しない slug だったことが分かった**（そのままでは弾かれていた）。詳細は `docs/roadmap.md` の M3.5 節。** リポジトリの複数箇所が「リンク済み」と書いていたが、`cmake/FindOpenCvUnityDeps.cmake` の `COMPONENTS` は `core imgproc` だけだった。**間違えるのが容易な形をしている** —— `tools/opencv-config.psd1` の `Modules` に `imgcodecs` が入っているので **OpenCV 自身はそれを含めてビルドされており**、`ocvu_get_build_information()` も `To be built: ... imgcodecs` と報告する。**「OpenCV に入っている」と「このプラグインがリンクしている」は別である。** 気づいたのは CMake を読み直してではなく、`cv::imencode` / `cv::imdecode` が未解決の外部シンボル（LNK2019）になったからである。ついでに分かったこと: **`COMPONENTS` に足すだけでは binary は 1 バイトも増えない**（静的リンクは参照された object しか引かない）。Windows の debug plugin が 8,831,488 → 10,177,536 バイト（+1.35 MB）になったのは、関数を書いたからである。

**M4（Mobile）は実装が済み、CI も green で main に入った**（PR #41、`5354658`、2026-08-30）。**対象 platform は 3 から 5 になった** —— Android arm64-v8a と iOS arm64 が加わり、**クロスコンパイルがこのリポジトリに初めて入った**（M0〜M3.5 の完了条件はすべて「実行中の OS で確かめる」形だった）。成立させたのは 4 つ: (1) **5 platform の OpenCV を CI がビルドし、plugin をクロスビルドする**。(2) **Android の 16 KB page size を実物の `.so` で両方向検証する** —— 対応時は `p_align = 16384`、linker flag の書き方を変えて効かなくすると `4096` で赤くなる（後者は事故だったが、**「16 KB 整列は NDK の既定ではなくこの flag が作っている」ことと「検査が実物で落ちる」ことを同時に証明した**）。(3) **iOS は静的ライブラリを作り、libtool で OpenCV を束ねる** —— 束ねられていることを「こちらの object が要求する `cv::` シンボルをこの archive が定義しているか」で測り、**同じ step の負の対照が毎回それを裏づける**。(4) `WebCamTexture` から `CvMat` を作れる（**新しい C ABI 関数は 1 本も増えていない**。既存の上に立つ C# である）。

**M4 は完了していない。完了条件 9 件のうち 5 件を満たし、4 件は閉じていない。2026-09-01 に、残る 4 件をすべてスキップすると決めた** ——iOS / Android の実機、lifecycle と memory pressure、macOS 上での Unity 起動、Windows IL2CPP の結論。**実機が要る 2 件は CI では原理的に閉じない**ので、人が実行する手順書（`docs/m4-device-verification.md`）に落としてある。**この 4 件はどれも自然には閉じない** —— **「まだ調べていない」ではなく「やらないと決めた」である**（判断と帰結は `docs/roadmap.md` の「配布 その 4」に 1 箇所だけ書いてある）。帰結: **Android / iOS は「CI がビルドするが誰も動かしたことがない」まま残り、利用者に届く最新版は v0.2.0（3 platform）のままである。**判定表は `docs/roadmap.md` の M4 節。

**クロスビルドが緑になってから CI で 8 回落ちた。** Android の sample プロジェクト / install 配置 /新しい third-party（`cpufeatures`）/ 自分が起こした回帰 / クロスでの `find_package` の閉じ込め /`.meta` のキーが `iPhone` ではなく `iOS` であること。**最後の 1 件は、`.meta` を自分でパースする検査は通し、Unity に問う検査だけが落とした。**

**PR 前の AI レビューが 37 件を出し、Critical 2 件はどちらも「CI が緑のまま」隠れていた** ——`package-release.ps1` が Android の `sdk/etc/licenses/` を知らず**tag を打つと Release が 1 件も作られない**状態だったこと、iOS の `.a` を見る検査 2 本がどちらも空振りしていたこと（`ar t` に当たっていた 1 件は OpenCV ではなく自分の object、`nm -u | match 'cv::'` は nm が demangle しないので決して真にならない）。**レビュアーの指摘 1 件は CI が否定した**（上記 16 KB の件）。

**その後 `release.yml` を PR でも空撃ちするようにし、そこからさらに 3 件出た**（PR #42）。packer の中の 2 つ目の一覧が 3 platform のまま / `package-release.ps1` が binary を拡張子で拾い iOS の `.a` を落とす /`assemble-plugins.ps1` の報告が同じく拡張子判定。**後ろ 2 件はレビュアー 2 人が読んでも出ず、走らせた瞬間に出た。**必須チェックはこれを受けて 13 本から **21 本**になった（`release` の 6 本とモバイルの 2 本）。

**v0.3.0 の tag は打ってあり、28 asset の下書きが検証済みで止めてある。公開していない** ——この版の目玉が実機で一度も動いていないためで、v0.1.0 で「ビルドは通ったが動かない物」を配った経緯を繰り返さない判断である（`docs/roadmap.md` の「配布 その 4」）。

**M5（binding specification と generator）は実装が済み、CI も green になった**（PR #55、2026-09-01。必須 21 本すべて）**。境界の宣言はもう手で書かない。** `bindings/spec/{infra,core,imgproc,imgcodecs}.json` が正本で、そこに並ぶ entry から **C ABI 宣言（`native/include/ocvu/*.h`）／C# の P/Invoke（`Runtime/Interop/NativeMethods.<module>.g.cs`）／全 entry point を 1 回ずつ呼ぶ到達性テスト（`tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs`）／API 対応表（`docs/api-map.md`）**が同時に出る（`./tools/dev.ps1 generate`）。**本数を数えるのは `docs/api-map.md` の冒頭だけである** —— ここに書くと、ABI が 1 本増えたときにこの行だけが静かに嘘になる。**手書きの `[DllImport]` は 0 個である**（全部が `.g.cs` の中にある）。一致は `./tools/dev.ps1 verify-generated` が見て、これは `dev.ps1 test` に入っているので **3 platform の `ci-native` が走らせる**（**PR #55 で 3 platform とも実際に通った**）。**検査は両向きに効く** —— 生成物を手で触ると落ち（実測）、`native/src/**/*.cpp` に `extern "C"` で `ocvu_` を実装して spec に書かなければ落ちる（後者は `tools/tests/BindingGenerator.Tests.ps1`。**見ているのは `native/src` の `.cpp` だけ**なので、他所に定義を置くと網に入らない）。**ABI は 1 本も増減していない** —— `OCVU_ABI_VERSION` は 1 のままで、M5 は移設であって追加ではない。**完了条件 5 件のうち 4 件を満たし、条件 2（`geometry` / `calib` / `features` / `objdetect` の追加）は計画の側で意図的に次へ送った**（判定表は `docs/roadmap.md` の M5 節）。

公開 ABI の内訳は次のとおり（**本数を数えるのは `docs/api-map.md` の冒頭だけ**。ここは何が在るかを説明する）。M0/M1 由来の 8 本（`ocvu_get_abi_version`、last-error の取得、status 表の照会、`ocvu_get_opencv_version` / `ocvu_get_build_information`）に、M2 で `Mat` のライフサイクルと buffer 転送の 6 本（`ocvu_mat_create` / `_release` / `_clone` / `_get_info` / `_copy_from_buffer` / `_copy_to_buffer`。`native/src/ocvu_mat_table.cpp`、`native/src/ocvu_mat.cpp`、`native/src/ocvu_mat_buffer.cpp`）、`imgproc` の 3 本（`ocvu_cvt_color` / `ocvu_resize` / `ocvu_gaussian_blur`。`native/src/ocvu_imgproc.cpp`）、L3 のクラッシュ・ハング耐性を実証する `ocvu_debug_crash`（`native/src/ocvu_debug.cpp`）が加わり、M3.5 で `imgcodecs` の 2 本（`ocvu_imencode` / `ocvu_imdecode`。`native/src/ocvu_imgcodecs.cpp`）が加わった。所有権・versioning・API allowlist の正本は `docs/abi-ownership-and-versioning.md`。**M5 で宣言の在り処が変わった** —— `extern "C"` の関数宣言は `native/include/opencv_unity_native.h` から module ごとの `native/include/ocvu/{infra,core,imgproc,imgcodecs}.h` へ移り、**いずれも生成物になった**。もとのヘッダが今も持つのは `OCVU_STATUS_LIST`・handle と struct の型・`OCVU_*` 定数だけで、**関数宣言はもう 1 本も無い**（4 つを include するだけである）。**「宣言は `opencv_unity_native.h` に在る」と書いた記述は、この時点で誤りになった。**

**この 2 本はファイルパスを受け取らない。メモリ上の byte 列だけを扱う。**「画像ファイルの読み書き」ではない。理由は 2 つ: Windows では境界を越えるパスの文字コードが問題になること、Android では StreamingAssets が APK の中にあってパスでは開けないこと。拡張子（`".png"` 等）も marshal した文字列ではなく、**UTF-8 の NUL 終端 byte 列として明示的に渡す**。また `ocvu_imencode` は **出力の大きさを呼ぶ側が事前に知り得ない最初の ABI 関数**である。native 側が確保した blob の handle は導入せず、既存の 2 回呼びの作法（`OCVU_STATUS_BUFFER_TOO_SMALL` + `out_required_size`）に載せた —— byte 列の所有権は最初から最後まで呼ぶ側にある。buffer が足りないときは何も書かない。C# 側の入口は `CvCodecs`（`Runtime/Core/CvCodecs.cs`）で、`CvOps` には入れていない（あちらは `imgproc` の範囲である）。

### 開発コマンド

ローカル開発はすべて `tools/dev.ps1` を通す。これが唯一の入口であり、CI も同じコマンドを呼ぶ（CI 専用の手順は無い）。PowerShell 7 以上が必要。OpenCV の取得は別の入口 `tools/opencv.ps1` が持つ（下記）。

| コマンド | 内容 | 実測 |
| --- | --- | --- |
| `./tools/dev.ps1 build` | native の configure + build | — |
| `./tools/dev.ps1 generate` | **M5。** `bindings/spec/*.json` から C ヘッダ・C# の P/Invoke・到達性テスト・API 対応表を書き出す（**10 ファイル**）。**境界の宣言を手で書く経路はもう無い** | — |
| `./tools/dev.ps1 verify-generated` | **M5。** 生成物が spec と一致しているかだけを見る（書き直さない）。食い違えば差分を並べて非 0 で返る。`test` に入っている | — |
| `./tools/dev.ps1 test` | **既定**。tools の速いテスト 3 本 + `verify-generated` + L1 + L3 | **約 65 秒**（増分、成果物が最新。2026-09-01 実測、exit 0）。**M3.5 以前の「約 21 秒」から伸びた** —— tools のテストが 3 本になり、`verify-generated` と L3 の 2 つ目の assembly が `dotnet` の起動を 2 回増やした |
| `./tools/dev.ps1 test-tools` | `tools/tests/` の速い 3 本（OpenCV 構成・ハッシュ無効化・**生成物と spec の一致**） | 約 18 秒（**2 本だった頃の値**） |
| `./tools/dev.ps1 test-tools-slow` | **CI 専用**。allowlist 検証・restore の実 download・linkage 検証・配布物生成 | 約 4 分 15 秒（2026-08-28 実測。M3 で `VerifyArtifactLinkage.Tests.ps1` と `PackageRelease.Tests.ps1` が加わり、M1 時点の約 70 秒から伸びた） |
| `./tools/dev.ps1 test-native` | L1 のみ（GoogleTest **64 件** + CTest **4 件**） | 約 10 秒 |
| `./tools/dev.ps1 test-managed` | L3 のみ。**solution の全テストプロジェクトを回す** —— `CvUnity.Tests.Managed` が P/Invoke 越しに実物の DLL を叩く **44 件**、`Ocvu.Generator.Tests` が spec と生成器を見る **88 件**（M5 で新設）。**件数を書いてあるのはこの行だけである** —— 他所に写すと、テストを 1 件足した瞬間にそちらだけが嘘になる（M5 で実際に 4 箇所が同時に古くなった） | 約 11 秒（**44 件だけだった頃の値**） |
| `./tools/dev.ps1 test-asan` | L2（AddressSanitizer） | 約 18 秒（増分。2026-08-28 実測。M1 時点の約 11 秒より伸びているが、原因は未特定——増えたのは L1 側で計測済みの再コンパイル対象と同じファイル群で、M3 固有の変更ではない） |
| `./tools/dev.ps1 test-managed-probe` | **CI 専用**。L3 のクラッシュ・ハングプローブ | 約 50 秒（segfault 6 秒 + hang 36 秒） |
| `./tools/dev.ps1 test-unity-editmode` | L4（Unity EditMode、Mono、**34 件**） | 約 27 秒（増分。2026-08-28 実測。**Unity 6000.0.82f1・EditMode 10 件のときの値。** その後 M3.5 で 16 件、M4 で 33 件、M5 で 34 件になったが所要時間は取り直していない） |
| `./tools/dev.ps1 test-unity-player` | L5（Unity IL2CPP Player のビルドと実行、**19 件**） | 約 54 秒（増分・キャッシュ温状態。2026-08-28 実測。cold 実測はまだ無く、roadmap の想定は 5〜20 分。**Unity 6000.0.82f1・10 件での値**） |
| `./tools/dev.ps1 test-unity-tarball` | **UPM tarball の導入検証。** tarball だけを指した使い捨ての Unity プロジェクトを作り、そこで EditMode を走らせる。**`-PluginSource` に他 platform の plugin 木（';' 区切り）を渡すと全部入りとして固めてから検証する** —— 渡さなければ従来どおり 1 platform 分で走り、**黙って全部入りのふりはしない** | 約 3 分（2026-08-28 実測。Library/ を持って行かないので Unity が import からやり直す。**Unity 6000.0.82f1・1 platform でのもの**）|
| `./tools/dev.ps1 clean` | `build/` を削除 | — |

**`dev.ps1` のレーンは相互排他である。2 つ同時に走らせないこと。** 結果を書くレーンは開始時に `Reset-Results` で `artifacts/test-results/` を**ディレクトリごと消す**ので、後から始めたほうが先行しているほうの結果を消す。**壊れ方が悪い** —— 先行したレーンは赤くならず**無音で止まり**、Unity のレーンなら起動した Player がそのまま置き去りになる。M5 で実測した。

上記のうち `test` / `test-asan` は 2026-08-28 に、`test-native` / `test-managed` は 2026-08-27 に、いずれもネイティブ成果物が最新の状態（直前のビルドから変更なし）で実測した値である。**M1 時点でソースの変更を伴う増分ビルドを計測したときは `test` が約 65 秒（`test-native` 約 28 秒、`test-managed` 約 43 秒）だった。** 差の主因は毎回のビルドで実際に何を再コンパイルするかで、OpenCV の `find_package` を伴う CMake の再 configure 自体は毎回走る。成果物が最新かどうかで数字は大きく動くので、ここでの「実測」は目安であって上限の保証ではない。

**M3.5 で上の数字の前提が変わったが、再計測していない。** L1 に 8 ケース（`native/tests/test_imgcodecs.cpp`）、L3 に 8 ケース（`ImgcodecsTests.cs`）、`test-tools-slow` に負の経路 4 件が加わり、plugin は `imgcodecs` をリンクして大きくなった（数字は上の imgcodecs の段）。**表のうち取り直したのは `test` の 1 行だけ**（2026-09-01）で、**残りはいずれも M3.5 より前のものである。**

「ローカルループは秒単位を死守する」という不変条件（本ファイル下部）と、`test` の実測（約 65 秒）はすでに緊張関係にある。M1 ではこれを**受け入れて記録するに留めており、解消していない**。**M5 でこの緊張は 1 段強まった** —— M1 の 65 秒は**ソースを変えた**ときの値だったが、2026-09-01 の 65 秒は**何も変えていない**ときの値である（tools のテストが 3 本になり、`verify-generated` と L3 の 2 つ目の assembly で `dotnet` の起動が 2 回増えた）。着手するなら configure の結果を跨いで再利用するか、OpenCV に依存しないレーンを分けることになる。

重いツールテスト 2 本（`VerifyOpenCvArtifact` は 1 ケースごとに `pwsh -NoProfile -File` を起こす作りで単体 69 秒、`OpenCvRestore` は実 download）は `test` から外して `test-tools-slow` に分け、`ci-native` の step として走らせている。**ローカルで走らないが、CI では必ず走る。** どこからも走らない状態にしないことが目的である（M1 のレビュー H2）。

`tools/dev.ps1` は OpenCV を自動では取得しない。`native` の configure/build より先に `./tools/opencv.ps1 restore` を実行しておくこと（未実行だと明示的なエラーで止まる）。

| コマンド | 内容 |
| --- | --- |
| `./tools/opencv.ps1 restore` | **既定**。CI が公開した artifact を `gh run download` で取得する（`gh` CLI と認証が必要）。ローカルでビルドしない |
| `./tools/opencv.ps1 build` | ローカル再現用の遅い経路。CI 実測は clone〜verify まで通しで 4 分 09 秒（`windows-2022` runner、run 32849957498）。ローカルでの実測はまだ無い。CI の結果を検証するときだけ使う |
| `./tools/opencv.ps1 verify` | 展開済みツリーに対して依存 allowlist を再検証する |
| `./tools/opencv.ps1 status` | 現在の構成ハッシュと展開状態を表示する |
| `./tools/opencv.ps1 clean` | `third_party/opencv/<hash>/` を削除する |

ビルド構成は `CMakePresets.json` に **5 platform**（`windows-x64` / `macos-arm64` / `linux-x64` / `android-arm64` / `ios-arm64`）× 2 構成（`-debug` / `-asan`）の **8 preset**（モバイルは `-asan` を持たない。クロスした sanitizer を host で走らせられないため）。`dev.ps1` は実行中の platform（`Get-OpenCvPlatform`）から `"$platform-debug"` / `"$platform-asan"` を機械的に導くので、ローカルで選べるのは実行環境が Windows である以上 `windows-x64-*` のみ（macOS/Linux の preset は CI 専用）。OpenCV のビルド構成は `tools/opencv-config.psd1` の 1 箇所に集約され、`Toolchains`（platform 別）と `PlatformCMakeArgs`（platform 固有 flag）を持つ。算出される構成ハッシュには `Platform` が混ざるため、同じ flag でも platform が違えば別ハッシュになり、artifact 名と展開先ディレクトリ名（`third_party/opencv/<hash>/`）に埋め込まれる（M3 Task 1。M2 時点の Windows ハッシュ `b20b4dacd9a9` はこの変更で `4785d98e9aad` に変わった）。開発環境の要件は `README.md` の Requirements にある（Visual Studio 2022 の C++ ワークロード / CMake 3.25+ / .NET 8 SDK / PowerShell 7+ / `gh` CLI）。

**非 ASCII を出力する PowerShell スクリプトは必ず `[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()` を先頭で設定する。** 指定しないと Windows の既定 ANSI コードページ（日本語環境は cp932、CI の en-US runner は cp1252）で書き出され、エラーメッセージの日本語部分が文字化けするか非可逆に失われる。M1 中に 3 つの別スクリプトで同じ欠落が独立に起きており、隣接するファイル（`tools/opencv.ps1` や `tools/verify-opencv-artifact.ps1`）に同じ対応が既にあっても、それを読むだけでは発見できないことが実証済みである。新しい PowerShell スクリプトを書くときは必ずこれを先頭に置くこと。

### ファイル配置

| 場所 | 内容 |
| --- | --- |
| `bindings/spec/*.json` | **境界の正本（M5）。** module ごとに 1 ファイル（`infra` / `core` / `imgproc` / `imgcodecs`）。`schema.json` が形を縛る。**entry 数を数えるのは `docs/api-map.md` の冒頭だけ**である。**ここに 1 エントリ書いて `dev.ps1 generate` を実行するのが、関数を足す唯一の経路である** |
| `bindings/generator/` | spec を読んで生成物を書く net8.0 の console（`Ocvu.Generator`）と、その xUnit（`Ocvu.Generator.Tests`）。`tests/Managed/CvUnity.Managed.sln` に同居するので `dev.ps1 test-managed` が一緒に回す（**件数はその行にある**） |
| `native/include/opencv_unity_native.h` | 公開 C ABI ヘッダの入口。`OCVU_STATUS_LIST`（status code の唯一の定義元）・handle と struct の型・`OCVU_*` 定数を持ち、下の 4 つを include する。**M5 以降、関数宣言はここに 1 本も無い**（足しても次の `generate` で消える） |
| `native/include/ocvu/{infra,core,imgproc,imgcodecs}.h` | **生成物（M5）。** module ごとの `extern "C"` 宣言。**手で編集しない** —— `dev.ps1 verify-generated` が落とす |
| `docs/api-map.md` | **生成物（M5）。** spec の entry を 1 行ずつ並べた API 対応表。**本数を数えるのはこの表の冒頭だけ**で、他所に数字を写さない。「OpenCV 全対応」のような曖昧な表現を置かないための出口でもある |
| `native/src/` | C ABI 実装（version / last-error / status 表 / debug throw・crash / OpenCV version・build information / `Mat` のライフサイクルと buffer 転送 / imgproc 3 関数 / **imgcodecs の encode・decode 2 関数**） |
| `native/tests/` | L1 の GoogleTest と、意図的にクラッシュ・ハングする `ocvu_probe` |
| `cmake/run_expect_failure.cmake` | 「失敗するはずのコマンド」を走らせる CTest ドライバ |
| `cmake/FindOpenCvUnityDeps.cmake` | `third_party/opencv/<hash>/` を探して OpenCV を取り込む。**`COMPONENTS` の行がこのプラグインの実際のリンク対象を決める**（現在は `core imgproc imgcodecs`）—— `tools/opencv-config.psd1` の `Modules` は OpenCV 側が何をビルドするかであって、こちらが何をリンクするかではない |
| `tools/opencv-config.psd1` | OpenCV ビルド構成の唯一の定義元。`Toolchains`（platform 別 generator/architecture）と `PlatformCMakeArgs`（platform 固有 flag）+ 共通の module allowlist・CMake flags（M3 Task 1 で platform 別化） |
| `tools/OpenCvConfig.psm1` | 構成の読み込みと構成ハッシュの算出（`opencv.ps1` と CI の両方が使う）。`Get-OpenCvPlatform` が `$IsWindows`/`$IsMacOS`/`$IsLinux` から実行中の platform を判定する |
| `tools/opencv.ps1` | OpenCV の `restore` / `build` / `verify` / `status` / `clean` の入口 |
| `tools/verify-opencv-artifact.ps1` | ビルド済み OpenCV ツリーに対する依存 allowlist の検証（denylist ではない） |
| `tools/verify-artifact-linkage.ps1` | 成果物の linkage が構成の意図と一致するかの検証（M3 Task 3/5。送った CMake flag ではなく `.lib`/`.a` を読む）。Windows は `DEFAULTLIB`、macOS/Linux は `nm -u`（リンク済み依存）・`lipo`/`readelf`（linkage）・`ar t` のメンバ名（**有効言語**——`foo.S.o` が出たらアセンブラが有効化された）で判定。**3 platform とも実物の artifact に対して CI で green。** 負の経路（アセンブル済み object を詰めた合成 archive）も macOS/Linux の CI で落ちることを確認済み。このマシンには `nm`/`ar` が無いのでローカルでは SKIP と出る——SKIP は「確かめていない」であって「合格」ではない |
| `tools/verify-plugin-portability.ps1` | Linux plugin が要求する GLIBC / GLIBCXX の上限検査。**readelf に頼らず ELF を直接読む**ので Windows の開発機でも動く（道具が無いから検査できない、という穴を作らない）。上限は「支える最も古い環境」= Ubuntu 22.04（glibc 2.35）|
| `tools/ci/setup-linux-container.sh` | Linux のビルドコンテナに道具を入れる。cmake は Kitware から（jammy の apt は 3.22.1 で古すぎる）。git の safe.directory も設定する（コンテナは root、ファイルは runner の UID）|
| `tools/tests/OpenCvConfig.Tests.ps1` | 構成ハッシュの検査（`dev.ps1 test` に入る速いレーン）に加えて、**workflow 側の不変条件を job 単位で**見る: `container:` を持つ job の宣言イメージが `opencv-config.psd1` と一致すること、その job の `run:` に `sudo` が残っていないこと、`opencv.ps1 restore` を呼ぶ job が `third_party/opencv/` を対象にした cache step を**ちょうど 1 つ**持ち、その `path:` と `key:` の両方が構成ハッシュを参照し、参照先の step id が同じ job に実在すること、テストレーンを走らせる job が結果を `if: always()` で artifact 化すること、全 job に `timeout-minutes` があること、配る binary を作る job が step 単位の `if:` 無しで移植性を検査し、その振り分けが matrix の platform 集合と過不足なく一致すること。**Unity を起動する job については**（`ci-unity` の中で `game-ci/unity-test-runner` を使う job だけに絞る。絞った先が空でないことも見る）、3 platform を重ねる step・合図を置く step・`assert-unity-results.ps1` に `-RequireTest` を渡す step がそれぞれちょうど 1 つあること、`needs:` を持つなら**ちょうど `if: !cancelled()`** で守られていること（ゆるい条件は必須チェックを**常時** skip にしうる）、合図の名前が C# の定数・workflow・`dev.ps1`・`.gitignore` の 4 箇所で一致していること。**job 単位にしたのは、ファイル単位では通ってしまう穴を実際に踏んだから**である——cache の検査が `ci-native` の Windows job の分で満足し、後から足した macOS / Linux と `ci-sanitizers` の linux-asan が漏れていた。**コンテナ名の検査も同じ穴を持っていた**: 4 本の workflow を名指ししていたので `nightly` を見落としており、`container:` を持つ全 job を対象にする形に直した。切り出しは YAML パーサを使わずインデント規約で行うが、**切れなかったときは空振りではなく落ちる**（`jobs:` 直下の 2 スペース key を緩く数えた数と、job として認識した数が合わなければ失敗させる）。**ファイル単位で見るもの**は 3 つある: `# shellcheck ` で始まる散文（道具が指示文として読んでしまう）、`tools/tests/*.Tests.ps1` が `dev.ps1` の `$ToolsTestScriptsFast` / `$ToolsTestScriptsSlow` に配線されていること、`.github/codeql/codeql-config.yml` の `query-filters`（下の行）。workflow の列挙は `.yml` と `.yaml` の両方を拾い、`git ls-files` の一覧と突き合わせる——**検査対象から静かに外れる**が構造上ありえないようにするため |
| `tools/tests/BindingGenerator.Tests.ps1` | **生成物と spec の一致を、外側から見る（M5。速いレーン）。** 一致していることに加えて、**生成物を手で書き換えると `verify-generated` が落ちること・戻すと通ること**を実際にやって確かめる（`prove-a-check-works` の「壊して、落ちることを見る」をレーンの中に常設した形）。**対象を名指ししない** —— 生成器に `--list-outputs` で自分の出力を申告させ、(a) **冒頭で「生成物である」と名乗るファイルが全部その申告に載っていること**（配線が外れると、ファイルは名乗ったまま残り誰も再生成しなくなる）、(b) **申告された全部が `--check` の比較対象であること**、を見る。名指しだった頃は 10 個のうち 2 つしか守っておらず、**到達性テストの配線を外しても全 assertion が緑だった**（実測）。**逆向きも見る** —— `native/src/**/*.cpp` の `extern "C" ocvu_*` を全部拾い、spec に無いものがあれば落とす。**拾えた数と `extern "C"` の総数が合わなければ、空振りではなく失敗させる** |
| `cmake/toolchains/<platform>.cmake` | クロスビルドの toolchain（M4。Android NDK / iOS）。**platform 固有の linker flag はここに置く** —— `tools/opencv-config.psd1` に書いても OpenCV は共有ライブラリを作らないので何にも当たらない（16 KB page size でこれを踏んだ）|
| `tools/verify-android-page-size.ps1` | Android の `.so` が 16 KB page size に対応しているかを見る（M4）。**readelf に頼らず ELF の program header を直接読む**ので Windows でも動く。PT_LOAD が 0 件なら落とす |
| `docs/m4-device-verification.md` | **CI では原理的に閉じない条件を、人が実行する手順書に落としたもの**（M4）。iOS 実機の smoke test と lifecycle / memory pressure |
| `Packages/.../Runtime/UnityIntegration/WebCamTextureConverter.cs` | `WebCamTexture` から `CvMat` を作る（M4）。**新しい C ABI 関数は使わない**（既存の上に立つ純 C#）。既定で上下を反転する —— Unity は左下原点、OpenCV は左上原点 |
| `tests/UnityProject/Assets/Tests/Shared/` | EditMode と PlayMode が**共有する**検証本体（M4）。**本体はここにしか無い** —— 写して 2 つ持つと、片方だけ直って「Editor と Player で同じ結果」を確かめられなくなる。**M5 で `AbiReachabilityChecks.g.cs` が加わった**（生成物）—— spec が載せる宣言を 1 本残らず 1 回ずつ呼ぶ。結果は見ず、**呼べたことだけ**を見る。IL2CPP の stripping が消せるのは**呼ばれない**宣言なので、これを確かめられるのは Player だけである |
| `tools/assert-unity-results.ps1` | Unity のテスト結果 XML の判定。**ローカルと CI の両方がここを通る** —— CI では game-ci が Unity を起動するので起動の仕方は分かれるが、判定は分けない。「0 件で緑にしない」もここが持つ。**`-RequireTest` は「その 1 群だけが消えた」を捕まえる**（M3.5 の追補）—— passed が 1 以上なら緑になるので、`PluginGatingTests` が assembly から外れても残りが通れば気づけない。実測: 結果 XML から gating の 6 件を抜くと `10 passed` になり、以前はそれで緑だった。**`Passed` であることまで見る** —— NUnit は `[Ignore]` を `Skipped` として出力し `failed` に数えないので、存在だけを見ると `[Ignore]` 1 行で満たせる（実測）。**`-RequireOutput` はさらに「どの分岐を通ったか」を見る** —— テストが通っても、合図が届かなければ弱い側の分岐を通っただけで、出力は成功時と 1 バイトも違わない。入力（合図を書く step が在ること）をいくら検査しても届いたことの証明にはならないので、テスト自身が出した事実（`native plugins present: 5`）を要求する |
| `tools/pack-upm-tarball.ps1` | UPM tarball を作る唯一の入口。`release.yml` と `dev.ps1 test-unity-tarball` の**両方**がここを通る（作り方が分かれると、導入を確かめた tarball と実際に配る tarball が別物になる）。中身は npm と同じく `package/` の下に入れる — package ID のディレクトリごと固めると UPM が 展開後の root に `package.json` を見つけられず導入に失敗する（M3 で実測）。**M3.5 で `-AllPlatforms` が加わり、これが配る正になった** —— 3 platform 分の binary を 1 つに束ね、名前から版番号を落とす（`com.ayutaz.opencv-unity-native.tgz`）。**存在検査だけにしない**: 全部入りは中身の一覧そのものが契約なので、3 つ揃っていることに加えて**予期しない binary が 1 つでもあれば止め**、固めた後の archive の中を数え直す。`-MaxBytes`（既定 512 MB）を**引数にしてあるのは、既定のままではこの検査が働くところを誰も確かめられないから**である（現在の配布物は上限に対して 1 桁以上小さい） |
| `tools/assemble-plugins.ps1` | 3 platform の plugin 木を 1 つに重ねる（全部入りの材料。M3.5）。**何でもコピーしない** —— 既知の binary と `.meta` だけを運び、知らないファイルがあれば止める。binary と `.meta` は必ず対で運ぶ（**binary の無い `.meta` を置くと Unity が消す**。下の `tools/plugin-meta/` の行）。**位置引数を禁止してある** —— `pwsh -File` から空白区切りで 2 つ渡すと 2 つ目が `PackageDir` に入り、**元の木を上書き先と取り違えたまま静かに成功する**（実測で踏んだ）。複数の元は ';' 区切りで受ける |
| `tools/package-release.ps1` | 配布物一式（`checksums.txt` / `sbom.spdx.json` / `build-manifest.json` / `THIRD_PARTY_NOTICES.md` の 4 点）を実物の artifact から生成する（M3 Task 6。手で書かない）。通知はリポジトリ root の全文に、**実物から拾った component 一覧の platform 固有ヘッダを足して**同梱する。**`-ChecksumsOnly` は `checksums.txt` だけを出す**（M3.5、全部入り用）—— SBOM と build-manifest はどちらも「復元済み OpenCV artifact（= 実行中 platform のもの）」から作るので、3 platform を束ねる job には元が無い。**統合版を捏造せず、中身の説明は platform ごとの物に任せる** |
| `third_party/opencv/<hash>/` | 展開先（gitignore 済み）。`build-manifest.json` に実測の構成が入る |
| `THIRD_PARTY_NOTICES.md` | OpenCV が bundle する third-party のライセンス全文。**構成ハッシュを埋め込まない** — パスは `<hash>` 表記で、取得方法を文書内に書いてある（値を書くと構成を変えるたびに古くなる。M3 で 19 箇所が一斉に死んだ）。`package-release.ps1` が配布物に同梱する |
| `Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/` | P/Invoke の置き場。**宣言は `NativeMethods.<module>.g.cs`（生成物）にあり、手書きの `[DllImport]` は 1 個も無い**（M5。本数は `docs/api-map.md` が数える）。手で残してある `NativeMethods.cs` が持つのは `LibraryName` と、spec が表現しない struct（`OcvuMatInfo`）だけである |
| `Packages/com.ayutaz.opencv-unity-native/` | UPM パッケージ本体（`Runtime/Core`、`Runtime/Interop`、`Runtime/UnityIntegration`）。**`Runtime/Plugins/` は丸ごと成果物で、git は追跡しない**——binary も `.meta` も。`dev.ps1 build` がビルドした platform の binary と `.meta` をここへ置く。**配る正の全部入りでは 3 platform 分が同居する**（`tools/assemble-plugins.ps1` が重ねる） |
| `tools/plugin-meta/<platform>/` | Plugin Import Settings（`.meta`）の正本。`Runtime/Plugins` を根とした鏡像。**package の中に置くと Unity に消される** — binary の無い platform の `.meta` は「asset の無い孤児」と見なされ、mutable な package では実際に削除される（`test-unity-editmode` を Windows で 1 回走らせるだけで macOS/Linux 分が消えることを実測。M3 のレビュー M4）|
| `Packages/com.ayutaz.opencv-unity-native/Runtime/UnityIntegration/` | UnityEngine に依存するコード（`TextureConverter` 等）を置く別 asmdef。`Runtime/Core` / `Runtime/Interop` には置かない |
| `Packages/com.ayutaz.opencv-unity-native/Samples~/BasicUsage/` | UPM sample（M3 Task 7）。末尾 `~` のため Unity にインポートされるまでコンパイルされない |
| `docs/api-reference.md` | C ABI と C# 公開 API（`CvMat`/`CvOps`/`CvCodecs`/`CvNative`/`TextureConverter`/`NativeArrayExtensions`）のリファレンス（M3 Task 7。M3.5 で `ocvu_imencode` / `ocvu_imdecode` と `CvCodecs` が加わった） |
| `tests/Managed/CvUnity.Runtime.Shim/` | netstandard2.1 の shim。UnityEngine 非依存をビルドで強制する |
| `tests/Managed/CvUnity.Tests.Managed/` | L3 の xUnit テスト（net8.0）。`HarnessProbeTests.cs` がクラッシュ・ハングプローブを持つ。**同じ solution に `bindings/generator/Ocvu.Generator.Tests` が同居する**ので、`dev.ps1 test-managed` は両方を回す（**件数はその行にある**） —— 結果 XML は `managed-{assembly}.xml` で assembly ごとに分かれる（固定名だと後勝ちで上書きされ、先に走ったほうの失敗が読めなくなる。M5 で実測） |
| `tests/UnityProject/` | L4（EditMode）と L5（IL2CPP Player）用の最小 Unity プロジェクト。UPM パッケージは `manifest.json` から `file:../../../Packages/...` でローカル参照する。**この参照はディレクトリであって tarball ではない**ので、tarball の中身が壊れていてもこのレーンは通る——**tarball からの導入は `dev.ps1 test-unity-tarball` が別に見る**（使い捨てのプロジェクトに tarball だけを入れて EditMode を走らせ、16/16 pass を実測済み。M3 でこのレーンを足して初めて「導入できない tarball」が見つかった。**M3.5 で `-PluginSource` が加わり、他 platform の plugin 木を重ねた全部入りも検証できる** —— このマシンでビルドできるのは 1 platform 分だけなので、他 platform は公開済み release から取ってくる）。**Git URL からの導入はこの構成では成立しない**（binary が git の追跡外にあるため） |
| `tests/UnityProject/Assets/Tests/EditMode/PluginGatingTests.cs` | 全部入りで **Unity が自分の platform の plugin だけを有効にしていること**を、`PluginImporter` に問う（M3.5）。`PackageRelease.Tests.ps1` の `.meta` 検査との違いは、YAML を自分で読むか **Unity に読ませた結果を読むか**。**着手前の実測: macOS の `.meta` を「Windows でも有効」に壊しても、既存の EditMode は 10 passed のまま通った**（3 platform で binary のファイル名が違うので `DllImport` の解決が名前の時点で分岐し、壊れた gating に触れない）。同じ壊し方で今は 16 中 3 件が落ちる。**`GetCompatibleWithEditor()` は 3 つとも true を返す** —— `.meta` は Editor を 3 つとも有効にし、振り分けは `GetEditorData("OS")` が持つ。**Editor の可否だけを見る検査は常に true で、何も見ていない**。**「3 つ揃っていること」を要求するのは合図が置かれたときだけ**で、合図は**環境変数ではなくプロジェクト直下のファイル**（`ocvu-expect-all-platforms`）である —— game-ci がコンテナへ渡す環境変数は 34 個の固定一覧で、任意の名前は届かない（`@v4` の dist で実測）。届かなければこの検査は「合図が無い」分岐に落ちて**要素 1 個でも緑になる** |
| `.github/workflows/` | 下の表を参照。9 本ある |
| `.github/codeql/codeql-config.yml` | CodeQL の解析範囲と `query-filters`。**触る前に、機械が捕まえられない罠が 2 つあることを知っておくこと。** (1) **filter の順序が既定を決める** — 先頭が `exclude` のときだけ「他は全部含める」が既定になる。先頭に `include:` を足すと既定が反転し、**解析がその 1 規則だけに縮む**（書いた覚えのない規則までまとめて消える）。(2) **`exclude` を `excludes` と綴り間違えても CI は緑のまま**で、外したはずの指摘だけが黙って戻ってくる —— codeql-action が持つ設定の JSON schema は `query-filters` の要素に「何でも通る」分岐を持つため、綴り間違いも 1 要素に exclude と include を両方書く形も schema 検証を通る（実測。schema を取ってきて手元で当てた）。**このうち機械が守るのは (1) と「除外する id の集合」だけ**である（`tools/tests/OpenCvConfig.Tests.ps1` が、全要素が `exclude` であること・先頭が `exclude` であること・id がちょうど `cs/unmanaged-code` と `cs/call-to-unmanaged-code` の 2 つであることを見る）。**守られないのは「その id が今も CodeQL に実在するか」**——上流で規則が改名されれば、綴りとして正しいまま何も外さなくなり、誰も赤くならない |
| `.github/dependabot.yml` | `actions/*` の可変タグと `tests/Managed` の NuGet を週 1 で追う。**「いつの間にか変わっていた」を「差分として見える変更」に変える**のが目的で、上流が壊れた版を出したときにこちらは何も変えていないのに壊れる、という経路を塞ぐ。M3 後に追加 |
| `SECURITY.md` / `CONTRIBUTING.md` | OSS として欠けていたので M3 後に追加（英語）。`SECURITY.md` は非公開の脆弱性報告先と、**この境界で何が範囲内か**（buffer の長さ・stride、handle の寿命、例外の漏出、不正な画像データがメモリ破壊になること）。`CONTRIBUTING.md` は `CLAUDE.md` を読ませ、`prove-a-check-works` と `add-abi-function` の規律、**CI が見ないもの**（文書の陳腐化・スコープ超過・完了の過大申告）を明示する |

### ワークフロー（`.github/workflows/`）

| workflow | trigger | 内容 | 実行実績 |
| --- | --- | --- | --- |
| `ci-native.yml` | push(main) / PR / 手動 | `dev.ps1 test` を 3 platform で（**L0 + L1 + L3**。M5 以降、生成物と spec の一致検査もここに乗る）。macOS / Linux job には `test-tools-slow` も配線。モバイル 2 job はクロスビルドのみ | **3 platform とも green**（M3 の PR #8 以降） |
| `ci-sanitizers.yml` | push(main) / PR / 手動 | L2。Windows は ASan、Linux は ASan+LSan（リーク検出はこのレーンだけが担う） | green |
| `build-opencv.yml` | 手動 + 構成ファイルの変更 | allowlist 構成の OpenCV を 3 platform でビルドし artifact 公開 | 稼働中 |
| `ci-unity.yml` | push(main) / PR / 手動 | L4（EditMode）+ L5（IL2CPP Player）。**Unity は ubuntu で走る**が、**2026-08-30 から他 platform の plugin もビルドし、Unity job がそれを重ねてから走る**（M4 以降は `windows-2022` / `macos-14` の 4 job で、全部入りの gating を**要素 5 個**の集合に当てる）（Windows で走らせない理由として記録していたものは 2026-08-29 に崩れた。上記参照）。したがって CI の L5 は Linux の IL2CPP Player で、Windows 版はローカルのレーンが担う。Unity の導入とアクティベーションは game-ci、合否の判定は `tools/assert-unity-results.ps1`（ローカルと共通）。Unity の版は `ProjectVersion.txt` から取るので、載せ替えても workflow は変えなくてよい | **green**（2026-08-29 に初めて。main の先端 `68fbdae` でも green）。**ただしM3.5 で Unity を 6000.3.16f1 へ、EditMode を 16 件へ替えた後も green**（run の詳細は `docs/roadmap.md` の M3.5 節。**同じ事実を 2 箇所に書かない**）。**2026-08-30 に 3 platform 構成でも green**（PR #37、run 33290375806。`native plugins present: 3` と gating 4 件の個別 Passed を CI が出した）。**M4 で 5 platform 構成になった後も green**（PR #41。`native plugins present: 5`、EditMode 33 passed / Standalone 18 passed）。**M5 で到達性テストが 1 件加わった後も green**（PR #55、2026-09-01。`==> [EditMode] 34 passed` / `==> [Standalone] 19 passed` で**ローカルの実測と一致**。Standalone は stripping 済みの実物で、生成した 21 本の P/Invoke が全部解決した）|
| `ci-lint.yml` | push(main) / PR / 手動 | 4 job: actionlint（workflow の構文・式・`run:` の中の shell）/ shellcheck（hook と CI のスクリプト）/ PSScriptAnalyzer（`tools/` の PowerShell、Error のみ）/ 文書の相対リンク検査（コードブロックの中は見ない。0 件なら「壊れていない」ではなく走査が効いていないとして落とす）。**静的に読めば分かる誤りを CI 1 周（10〜20 分）かけて確かめていた**のを埋める。数分で終わるので重いレーンより先に落ちる | green |
| `codeql.yml` | push(main) / PR / 週 1 / 手動 | C++ と C#。C++ は**配布する `opencv_unity_native` だけ**をビルドする——`paths-ignore` は C++ に効かず（解析対象は「実際にコンパイルされたもの」）、テストごとビルドすると FetchContent の GoogleTest の指摘が混ざるため。C# は P/Invoke していること自体への 2 規則を `query-filters` で外す（**設計どおりの指摘に本物が埋もれる**ため。実測で open 107 件中 84 件がこれで、その陰に本物が 4 件あった）。OpenCV の cache は `if: matrix.language == 'c-cpp'` で c-cpp の leg に限る——csharp の leg は OpenCV を一度も開かないので、揃えないと cache hit 時に使わない木を落として展開し、miss 時は post step が `Path Validation Error` を出して何も保存しない（後者は「なぜ cache が温まらないのか」を調べる人に偽の手がかりを渡す） | green。埋もれていた本物 4 件の現状は下記 |
| `nightly.yml` | 毎日 04:00 UTC / 手動 | 誰も push していない間に壊れることを見つける。**3 job 定義**（速いレーンの job は `lanes` という 2 runner の matrix なので、**実行時は 4 件**になる）: Linux 成果物の移植性（`ubuntu:22.04` でビルドし直して GLIBC の要求を見る）/ Windows・macOS の速いレーン（`dev.ps1 test`。結果を `if: always()` で artifact 化する。名前は `matrix.runner` で分ける——`matrix.name` は空白を含み、分けないと 2 つの job が同じ artifact 名を取り合う）/ OpenCV artifact の期限切れ確認 | **schedule で起動した実績はまだ無い。** 手動起動が 2 回あり、1 回目（run 33230097557、2026-08-29 02:54Z）は 4 job 中 3 job が API レート制限で失敗、2 回目（run 33233610215、同 04:21Z、修正後）は 4 job とも success |
| `unity-probe.yml` | **手動のみ** | **Linux 以外で Unity が動くかの探査**（M4 の条件 6・7）。恒久レーンではない —— **結論を出すための道具**である。5 回分の壁が step のコメントに書いてあり、`game-ci は macOS を支えない` / `Windows のコンテナに MSVC が無い` / `Unity Hub は --headless でも architecture を聞く` / `macOS では entitlement が 0 件` を**同じ疑問を持った次の人が調べ直さずに済む**形で残してある | **5 回実行**（run 33350726005 / 33352025223 / 33356182306 / 33358384921 / 33361012965）。結論は roadmap の「担当が無かった制約」にある |
| `release.yml` | tag `v*` / **PR** / 手動 | **5 platform 分**の UPM tarball と配布物 4 点、**配る正である全部入りの tarball `com.ayutaz.opencv-unity-native.tgz` とその `checksums.txt`**、`SHA256SUMS.txt` を GitHub Release へ（staging する asset は **27 件** = 5 × 5 + 全部入りの 2 件、`SHA256SUMS.txt` を足して Release には **28 件**）。**数だけでは足りない**ので、全部入りが実際に並んでいることも名指しで見る。全部入りに **SBOM と build-manifest は付けない**（理由は上の `tools/package-release.ps1` の行）。M3.5 で各 matrix job が `Runtime/Plugins/` も artifact 化するようになり、**`assemble` job が重ねて固める**（`publish` job は出来た asset を受け取って Release にするだけ）。asset にするのは `upm-out/` と `release-out/` の中身だけで、**生の binary は asset にしない**。`--draft` で下書きを作り、点検してから人が公開する（**tag を打っただけでは外から見えない**）。ノートは `.github/release-notes.md` から読む（YAML の中の PowerShell の中の Markdown という三重のエスケープを避けるため） | **M4 以降は PR でも空撃ちする。** それまで配る経路は tag と手動でしか走らず、**M4 で欠陥が 3 件たまった** —— Android の `sdk/etc/licenses/` を知らない（tag を打つと Release が 1 件も作られない）／packer の中の 2 つ目の一覧が 3 platform のまま／`package-release.ps1` が binary を拡張子で拾い iOS の `.a` を落とす。**3 件とも CI は緑のままで、2 件は空撃ちを 1 回回すまで誰も知らなかった。** 費用は安い（実測: 5 platform で合計 5 分弱、並列 2 分）ので `paths` で絞らない —— **絞ると必須チェックにできない**（当たらない PR では check が現れず、必須にすると永久に merge できない）。**v0.1.0 / v0.1.1 で実行済み**（どちらも M3.5 より前の形）。**M3.5 が足した全部入りの配線は 2026-08-30 の空撃ちで初めて通した**（run の詳細は `docs/roadmap.md` の該当行。**いまの 2 job 構成での実績は run 33289128197**）。**そのために job を `assemble` と `publish` に割った** —— 以前は組み立ても公開も 1 つの job にあり、その job ごと tag に限っていたので、**束ねる側は tag を打つまで 1 行も動かなかった** |

**どの workflow が merge を止めるかは、この表には書かない。** 走ることと止めることは
別で、しかも止める側は GitHub の設定であってファイルではない。現在の必須チェックと、
その補集合（= 赤くても merge できるレーン）は下の「機構として強制されていること」に
**1 箇所だけ**書いてある。**正本はそこですらなく GitHub 側の設定である** ——
同節に読み出しコマンドがある。

**CodeQL の `query-filters` が外した 84 件の陰にいた「本物 4 件」の現状**
（2026-08-29 に API で実測。**4 件ともテストコードにあり、配布物には入らない**）:
`cs/dispose-not-called-on-throw` 2 件と `cs/useless-assignment-to-local` 1 件は
`tests/Managed/CvUnity.Tests.Managed/CvMatTests.cs` にあり、`using` を足して
捨てる値を破棄子（`_`）で受ける形に直した。**残る 1 件は `cs/path-combine`**
——`tests/Managed/CvUnity.Tests.Managed/NativeLibraryResolver.cs:55`、環境変数
`OCVU_NATIVE_DIR` を `Path.Combine` の第 1 引数に渡している箇所で、**手を付けていない**。
なお **alert は 4 件とも open のままである**: この差分に対する CodeQL の解析がまだ
走っていないので、直した 3 件が消えるのは次の解析後になる。「直した」と
「alert が閉じた」は別である。

**M3 後の点検で、workflow 側に 3 つの穴が見つかったので埋めた。** いずれも「足したときに一緒に足すのを忘れた」形である。

- **`opencv.ps1 restore` を呼ぶのに OpenCV の cache が無い job** が 3 つ（`ci-native` の macOS / Linux、`ci-sanitizers` の linux-asan）。cache が無いと job のたびに artifact を探す API 呼び出しが起きる。**レート制限に当たると、成果物にもコードにも問題が無いのに CI が全部赤くなる**（2026-08-29 に実測。Dependabot の PR 9 件とリリースが同時に落ちた）。`tools/tests/OpenCvConfig.Tests.ps1` に検査はあったが、**判定が workflow 単位で「cache が 1 つでもあるか」しか見ていなかった**ので、同じ workflow の Windows job の分で通っていた（検査は job 単位に直した。上の表の該当行）。**job 単位にしただけでは足りなかった**——「job 本文のどこかに `actions/cache@` とハッシュ参照が在れば通る」形だったので、`key:` を定数に書き換えても、別目的の cache（Windows job の GoogleTest 用 FetchContent キャッシュ）で満たしても緑になった。いまは `third_party/opencv/` を対象にした step を特定し、その `path:` と `key:` の両方がハッシュを参照していること、参照先の step id が同じ job に実在することまで見る。**定数キーは cache が無いより悪い**: 別構成で保存された木が復元されて毎回捨てられ、しかも key は完全一致するので保存もされない。
- **テスト結果の artifact 化（`if: always()`）が同じ 3 job に無かった。** M0 の完了条件「テスト結果を機械可読な形式で artifact 化し、失敗時に読める状態にする」は Windows job にしか掛かっていなかった。落ちたときに読めることが目的なので、成功時だけ上げても意味が無い（`if: always()` の有無まで job 単位の検査が見る）。**同じものが後から足した `nightly.yml` の速いレーンにも無かった**ので、そちらも埋めた（artifact 名は `matrix.runner` で分ける。`matrix.name` は空白を含み、分けないと 2 つの job が同じ名前を取り合う——M3 の Release asset 名の衝突と同じ形である）。
- **`verify-plugin-portability.ps1` が `release.yml` で走っていなかった。** この検査は v0.1.0 の欠陥そのものに対応して作ったのに、走るのは `ci-unity.yml` と `nightly.yml` だけで、**tag を打ったときには走らない** — つまり実際に配る binary には 1 度も掛かっていなかった。今は Linux のビルドがコンテナに固定されているので構造的には防げているが、「構造で防げているから検査は要らない」は v0.1.0 が否定した論法そのものである。linux-x64 でだけ走らせ、他 platform は明示的に skip、**未知の platform は失敗させる**（検査するかしないかを決めるまで進めない形にする）。「配る binary を作る job が移植性を検査すること」自体も job 単位の検査に入れた。

正本となる設計文書:

- `docs/roadmap.md` — **確定事項と M0〜M7 のマイルストーン定義。まずここを読む。**
- `docs/superpowers/plans/2026-08-25-m0-tdd-harness.md` — M0 の実装計画（タスク単位、TDD 手順つき）
- `docs/superpowers/plans/2026-08-25-m1-opencv-build.md` — M1 の実装計画（タスク単位、TDD 手順つき）
- `docs/superpowers/plans/2026-08-26-m2-windows-vertical-slice.md` — M2 の実装計画（タスク単位、TDD 手順つき）
- `docs/superpowers/plans/2026-08-28-m3-desktop-three-platforms.md` — M3 の実装計画（タスク単位、TDD 手順つき）
- `docs/superpowers/plans/2026-08-30-m3.5-distribution-shape.md` — M3.5 の実装計画（タスク単位、TDD 手順つき）
- `docs/openupm-registration.md` — OpenUPM へ出した登録定義と手順。**2026-08-30 に提出し、受理された**（openupm/openupm PR #6843）
- `docs/abi-ownership-and-versioning.md` — `Mat` と Unity メモリの所有権契約、`OCVU_ABI_VERSION` の versioning 規約、`core`/`imgproc`/`imgcodecs` API allowlist の正本
- `docs/unity-opencv-integration-research-and-plan.md` — 競合調査、アーキテクチャ、ライセンス方針、命名方針（519 行）
- `docs/native-backend-language-tdd-evaluation.md` — C++ / Rust の評価とテストハーネス設計
- `docs/README.md` — 文書一覧とステータス

## 確定事項

| 項目 | 決定 |
| --- | --- |
| native backend 実装言語 | **C++**（Rust spike は不要になった） |
| UPM package ID | **`com.ayutaz.opencv-unity-native`** |
| 対象 Unity | **6000.x のみ**（2022 LTS 非対応）。**実際に検証しているのは 6000.3.16f1 の 1 版だけ** —— M3.5 で 6000.0.82f1 から載せ替えた（6000.0 の通常サポートは 2026-10 に終わる。`docs/roadmap.md` の「差別化の穴」#4）。`package.json` の `"unity"` も 6000.3 で、検証している版と一致している |
| C# ターゲット | netstandard2.1 / C# 9 |
| OpenCV 入手 | allowlist 構成で CI がビルドし artifact 配布。**ローカルではビルドしない** |
| CI/CD | public OSS のため GitHub Actions を全面活用。重い検証はすべて CI |
| Windows の compiler / runtime linkage | **共有（/MD、`CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL`）。embedded（/MT）にしない。** このパッケージを組み込む開発者が、自分のゲームに何を同梱するかを自分で決められる状態を保つのが理由で、パッケージ側が選択肢を奪わない（M1 Task 8）。OpenCV 自身は `BUILD_WITH_STATIC_CRT=OFF` を明示しないと `cmake/OpenCVCRTLinkage.cmake` がこの指定を黙って /MT へ上書きする（M1 Task 7 で発見） |

この文書の記述は「確認済み事実 / プロジェクト自己申告 / 提案」に区別されている（同文書 §2）。設計を語る際はこの区別を維持し、**提案を実装済みの事実として扱わない**こと。

## プロジェクトの目的

> OpenCV 5 C++ を、Unity / IL2CPP 向けの安定した独自 C ABI と C# API で提供する、再現可能なネイティブ UPM パッケージ。

Apache-2.0 の OSS として公開予定。既存の代替（Enox の OpenCV for Unity、neon-izm/OpenCV-plus-Unity、OpenCvSharp、Emgu CV）との差別化は「機能の総数」ではなく **OpenCV 5 / OSS / OpenCvSharp 非依存の Unity 専用 ABI / ビルド再現性 / Unity データとの低コピー連携** に置く。

## アーキテクチャの中核

レイヤ構成（同文書 §6）:

```
Unity application
  -> Unity integration layer (Texture2D / WebCamTexture / NativeArray / lifecycle)
  -> C# public API + 生成された P/Invoke 宣言
  -> プロジェクト所有のバージョン付き C ABI (opaque handle / error code / 明示的 ownership)
  -> native bridge (C++)
  -> OpenCV 5 C++ API
```

複数ファイルを読まないと分からない、実装時に効いてくる不変条件:

- **C ABI が唯一の native contract**。`cv::Mat*` や STL 型を境界の外へ出さない。`ocvu_mat_handle` のような opaque handle と固定サイズ型（`int32_t`、`uint64_t`、明示 struct）のみを公開する。
- **例外を ABI の外へ伝播させない**。OpenCV / C++ 例外は status code + thread-local last-error に変換する。FFI 境界を越える unwind は未定義動作になり得る。公開 ABI 関数は原則 `OCVU_TRY_BEGIN` / `OCVU_TRY_END` で本体を囲む。**ただし `ocvu_get_last_error_status` と `ocvu_get_last_error_message` は囲んではならない**: `OCVU_TRY_BEGIN` は `clear_last_error()` を呼ぶため、エラーを報告するために存在する関数が、報告すべきエラーを読む直前に自分で消してしまう。同様に `ocvu_get_abi_version` と `ocvu_get_status_count` は `ocvu_status` を返さないので囲めない。囲まない関数は「throw し得ない実装であること」が条件であり、この一覧は `native/src/ocvu_error.h` のマクロ定義の隣にも書いてある。
- **エラー報告経路自体が throw してはならない**。`ocvu::set_last_error` は `OCVU_TRY_END` の `catch (std::bad_alloc&)` の内側からも呼ばれる。よってアロケートせず、固定長 thread-local バッファへの bounded copy だけを行う（`noexcept` で契約を固定している）。上限を超えたメッセージは UTF-8 の文字境界で切り詰められ、`out_required_size` は常に「実際に取得できるバイト数 + NUL」を返す。
- **`ocvu_mat_handle` は常に native が所有する。Unity 所有のメモリを指す handle を返さない**（`docs/abi-ownership-and-versioning.md` §1 で確定）。Unity 側の buffer はその場でポインタ・長さ・stride を受け取って読み書きするだけで、handle にはならない。借用は 1 回の ABI 呼び出しの内側で完結する。理由は、借用 handle が buffer より長く生きたときの壊れ方が「即座には落ちず、後から無関係な場所が壊れる」形で、Windows の ASan は Unity のアロケータを見られないため CI でも検出できないからである。規約で禁じるのではなく、**表現できなくする**。buffer 引数の長さと stride は必ず検証し、`rows * stride` が渡された長さを超えるなら何も書かずに `OCVU_STATUS_INVALID_ARGUMENT` を返す（呼ぶ側を信用しない）。
- **C ABI と C# 宣言は手書き header の無制限解析から生成しない**。レビュー可能な binding specification（`bindings/spec/`）を正本とし、そこから C ABI 宣言 / C# P/Invoke / API 対応表 / conformance test を生成する。**M5 で成立した** —— これは方針ではなく現状の説明である。宣言を手で足すと `dev.ps1 verify-generated` が落とす。
- **IL2CPP / AOT を前提とする**。P/Invoke 宣言が stripping で消えないことを検証する。iOS は静的リンク + `DllImport("__Internal")`。
- **毎フレームの細かな境界呼び出しを避ける**。必要に応じて処理をまとめた粒度の粗い API も用意する。

命名規約（同文書 §11）:

| 用途 | 名前 |
| --- | --- |
| リポジトリ / 表示名 | `OpenCVUnityNative` / OpenCV Unity Native |
| C# namespace・ブランド | `CvUnity` |
| native library | `opencv_unity_native` |
| C ABI 関数 prefix | `ocvu_` |
| UPM package ID | `com.ayutaz.opencv-unity-native` |

`OpenCV for Unity`、`OpenCV-plus-Unity`、`UnityCV` は既存製品との混同・衝突のため使わない。

## 重要な制約

- **OpenCV 5 は 4.x の互換 wrapper ではない**。レガシー C API は完全削除済み、最低 C++17、`calib3d` は `geometry`/`calib`/`stereo`/`ptcloud` へ、`features2d` は `features` へ再編。ML・G-API・Haar/HOG 系の一部は contrib へ移動。API 設計は 5.x のモジュール構成を基準にする。
- **OpenCvSharp5 を Unity に持ち込む前提で設計しない**。managed layer が net8.0 / C# 12 対象で、Unity の managed plug-in は .NET Standard / .NET Framework 対象。OpenCvSharp の managed API 名を互換目的で複製することも目的外。
- **「本体が Apache-2.0」と「バイナリ内の全依存が Apache-2.0」は別問題**（同文書 §8.2）。OpenCV の CMake は FFmpeg / GStreamer / JPEG / PNG / TIFF / WebP / OpenEXR / protobuf / IPP 等の optional・bundled 依存を持ち、`WITH_FFMPEG` は既定で有効。初期標準 build では `videoio` と FFmpeg/GStreamer を外す。`imgcodecs` は notice を確認したうえで有効化済みで、**M3.5 で初めて実際にリンクされた**（PNG / JPEG のみ。「ビルドに入っている」と「リンクしている」を取り違えていた経緯は上の「リポジトリの現状」にある）。**CMake configure summary を保存し、想定外の依存が有効なら CI を失敗させる**。
- native artifact ごとに OpenCV tag、contrib tag、compiler、toolchain、CMake flags、依存 version、hash を manifest 化する（`artifacts/<platform>/build-manifest.json`、`sbom.spdx.json`）。
- ライセンス面はプロジェクト方針であり法的助言ではない。公開前に別途法務確認が必要。

## 開発の進め方: TDD と自動イテレーション

**すべての実装を TDD で行い、開発イテレーションを自動で回す。** この前提から次が導かれる（詳細は `docs/native-backend-language-tdd-evaluation.md` §5）。

**テストレーン**（層が上がるほど遅く、実行頻度を下げる）

| 層 | 内容 | 想定時間 | 導入 |
| --- | --- | --- | --- |
| L0 | spec → 生成物の golden test | < 1 秒 | M5（**導入済み**。`dev.ps1 verify-generated` と `tools/tests/BindingGenerator.Tests.ps1`、`bindings/generator/Ocvu.Generator.Tests`。いずれも `dev.ps1 test` に入る） |
| L1 | C ABI 契約テスト（GoogleTest + CTest） | 1〜5 秒 | M0 |
| L2 | ASan / UBSan レーン | 10〜30 秒 | M0 |
| L3 | **P/Invoke 検証（素の .NET、Unity 不使用）** | 2〜5 秒 | M0 |
| L4 | Unity EditMode (Mono) | 1〜3 分 | M2（CI は Linux。ローカルは Windows） |
| L5 | Unity IL2CPP Player | 5〜20 分 | M2（**CI は Linux の IL2CPP**。Windows 版はローカルのみ） |

**「想定時間」は roadmap 起草時の見積もりであり、実測はもっと速い。** `dev.ps1 test-unity-editmode` は約 27 秒、`dev.ps1 test-unity-player`（IL2CPP Player の実ビルド込み）は約 54 秒だった（いずれも 2026-08-28、Unity / Bee のキャッシュが温まった状態での増分実測。cold の実測はまだ無い）。両レーンとも `tests/UnityProject/` から `Packages/com.ayutaz.opencv-unity-native/` をローカル参照して動く。CI（`ci-unity.yml`）は 2026-08-29 に初めて green になった——ただし **CI は ubuntu で game-ci を使い、Unity を起動するのは `dev.ps1` ではない**ので、上の実測値は ローカル（Windows）のものである。CI の L5 は Linux の IL2CPP Player で、EditMode / Standalone とも 10 件 pass した（2026-08-29、Unity 6000.0.82f1）。**M3.5 で EditMode は 16 件、Unity は 6000.3.16f1 になったので、上の所要時間はその構成のものではない**（CI の実績のほうは 6000.3.16f1・16 件で取り直してある。上の `ci-unity.yml` の行）。 6.3 でのローカル実測は 2026-08-30 に取り直してあり（EditMode 16 passed / IL2CPP Player 10 passed）、数字は「リポジトリの現状」にある。

**L3 のクラッシュ・ハング耐性は M2 Task 4 で実証済み。** `ocvu_debug_crash`（`native/src/ocvu_debug.cpp`、kind=0 で不正アクセス、kind=1 で無限ループ。戻らない前提の関数なので `OCVU_TRY_BEGIN` では囲まない）を `tests/Managed/CvUnity.Tests.Managed/HarnessProbeTests.cs` から P/Invoke し、`tools/run-managed-probe.ps1`（`dev.ps1 test-managed-probe` 経由）が「非 0 終了かつ有限時間」を assertion する形で確かめている。実測（このマシン、2026-08-27）: segfault は `AccessViolationException` で 6 秒後に非 0 終了、hang は `--blame-hang-timeout 30s` に捕まり 36 秒後に非 0 終了・hangdump を生成。いずれも 60〜180 秒の上限内に収まった。数字は実行のたびに数秒動く（初回計測では 5 秒 / 35 秒だった）。L1 / L2 の `native/tests/ocvu_probe.cpp` が持つ expect-failure の構図（`cmake/run_expect_failure.cmake`）の L3 版であり、`cmake/run_expect_failure.cmake` 同様「非 0 で終わっただけ」では合格にせず、スタックトレース／hangdump の宛先テスト名でプローブが意図した経路に実際に到達したことまで見ている。このプローブは意図的に落ちるため通常の `dev.ps1 test` には含めない（`Category!=Probe` で除外、`StatusCodeSyncTests` 等の既存 L3 とは別枠）。数分かかるので CI 専用（`ci-native.yml` の「Run the L3 crash and hang probes」）で、ローカルでは走らない。

守るべき不変条件:

- **L3 を維持するために `Runtime/Interop` と `Runtime/Core` は `UnityEngine` を参照してはならない。** UnityEngine 依存コードは `Runtime/UnityIntegration/`（別 asmdef）にのみ置く。この制約は netstandard2.1 の shim プロジェクト（`tests/Managed/CvUnity.Runtime.Shim/`）がビルドで機械的に強制する。
- **ローカルループは秒単位を死守する。** 重い処理を持ち込まない。OpenCV はローカルでビルドせず、CI が生成した artifact を download する。
- **クラッシュは「赤いテスト」でなければならない。** ネイティブ層でループを殺す最大要因はテスト失敗ではなくハングとモーダルダイアログ。テストは必ずタイムアウト付きサブプロセスで実行し、Windows では `SetErrorMode` / `_CrtSetReportMode` でダイアログを抑止する。**ただしこれが成立しているのは L3（`dev.ps1 test-managed-probe`）までである** —— **Unity のレーンでは成立しない。** M5 で実測した: `ocvu_debug_crash` を Unity Editor 経由で呼ぶと、テストが赤くなるのではなく**レーンが 10 分以上返らず、結果 XML が 1 バイトも出ない**。だから到達性テストはこの 1 本だけを呼ばない（`bindings/spec/infra.json` の `reachableNote`）。詳細は `prove-a-check-works` skill。
- **CI はローカルと同一のコマンド（`tools/dev.ps1`）を呼ぶ。** CI 専用の手順を作らない。全ジョブに `timeout-minutes` を設定する。
- **CI が唯一の正本の検証結果。** ローカルの green は速さのための近似であり、merge 可否は CI が決める。

## backend 言語決定の再評価トリガー

C++ を選んだ主因は、**sanitizer が安定版ツールチェーンで使えること**である（MSVC ASan は GA、Rust の sanitizer は nightly 限定）。加えて Miri は FFI 層を検査できないため、Rust の安全性優位はこのプロジェクトの危険な層で大きく減衰する。

次のいずれかが起きたら再評価の価値がある: **Rust の ASan / LSan が stable 化する**（Rust project goals の 2026 目標として進行中）／ Web または iOS がスコープから外れる ／ generator を採用せず bridge を大量に手書きする方針に変わる。

再評価を安価に保つため、**public C header と契約テスト（L1 / L3）は backend 実装から独立に保つ**。この不変条件は M0 で確立し、以降のすべてのマイルストーンで維持する。

## マイルストーン（現在地: **M5（binding specification と generator）を実装し、完了条件 5 件のうち 4 件を満たした**（計画は `docs/superpowers/plans/2026-08-31-m5-binding-generator.md`）。**条件 2（`geometry` / `calib` / `features` / `objdetect` の追加）は計画の側で意図的に外してあり、次の計画で閉じる。** **M4（Mobile）も完了していない** —— 完了条件 9 件のうち 4 件が閉じていない（iOS 実機 / lifecycle / macOS 上の Unity / Windows IL2CPP の結論。うち後ろ 2 件は 2026-08-31 に「CI では閉じない」と結論した）。**v0.2.0 が最新の公開版で、v0.3.0 は下書きのまま止めてある**（2026-09-01 に公開しないと決めた）。**その下書きをそのまま公開してはならない** —— 作った時点は M5 が main に入る前で、生成物が 1 つも入っていない。判定表はいずれも roadmap にある）

詳細と完了条件は `docs/roadmap.md` にある。要点のみ:

| M | 目的 |
| --- | --- |
| **M0** | **自動 TDD ハーネスの成立（OpenCV 非依存）。** 反復速度の土台を他の何よりも先に固定する — **完了** |
| **M1** | **OpenCV 5.0.0 の再現可能ビルド。CI がビルドし artifact 配布、ローカルは download のみ — 完了** |
| **M2** | **Windows vertical slice。API の広さではなく ownership / stride / エラー / IL2CPP の正しさを確定 — 8 件すべて達成。最後の条件 7（CI で L4/L5）は game-ci + Linux で満たした。その過程で、公開済み Linux 版が古い環境で読み込めない欠陥が判明し修正** |
| **M3** | **Desktop 3 platform と配布の再現性。Linux レーンでリーク検出、成果物 linkage の機械的検証 — 6 件すべて達成。CI に通した時点で、ローカルでは緑だった欠陥が 3 件出た（handle table の use-after-free、導入できない tarball、Release asset 名の衝突）。配布まで踏み、v0.1.0 と、Linux の欠陥を直した v0.1.1 を公開済み** |
| **M3.5** | **配布の形と、実用に必要な最小の穴** —— 全部入りの package、`imgcodecs` の encode / decode（**ファイルパスではなく byte 列**）、Unity 6.3 LTS への載せ替え。2026-08-29 の再調査で足した。配る正を 3 platform 分を束ねた 1 つの tarball にしたので「エディタは Windows、実機は Android」が表現でき、M4 の成果物を配れるようになった。**完了（6 件すべて、2026-08-30）。** v0.2.0 を公開し、OpenUPM にも登録された（登録には新しい asset 名を持つ公開済み release が要る） |
| M4 | Mobile。ここで見つかる制約（stripping、static link、16 KB page size）が M5 の生成コードの形を規定する。**16 KB 対応は 2027-02-01 から Google Play の要件**（それより前に満たす。止まるのは利用者のリリースである）。macOS の `.meta` 実測と Windows IL2CPP の結論もここ |
| M5 | binding specification と generator。**`imgcodecs` は M3.5 で出した**（`ocvu_imencode` / `ocvu_imdecode`、2026-08-30）ので、ここには残っていない。**生成の仕組みは 2026-09-01 に成立し、完了条件 4 件を満たした。残る 1 件は新しい OpenCV module（`geometry` / `calib` / `features` / `objdetect`）の追加**で、別の subsystem（`COMPONENTS` / `Modules` / notice / 成果物の大きさ / 依存 allowlist が同時に動く）なので次の計画に分けてある —— 混ぜると「生成が壊れたのか module が壊れたのか」が切り分けられない |
| M6 | Web / Wasm（Unity 同梱 Emscripten と整合） |
| M7 | Optional profiles と性能。**OpenCV 5 の新しい DNN エンジンはここ** —— 競合が持たない最大の差になりうるが、Unity には推論の代替があるので前倒ししない。**2026-08-30 の上流調査で「5.0 で DNN を作り込むと 5.1 で作り直しになる」根拠が付き、`dnn` を足す前に native bridge を module 単位に分ける決定を入れた。** 決定の内訳・前提条件・一次情報は roadmap の M7 節にある（**ここに再掲しない** —— 2 箇所が同時に古くなる） |

**M2 以降の完了条件には、native 単体テストだけでなく実際の Unity Player から C# → P/Invoke → C ABI → OpenCV を通る smoke test を含める。** M2 はこれをローカルで満たしたうえで、2026-08-29 に CI（Linux）でも実行して条件 7 を満たした。**ただし「CI で走っている」は「赤ければ止まる」ではない** —— `ci-unity` が merge を止めるかどうかは下記「機構として強制されていること」を見ること。

## 実装に着手するとき

1. `docs/roadmap.md` で対象マイルストーンの目的・ゴール・完了条件・**非ゴール**を確認する
2. 実装計画があればそれに従う。M0 の計画は `docs/superpowers/plans/2026-08-25-m0-tdd-harness.md`、M1 の計画は `docs/superpowers/plans/2026-08-25-m1-opencv-build.md`、M2 の計画は `docs/superpowers/plans/2026-08-26-m2-windows-vertical-slice.md`（いずれも実施済み。M2 は完了条件 8 件すべてを満たした）、M3 の計画は `docs/superpowers/plans/2026-08-28-m3-desktop-three-platforms.md`（Task 8 まで実施済み。完了条件 6 件すべて達成。v0.1.0 を公開し、Linux の欠陥を直した v0.1.1 を出した）、M3.5 の計画は `docs/superpowers/plans/2026-08-30-m3.5-distribution-shape.md`（実施済み。**完了条件 6 件をすべて満たした** —— 判定は `docs/roadmap.md` の M3.5 節）、M4 の計画は `docs/superpowers/plans/2026-08-30-m4-mobile.md`（実施済み。**9 件中 5 件**）、M5 の計画は `docs/superpowers/plans/2026-08-31-m5-binding-generator.md`（実施済み。**5 件中 4 件。条件 2 は計画の側で意図的に外してある**）。M6 以降の計画はまだ無いので、`superpowers:writing-plans` で先に書く
3. 計画は**マイルストーンごとに 1 つ**書く。各計画は単独で動作・テスト可能なソフトウェアを produce すること

M2 以降で確定が必要な残りの事項（計画書 §12 のうち未決定分）: OpenCV 5.0.0 の固定期間と 5.x update policy、ライセンス表示と SBOM の公開フロー、各 platform で必須とする Editor / Mono / IL2CPP / device test matrix。

決定済みで、計画書 §12 の記述より新しいもの（**計画書より下の表と参照先を優先すること**）:

| 事項 | 決定 | 決定場所 |
| --- | --- | --- |
| Windows の compiler / runtime linkage | 実行時ライブラリは共有する形。組み込む開発者が同梱物を選べる状態を保つ | M1 Task 8。上の「確定事項」表 |
| `Mat` と Unity メモリの lifetime contract | **借用 handle を作らない。** handle は常に native 所有、Unity の buffer は呼び出し内で完結する借用 | `docs/abi-ownership-and-versioning.md` §1 |
| C ABI の versioning / 後方互換 | 単一整数の `OCVU_ABI_VERSION`、C# 側は**完全一致**で検査。bump する変更としない変更を明記 | 同 §2 |
| `core` / `imgproc` / `imgcodecs` API の allowlist | Mat の create / release / clone / get_info / copy_from_buffer / copy_to_buffer と cvtColor / resize / GaussianBlur（M2 の 9 本）に、M3.5 の imencode / imdecode を足した 11 本 | 同 §3 |

ディレクトリ構成の想定は計画書 §10 にある（`native/`、`bindings/spec|generator|generated-checks/`、`Packages/com.ayutaz.opencv-unity-native/`、`tests/UnityProject/`、`tools/`、`cmake/`、`.github/workflows/`）。このうち `native/`、`Packages/com.ayutaz.opencv-unity-native/`、`tests/Managed/`、`tools/`、`cmake/`、`.github/workflows/` は M0 で実在するようになり、`tests/UnityProject/` は M2 で、`bindings/spec/` と `bindings/generator/` は M5 で実在するようになった。**想定にあった `bindings/generated-checks/` だけは作っていない** —— 生成物の一致検査は `bindings/generator/Ocvu.Generator.Tests`（L3 と同じ solution）と `tools/tests/BindingGenerator.Tests.ps1` が持ち、**既にあるレーンに載せたほうが「どこからも走らない検査」を作らずに済む**ためである。

## 変更を main へ入れるまで

**人間のレビューは挟まない。したがって PR を出す前の AI レビューが唯一のゲートである。**
この順序を守ること。

1. **main で直接作業しない。** ブランチを切る。
2. 実装する（TDD。マイルストーン作業なら該当する計画に従う）。
3. **ローカルで全レーンを回す** — `tools/dev.ps1 test`、メモリを触ったなら `test-asan` も。
4. **AI レビューをここで行う。** PR を出した後ではない。差分全体を、タスク単位ではなく
   ブランチ単位で見る。指摘が出たら修正し、修正差分をスコープを絞って再レビューする。
   マイルストーンの完了なら `milestone-complete` skill の手順を踏む。
5. push して PR を作る。PR 本文には、何を成立させたか・実測値・**意図的に見送ったもの**を書く。
   穴があるなら隠さず書く。読むのは将来の自分と外部の利用者である。
   **ステップ 4 のレビュー結果も本文に残す** — 何が指摘され、どう直したか。GitHub 側は
   レビューが行われたかを検査できないので、ここに書かれていないことは省略されたのと
   区別がつかない。省略を「見えない」から「見て分かる」に変えるのがこの記載の役目である。
6. **CI が全パスしたらマージする。** 落ちたら直す。ローカルが緑で CI が赤なら CI が正しい。

この流れの帰結として、**PR は「レビューしてもらう場」ではなく「CI に判定させる場」**である。
レビューで見つかるはずだったものは、PR を出した時点で全部潰れていなければならない。

### 「AI レビュー」の定義

**書いた本人が読み返すことはレビューではない。** ステップ 4 は、**その差分を書いていない
別のエージェントを起動して**行う。実装したエージェントが自分の差分を読み直して
「レビュー済み」と称するのが、この流れで最も起きやすい失敗である。文面上は満たせるが、
ゲートとしては機能していない。

レビュアーには次を渡す: ブランチ全体の差分、対象マイルストーンの完了条件（あれば）、
このリポジトリの不変条件。そして**何を指摘してほしくないかを事前に伝えない**。
偽陽性だと思う指摘は、出させてから自分で裁定する。

### PR を出した後に直したとき

CI が赤くて直した場合、その修正差分にもレビューが要るかを判断する。

- **要る** — 挙動・スコープ・公開 API・文書のいずれかが変わったとき。CI は
  ビルドと L1 / L2 / L3 しか見ない。文書の陳腐化、過大な主張、スコープ超過は
  素通りする。**M0 で Critical になったのはまさにこの種類で、CI は緑のままだった。**
- **要らない** — CI 環境側の問題（runner の一時障害、キャッシュキー）や、
  挙動を変えない機械的な修正。

判断に迷うなら要る側に倒す。修正差分は小さいので、スコープを絞った再レビューは安い。

### 機構として強制されていること

この流れは慣習ではなく、GitHub 側の設定で強制されている。守ろうとしなくても守らされる。

| 設定 | 値 | 意味 |
| --- | --- | --- |
| main の branch protection | 有効 | 直接 push は `GH006` で拒否される |
| 必須チェック | **21 本。** `ci-native` の 3 job（`Windows x64 (L1 + L3)` / `macOS arm64 (L1 + L3)` / `Linux x64 (L1 + L3)`）、`ci-sanitizers` の 2 job（`Windows x64 AddressSanitizer (L2)` / `Linux x64 ASan+LSan (L2)`）、`ci-lint` の 4 job（`Workflows (actionlint)` / `Shell scripts (shellcheck)` / `PowerShell (PSScriptAnalyzer)` / `Documentation links`）、`codeql` の 2 job（`Analyze c-cpp` / `Analyze csharp`）、`ci-unity` の 2 job（`Unity EditMode (Linux)` / `Unity Standalone (Linux)`）、**`release` の 6 job（`Package windows-x64` / `macos-arm64` / `linux-x64` / `android-arm64` / `ios-arm64` と `Assemble the release assets`）、`ci-native` のモバイル 2 job（`Android arm64-v8a (cross-build)` / `iOS arm64 (cross-build)`）**。2 本 → 5 本（M3 完了時）→ 13 本（2026-08-29、PR #30 が 13 本すべてを緑にしたのを見てから拡張）→ **21 本（2026-08-31。`release.yml` を PR でも走らせるようにして 6 本、モバイルのクロスビルド 2 本を足した。どちらも main と PR の両方で安定して緑になったのを見てから拡張した）**。2026-08-31 に API で実測し、この表と一致 | 全部 pass しないと merge できない |
| 必須でないもの | **`ci-unity` の `Plugin <platform>` 4 本と、`release` の `Publish the release` の 1 本。** `Plugin` は落ちると `unity` job が `if: !cancelled()` で走って材料が無いまま赤くなるので、必須チェックである Unity の 2 レーンがそのまま止める（**skip は required check を通す**ので `needs:` だけでは止まらない —— そこは workflow の構造で塞いである）。**モバイルの 2 本は 2026-08-31 に必須へ昇格した** —— 当初の理由（この構成の CI がまだ 1 度も緑になっていない）が失効し、M4 以降 PR と main で安定して緑になったためである。**`Publish the release` は必須にしない** —— PR では常に skip される job で、**GitHub は skip を合格として通す**ので、必須にしても何も止めない。「見ているが止めない」の典型である。`build-opencv` / `nightly` は PR では起動しない（構成変更・定期実行が trigger）ので、そもそも必須にできない | — |
| strict | 有効 | ブランチが main より古いと merge できない（`allow_update_branch` で自動更新可） |
| 必須レビュー数 | **0** | PR は必須だが人間の承認は不要 |
| enforce_admins | **有効** | 管理者も例外ではない。抜け道は無い |
| 許可されるマージ方式 | **squash のみ** | merge commit と rebase は無効 |
| linear history | 必須 | main は一直線に保たれる |
| force push / ブランチ削除 | 禁止 | main の履歴は書き換えられない |
| auto-merge | 有効 | `gh pr merge <n> --auto --squash` で予約でき、CI が緑になった時点で自動的に入る |

**必須チェックの正本はこの表ではなく GitHub 側の設定である。**
`gh api repos/ayutaz/OpenCVUnityNative/branches/main/protection --jq .required_status_checks.contexts`
で読める。増やしたら、この表も一緒に直すこと。

**この規律は「必須でないもの」の側にも同じだけ掛かる。** 必須の一覧より、その
補集合のほうが陳腐化しやすい —— 必須を 1 本増やせば、他所に散らばった
「あれは必須ではない」という記述が同時に全部嘘になるからである。**だから
「何が merge を止めないか」を書くのはこの表の 1 行だけにしてある**（上の
「必須でないもの」）。他の節と `docs/roadmap.md` は、事実を繰り返さずここを指す。
**別の場所に同じ事実を書き足さないこと。**

例外が 1 つある。`README.md` の "Almost every lane that runs on a pull request
blocks a merge." の段落は外部の
利用者向けに英語で同じことを述べており、ここを指すわけにいかない
（`CLAUDE.md` はエージェント向けの文書である）。**必須チェックを増減したら
そこも一緒に直すこと。** リポジトリ内で二重に書かれているのはこの 1 箇所だけ、
という状態を保つ。

**この穴は 2 度開いて 2 度塞いだ。** 1 度目は M3 の途中で、macOS / Linux の
3 job が必須外だった。2 度目は `ci-lint` / `codeql` / `ci-unity` を足したときで、
**M2 の完了条件そのものである Unity レーンが、赤くても merge できる状態が
2026-08-29 まで残っていた** —— 「CI で L4 / L5 を実行する」を満たしたと記録
しながら、それが赤いまま入る変更を止められなかった。どちらも同じ理由で
塞いだ: 安定して緑になったのを見てから必須へ加える。

**次に workflow を足すときも同じ穴が開く。** PR に出るチェックを足しただけでは
merge は止まらない。**CI が「見ている」ことと「止める」ことは別である。**
必須にするかどうかを決めるまでが、workflow を足す作業である。

main には squash された 1 コミットしか残らないので、**squash の本文にそのブランチの要約を書く**。
個々のコミットは PR ページに残る。

**CI が構成上の理由で永久に赤くなった場合**（runner イメージの廃止など）、必須チェックを
満たせないため main が固まる。その場合は protection を一時的に外して直し、すぐ戻す。
これは意図的に「面倒な操作」にしてある。日常の抜け道として使わないこと。

### CI が保証していないこと

「CI が唯一の正本の検証結果である」は **merge 可否の判定について**の話であって、
「CI が緑なら正しい」という意味ではない。

**CI の守備範囲は M2 / M3 の完了で大きく広がった。** 現在は 3 platform の
L1 / L2 / L3、Linux の LeakSanitizer、成果物の linkage と移植性、Linux 上の
Unity EditMode / IL2CPP Player、workflow・shell・PowerShell の静的解析、
CodeQL まで見る。それでも次は緑のまま通過する。

- 文書の陳腐化（M0 で Critical になった経路。CI は緑だった）
- 完了条件を満たしていないのに完了と称すること、スコープ超過
- **必須でないレーンが赤いこと。** どのレーンがそれに当たるかはここには
  書かない —— 上の「機構として強制されていること」の表が唯一の記載場所で、
  正本はさらにその先の GitHub 側の設定である
- **schedule で起動する検査。** `nightly.yml` は cron（毎日 04:00 UTC）で
  走る前提で書いてあるが、**cron の経路はまだ 1 度も動いていない**
  （手動起動が 2 回あるだけで、1 回目は 4 job 中 3 job が失敗した）。
  「ファイルが存在する」は「CI で実行された」ではない —— M2 の条件 7 を
  そう判定したのと同じ基準を、こちらにも当てる
- **macOS 上の Unity の挙動**（CI の macOS job は plugin をビルドするが Unity を
  起動しない）。**2026-08-31 に 4 回試して「CI では埋まらない」と確定した** ——
  game-ci は macOS を支えず（`darwin-platform is not supported`）、Unity Hub で
  直接入れる経路は **Editor は 14 分で入るがライセンスで止まる**
  （`Found 0 entitlement groups and 0 free entitlements`。認証を 2 系統とも試して同じ）。
  **Editor の導入は障害ではなく、障害はライセンスである。** 詳細は
  `docs/roadmap.md`「担当が無かった制約」。**`.meta` の解釈自体は M3.5 で
  実測に変わっている**（他 OS の Unity に読ませた結果を `PluginImporter` で確認）
- **Windows の IL2CPP Player**（CI の L5 は Linux で、Windows 版はローカルの
  レーンだけが担う）。**2026-08-31 に「CI で回さない」と結論した** ——
  `windows-2022` に 2 回投げ、EditMode は動いたが `Standalone` は
  `ToolchainNotFoundException` で落ちた（game-ci の Windows コンテナに、
  IL2CPP が生成した C++ をコンパイルする MSVC が無い）。**根拠は実測であって
  他人の issue ではない。** 詳細は `docs/roadmap.md`「担当が無かった制約」。
  **したがってこれは「まだ調べていない穴」ではなく、意図して CI の外に置いた
  ものである** —— Windows 固有の IL2CPP の欠陥だけが CI に映らない
- **全部入りの package。** 3 platform を 1 つに束ねる形自体は M3.5 で成立したが、
  **それを確かめるレーン（`dev.ps1 test-unity-tarball`）はどの workflow からも
  走っていない。** 実測はローカル（Windows、2026-08-30）だけである
- mobile / Web（M4 / M6 の担当。まだ何も無い）
- **「ビルドできた」と「動く」の差。** v0.1.0 でこれを踏んだ——3 platform とも
  ビルドが成功し linkage 検証も配布物生成も通ったのに、Linux の成果物は
  古い環境で読み込めなかった。`tools/verify-plugin-portability.ps1` は
  その一形態（glibc の要求）を見るが、**「動く」の全部を機械が見ているわけでは
  ない**
- **spec が実物の意味を正しく書いているか（M5）。** `verify-generated` が見るのは
  「生成物が spec と一致するか」だけで、**spec の `summary` が実装の挙動を
  正しく述べているかは誰も見ていない。** 一致検査は嘘を書いた spec でも緑になる。
  同じ形で、**生成物の中身を構造として見る門があるのは `docs/api-map.md` だけ**である
  —— C ヘッダはコンパイラが下流で受けるので手書きの検査を足す価値が薄いが、
  **Markdown は決して文句を言わない**ので出口側に置いた（表の各行がちょうど 5 列
  であること）。**XML doc は今のところどちらでもない** ——
  `GenerateDocumentationFile` を有効にすればコンパイラが引き継ぐが、
  有効にしていない（`Runtime/Core` に `CS1591` が大量に出るので別判断）

**これらを見るのが PR 前の AI レビューである。** 2 つのゲートは重なっておらず、
どちらかで代替できない。CI が機械的に検査できないものを人手なしで拾う唯一の場が
ステップ 4 であり、だからそこを省略すると誰も見ていないことになる。

## このリポジトリの skill と hook

`.claude/` にプロジェクト固有の skill と hook がある。いずれもコミット済みで、
全員・全エージェントに効く。

**skill**（手順。CLAUDE.md が「事実」を持ち、skill が「手順」を持つ）

| skill | いつ使うか |
| --- | --- |
| `add-abi-function` | `ocvu_` の ABI 関数を追加・変更・削除するとき。L1 → **spec に 1 エントリ + `dev.ps1 generate`** → 実装 → L3 → status 同期の TDD 順序と、所有権・バッファ・例外バリアの規約。**M5 以降、宣言は手で書かない** —— ヘッダにも `NativeMethods.cs` にも手で足さない（足せば `verify-generated` が落とす）|
| `add-a-platform` | **対象 platform を足す・外す・変えるとき。** 一覧を持つ場所は **17 箇所**あり（M4 で実測。roadmap が長らく書いていた「2 か所」は誤りだった）、語彙が違うので grep 1 回では揃わない。`.meta` のキー名 / ファイル名の platform 間衝突 / クロスでの `find_package` の閉じ込め / 静的ライブラリの依存の束ね / 新しい third-party など、**クロスビルドが緑になってから CI で 8 回落ちた**罠を、踏んだ順に並べてある |
| `milestone-complete` | マイルストーンの完了を判定するとき。roadmap の完了条件との実測照合、**文書の陳腐化確認**、CI での確定。**M4 で 2 つ加わった** —— 実機が要る条件は「満たすが未実証」ですらなく人が実行する手順書に落とす / **必須チェックの充足は成功件数ではなく名前で突き合わせる**（GitHub は `skipped` と `neutral` も pass として通す）|
| `prove-a-check-works` | テスト・assertion・検証スクリプト・allowlist・CI ゲート・hook を足すか変えるとき。**壊して落ちることを見るまで、その検査は動くと言えない。** M1 の全タスクが同じ欠陥（著者が列挙した形だけを見る）を生んだので手順にした。**M4 で 6 つの節が加わった** —— 壊す前にコミットする / 置換が空振りしていないか確かめる / 手前に別の門があると番人に到達しない / 述語のゆるさ（構造的に常に真・部分一致・大文字小文字・散文に当たる）/ **自分でパースする検査は本物の解釈を代理できない** / **正本を写さず正本から読む**。**M5 でさらに 4 つ** —— **Unity 経由のクラッシュは赤いテストにならない**（無音で 10 分以上返り、結果が 1 バイトも出ない）/ 手前の門の 2 例目（`System.Text.Json` が先に落とすので、足した検査は 1 度も動いていなかった）/ **アンカーの意味**（.NET の `$` は末尾の `\n` の直前にも当たる。「一致したか」ではなく**値全体を覆ったか**を見る）/ **列挙に基づく門を出口側の構造に基づく門へ変える**（ただし下流に検査が無い所にだけ足す）|

**hook**（`.claude/settings.json`）

| hook | 契機 | 動作 |
| --- | --- | --- |
| `block-bulk-git-add.sh` | PreToolUse (Bash/PowerShell) | `git add -A` / `git add .` を**拒否**。連結コマンド内も見る |
| `check-unityengine-leak.sh` | PostToolUse (Write/Edit) | `Runtime/Interop` と `Runtime/Core` への `UnityEngine` 混入を指摘 |
| `check-exception-barrier.sh` | PostToolUse (Write/Edit) | `ocvu_status` を返す `extern "C"` 関数の `OCVU_TRY_BEGIN` 囲い忘れを指摘 |
| `check-powershell-encoding.sh` | PostToolUse (Write/Edit) | 非 ASCII を出力する `.ps1` / `.psm1` の `[Console]::OutputEncoding` 未設定を指摘。M1 で 3 つの別々のスクリプトに順に現れた |
| `check-assertions-reachable.sh` | PostToolUse (Write/Edit) | `*.Tests.ps1` で、終了コードを決めた後ろに置かれ**落ちようがない** assertion を指摘 |
| `check-shared-temp-paths.sh` | PostToolUse (Write/Edit) | `tools/tests/*.Tests.ps1` の**固定名の一時ファイル**を指摘。`dev.ps1 test` はレーンを並べて走らせるので、名前を固定すると 2 つの実行が潰し合う —— **落ちるのは無関係な assertion**で、再実行すると緑になるためフレークとして片付けられる（M4 で実測）|
| `check-platform-list-drift.sh` | PostToolUse (Write/Edit) | **binary の相対パスで** platform を列挙しているファイルが、**正本より短いまま**置いていかれるのを指摘。**platform 名（`nightly.yml`）・`BuildTarget`（`Slots`）・workflow の matrix は構造的に見えない** —— M4 のレビューで `nightly.yml` の取りこぼしが実例として出た。正本は `tools/dev.ps1` の `$script:AllPlatformBinaries` で、**写さずそこから読む**ので platform が増えれば判定も増える。M4 で 3 platform のまま残った一覧が 3 つ出た（うち 1 つは直したのに巻き戻して再発）。**見えないのは同一ファイル内の 2 つ目以降の一覧**で、そちらは検査側が正本と突き合わせる |
| `check-generated-file-edit.sh` | PostToolUse (Write/Edit) | **生成物を手で編集したことを、その場で指摘する**（M5）。一致は `verify-generated` が見て CI も落とすが、**赤くなるのはずっと後**で、そのとき手で書いた分は全部無駄になる（`generate` が上書きする）。**対象を一覧で持たない** —— 生成物が先頭 5 行で名乗る規約だけを見るので、**11 個目の生成物も自動で網に入る**（実測）。一覧にした場合の壊れ方は M5 で踏んだ: 生成物 10 個のうち名指しで守られていたのは 2 個だけで、**配線を外しても検査は全部 PASS した** |

**後の 5 つは、どれも実際に起きたものを機械に見させている。** `check-powershell-encoding.sh`
と `check-assertions-reachable.sh` は M1 で、`check-shared-temp-paths.sh` と
`check-platform-list-drift.sh` は M4 で踏んだ。**`check-generated-file-edit.sh` だけは
性質が違う** —— 事故を受けてではなく、M5 で境界の宣言が生成物になったときに
**先回りで置いた**（生成物を手で編集する経路は、まだ誰も踏んでいない）。1 つ目は修正が隣のファイルに在っても
再発し、2 つ目は PASS 表示が出るので目視では気づけず、3 つ目は**再実行すると緑になる**
ので原因の追跡が最も難しく、4 つ目は**ビルドも CI も通ったまま**配布物の中身だけが
食い違い、**5 つ目は最終的には赤くなるが、赤くなる頃には「その編集は全部無駄だった」
と分かるだけ**である。「近くのコードを読めば分かる」類ではないから機械に見させている。

hook は PowerShell ではなく **sh** で書いてある。この環境では pwsh の起動に
約 3.3 秒、python に約 2.4 秒かかるのに対し sh は約 0.19 秒で、hook は毎回の
ツール呼び出しで走るため起動コストがそのまま開発ループの速度になる。副次的に
macOS / Linux でもそのまま動くので M3 で書き直さなくてよい。`jq` が無い環境では
黙って素通しする（hook が理由でツールが使えなくなる方が有害なため）。

**hook にマイルストーン固有の不変条件を入れないこと。** 例えば「OpenCV に依存
しない」は M0 限定で M1 で失効する。期限のある条件を hook に埋めると、まさに
M0 で `CLAUDE.md` が陥ったのと同じ陳腐化を起こす。

## Unity 起動

Unity プロジェクトを開く必要が生じたら、`uloop-launch` skill を使うと Editor バージョンを合わせて起動できる。
