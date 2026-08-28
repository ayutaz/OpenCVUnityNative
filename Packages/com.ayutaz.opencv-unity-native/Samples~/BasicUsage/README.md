# Basic Usage サンプル

`Texture2D` を OpenCV の `imgproc` で処理して書き戻す最小の例です。M2 が公開した
`Mat` のライフサイクルと `GaussianBlur`、および `TextureConverter` によるコピー無しの
Texture 連携を一通り使います。

## 何をするか

`BasicUsage.cs` は次の手順を `Start()` の中で行います。

1. `TextureConverter.ToMat(_source)` で `Source` テクスチャの生データを直接読み、
   native 側に確保された `CvMat`（BGRA32）を作る（コピー 1 回）。
2. 出力用の `CvMat` を `CvMat.Create` で確保する。
3. `CvOps.GaussianBlur` でぼかす。
4. 結果を新しい `Texture2D` へ `TextureConverter.ToTexture` で書き戻す（コピー 1 回）。
5. 付いている `Renderer` があれば、その material の `mainTexture` に差し替える。

`using` で `CvMat` を包んでいるので、スコープを抜けると同時に native 側の handle が
解放されます。二重解放や解放後アクセスを防ぐための明示的な後片付けは、この例では
特に要りません。

## 使い方

1. このサンプルを Package Manager からインポートする
   （下記「インポート方法」）。インポート先はプロジェクトの
   `Assets/Samples/OpenCV Unity Native/<version>/Basic Usage/` になる。
2. シーンに、`Renderer`（`MeshRenderer` など）を持つ GameObject を用意する
   （例: 3D の Quad）。
3. その GameObject に `BasicUsage` コンポーネントを付ける。
4. `Source` フィールドに **RGBA32** 形式の `Texture2D` を割り当てる。
   `TextureConverter` は M2 時点で RGBA32 のみに対応しており、それ以外の形式を
   渡すと `NotSupportedException` が出る
   （`Packages/com.ayutaz.opencv-unity-native/Runtime/UnityIntegration/TextureConverter.cs`）。
5. Play する。Console に `OpenCV <version>, ABI <n>` が出て、GameObject の見た目が
   ぼかした結果に差し替わる。

`_blurKernel`（既定 5）はガウシアンカーネルの一辺のサイズ。OpenCV の制約上、奇数を
指定すること。

## インポート方法

Unity Editor の **Window > Package Manager** で `OpenCV Unity Native` を選び、
右側パネルの **Samples** タブから **Basic Usage** の **Import** を押す。

`Samples~`（末尾 `~`）は Unity から見えない扱いのフォルダなので、インポートするまで
このスクリプトはどのプロジェクトでもコンパイルされない。裏を返すと、この README は
**インポートされて初めて動く**ことが書かれており、パッケージに UPM として入れただけの
状態ではこのサンプルの動作を保証しない。

## 現時点で動く環境

このリポジトリが今コミットしている native plugin は **Windows x64 のみ**
（`Runtime/Plugins/x86_64/opencv_unity_native.dll`）。macOS / Linux 向けの
ビルド設定と CI（M3 Task 1〜4）は入っているが、それぞれの plugin binary は
CI が artifact を公開してから `tools/dev.ps1 build` で配置する運用であり、
このコミットの時点では同梱されていない。Windows 以外でこのサンプルを動かすには、
該当 platform で native plugin を配置してからになる。
