# M7 — Optional profiles と性能: 設計（3 計画が共有する正本）

**この文書は仕様であって計画ではない。** 実行手順は 3 つの計画が持つ:

| | 計画 | 何を成立させるか |
| --- | --- | --- |
| **(a)** | [`2026-09-05-m7a-low-copy-and-benchmarks.md`](./2026-09-05-m7a-low-copy-and-benchmarks.md) | 低コピー経路の評価と benchmark の公開（完了条件 2・3） |
| **(b)** | [`2026-09-05-m7b-module-separation.md`](./2026-09-05-m7b-module-separation.md) | C ABI と C# の module 分離（完了条件 4 の前提） |
| **(c)** | [`2026-09-05-m7c-dnn-profile.md`](./2026-09-05-m7c-dnn-profile.md) | `dnn` を opt-in profile として足す（完了条件 1） |

**依存は (b) → (c) の 1 本だけである。** (a) はどちらにも依存せず、並行して進められる。
**(c) は (b) が済むまで着手してはならない** —— roadmap の決定 4 が明文でそう定めている。

---

## 1. M7 の完了条件（`docs/roadmap.md` の M7 節が正本。ここは写しである）

| # | 条件 | 担当 |
| --- | --- | --- |
| 1 | profile ごとの native artifact、manifest、third-party notices | **(c)** |
| 2 | RenderTexture / native texture pointer / AsyncGPUReadback を使う低コピー経路の評価 | **(a)** |
| 3 | package size、startup time、frame time、allocation の benchmark を公開 | **(a)** |
| 4 | `dnn` を足す前に、C ABI と C# の module 分離が済んでいること | **(b)** |
| 5 | CUDA / cuDNN を同梱するなら、再配布条件の確認が済んでいること。確認できないなら**同梱しないと決めて記録する** | **(c)** |

**条件 5 の結論は先に出ている。** roadmap が実測を持っている ——
cuDNN は 1 platform あたり **698〜772 MB**（PyPI `nvidia-cudnn-cu12` 9.25.1.1、2026-08-30 実測）で、
`tools/pack-upm-tarball.ps1` の上限は **512 MB**、現在の全部入りは **66 MB**
（69,565,901 バイト。**v0.3.0 の実物の asset を 2026-09-05 に測った**）。
**1 platform 分だけで上限を超えるので、ライセンスが解決しても現在の形では配れない。**

> **訂正**: ここには当初 9.6 MB と書いていたが、**それは M3.5 時点の 3 platform の値**である
> （`CLAUDE.md` は「その後 platform が増えたが測り直していない」と正しく断っており、
> 写した側が現在の値として扱ったのが誤りだった）。**6 platform では 66 MB である。**
> この訂正は (a) の Task 5 の上限に直接効く —— 計画が例として挙げた 50 MB では**即座に落ちる。**

(c) の仕事は「同梱しないと決めて記録する」ことであって、条項を読むことではない。

---

## 2. 3 つに分けた理由

**混ぜると、壊れたときにどれが壊れたか切り分けられない。** M5 で同じ判断をしている
（生成の仕組みと module 追加を分けた —— 「生成が壊れたのか module が壊れたのか」）。

具体的に、3 つは**別の subsystem を動かす**:

| | 動く subsystem | OpenCV の再ビルド | 公開 ABI |
| --- | --- | --- | --- |
| (a) | `Runtime/UnityIntegration`、Unity のレーン、新しい測定スクリプト | **起きない** | **増えない** |
| (b) | `native/CMakeLists.txt`、asmdef、生成器の emitter | **起きない** | **増えない** |
| (c) | `tools/opencv-config.psd1` の `Modules`、依存 allowlist、notices、配布物 | **起きる（6 platform）** | 増える |

**(a) と (b) は公開 ABI を 1 本も増やさない。** `OCVU_ABI_VERSION` は 1 のままである。

---

## 3. Global Constraints（3 計画すべてに掛かる）

**`docs/roadmap.md` と `CLAUDE.md` から逐語で写した。各計画の全タスクに暗黙に掛かる。**

### 境界の規約

- **C ABI が唯一の native contract。** `cv::Mat*` や STL 型を境界の外へ出さない。
  `ocvu_mat_handle` のような opaque handle と固定サイズ型のみを公開する
- **例外を ABI の外へ伝播させない。** 公開 ABI 関数は原則 `OCVU_TRY_BEGIN` /
  `OCVU_TRY_END` で本体を囲む
- **`ocvu_mat_handle` は常に native が所有する。Unity 所有のメモリを指す handle を返さない**
  （`docs/abi-ownership-and-versioning.md` §1）。**借用は 1 回の ABI 呼び出しの内側で完結する**
- **buffer 引数の長さと stride は必ず検証する。** `rows * stride` が渡された長さを超えるなら
  何も書かずに `OCVU_STATUS_INVALID_ARGUMENT` を返す。
  **`stride * rows` を計算してはならない** —— `stride > length / rows` の形で比べる（除算なら桁あふれしない）
- **`Runtime/Interop` と `Runtime/Core` は `UnityEngine` を参照してはならない。**
  UnityEngine 依存コードは `Runtime/UnityIntegration/`（別 asmdef）にのみ置く。
  この制約は `tests/Managed/CvUnity.Runtime.Shim/`（netstandard2.1）がビルドで機械的に強制する
- **境界の宣言を手で書かない。** `bindings/spec/*.json` が正本で、
  C ヘッダ・C# の P/Invoke・到達性テスト・API 対応表は `./tools/dev.ps1 generate` が出す。
  手で足すと `./tools/dev.ps1 verify-generated` が落とす

### 進め方

- **すべての実装を TDD で行う。** 失敗するテストを先に書き、赤いことを確かめてから実装する
- **main で直接作業しない。** 現在のブランチは `feat/m7-profiles-and-performance`
- **`dev.ps1` のレーンは相互排他である。2 つ同時に走らせないこと。**
  結果を書くレーンは開始時に `artifacts/test-results/` を**ディレクトリごと消す**ので、
  後から始めたほうが先行しているほうの結果を消す。**先行したレーンは赤くならず無音で止まる**
- **OpenCV をローカルでビルドしない。** `block-local-opencv-build.sh` が `opencv.ps1 build` を拒否する。
  逃げ道は `OCVU_ALLOW_LOCAL_OPENCV_BUILD=1` だが、**使わない**
- **`git add -A` / `git add .` は hook が拒否する。** ファイルを名指しで stage する
- **非 ASCII を出力する PowerShell スクリプトは、必ず先頭に**
  `[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()` **を置く**
- **PR を出す前に、その差分を書いていない別のエージェントに AI レビューさせる。**
  これがこのリポジトリの唯一のゲートである（人間のレビューは無い）
- **検査を足したり変えたりしたら、壊して落ちることを見る**（`prove-a-check-works` skill）。
  落ちることを確かめていない検査は、通っても証拠にならない

### 数を写さない

**このリポジトリは「本数を数える場所を 1 つに決める」規律を持つ。** 破ると、
1 つ足した日にそれ以外の全部が静かに嘘になる（M5 で 4 箇所が同時に古くなった実績がある）。

| 数えるもの | 正本 |
| --- | --- |
| 公開 ABI の本数 | `docs/api-map.md` の冒頭 |
| API allowlist の本数 | `docs/abi-ownership-and-versioning.md` §3 の冒頭 |
| 対象 platform の一覧 | `tools/dev.ps1` の `$script:AllPlatformBinaries` と `tools/opencv-config.psd1` の `Toolchains` |
| テストの件数 | `CLAUDE.md` の開発コマンドの表 |
| 必須チェックの本数 | `CLAUDE.md` の「機構として強制されていること」（正本は GitHub 側の設定） |

**新しく数を書きたくなったら、まず正本から読めないかを考える。**

---

## 4. 決定

### D1. benchmark は「主張する」ものと「公開する」ものを分ける

**時間を assert するテストは、共有 CI ランナーの上で必ずフレークになる。**
閾値を緩めればフレークは消えるが、そのときその検査は何も見ていない。
`prove-a-check-works` の規律（壊して落ちることを見る）を満たせない検査を足さない。

| 種類 | 扱い | 例 |
| --- | --- | --- |
| **決定的な量** | **assert する。CI を落とす** | 割り当てバイト数、package size、画素の一致 |
| **時間** | **公開するだけ。落とさない** | frame time、startup time、スループット |

**割り当てバイト数が決定的であることは実測で確かめた**（2026-09-05、.NET 8）:

```
GC.GetAllocatedBytesForCurrentThread() delta=4120   # new byte[4096]（+ヘッダ 24）
GC.GetAllocatedBytesForCurrentThread() delta=0      # 何も割り当てないとき
```

### D2. 測定の道具は、それ自身が壊れたときに落ちなければならない

**「0 バイトだった」は、測れていないときにも出る。** だから
**正の対照と負の対照を対にする**:

- **ポインタ経路は 0 バイトであること**（主張したいこと）
- **`byte[]` 経路は buffer の大きさ以上を割り当てること**（測定器が生きている証拠）

後者が落ちたら、測定器が死んでいるか、誰かが `byte[]` 経路を消した。
**どちらも知りたいことである。**

### D3. Unity の性能テストに新しい package を足さない

`com.unity.test-framework.performance` を足す案は採らない。理由は 2 つ:

1. **CI の Unity は game-ci のコンテナで package を復元する。** 依存を増やすと
   復元が増え、上流の都合で壊れる経路が 1 本増える
2. **このリポジトリには既に「機械可読な行を出して外から読む」型がある** ——
   `tools/run-web-e2e.ps1` が `OCVU_WEB_RESULT: passed=21 failed=0 reachable=54` を読み、
   `tools/assert-unity-results.ps1` が `native plugins present: 6` を読む。
   **同じ型に載せれば、判定の置き場所が増えない**

### D4. native texture pointer は「評価」であって「実装」ではない

`Texture.GetNativeTexturePtr()` が返すのは GPU 側のハンドルで、
**CPU から読むにはグラフィックス API をレンダースレッドから呼ぶ必要がある**
（`GL.IssuePluginEvent` / `CommandBuffer.IssuePluginEventAndData` と、
それを受ける native のレンダリングプラグイン）。

**これは新しい subsystem である** —— グラフィックス API ごと（D3D11 / D3D12 / Vulkan /
Metal / OpenGL ES / WebGL）に実装が分かれ、6 platform 分の分岐が要る。

**M7 の完了条件は「評価」である。** (a) は測定と記録を行い、実装はしない。
**「やらないと決めた」ことを明記する** —— roadmap の M4 で 4 件をそうしたのと同じ形である。

### D5. profile は「別 package」ではなく「同じ package の asmdef 制約」で表す

roadmap が未決としていた項目（「dnn を別 package で配るか、同じ package の
optional profile にするか」）を、**(b) の設計として決める。**

**同じ package に置き、`defineConstraints` で切り替える。** 理由:

- **全部入り tarball を配る正にしたのは M3.5 の決着である。** 別 package にすると、
  利用者は 2 つを導入し、版を合わせる責任を負う
- **`defineConstraints` は compile 時に効く。** define が無ければ dnn の asmdef は
  コンパイルされず、それを参照するコードは**コンパイルエラーになる** ——
  roadmap の決定 2 が求める「dnn が入らないビルドで参照が壊れない」は、
  **実行時に `EntryPointNotFoundException` が出ることではなく、ビルドが通らないこと**である

### D6. `dnn` を足すと OpenCV を 6 platform 分ビルドし直す

`tools/opencv-config.psd1` の `Modules` に `dnn` を足すと構成ハッシュが変わる。
**`calib` を足したときの実測: `4785d98e9aad` → `09fcbe260d87`、5 platform 分を作り直した**
（run 33589583504）。**現在のハッシュは `09fcbe260d87` で、platform は 6 つある。**

**あわせて依存 allowlist が確実に落ちる。** `tools/verify-opencv-artifact.ps1:177` に
`@{ Pattern = '*protobuf*'; Why = 'protobuf は dnn 用で allowlist 外' }` があり、
**これは dnn を足した瞬間に発火する検査である**（意図どおりに働く）。

`THIRD_PARTY_NOTICES.md:843` も明文で指示している:
*"If a future `Modules` list adds `dnn` or `gapi`, re-run these searches — they will very
likely start matching, and these two need to move up into the reproduced sections above."*
—— dlpack と flatbuffers はいま「ライセンスディレクトリにあるがリンクされていない」側に
分類されており、**`dnn` を足すとその分類が崩れる。**

### D7. `dnn` の C ABI は engine / backend の選択を出さない

roadmap が調べた上流の事実（2026-08-30）が、そのまま設計制約になる:

| 壊れるもの | 壊れないもの |
| --- | --- |
| `enum EngineType` の値（`ENGINE_AUTO` が 3 → 0、`ENGINE_NEW` は改名して値 1、`ENGINE_CLASSIC` は削除） | `readNetFromONNX` |
| 環境変数 `OPENCV_FORCE_DNN_ENGINE`（`2` が新エンジン → **ONNX Runtime** に変わる） | `Net::forward` |
| GPU 経路の 1 本（classic エンジン経由）が消えた | `blobFromImage` |

**したがって (c) の C ABI は、推論の入口だけを出す。** engine / backend を選ぶ引数も
定数も**公開しない**。5.1 で意味が変わる数字を `int` で境界の外へ出すのは、
`docs/abi-ownership-and-versioning.md` §2 が「bump する変更」に挙げている
**「既存 status code の数値または意味が変わる」と同じ形**である。

---

## 5. 明示的な非ゴール

**3 計画のどれにも入らないもの。** 「まだやっていない」ではなく「やらないと決めた」である。

| | なぜ |
| --- | --- |
| **CUDA / cuDNN の同梱** | 1 platform 分で配布上限を超える（上記 §1）。(c) が「同梱しない」と記録する |
| **native rendering plugin（`IssuePluginEvent`）** | グラフィックス API ごとに 6 platform 分の実装が要る新しい subsystem（D4） |
| **`gapi` / `videoio` / 動画 codec** | M7 のゴールには挙がっているが、`dnn` より優先度が低く、FFmpeg / GStreamer の再配布条件を別途確認する必要がある。**(c) の後に別計画で扱う** |
| **OpenCV の版を跨いだ並走**（roadmap 決定 3） | 「確認」ではなく config に軸を 1 本増やす設計作業で、版文字列を直に assert している 5 箇所の書き換えを伴う。**M7 の完了条件に入っていない** |
| **`OCVU_ABI_VERSION` の分割** | 単一の整数のままにする決定は `docs/abi-ownership-and-versioning.md` §2 が正本で、**ここで再オープンしない** |

---

## 6. 実機の穴は、この 3 計画では閉じない

**Android / iOS は CI がビルドするが、誰も実機で動かしたことがない**（M4 の完了条件 3 件が
未クローズ）。(a) が測る frame time は **CI のランナーと開発機のもの**であって、
利用者の端末のものではない。

**benchmark を公開するときは、どこで測ったかを必ず併記する。**
「速い」とだけ書くと、測っていない環境についても言ったことになる。
