# API リファレンス

**対象範囲: M2 で公開した C ABI の 9 関数と、その上に立つ C# の公開 API だけ。** まだ無い
機能（`Mat` の部分参照、型変換・算術演算、`imgcodecs`、`WebCamTexture` 連携など）はここに
書かない。詳しい経緯は `docs/abi-ownership-and-versioning.md` §3「初期 API の allowlist」を、
所有権契約そのものは同 §1 を参照。

対応 Unity は 6000.x のみ。native plugin は本リポジトリの現時点では Windows x64 のみ同梱
（`Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/x86_64/`）。macOS / Linux 向けの
ビルド構成と CI は M3 で追加済みだが、それぞれの plugin binary が同梱されるのは CI が
artifact を公開してからになる。

## 1. C ABI（`native/include/opencv_unity_native.h`）

すべて `extern "C"`、呼び出し規約は Cdecl。戻り値は `ocvu_status`（`int32_t`）。
`OCVU_STATUS_OK` (0) と `OCVU_STATUS_BUFFER_TOO_SMALL` (6) 以外はすべて失敗として扱う
（詳細後述）。C# から直接この層を呼ぶことは想定していない —
`CvUnity.Interop.NativeMethods`（`internal`）が P/Invoke 宣言を持ち、`CvUnity.CvMat` /
`CvUnity.CvOps` / `CvUnity.CvNative` がそれを包んで公開する。

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

### この allowlist に含まれないもの

`ocvu_get_abi_version` / last-error 取得 / status 表の照会 / `ocvu_get_opencv_version` /
`ocvu_get_build_information` / `ocvu_debug_throw` / `ocvu_debug_crash` は存在するが、
M0/M1 由来の診断・conformance test 用 API であり、この allowlist（M2 で追加した 9 本）の
対象外。C# 側では `CvNative` の一部メンバがこれらを包んでいるので、公開 C# API としての
契約は §2.3 に記載する。

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

### 2.3 `CvUnity.CvNative`

`static class`。ネイティブ層のバージョン照会とエラー取得。

| メンバ | 内容 |
| --- | --- |
| `static int AbiVersion` | `ocvu_get_abi_version()`。ロードされている native library の C ABI バージョン |
| `static CvStatus GetLastErrorStatus()` | 呼び出しスレッドの直近のエラー status |
| `static string GetLastErrorMessage()` | 直近のエラーメッセージ。無ければ空文字列 |
| `static void ThrowIfFailed(CvStatus status)` | `status` が失敗なら `GetLastErrorMessage()` を添えて `CvNativeException` を送出する。`CvMat`/`CvOps` の各メンバが内部で使っている |
| `static bool IsFailure(CvStatus status)` | `Ok` と `BufferTooSmall` 以外を失敗とみなす |
| `static string OpenCvVersion` | リンクされている OpenCV のバージョン文字列（例 `"5.0.0"`） |
| `static string GetBuildInformation()` | `cv::getBuildInformation()` の内容。どの依存が有効リンクかを実行時に確認する用途 |
| `static CvStatus DebugThrow(int kind)` | conformance test 専用。native 側に意図的に例外を投げさせる。通常のアプリケーションコードから呼ぶ用途ではない |

`CvStatus`（`enum`）: `Ok = 0`、`InvalidArgument = 1`、`NullPointer = 2`、
`OutOfMemory = 3`、`OpenCvError = 4`、`UnknownError = 5`、`BufferTooSmall = 6`、
`InvalidHandle = 7`。native 側の `OCVU_STATUS_LIST` と数値が一致することを L3 の
`StatusCodeSyncTests` が検査する。`BufferTooSmall` は失敗ではなく、出力バッファの
必要サイズを問い合わせる正規の使い方の結果である。

`CvNativeException`（`class`, `Exception` 派生）: `CvStatus Status { get; }` を持つ。
`Message` は `ThrowIfFailed` が `GetLastErrorMessage()` から埋める。

### 2.4 `CvUnity.Unity.TextureConverter`

`static class`（`CvUnity.UnityIntegration` アセンブリ）。`Texture2D` と `CvMat` の
相互変換。**M2 時点で `TextureFormat.RGBA32` のみ対応**、それ以外を渡すと
`NotSupportedException`。

| メンバ | 内容 |
| --- | --- |
| `static CvMat ToMat(Texture2D texture)` | `texture.GetRawTextureData<byte>()` の先頭アドレスを直接 native に渡し、コピー無しで新しい `CvMat`（`CvMatType.Bgra32`）を作る。**借用契約**: 呼び出しの内側だけで読み、戻った時点で終わる。返された `CvMat` は呼び出し元が `Dispose` する責任を持つ |
| `static void ToTexture(CvMat mat, Texture2D texture)` | `mat` の内容を `texture` の生データへ直接書き込み、`Apply()` する。`mat.Cols`/`Rows` が `texture` のサイズと一致しない場合は `ArgumentException`。**`mat` のチャンネル数 × 画素数が `texture` の RGBA32 前提（4 バイト/画素）と一致しない場合も `ArgumentException`** — native の検証は `stride`/`length` の整合しか見ないため、この不一致は Unity 層側で追加に検査している（詳細は `TextureConverter.cs` のコメント。実測: 4×3 の Gray8 を RGBA32 相当へ書くと native は成功を返しつつ先頭 12 バイトだけ書き換えていた） |

### 2.5 `CvUnity.Unity.NativeArrayExtensions`

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

`Mat` の部分参照（ROI）、型変換・算術演算、チャンネル分離、`imgcodecs` の読み書き、
`WebCamTexture` 連携 — いずれも `docs/abi-ownership-and-versioning.md` §3 が
「M2 で作らないもの」として明記しており、この API リファレンスにも存在しない。
契約が固まり実装されたマイルストーンで、この文書に追記する形にする。

## 参照

- `docs/abi-ownership-and-versioning.md` — 所有権契約・versioning・API allowlist の正本
- `native/include/opencv_unity_native.h` — C ABI ヘッダ本体
- `Packages/com.ayutaz.opencv-unity-native/Samples~/BasicUsage/` — この API を使う最小サンプル
- `CLAUDE.md` — リポジトリ全体の不変条件と現在地
