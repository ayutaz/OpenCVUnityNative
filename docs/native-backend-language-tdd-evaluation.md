# Native backend 実装言語の評価（TDD・エージェント自動イテレーション観点）

- 調査基準日: **2026-08-25**
- 対象: `native/backend/` の実装言語（C++ / Rust）
- 前提条件: **実装はすべて Claude Code が行う。TDD で進め、開発イテレーションを自動で回す。**
- 文書の状態: 調査・提案
- 関連: [Unity 向け OpenCV 統合の競合調査と初期計画](./unity-opencv-integration-research-and-plan.md) §6.1

## 1. 結論

**C++ を production backend として開始することを推奨する。** ただし本調査の主要な結論は言語選択そのものではない。

> 自動 TDD イテレーションの成否を決めるのは実装言語ではなく、テストハーネスの構造である。特に **「Unity を経由しないテスト層をどこまで厚くできるか」** が支配的な要因であり、これは C++ / Rust のどちらを選んでも同じだけ重要である。

言語選択が効いてくるのは主に次の 3 点で、いずれも現時点では C++ が有利である。

1. **UB 検出オラクルが安定版ツールチェーンで使えるか** — MSVC の AddressSanitizer は GA、Rust の sanitizer は現在も nightly 限定。handle / ownership を持つ C ABI にとって、これは自動テストの品質を直接左右する。
2. **ツールチェーン鎖の長さ** — Rust 案は OpenCV C++ ツールチェーンの上に Rust ツールチェーンと `opencv` crate を積む。本プロジェクトの価値が集中する iOS static link / Android NDK / Unity 同梱 Emscripten で、検証対象が増える。
3. **不安定な upstream 依存の有無** — `opencv` crate は自ら "unstable and not very battle-tested" と表明し、かつ **`Mat` の共有可変性** について明示的に警告している。これは本プロジェクトが最も厳密に定義したい ownership contract と正面から衝突する。

同時に、**この判断は安価に覆せる形にしておくべきである**（§6）。

## 2. 判断基準の再定義

通常の C++ / Rust 比較は「開発者の生産性・安全性・採用」を軸にする。本プロジェクトの前提では開発者が Claude Code であり、重み付けが変わる。自動イテレーションの観点で本当に効く基準は次の 5 つである。

| # | 基準 | なぜエージェント特有か |
| --- | --- | --- |
| A | cold clone から**単一コマンド**で build + test が通るか | 手動のツールチェーン調整が必要な瞬間にループが止まる |
| B | **インクリメンタル所要時間** | エージェントの 1 イテレーションあたりの固定コスト。分単位だと TDD が成立しない |
| C | 失敗が**機械可読かつ必ず有限時間で返る**か | ネイティブ層では「クラッシュしてハングする」がループを殺す最大要因 |
| D | **UB を自動検出できる**か | エージェントは所有権ミスを必ず作る。テストが green でも UB が残る状態が最も危険 |
| E | 環境の**非決定性**が小さいか | リポジトリ外に状態（環境変数・グローバル install）があると再現しない |

「コンパイラのエラーメッセージの親切さ」は Rust が明確に優れるが、本件では影響が限定的である。理由は §4.2 に述べる。

## 3. 確認済み事実（2026-08-25 時点）

### 3.1 `opencv` crate（Rust 案の前提）

- 最新版は **0.100.1**（2026-07-31 リリース）。**OpenCV 4.x と 5.x をサポート**する。3.4 は deprecated。
- **MSRV は Rust 1.88.0**。
- ビルドには **Clang（LLVM）が必須**と明記されている: "Make sure the supported OpenCV version (4.x or 5.x) and Clang (part of LLVM, needed for automatic binding generation) are installed in your system."
- API の位置づけを自ら次のように説明する: **"The API is usable, but unstable and not very battle-tested; use at your own risk."**
- `Mat` について明示的な警告がある: "Mat which is a reference counted object in its essence... you can own a seemingly separate Mat in Rust terms, but it's going to be a mutable reference to the other Mat under the hood."
- **主開発・テストは Linux 上**で行われ、macOS と Windows も "supported" とされる。
- Windows のセットアップは `choco install llvm opencv` または `vcpkg install llvm opencv4[...]` に加え、**`OPENCV_LINK_LIBS` / `OPENCV_LINK_PATHS` / `OPENCV_INCLUDE_PATHS` の環境変数設定**が必要（vcpkg 経路では `VCPKGRS_DYNAMIC`）。INSTALL.md は補足手順として GitHub issue #118 / #113 を参照させている。
- ビルド時間の目安として docs.rs は現行リリース **2 分 51 秒**、2024-10-23 以降の全リリース平均 **7 分 54 秒**を記録している。

> **要検証（Phase 0 spike の測定項目）**: binding 生成のタイミングについて情報が一致しない。README は「Clang が binding 自動生成に必要」とし、`opencv-binding-generator` は **build dependency** に列挙される一方、docs.rs 上の記述は「生成済み Rust コードは repo に commit 済みで利用者は生成コストを負わない」とする。実測で「初回ビルド時間」「OpenCV バージョン変更時の再生成の有無」「インクリメンタルビルド時間」を確定させること。これは基準 B に直結する。

### 3.2 Sanitizer（基準 D）

- **MSVC の AddressSanitizer は GA**。Visual Studio 2019 16.9 で experimental を脱し、"stable and ready for production environments" とされる。`/fsanitize=address` の**単一フラグ**で、x86 / x64、全最適化レベルに対応し、ランタイムは自動リンクされる。非対応は coroutines / OpenMP / Managed C++ / C++ AMP / UWP。
- **Rust の sanitizer は現在も unstable**。`-Zsanitizer=address` 等で nightly が必要。AddressSanitizer と LeakSanitizer の安定化は Rust project goals の 2026 目標として進行中だが、2026-08-25 時点で stable ではない。
- **Miri は FFI 呼び出しを実行できない**。Miri は Rust 固有の UB（aliasing 違反、stacked borrows 等）に対しては Valgrind より精密だが、外部関数呼び出しを解釈実行できないため、**OpenCV C++ を呼ぶ層＝まさにリスクのある層には適用できない**。代替は Valgrind（Linux）や cargo-careful になる。

### 3.3 OpenCV 5.0.0 のバイナリ入手性（基準 A / B）

- OpenCV 5.0.0 の **Windows 向け prebuilt（`opencv-5.0.0-windows.exe`、自己展開アーカイブ）が公式 GitHub Releases / SourceForge で配布されている**。ソースからのビルドを開発ループに含めずに済む。

### 3.4 Unity 側の自動化（両案共通）

- Unity Test Framework は `Unity.exe -runTests -batchmode -projectPath <PATH> -testResults <XML> -testPlatform EditMode|PlayMode` で CLI 実行でき、結果は **NUnit XML 形式**、テスト失敗時は**非ゼロ終了コード**を返す。`-testCategory` / `-testFilter` で絞り込める。
- Unity は Web の native plug-in について、**Unity に同梱された Emscripten と一致するツールチェーン**で `.o` を生成し `.a` にまとめることを推奨する。同梱バージョンは `<Editor>/Editor/Data/PlaybackEngines/WebGLSupport/BuildTools/Emscripten/emscripten/emscripten-version.txt` で確認できる。**LLVM はコンパイラバージョン間のバイナリ互換を保証しないため、Unity バージョン更新時は再コンパイルが推奨される。**

## 4. 基準ごとの評価

### 4.1 基準 A: cold clone から単一コマンドで通るか

| | C++ (CMake) | Rust (Cargo) |
| --- | --- | --- |
| OpenCV の入手 | prebuilt 展開 or vcpkg | 同左（**Rust 案も OpenCV C++ 本体が必要**） |
| 追加の必須依存 | なし | **LLVM/Clang** |
| 設定の置き場所 | **`CMakePresets.json` としてリポジトリ内に宣言的に記述できる** | `.cargo/config.toml` の `[env]` に書けるが、`OPENCV_LINK_LIBS` 等はマシン固有パスになりやすい |
| 手数 | `cmake --preset` → `--build` → `ctest --preset` | `cargo test`（環境変数が正しく設定されていれば） |

Rust の `cargo test` は単体では最短だが、**OpenCV への到達に必要な環境変数がリポジトリ外に漏れやすい**点が基準 E とあわせて効く。C++ 側は `CMakePresets.json` に `CMAKE_PREFIX_PATH` を含めてコミットでき、状態をリポジトリ内に閉じ込めやすい。

**評価: C++ がやや有利。** ただし差は小さく、どちらも「OpenCV のバージョン固定 prebuilt をキャッシュから配置する」ステップを自前で用意すれば解消できる（§5.2）。

### 4.2 基準 B: インクリメンタル所要時間 / エラーメッセージ

Rust のコンパイラ診断は C++ より明確に優れ、エージェントへのフィードバック信号としては本来強力である。**ただし本件では効果が減衰する。**

- 悪名高い C++ のエラーは**テンプレート重用コード**で発生する。本プロジェクトの native 層は `extern "C"` の handle ラッパであり、テンプレートメタプログラミングをほぼ含まない。発生するのは型不一致・未宣言・リンクエラーといった平易なものが中心になる。
- さらに計画上、**C ABI と C# P/Invoke は binding specification から生成される**（計画書 §6）。手書き量が少ないほど「1 行あたりの書きやすさ」の差は薄まり、**generator と spec の正しさ**が支配的になる。

ビルド時間は、C++ 側が「小さな ABI 層のみ再コンパイル、prebuilt OpenCV にリンク」で秒単位に収まる。Rust 側は自クレートのインクリメンタルは速いが、**依存バージョン更新時に巨大な生成済みクレート全体の再ビルドが発生する**（§3.1 の要検証項目に依存）。

**評価: 引き分け〜C++ わずかに有利。** Rust の診断優位は本件の性質上ほとんど発揮されない。

### 4.3 基準 C: 失敗が機械可読かつ有限時間で返るか

これは**言語ではなくハーネス設計の問題**であり、両案で同じ対策が必要になる。

エージェントの TDD ループを止める最大の要因は、テスト失敗ではなく **native クラッシュによるハング**である。具体的には次を必ず潰す必要がある。

- テストは**サブプロセスかつタイムアウト付き**で実行する（CTest の `TIMEOUT` プロパティ等）。segfault を「赤いテスト」に変換し、待ち続けない。
- **Windows Error Reporting のモーダルダイアログを無効化する**。テストハーネス起動時に `SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX)` と `_CrtSetReportMode` を設定しないと、クラッシュがダイアログで停止してタイムアウトまでループが固まる。
- 出力を機械可読にする: `ctest --output-junit`、`dotnet test` の TRX / JUnit logger、Unity の `-testResults`。

`cargo test` は標準でプロセス分離とパニック捕捉を持つため**初期セットアップは Rust が明確に楽**である。C++ は GoogleTest / Catch2 + CTest の配線が必要（一度書けば済む規模）。

**評価: セットアップ容易性は Rust 有利、定常運用では差がない。**

### 4.4 基準 D: UB の自動検出 ★決定的

ここが本調査で最も差がついた項目である。

Rust の安全性は「安全な Rust を書いている限り」成立する。しかし**本プロジェクトの native 層は定義上ほぼ全体が `unsafe`** である — 生ポインタ、stride、buffer length、borrowed lifetime を C ABI 越しに扱うのが仕事だからである。そして §3.2 のとおり **Miri はその層を検査できない**。

結果として両案とも sanitizer に頼ることになるが、その入手条件が異なる。

| | C++ | Rust |
| --- | --- | --- |
| ASan / LSan | **stable MSVC で `/fsanitize=address` 単一フラグ、GA** | **nightly 限定**（`-Zsanitizer`、安定化は 2026 目標として進行中） |
| UBSan | Clang/GCC で成熟 | 一部のみ |
| Miri | 該当なし | **FFI 層に適用不可** |
| Valgrind (Linux CI) | 利用可 | 利用可 |

つまり **Rust の主要な安全性優位は、まさに危険な層で大きく減衰する一方、C++ の sanitizer エコシステムはその層にフルに適用できる。**

use-after-free / double-free / buffer overflow / leak は、handle table と create-release 契約を持つ C ABI の典型的な失敗モードそのものであり、これを**安定版ツールチェーンの CI レーンで自動検出できること**は、エージェント駆動開発において非常に大きい。テストが green でも UB が残る状態を機械的に排除できる。

**評価: C++ が明確に有利。**

### 4.5 基準 E: 環境の非決定性 / upstream 依存

- Rust 案は依存が 1 段深い: `Unity C# → ocvu_ C ABI (Rust) → opencv crate が生成した C++ bridge → OpenCV C++`。C++ 案は `Unity C# → ocvu_ C ABI (C++) → OpenCV C++`。
- `opencv` crate は **自ら unstable と表明**し、**`Mat` の共有可変性**について警告している（§3.1）。本プロジェクトが最優先で厳密化したいのは `Mat` の ownership contract であり、**その一点について upstream が「Rust の通常の安全性保証を期待するな」と述べている**のは、価値提案と直接衝突する。
- crate が OpenCV 5.x の point release に追随できない期間が発生すると、**エージェントのループが upstream 待ちでブロックされる**。C++ 案にはこの中間層が存在しない。
- Rust 案では `opencv` crate の MIT license と transitive dependency を third-party notices / SBOM の対象に加える必要があり、計画書 §8 の管理対象が増える。

**評価: C++ が有利。**

### 4.6 モバイル / Web（プロジェクト価値の集中点）

| Platform | C++ | Rust |
| --- | --- | --- |
| iOS | `extern "C"` + static `.a` を `__Internal` で参照。Unity 標準経路 | Rust static lib + 生成 C++ bridge + OpenCV static libs のリンク統合が追加 |
| Android | NDK 標準経路。16 KB page size 検証 | Rust cross target と NDK / OpenCV の統合検証が追加 |
| Web | **Unity 同梱 Emscripten をそのまま使う（Unity が文書化した経路）** | Rust の Emscripten target を **Unity 同梱 emsdk と厳密に一致させる**必要がある。最大の事前検証項目 |

Web は計画書 §6.1 でも「Rust 案の最大の事前検証項目」とされている。§3.4 のとおり **LLVM はバージョン間のバイナリ互換を保証せず、Unity バージョン更新のたびに再ビルドが要る**ため、ここに Rust ツールチェーンの一致条件を追加するのは、自動化したいループにとって継続的な負債になる。

**評価: C++ が明確に有利。**

## 5. 提案するハーネス設計（言語選択より重要）

### 5.1 テストピラミッド

**Unity を経由しないテスト層を最大化する**ことが自動 TDD の核心である。

| 層 | 内容 | 実行手段 | 想定時間 | 頻度 |
| --- | --- | --- | --- | --- |
| L0 | spec → 生成物の一致（golden test） | generator の単体テスト | < 1 秒 | 毎編集 |
| L1 | **C ABI の契約テスト** | GoogleTest / Catch2 + CTest | 1〜5 秒 | 毎編集 |
| L2 | **ASan / UBSan / LSan レーン** | L1 と同一テストを instrumented ビルドで | 10〜30 秒 | 毎コミット |
| L3 | **P/Invoke マーシャリング** | **素の .NET + `dotnet test`（Unity 不使用）** | 2〜5 秒 | 毎編集 |
| L4 | Unity EditMode (Mono) | `Unity -batchmode -runTests` | 1〜3 分 | pre-merge |
| L5 | Unity IL2CPP Player | Player ビルド + 実行 | 5〜20 分 | nightly / release |

### 5.2 この設計の要点

**L3 が最大の工夫である。** C# の P/Invoke 宣言、マーシャリング、`SafeHandle` / `IDisposable` の破棄経路、stride やピクセルフォーマットの取り回しは、**Unity を一切起動せずに素の .NET 上で検証できる**。UPM パッケージ配下の `.cs` を .NET テストプロジェクトから共有参照（`<Compile Include="../../Packages/.../Runtime/**/*.cs" />`）すれば、同一ソースを秒単位で回せる。

Unity が本当に必要なのは **Mono と IL2CPP の差、stripping、プラットフォーム固有のロード挙動**の検証だけであり、それは L4 / L5 に隔離する。これにより**エージェントのイテレーションの大半が数秒レーンに収まる**。ここを設計しないと、言語をどちらにしても Unity の起動時間でループが死ぬ。

その他の必須事項:

- **OpenCV は固定バージョンの prebuilt をキャッシュして配置し、開発ループ内でビルドしない。** キャッシュキーは OpenCV tag + toolchain + CMake flags。
- **単一のエントリポイントを用意する**（例: `tools/dev.ps1 test`）。エージェントが CMake / Cargo の呪文を覚え直す必要をなくす。
- **設定はリポジトリ内に宣言的に置く**（`CMakePresets.json`）。マシン固有の環境変数に依存させない。
- **クラッシュ対策**を最初に入れる（§4.3）— タイムアウト、WER ダイアログ抑止。これは Phase 1 の最初のコミットに含めるべきで、後回しにすると必ずループが固まる。
- 出力はすべて機械可読形式に統一する。
- テストから wall-clock / 乱数を排除し、シードを固定する。

### 5.3 TDD の書き方

C ABI に対する TDD では、**テストを実装言語の外側に置く**。

- L1 は C++ で書いても、**C ABI のみに触れ、backend の内部型に依存しない**ようにする。
- L3（.NET）を**契約スイートの正本**に据える。ここが言語中立な仕様の実行可能表現になる。

これにより、後から Rust backend を差し替えても**同一のテストスイートがそのまま合否判定に使える**。

## 6. 判断を安価に覆せる形にする

現時点で C++ を選ぶが、この判断は不可逆にしない。

- **public C header と binding specification を backend から独立させる**（計画書 §10 が既にそう述べている）。
- **契約テスト（L1 / L3）を backend 非依存に書く。**
- 上記 2 点が守られていれば、Rust backend は「同じ C ABI を実装し、同じスイートを通す」だけで評価でき、置き換えコストは実装分に限定される。

したがって **Phase 0 の Rust spike は「実施するか否か」ではなく「いつ実施すると最も安いか」の問題**になる。推奨は次のとおり。

- Phase 0 では **C++ で L0〜L3 のハーネスを先に完成させる**。
- Rust spike は**そのハーネスが動いた後に、同じスイートに対して**タイムボックス付きで実施する。ハーネスが先にあれば spike の評価が客観的になり、計画書 §6.1 の 6 条件をそのまま合否判定に使える。
- spike の追加測定項目として §3.1 の「binding 生成タイミングと初回/インクリメンタルビルド時間」を必ず含める。

### Rust を選ぶべきケース

次のいずれかが成立するなら結論は変わり得る。

- ~~**Web / Wasm をスコープから外す**~~ — **消えた（2026-09-03、M6）。**
  外すのではなく **C++ で実際にやったので、この検証項目は解決済みである。**
  Unity 同梱 Emscripten（6000.3 系は 3.1.39-git）で `.o` を作り `.a` に束ね、
  実物のブラウザで Player を動かすところまで通した。**§4.6 が「Rust 案最大の
  事前検証項目」と書いていた一致条件は、C++ 側では対応表 1 つと、それを守る
  検査 2 本で済んだ** —— 表の自己整合を見るもの（`tools/tests/EmscriptenVersion.Tests.ps1`）と、
  **Unity の実物と突き合わせるもの**（`tools/assert-emscripten-version.ps1`）。
  **対でなければ、写しである表（`tools/emscripten-versions.psd1`）が現実と
  合っているかを誰も見ない。**
  **Rust に移すなら、この一致条件を Rust の Emscripten target で作り直すことになる。**
- ~~**iOS をスコープから外す**~~ — **消えた（2026-08-30、M4）。** 外さずに実装した
  （静的ライブラリを libtool で束ねる）。**ただし実機で動かした実績はまだ無い。**
- **binding generator を採用せず、bridge を大量に手書きする方針に変える** — 安全な Rust の比率が上がり、行あたりの安全性が効いてくる。
- **Rust の sanitizer が stable 化する**（2026 目標として進行中）— 基準 D の差が消える。この進捗は再評価のトリガーとして監視する価値がある。

## 7. 主要情報源

- [opencv-rust (twistedfall/opencv-rust)](https://github.com/twistedfall/opencv-rust)
- [opencv crate INSTALL.md](https://github.com/twistedfall/opencv-rust/blob/master/INSTALL.md)
- [opencv crate on docs.rs](https://docs.rs/crate/opencv/latest)
- [opencv crate on crates.io](https://crates.io/crates/opencv)
- [Tracking Issue for stabilizing the sanitizers · rust-lang/rust#123615](https://github.com/rust-lang/rust/issues/123615)
- [Rust Unstable Book: sanitizer](https://doc.rust-lang.org/beta/unstable-book/compiler-flags/sanitizer.html)
- [Rust Project Goals: Stabilize MemorySanitizer and ThreadSanitizer Support](https://rust-lang.github.io/rust-project-goals/2026/stabilization-of-sanitizer-support.html)
- [Support native FFI calls via libffi · rust-lang/miri#11](https://github.com/rust-lang/miri/issues/11)
- [Address Sanitizer for MSVC Now Generally Available](https://devblogs.microsoft.com/cppblog/address-sanitizer-for-msvc-now-generally-available/)
- [MSVC AddressSanitizer (Microsoft Learn)](https://learn.microsoft.com/en-us/cpp/sanitizers/asan?view=msvc-170)
- [/fsanitize (Enable sanitizers)](https://learn.microsoft.com/en-us/cpp/build/reference/fsanitize?view=msvc-170)
- [OpenCV Releases](https://github.com/opencv/opencv/releases)
- [Unity - Manual: Run tests from the command line](https://docs.unity3d.com/6000.3/Documentation/Manual/test-framework/run-tests-from-command-line.html)
- [Unity - Manual: Web native plug-ins for Emscripten](https://docs.unity3d.com/6000.0/Documentation/Manual/webgl-native-plugins-with-emscripten.html)
