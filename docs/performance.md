# 性能

**この文書は測った数字と、測っていないことを書く。** 数字を書く経路は
**2 つある**。ローカルの `./tools/dev.ps1 benchmark` —— 内部で `test-unity-player`
（GPU に依らない経路）と `test-unity-graphics`（GPU に依る経路）を順に走らせ、
両方の結果 XML から集めた `OCVU_BENCH:` 行を `artifacts/benchmarks/latest.json`
へ書く —— と、**2026-09-11 に足した CI の `benchmarks` job**（`ci-unity.yml`）で、
そちらは `Standalone` と `Graphics` の 2 レーンの結果 artifact を材料に
同じ `run-benchmarks.ps1` を呼び、`latest.json` を artifact として publish する。
**集計と判定はどちらも `run-benchmarks.ps1` で、そこは分かれていない。****`test-unity-graphics` 単体は `latest.json` を 1 バイトも書かない**
—— そちらは Unity のテストレーンにすぎず、収集は `run-benchmarks.ps1`
（`benchmark` コマンドだけが呼ぶ）が担う。

**ただし `./tools/dev.ps1 benchmark` は、Unity がある唯一のこのマシンでは
現状完走しない。** 内部で呼ぶ `test-unity-player` が後始末段階
（`Stop-UnityTestPlayers` 内の `Get-CimInstance`）でハングする既知の欠陥を
踏むため（詳細は `docs/roadmap.md` の M7a の判定「穴を隠さず書く」の項）。
**この文書の数字は、ハングしたプロセスを止めたうえで `run-benchmarks.ps1`
を直接叩いて得たものである。**

**測った環境**: Windows 10.0.22631、X64、Unity 6000.3.16f1、開発機 1 台
（2026-09-06、このマシン）。512×512 RGBA。**転記した日付と測った環境を
必ず併記する** —— 数字だけ残すと、測っていない環境についても言ったことになる。
利用者の端末の数字ではない。

## Texture と CvMat の間の経路

| 経路 | いつ使うか | GPU を待たせるか |
| --- | --- | --- |
| `TextureConverter.ToMat(Texture2D)` | CPU 側に実体がある画像 | 待たせない（転送が要らない） |
| `RenderTextureConverter.ToMat(RenderTexture)` | 描画結果を 1 回だけ読む | **待たせる** |
| `RenderTextureConverter.RequestMat(RenderTexture)` | **毎フレーム読む** | 待たせない |

**`Texture2D` の経路は写しを増やさない。** `GetRawTextureData` が返す
`NativeArray` のポインタをそのまま渡し、native は呼び出しの内側でだけ読む。
**この主張は L3 の `AllocationTests` が機械で守っている** —— ポインタ経路が
0 バイト、`byte[]` 経路がそれ以上であることを毎回確かめる。

**`RenderTexture` の経路は写しを 1 回増やす。** 上下反転のためである
（Unity は左下原点、OpenCV は左上原点）。避けるには native 側で反転する
ABI 関数を足すか、反転しないことを選ぶかで、**どちらも採らなかった** ——
前者は公開 ABI を増やし、後者は `WebCamTextureConverter` と規約が割れる。

## 測った数字

**単位は key の末尾で決まる** —— `_ns` で終わる key はナノ秒、それ以外は
マイクロ秒である（`tools/run-benchmarks.ps1`。`latest.json` は entry ごとに
`unit` を持つ）。

### このマシン（Windows、2026-09-06）

| 経路 | 実測 | レーン |
| --- | --- | --- |
| `mat_copy_to_pointer` | 29 µs | Player（IL2CPP、`-nographics`） |
| `mat_copy_from_pointer` | 33 µs | Player（IL2CPP、`-nographics`） |
| `texture2d_to_mat` | 292 µs | Player（IL2CPP、`-nographics`） |
| `rendertexture_sync` | 1756〜2562 µs（揺れる。下記） | Graphics（Editor/Mono、グラフィックス有効） |
| `rendertexture_async_request` | 1643〜2841 µs（揺れる。下記） | Graphics（Editor/Mono、グラフィックス有効） |
| `first_pinvoke`（起動時間） | 1 µs（下記の留保つき） | Player（IL2CPP、`-nographics`） |

### CI（Linux、run 34615630480、2026-09-11）

**2026-09-11 に CI が publish するようになったので、初めて 2 つの環境の
数字が並んだ。**

| 経路 | 実測 | レーン |
| --- | --- | --- |
| `mat_copy_to_pointer` | 39 µs | Standalone（IL2CPP、`-nographics`） |
| `mat_copy_from_pointer` | 50 µs | Standalone（IL2CPP、`-nographics`） |
| `texture2d_to_mat` | 52 µs | Standalone（IL2CPP、`-nographics`） |
| `rendertexture_sync` | 810 µs | Graphics（Editor/Mono、xvfb + ソフトウェア GL） |
| `rendertexture_async_request` | 1289 µs | Graphics（Editor/Mono、xvfb + ソフトウェア GL） |
| `first_pinvoke_ns`（起動時間） | 400 ns（下記の留保つき） | Standalone（IL2CPP、`-nographics`） |

**2 つの表を並べて読むときの注意が 3 つある。**

1. **`texture2d_to_mat` が 292 µs 対 52 µs で 5 倍以上違う。** 境界のコピー
   （29/33 対 39/50）はほぼ同じなので、差は `CvMat.Create` の確保側にある
   —— **どちらが「正しい」でもない。** 別の OS・別のアロケータ・別の負荷で
   測った別の数字である。
2. **CI の `Graphics` レーンの GPU はソフトウェア実装である**（コンテナの
   xvfb + Mesa）。実機の GPU の数字ではない。
3. **どちらも利用者の端末の数字ではない。**

**読み方を 3 つ書く。1 つでも欠けると誤読する。**

1. **境界そのものは安い。** 512×512 RGBA = 1 MB のコピーが 29〜33 µs である。
   `texture2d_to_mat` が 292 µs なのは `CvMat.Create` の確保が乗るからで、
   境界の往復そのものはこの数字に含まれない。
2. **RenderTexture は 1 桁高い。** 1756〜2562 µs は `texture2d_to_mat` の約 6〜9 倍で、
   GPU から CPU への転送が支配的である。
3. **`rendertexture_sync` と `rendertexture_async_request` の大小は、run をまたぐと
   入れ替わる。** 実際に 2 回計測しており、結果はこうだった:

   | | rendertexture_sync | rendertexture_async_request |
   | --- | --- | --- |
   | run A | 2562 | **2841**（sync より大きい） |
   | run B（`latest.json` の現在値） | **1756**（async より大きい） | 1643 |

   **2 つの経路の差は、実行ごとの揺れに埋もれている。** 「非同期のほうが
   速い」も「遅い」もどちらも主張できない。同期経路は `WaitAllRequests()` で
   同期的に完了させてから測っているため、非同期の価値（GPU を待たせない）
   そのものはこの測り方では数字に出ない —— 出ているのは「依頼してから
   取り出すまでの総コスト」であって、フレームをまたいで待たない場合の
   実際の得はここには表れない。**この逆転は、時間を assert しない設計判断
   （下記）の最も強い裏づけである** —— もし比率や閾値を置いていたら、
   run ごとに緑と赤が入れ替わっていたことになる。

**時間は測って公開するが、assert しない。** 共有 CI ランナーの上で時間を
assert すると必ずフレークになり、閾値を緩めればその検査は何も見ていない
ことになる。`./tools/dev.ps1 benchmark` の収集（`run-benchmarks.ps1`）が
時間の値そのものを理由に落ちるのは「測れなかったとき」（0 マイクロ秒 =
測定が効いていない、または該当レーンから benchmark の行が 1 本も拾えない）
だけで、遅い・速いでは落ちない。**ただし `test-unity-graphics` レーン全体は
これとは別の理由でも落ちる** —— `GraphicsChecks.AGraphicsDeviceIsPresent`
（GPU が無い）や画素の一致検査（読み出した内容が期待と違う）は correctness
の検査であって時間の検査ではなく、こちらは意図どおり普通に fail する。
**割り当て（allocation）と package size は事情が違い、
そちらは L3 と `PackageSize.Tests.ps1` が実際に assert している** ——
時間は run ごとに揺れるが、確保するバイト数と tarball のバイト数は
決定的だからである。

## native texture pointer を使う経路は実装していない

**やらないと決めた。** `Texture.GetNativeTexturePtr()` が返すのは GPU 側の
ハンドルで、CPU から読むにはレンダースレッドからグラフィックス API を
呼ぶ必要がある（`CommandBuffer.IssuePluginEventAndData` と、それを受ける
native のレンダリングプラグイン）。

**これは新しい subsystem である** —— D3D11 / D3D12 / Vulkan / Metal /
OpenGL ES / WebGL ごとに実装が分かれ、6 platform 分の分岐が要る。
`AsyncGPUReadback` は同じ「GPU を待たせない」性質を、**Unity が
platform 差を吸収した形で**提供する。

**得られるはずのもの**: GPU 上のテクスチャを CPU へ転送せずに native へ
渡せるので、転送のぶんが消える。**ただし OpenCV の関数は CPU のメモリを
読む**ので、結局どこかで転送が要る。**転送を無くせるのは、native 側でも
GPU の API を使って処理する場合だけ**で、それは OpenCV の CUDA / OpenCL
backend の話になり、M7 の CUDA に関する決定（同梱しない）に突き当たる。

**再評価の条件**: 利用者から「毎フレームの転送がボトルネックである」という
実測つきの報告が来たとき。**推測では着手しない。**

## RenderTexture の経路には落とし穴が 2 つある

1. **`-nographics` では動かない。** `RenderTexture.Create()` は
   **true を返すのに**、読んだ画素は塗った色ではなく `205,205,205` になる
   （実測、2026-09-05、このマシン、Unity 6000.3.16f1）。

   | | `-nographics` | グラフィックス有効 |
   | --- | --- | --- |
   | `graphicsDeviceType` | **Null** | Direct3D11 |
   | `supportsAsyncGPUReadback` | **False** | True |
   | `RenderTexture.Create()` | **true（誤解を招く）** | true |
   | `GL.Clear(10,20,30)` → `ReadPixels` | **205,205,205（描画されていない）** | **10,20,30** |

   **「作れた」が「読める」を意味しないのがこの経路の落とし穴である。**
   v0.1.0 の「ビルドできた ≠ 動く」と同じ形が、ここにも出た。
   `-nographics` で走るレーン（ローカルの `test-unity-player` /
   `test-unity-editmode`、CI の `EditMode` / `Standalone`）では
   **`RenderTextureConverter.ToMat` / `RequestMat` を検証できない** ——
   検証は `-nographics` を付けないレーンが担う。ローカルの
   `test-unity-graphics` と、**2026-09-11 に足した CI の `Graphics` レーン**の
   2 つである（**当初ここには「CI のレーンはどちらも `-nographics` で走る」と
   書いてあったが、それは誤りだった** —— 下の節を参照）。上下反転だけを行う
   `FillFlipped` は GPU に依存しないので、こちらは通常の EditMode / Player
   レーンで（合成した配列を使い）検証できる。
2. **`AsyncGPUReadback` は IL2CPP の Player で 1 度も走っていない。**
   `test-unity-player` も `-nographics` で走るため
   `supportsAsyncGPUReadback` が `false` になり、`RequestMat` の経路は
   **Editor（Mono）でしか実行されたことがない** —— 2026-09-11 からは
   ローカルの `test-unity-graphics` に加えて **CI の `Graphics` レーン**でも
   走るが、どちらも Editor である。実機の IL2CPP Player でこの経路が動くか
   どうかは、いまのところ未実証である。

**2026-09-11 に、この経路は CI へ配線された。** `ci-unity.yml` の
`Graphics` レーンが `-testCategory Graphics` で EditMode を走らせる。

**成立した理由は、前提が誤っていたことである。** ここには長らく
「CI のレーンは `-nographics` で走るのでこの経路を通れない」と書いてあったが、
**game-ci が Editor を `-nographics` で起動していないことを誰も測っていなかった。**
コンテナの `unity-editor` は

    xvfb-run -ae /dev/stdout "$UNITY_PATH/Editor/Unity" -batchmode "$@"

で、仮想 X の下から起動する（game-ci/docker の `images/ubuntu/editor/Dockerfile`）。
実測（run 34612557397）では `AGraphicsDeviceIsPresent` が通り、
`SyncReadbackProducesTheExpectedPixels` / `VerticalFlipIsApplied` /
`AsyncMatchesSync` / `TakingTheMatTwiceIsRejected` もすべて通った ——
**コンテナには実物の graphics device が在り、`AsyncGPUReadback` も動く。**

**「CI から見えないテストの一覧」を固定していた `CiVisibilityTests` は、
同時に消した。** その class の docstring が「graphics レーンを CI に配線できたら、
この一覧は空にでき、そのとき検査ごと消してよい」と書いていたとおりである。

**Player 側は依然として閉じていない。** game-ci の `run_tests.sh` は
Standalone Player を `xvfb-run ... -batchmode -nographics` で起動しており、
**`-nographics` は action 側が固定していてこちらからは外せない。**

## startup time

**Player が起きてから最初の P/Invoke が返るまで**を、
`BenchmarkRunner.MeasureFirstPInvoke`（`test-unity-player` レーン）で
測った: **1 マイクロ秒**（2026-09-06、このマシン）。

**2026-09-11 に単位をナノ秒へ変えた**（キーも `first_pinvoke` から
`first_pinvoke_ns` に改名した）。理由は、**CI の Linux Player で実測 0 に
なったから**である（run 34612557397）。`tools/run-benchmarks.ps1` は
0 を「測定が効いていない」として落とすので、そのままでは benchmark を
CI で集められない。**0 が出たのは測定が壊れていたからではなく、
マイクロ秒では分解能が足りなかったからである** —— 下に書くとおり、
ここで測っているのは既にライブラリが読み込まれた後の 1 回の呼び出しで、
それは 1 µs に満たない。**値そのものは正しく、桁の取り方だけが誤っていた。**

**この数字は「native ライブラリの真の初回ロード」を捉えていない。**
同じ Player の実行では `PlayerSmokeTests` など他の PlayMode テストが
先に `CvNative.AbiVersion` や他の `ocvu_` 関数を呼んでおり、NUnit の
実行順序はこのテストメソッドが**それらより先に走ることを保証しない**。
実測の 1 µs という値そのものが、ライブラリが既に読み込まれ済みだったことを
示唆している —— DLL のロードと静的初期化を含む真の初回呼び出しであれば、
この桁には収まらないはずである。**測れるものを測っただけであり、
測れていないもの（native ライブラリの真のコールドスタート）を測れた
ことにはしない。**

## 測っていないこと

- **実機の数字。** Android / iOS は CI がビルドするが、誰も実機で動かしたことがない
  （M4 の完了条件 3 件が未クローズ）
- **ブラウザの数字。** Web の E2E は Linux の headless Chromium 1 つだけである
- **native ライブラリの真のコールドスタート。** 上の「startup time」で書いたとおり、
  測った 1 µs は同じ Player 内の他テストが先に P/Invoke を呼んだ後の値である
  可能性が高く、真の初回ロード時間ではない
- **IL2CPP Player での `RenderTexture` の経路。** `RenderTextureConverter.ToMat` /
  `RequestMat` は Editor（Mono）でしか実行されたことがない —— ローカルの
  `test-unity-graphics` と、CI の `Graphics` レーンの 2 つである。
  **Player 側は原理的に届かない** —— game-ci が Standalone Player を
  `-nographics` で起動しており、その指定は action の中にある
- **`dnn` の推論（M7c、2026-09-10）。** `./tools/dev.ps1 benchmark` の対象に `dnn` の
  項目は無く、`OCVU_BENCH:` 行を `ocvu_dnn_net_forward` から出したことも無い。
  **モデルの読み込み・blob 化・forward のいずれについても、このリポジトリは
  数字を 1 つも持っていない** —— 実機で動かしたことが無いこと（上の 1 つ目）と
  合わせて、`dnn` は「作ってあるが、速さは分からない」状態である
  （roadmap の `### M7c の判定`）
