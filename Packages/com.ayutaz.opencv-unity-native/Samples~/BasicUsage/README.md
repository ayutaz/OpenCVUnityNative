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

## 動く環境

**リリースの tarball から導入したなら、全 platform 分の native plugin が
入っているので、そのまま動く。** Unity が自分の platform 向けだけを読み込む。

**リポジトリを直接使っている場合は、binary が入っていない。**
`Runtime/Plugins/` は丸ごと成果物で、**git は binary も `.meta` も追跡しない**
（全 platform 分を履歴に持つと際限なく肥大するため）。ローカルでは
`./tools/dev.ps1 build` が、**実行中の platform 分だけ**をそこへ置く。
他の platform 分が要るなら、公開済みリリースから取ってくるか CI の artifact を使う。

**対応 platform の一覧をここには書かない** —— 増減するたびにこの行だけが
古くなる。正本はリポジトリの README である。
