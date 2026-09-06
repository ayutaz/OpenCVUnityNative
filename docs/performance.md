# 性能

**この文書は測った数字と、測っていないことを書く。** 数字は
`./tools/dev.ps1 benchmark`（GPU に依らない経路）と
`./tools/dev.ps1 test-unity-graphics`（GPU に依る経路）が
`artifacts/benchmarks/latest.json` に書いたものを転記する。

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

| 経路 | µs/回 | レーン |
| --- | --- | --- |
| `mat_copy_to_pointer` | 29 | Player（IL2CPP、`-nographics`） |
| `mat_copy_from_pointer` | 33 | Player（IL2CPP、`-nographics`） |
| `texture2d_to_mat` | 292 | Player（IL2CPP、`-nographics`） |
| `rendertexture_sync` | 1756〜2562（揺れる。下記） | Graphics（Editor/Mono、グラフィックス有効） |
| `rendertexture_async_request` | 1643〜2841（揺れる。下記） | Graphics（Editor/Mono、グラフィックス有効） |
| `first_pinvoke`（起動時間） | 1（下記の留保つき） | Player（IL2CPP、`-nographics`） |

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
ことになる。`./tools/dev.ps1 benchmark` と `test-unity-graphics` が
落ちるのは「測れなかったとき」（0 マイクロ秒 = 測定が効いていない）だけで、
遅い・速いでは落ちない。**割り当て（allocation）と package size は事情が違い、
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
   `test-unity-player` / `ci-unity.yml` はどちらも `-nographics` で走るので、
   **`RenderTextureConverter.ToMat` / `RequestMat` はこの 2 つのレーンでは
   検証できない** —— 検証は `test-unity-graphics`（`-nographics` を付けずに
   EditMode を走らせる新しいローカル専用レーン）が担う。上下反転だけを行う
   `FillFlipped` は GPU に依存しないので、こちらは通常の EditMode / Player
   レーンで（合成した配列を使い）検証できる。
2. **`AsyncGPUReadback` は IL2CPP の Player で 1 度も走っていない。**
   `test-unity-player` も `-nographics` で走るため
   `supportsAsyncGPUReadback` が `false` になり、`RequestMat` の経路は
   **Editor（Mono）の `test-unity-graphics` でしか実行されたことがない。**
   実機の IL2CPP Player でこの経路が動くかどうかは、いまのところ未実証である。

**`test-unity-graphics` は CI に配線していない。** `ci-unity.yml` からは
呼ばれないので、**このレーンが赤くても merge は止まらない。**
`tests/UnityProject/Assets/Tests/EditMode/CiVisibilityTests.cs` が
「CI から見えないテストの一覧」を名指しで固定しており、
`GraphicsTests` / `GraphicsBenchmarkRunner.MeasureRenderTexturePaths` は
その一覧に載っている。新しく `[Category("Graphics")]` を付けたテストが
増えるとこの一覧との不一致で `CiVisibilityTests` 自体が落ちるので、
「いつの間にか CI から見えなくなっていた」は「差分として見える変更」に
変わる —— ただし変わるのは気づき方であって、**CI に配線されること自体では
ない。**

## startup time

**Player が起きてから最初の P/Invoke が返るまで**を、
`BenchmarkRunner.MeasureFirstPInvoke`（`test-unity-player` レーン）で
測った: **1 マイクロ秒**（2026-09-06、このマシン）。

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
  `RequestMat` は Editor（Mono）の `test-unity-graphics` でしか実行されたことがない
