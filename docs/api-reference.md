# API リファレンス

**対象範囲: C ABI の 11 関数（M2 の 9 本 + M3.5 の 2 本）と、その上に立つ C# の公開 API
だけ。** まだ無い機能（`Mat` の部分参照、型変換・算術演算、**`imgcodecs` のファイルパス
経路**など）はここに書かない。**`WebCamTexture` 連携は M4 で足したので §2.6 にある。**詳しい経緯は
`docs/abi-ownership-and-versioning.md` §3「API の allowlist」（M3.5 の追加は §3.5）を、
所有権契約そのものは同 §1 を参照。

対応 Unity は **6000.3 以降**（`package.json` の下限が `6000.3`。**実際に検証しているのは
6000.3.16f1 の 1 版だけ**）。**対応 platform は Windows x64 / macOS arm64 / Linux x64 の 3 つ**
（mobile と Web は未対応）。

**native plugin の binary はリポジトリに入っていない。**
`Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/` は丸ごと成果物で、binary も
`.meta` も git は追跡しない。ローカルでは `./tools/dev.ps1 build` が、実行中の platform 分を
そこへ置く。利用者に届く経路は GitHub Release の **全部入り UPM tarball**
（`com.ayutaz.opencv-unity-native.tgz`）で、**3 platform 分の binary が 1 つに入る** ——
Unity は同じ package ID を 1 つしか導入できないので、platform ごとに分かれた tarball では
「エディタは Windows、実機は別の platform」が表現できないためである。**どの binary が
有効になるかは Plugin Import Settings（`.meta`）が決め**、Unity は自分の platform 向けの
1 つだけを読み込む（Unity 6.3 の EditMode で `PluginImporter` に問うて実測している。
**ただし実測したのは Windows 上で動く Unity であり、macOS 上での実測は無い**）。
platform ごとの tarball（`…-<version>-<platform>.tgz`）も補助として引き続き出るが、
**正は全部入りである**。したがって **Git URL では導入
できない**（`.meta` しか届かず `DllImport` が実行時に全部失敗する）。導入手順は
[README](../README.md) の Installing にある。

## 1. C ABI（`native/include/opencv_unity_native.h`）

すべて `extern "C"`、呼び出し規約は Cdecl。戻り値は `ocvu_status`（`int32_t`）。
`OCVU_STATUS_OK` (0) と `OCVU_STATUS_BUFFER_TOO_SMALL` (6) 以外はすべて失敗として扱う
（詳細後述）。C# から直接この層を呼ぶことは想定していない —
`CvUnity.Interop.NativeMethods`（`internal`）が P/Invoke 宣言を持ち、`CvUnity.CvMat` /
`CvUnity.CvOps` / `CvUnity.CvCodecs` / `CvUnity.CvNative` がそれを包んで公開する。

### Mat のライフサイクル

| 関数 | 内容 |
| --- | --- |
| `ocvu_mat_create(int32_t rows, int32_t cols, int32_t type, ocvu_mat_handle* out_handle)` | rows × cols、指定 type の Mat を確保し、**native が所有する** handle を返す。`rows`/`cols` が 1 未満、または `type` が未知の場合は `OCVU_STATUS_INVALID_ARGUMENT`。`out_handle` が NULL なら `OCVU_STATUS_NULL_POINTER` |
| `ocvu_mat_release(ocvu_mat_handle handle)` | 解放する。解放済み・未知の handle は `OCVU_STATUS_INVALID_HANDLE`（落とさない） |
| `ocvu_mat_clone(ocvu_mat_handle src, ocvu_mat_handle* out_handle)` | `src` の内容を複製した、別の記憶域を持つ owned handle を作る |
| `ocvu_mat_get_info(ocvu_mat_handle handle, ocvu_mat_info* out_info)` | 形状を `out_info` に書く。NULL なら `OCVU_STATUS_NULL_POINTER` |

`ocvu_mat_handle`（`uint64_t`）は生ポインタではない。上位 32 bit が世代、下位 32 bit が
table の索引で、解放のたびに世代が進むため解放済み handle の再利用は必ず
`OCVU_STATUS_INVALID_HANDLE` になる。`0` は常に無効（`OCVU_MAT_HANDLE_NONE`）。

`ocvu_mat_info` の各フィールド:

| フィールド | 型 | 内容 |
| --- | --- | --- |
| `rows` / `cols` | `int32_t` | 形状 |
| `type` | `int32_t` | `OCVU_MAT_TYPE_8UC1` (0) / `_8UC3` (16) / `_8UC4` (24) のいずれか |
| `channels` | `int32_t` | チャンネル数 |
| `step` | `int64_t` | 1 行のバイト数 |
| `total_bytes` | `int64_t` | `rows * step` |

### Unity の buffer との受け渡し（借用は呼び出し内で完結）

| 関数 | 内容 |
| --- | --- |
| `ocvu_mat_copy_from_buffer(ocvu_mat_handle dst, const uint8_t* src, int64_t src_length, int64_t src_stride)` | 外部 buffer から Mat へコピーする |
| `ocvu_mat_copy_to_buffer(ocvu_mat_handle src, uint8_t* dst, int64_t dst_length, int64_t dst_stride)` | Mat から外部 buffer へコピーする |

**所有権契約（`docs/abi-ownership-and-versioning.md` §1）**: `src` / `dst` は
**この呼び出しの内側でだけ**読み書きされる借用であり、関数が戻った後 native は
一切保持しない。呼ぶ側は、呼び出しが戻るまでその領域を生かしておく責任を負う。

書く前にすべて検証し、1 つでも合わなければ**何も書かずに**該当 status を返す:
`src`/`dst` が NULL → `OCVU_STATUS_NULL_POINTER`、handle が無効 →
`OCVU_STATUS_INVALID_HANDLE`、`length`/`stride` が負、`stride` が Mat の 1 行より小さい、
`length` が `stride * rows` 分に満たない → いずれも `OCVU_STATUS_INVALID_ARGUMENT`。
`stride` は Mat の `step` と異なってよく（行ごとにコピーする）、Unity のテクスチャの
行アライメントを吸収できる。

### imgproc

| 関数 | 内容 |
| --- | --- |
| `ocvu_cvt_color(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t code)` | 色空間変換。`dst` の形状・型は結果に応じて上書きされる |
| `ocvu_resize(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t width, int32_t height, int32_t interpolation)` | 拡大縮小。`width`/`height` が 1 未満なら `OCVU_STATUS_INVALID_ARGUMENT` |
| `ocvu_gaussian_blur(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t ksize_width, int32_t ksize_height, double sigma_x, double sigma_y)` | ガウシアンぼかし。`ksize` は正の奇数でなければ `OCVU_STATUS_INVALID_ARGUMENT`。`sigma` に 0 を渡すと `ksize` から OpenCV が算出する |

いずれも `src` と `dst` に同じ handle を渡すと `OCVU_STATUS_INVALID_ARGUMENT`
（in-place 対応は OpenCV の関数ごとに異なるため、曖昧さを ABI に持ち込まない）。
OpenCV 由来の失敗は `OCVU_STATUS_OPENCV_ERROR` になる。

`code` / `interpolation` の定数（M2 で公開する分のみ）:

| 定数 | 値 | 用途 |
| --- | --- | --- |
| `OCVU_CVT_BGRA2BGR` | 1 | `code` |
| `OCVU_CVT_RGBA2BGRA` | 5 | `code` |
| `OCVU_CVT_BGR2GRAY` | 6 | `code` |
| `OCVU_INTER_NEAREST` | 0 | `interpolation` |
| `OCVU_INTER_LINEAR` | 1 | `interpolation` |

### imgcodecs（M3.5 で追加）

**ファイルパスは受けない。** 扱うのはメモリ上の byte 列だけである（理由は
`docs/abi-ownership-and-versioning.md` §1.6）。

| 関数 | 内容 |
| --- | --- |
| `ocvu_imencode(ocvu_mat_handle src, const char* ext, uint8_t* buffer, int32_t buffer_size, int32_t* out_required_size)` | `src` を `ext`（".png" のように先頭のドットを含む）の形式に符号化して `buffer` へ書く。**2 回呼ぶ**（下記）|
| `ocvu_imdecode(const uint8_t* data, int64_t length, int32_t flags, ocvu_mat_handle dst)` | 符号化された byte 列を復号して `dst` に入れる。`dst` の形状・型は結果に応じて上書きされる |

**`ocvu_imencode` は 2 回呼ぶ。** 符号化後の大きさは呼ぶ側に分からないので、1 回目は
`buffer = NULL` / `buffer_size = 0` で呼んで `out_required_size` に必要バイト数を受け取り
（戻り値は `OCVU_STATUS_BUFFER_TOO_SMALL`。**これは失敗ではない**）、2 回目にその大きさの
buffer を渡す。last-error や OpenCV version の取得と同じ作法である。**足りないときは
buffer に 1 バイトも書かない** —— 途中まで書くと、呼ぶ側は部分的に正しい buffer を掴む。
成功時、`out_required_size` には実際に書いたバイト数が入る。

**出力の所有権は最初から最後まで呼ぶ側にある。** native が確保した blob を handle で
返す形は採らない（`docs/abi-ownership-and-versioning.md` §1 に無い所有権の種類を
増やすため）。`ocvu_imdecode` の `data` も、`ocvu_mat_copy_from_buffer` の `src` と同じ
**呼び出し内で完結する借用**である。

status:

| 条件 | status |
| --- | --- |
| `out_required_size` が NULL | `OCVU_STATUS_NULL_POINTER` |
| `ext` が NULL | `OCVU_STATUS_NULL_POINTER` |
| `ext` が空文字列 | `OCVU_STATUS_INVALID_ARGUMENT` |
| `buffer_size` が負 | `OCVU_STATUS_INVALID_ARGUMENT` |
| `buffer_size > 0` なのに `buffer` が NULL | `OCVU_STATUS_NULL_POINTER` |
| handle が無効（`src` / `dst` とも）| `OCVU_STATUS_INVALID_HANDLE` |
| `buffer_size` が必要量に満たない | `OCVU_STATUS_BUFFER_TOO_SMALL`（`out_required_size` に必要量。**buffer は書かない**）|
| 符号化結果が `int32_t` に収まらない | `OCVU_STATUS_INVALID_ARGUMENT` |
| OpenCV が扱えない拡張子、`imencode` が false を返す | `OCVU_STATUS_OPENCV_ERROR` |
| `data` が NULL | `OCVU_STATUS_NULL_POINTER` |
| `length` が 0 以下、または `INT32_MAX` を超える | `OCVU_STATUS_INVALID_ARGUMENT` |
| 画像として解釈できない byte 列 | `OCVU_STATUS_OPENCV_ERROR`（メモリは壊さない）|

`flags` の定数（`cv::IMREAD_*` と同じ値。実装側の `static_assert` が写し間違いを固定する）:

| 定数 | 値 | 内容 |
| --- | --- | --- |
| `OCVU_IMREAD_UNCHANGED` | -1 | そのまま読む（アルファも保つ）|
| `OCVU_IMREAD_GRAYSCALE` | 0 | 1 チャンネルの灰色 |
| `OCVU_IMREAD_COLOR` | 1 | 3 チャンネルの BGR |

### この allowlist に含まれないもの

`ocvu_get_abi_version` / last-error 取得 / status 表の照会 / `ocvu_get_opencv_version` /
`ocvu_get_build_information` / `ocvu_debug_throw` / `ocvu_debug_crash` は存在するが、
M0/M1 由来の診断・conformance test 用 API であり、この allowlist（M2 の 9 本 + M3.5 の
2 本 = 11 本）の対象外。C# 側では `CvNative` の一部メンバがこれらを包んでいるので、
公開 C# API としての契約は §2.4 に記載する。

## 2. C# 公開 API

対象アセンブリ: `CvUnity.Core`（`Runtime/Core/`、`UnityEngine` 非参照）、
`CvUnity.UnityIntegration`（`Runtime/UnityIntegration/`、`UnityEngine` 参照）。
`CvUnity.Interop`（`Runtime/Interop/`）は P/Invoke 宣言のみを持ち、公開型は無い
（`NativeMethods` は `internal`）。

### 2.1 `CvUnity.CvMat`

native が所有する `Mat` への handle を包む `sealed class`、`IDisposable`。
**Unity が所有するメモリを指す `CvMat` は存在しない** — handle は常に native 側の
ものであり、Unity の buffer は下記の `CopyFrom`/`CopyTo` でその場だけ読み書きされる。

| メンバ | 内容 |
| --- | --- |
| `static CvMat Create(int rows, int cols, CvMatType type)` | `ocvu_mat_create` を呼ぶ。失敗すると `CvNativeException` |
| `CvMat Clone()` | `ocvu_mat_clone` を呼ぶ。複製は独立した記憶域を持つ |
| `int Rows` / `int Cols` / `int Channels` / `long Step` | `ocvu_mat_get_info` から都度取得するプロパティ。`ocvu_mat_info` の `type` と `total_bytes` は C# 側に公開していない |
| `void CopyFrom(byte[] source, long stride)` / `void CopyTo(byte[] destination, long stride)` | managed 配列との相互コピー。配列全体を marshal するので、`IntPtr` 版に比べコピーが 1 回多い |
| `void CopyFrom(IntPtr source, long length, long stride)` / `void CopyTo(IntPtr destination, long length, long stride)` | ポインタを直接渡す版。**借用契約**: `source`/`destination` は**この呼び出しが戻るまで**生きていなければならない。native はこの呼び出しの内側でしか触れず、戻った後は一切保持しない。`length`/`stride` は native 側が検証し、不整合なら 1 バイトも書かれない |
| `void Dispose()` | `ocvu_mat_release` を呼ぶ。二度目以降の `Dispose()` は no-op（内部 handle が既に 0） |

`CvMatType`（`enum`）: `Gray8 = 0`、`Bgr24 = 16`、`Bgra32 = 24`
（`OCVU_MAT_TYPE_8UC1` / `_8UC3` / `_8UC4` に対応）。

`CvMat` を Dispose せずに破棄すると native 側の handle が解放されない
（finalizer は無い）。`using` で確実に囲むこと。

### 2.2 `CvUnity.CvOps`

`static class`。imgproc 3 関数の薄い wrapper で、非 OK status を
`CvNativeException` に変換する。

| メンバ | 内容 |
| --- | --- |
| `static void CvtColor(CvMat src, CvMat dst, int code)` | `code` には下記定数を渡す |
| `static void Resize(CvMat src, CvMat dst, int width, int height, int interpolation)` | `interpolation` には下記定数を渡す |
| `static void GaussianBlur(CvMat src, CvMat dst, int ksizeWidth, int ksizeHeight, double sigmaX, double sigmaY)` | `sigmaX`/`sigmaY` に 0 を渡すと ksize から算出される |

定数: `Bgra2Bgr = 1`、`Rgba2Bgra = 5`、`Bgr2Gray = 6`、`InterNearest = 0`、`InterLinear = 1`。

### 2.3 `CvUnity.CvCodecs`

`static class`（`CvUnity.Core` アセンブリ）。符号化された画像 byte 列と `CvMat` の
相互変換。**ファイルは扱わない** —— 開くのは呼ぶ側の仕事で、ここが受けるのはメモリ上の
byte 列だけである（`File.ReadAllBytes`、`UnityWebRequest`、Android の `StreamingAssets`
から得たもの）。`CvOps` と別クラスにしてあるのは、`CvOps` が imgproc に範囲を
限っているためである。

| メンバ | 内容 |
| --- | --- |
| `static byte[] Encode(CvMat src, string ext)` | `ext`（".png" のように先頭のドットを含む）の形式に符号化する。**2 回呼びを隠す** —— 1 回目のサイズ問い合わせで `BufferTooSmall` 以外の status（無効な handle、扱えない拡張子）が返れば**そこで `CvNativeException` を投げる**。空配列を返して呼ぶ側に気づかせない形にはしない。返る配列の長さは必要量ちょうど |
| `static void Decode(byte[] data, int flags, CvMat dst)` | 復号して `dst` に入れる。`dst` の大きさと型は結果に応じて置き換わる |
| `static CvMat Decode(byte[] data, int flags)` | 復号して新しい `CvMat` を返す。**呼び出し元が `Dispose` する責任を持つ**（失敗時は内部で破棄してから送出する）|

定数: `ImreadUnchanged = -1`、`ImreadGrayscale = 0`、`ImreadColor = 1`
（C ABI の `OCVU_IMREAD_*` に対応）。

`ext` は **UTF-8 の NUL 終端 byte 列**として native へ渡す。marshaller の既定 `CharSet` に
任せないのは、境界での文字コード変換を実行環境（Mono / IL2CPP）任せにしないためである
（`CvNative` が文字列の取得で UTF-8 を明示的に扱っているのと同じ理由）。

### 2.4 `CvUnity.CvNative`

`static class`。ネイティブ層のバージョン照会とエラー取得。

| メンバ | 内容 |
| --- | --- |
| `static int AbiVersion` | `ocvu_get_abi_version()`。ロードされている native library の C ABI バージョン |
| `static CvStatus GetLastErrorStatus()` | 呼び出しスレッドの直近のエラー status |
| `static string GetLastErrorMessage()` | 直近のエラーメッセージ。無ければ空文字列 |
| `static void ThrowIfFailed(CvStatus status)` | `status` が失敗なら `GetLastErrorMessage()` を添えて `CvNativeException` を送出する。`CvMat` / `CvOps` / `CvCodecs` の各メンバが内部で使っている |
| `static bool IsFailure(CvStatus status)` | `Ok` と `BufferTooSmall` 以外を失敗とみなす |
| `static string OpenCvVersion` | リンクされている OpenCV のバージョン文字列（例 `"5.0.0"`） |
| `static string GetBuildInformation()` | `cv::getBuildInformation()` の内容。どの依存が有効リンクかを実行時に確認する用途 |
| `static CvStatus DebugThrow(int kind)` | conformance test 専用。native 側に意図的に例外を投げさせる。通常のアプリケーションコードから呼ぶ用途ではない |

`CvStatus`（`enum`）: `Ok = 0`、`InvalidArgument = 1`、`NullPointer = 2`、
`OutOfMemory = 3`、`OpenCvError = 4`、`UnknownError = 5`、`BufferTooSmall = 6`、
`InvalidHandle = 7`。native 側の `OCVU_STATUS_LIST` と数値が一致することを L3 の
`StatusCodeSyncTests` が検査する。`BufferTooSmall` は失敗ではなく、出力バッファの
必要サイズを問い合わせる正規の使い方の結果である。**M3.5 以降、これは診断 API だけの
話ではない** —— `ocvu_imencode` が同じ作法で画像データの必要量を返す。

`CvNativeException`（`class`, `Exception` 派生）: `CvStatus Status { get; }` を持つ。
`Message` は `ThrowIfFailed` が `GetLastErrorMessage()` から埋める。

### 2.5 `CvUnity.Unity.TextureConverter`

`static class`（`CvUnity.UnityIntegration` アセンブリ）。`Texture2D` と `CvMat` の
相互変換。**M2 時点で `TextureFormat.RGBA32` のみ対応**、それ以外を渡すと
`NotSupportedException`。

| メンバ | 内容 |
| --- | --- |
| `static CvMat ToMat(Texture2D texture)` | `texture.GetRawTextureData<byte>()` の先頭アドレスを直接 native に渡し、コピー無しで新しい `CvMat`（`CvMatType.Bgra32`）を作る。**借用契約**: 呼び出しの内側だけで読み、戻った時点で終わる。返された `CvMat` は呼び出し元が `Dispose` する責任を持つ |
| `static void ToTexture(CvMat mat, Texture2D texture)` | `mat` の内容を `texture` の生データへ直接書き込み、`Apply()` する。`mat.Cols`/`Rows` が `texture` のサイズと一致しない場合は `ArgumentException`。**`mat` のチャンネル数 × 画素数が `texture` の RGBA32 前提（4 バイト/画素）と一致しない場合も `ArgumentException`** — native の検証は `stride`/`length` の整合しか見ないため、この不一致は Unity 層側で追加に検査している（詳細は `TextureConverter.cs` のコメント。実測: 4×3 の Gray8 を RGBA32 相当へ書くと native は成功を返しつつ先頭 12 バイトだけ書き換えていた） |

### 2.6 `CvUnity.Unity.WebCamTextureConverter`

`static class`（`CvUnity.UnityIntegration` アセンブリ、M4 で追加）。
`WebCamTexture` の画素から `CvMat` を作る。**新しい C ABI 関数は使わない** ——
`CvMat.Create` + `CopyFrom` の上に立つ純粋な C# である。

| メンバ | 内容 |
| --- | --- |
| `static CvMat ToMat(WebCamTexture texture, bool flipVertically = true)` | `GetPixels32()` で画素を取り、`CvMat`（`CvMatType.Bgra32`）を作る。毎フレーム呼ぶと配列を確保し続けるので、下の overload を使うこと |
| `static CvMat ToMat(WebCamTexture texture, ref Color32[] buffer, bool flipVertically = true)` | 呼ぶ側が持つ配列を再利用する。`buffer` が `null` か長さ不足なら確保し直して返す |
| `static CvMat ToMat(Color32[] pixels, int width, int height, bool flipVertically = true)` | 画素配列から直接作る。`pixels.Length` が `width * height` と一致しない場合は `ArgumentException` |

**落とし穴が 2 つある。**

1. **既定で上下を反転する。** Unity のテクスチャは左下が原点、OpenCV の `Mat` は
   左上が原点である。既定（`flipVertically: true`）はその差を吸収するので、
   得られた `Mat` は OpenCV の慣習どおり「先頭行 = 画像の上端」になる。
   **その `Mat` をそのまま `TextureConverter.ToTexture` に渡すと上下逆に表示される**
   —— 往復させるなら `flipVertically: false` を使う。
2. **型は `Bgra32` だが、中身は RGBA の並びである。** `Color32` は R,G,B,A の順に
   格納されており、この変換はバイト列をそのまま渡す。`TextureConverter.ToMat` と
   同じ扱いで、`Texture2D` へ書き戻すぶんには一貫している。**`cv::cvtColor` に
   BGRA として渡すと赤と青が入れ替わる。**

### 2.7 `CvUnity.Unity.NativeArrayExtensions`

`static class`（`CvUnity.UnityIntegration` アセンブリ）。`CvMat` に対する
`NativeArray<T>` 向け拡張メソッド。`IntPtr` 版と等価だが、呼び出し側に
`allowUnsafeCode` やアドレス取得・バイト長計算を要求しない。

| メンバ | 内容 |
| --- | --- |
| `static void CopyFrom<T>(this CvMat mat, NativeArray<T> source, long stride) where T : struct` | `source` の内容を `mat` へ写す |
| `static void CopyTo<T>(this CvMat mat, NativeArray<T> destination, long stride) where T : struct` | `mat` の内容を `destination` へ写す |

**`NativeArray<T>.Length` は要素数であってバイト数ではない。** 両メソッドは内部で
`UnsafeUtility.SizeOf<T>()` を掛けてバイト長を計算する。`IntPtr` 版
（`CvMat.CopyFrom(IntPtr, long, long)` / `CopyTo`）を直接使う場合、この換算は
**呼ぶ側の責任**になる。`Color32`（4 バイト/要素）のような多バイト要素で
`Length` をそのままバイト数として渡すと 4 倍のずれになり、確保領域の外へ書き込む。

**借用契約**は `CvMat.CopyFrom(IntPtr, long, long)` と同じ: 渡した `NativeArray<T>` は
呼び出しが戻るまで `Dispose` してはならない。


### スレッドから使うとき

利用者が最初に踏みやすいところなので、ここにも短く書く。正本は
[所有権と versioning](./abi-ownership-and-versioning.md) §1.5 にある。

| | |
| --- | --- |
| **別々の `CvMat` を、別々のスレッドから同時に使う** | してよい |
| 同じ `CvMat` を、複数のスレッドから同時に使う | してはいけない（`cv::Mat` 自体のデータ競合になる） |
| 他のスレッドが使っている最中に `Dispose()` する | してはいけない（解放済みメモリへのアクセスになる） |

後ろの 2 つは、解放済み handle の再利用と違って**世代検査では捕まらない**。
`Dispose()` 済みの handle をあとで使えば `OCVU_STATUS_INVALID_HANDLE` で
弾かれるが、「解放と使用が本当に同時に起きた」場合は弾けない。

1 つ目を支えるために、handle が指す `Mat` のアドレスは他の handle の作成・
解放で動かないようにしてある（M3 でここが壊れていたのを直した。経緯は §1.5）。

## 3. 対象外（この文書に書かないもの）

`Mat` の部分参照（ROI）、型変換・算術演算、チャンネル分離、**`imgcodecs` のファイルパス
経路** — いずれも `docs/abi-ownership-and-versioning.md` §3 が
「まだ作らないもの」として明記しており、この API リファレンスにも存在しない。
契約が固まり実装されたマイルストーンで、この文書に追記する形にする。
**メモリ上の byte 列の encode / decode は M3.5 で足したので、上の §1「imgcodecs」と
§2.3 にある。`WebCamTexture` 連携は M4 で足したので §2.6 にある** —— どちらも
ここには残っていない。

## 参照

- `docs/abi-ownership-and-versioning.md` — 所有権契約・versioning・API allowlist の正本
- `native/include/opencv_unity_native.h` — C ABI ヘッダ本体
- `Packages/com.ayutaz.opencv-unity-native/Samples~/BasicUsage/` — この API を使う最小サンプル
- `CLAUDE.md` — リポジトリ全体の不変条件と現在地
