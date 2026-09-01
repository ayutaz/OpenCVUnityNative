# API リファレンス

**この文書は手書きである。** 機械的な一覧は [API 対応表](./api-map.md)（生成物）にある。
こちらが持つのは**契約と落とし穴**（所有権、stride、2 回呼びの作法、
`WebCamTextureConverter` の上下反転など）で、**関数の一覧ではない。**
**両者を同期させる仕組みは無い** —— 境界に関数が増えると対応表は自動で伸びるが、
この文書は伸びない。関数を足したら**ここを手で直すところまでが作業である**（M5）。

**対象範囲: C ABI の 14 関数（M2 の 9 本 + M3.5 の 2 本 + M5 の 3 本）と、その上に立つ
C# の公開 API だけ。** まだ無い機能（`Mat` の部分参照、型変換・算術演算、
**`imgcodecs` のファイルパス経路**、記述子を伴う特徴点マッチング、`aruco`、
`geometry` / `calib` など）はここに書かない。**`WebCamTexture` 連携は M4 で足したので
§2.6 にある。QR コードの符号化・復号と ORB 特徴点検出は M5 で足したので §1「objdetect /
features」と §2.8・§2.9 にある。**詳しい経緯は
`docs/abi-ownership-and-versioning.md` §3「API の allowlist」（M3.5 の追加は §3.5、
M5 の追加は §3.6）を、所有権契約そのものは同 §1 を参照。

対応 Unity は **6000.3 以降**（`package.json` の下限が `6000.3`。**実際に検証しているのは
6000.3.16f1 の 1 版だけ**）。**対応 platform は最新の公開版（v0.2.0）の
Windows x64 / macOS arm64 / Linux x64 の 3 つ**で、この文書はその 3 つを前提に書いてある。
**どこまでが「対応」かの正本は [README](../README.md) の Status である** ——
mobile と Web の現況（何がビルドされ、何が公開版に入っておらず、何が実機で
動いていないか）はあちらに 1 箇所だけ書いてあるので、**ここには写さない。**

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

## 1. C ABI（`native/include/ocvu/*.h`）

**M5 で宣言の在り処が変わった。** 関数宣言は module ごとの
`native/include/ocvu/{infra,core,imgproc,imgcodecs,objdetect,features}.h` にあり、
**いずれも `bindings/spec/*.json` からの生成物である**（手で編集すると
`./tools/dev.ps1 verify-generated` が落とす）。利用者が include するのは
これまでどおり `native/include/opencv_unity_native.h` で、そちらは
`OCVU_STATUS_LIST`・handle と struct の型・`OCVU_*` 定数を持ち、6 つを include する。
**「関数宣言は `opencv_unity_native.h` に在る」と書いていた記述は、この時点で誤りになった。**

すべて `extern "C"`、呼び出し規約は Cdecl。戻り値は `ocvu_status`（`int32_t`）。
`OCVU_STATUS_OK` (0) と `OCVU_STATUS_BUFFER_TOO_SMALL` (6) 以外はすべて失敗として扱う
（詳細後述）。C# から直接この層を呼ぶことは想定していない —
`CvUnity.Interop.NativeMethods`（`internal`）が P/Invoke 宣言を持ち、`CvUnity.CvMat` /
`CvUnity.CvOps` / `CvUnity.CvCodecs` / `CvUnity.CvNative` / `CvUnity.CvQrCode` /
`CvUnity.CvFeatures` がそれを包んで公開する。

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

### objdetect / features（M5 で追加）

| 関数 | 内容 |
| --- | --- |
| `ocvu_qr_encode(const char* text, ocvu_mat_handle dst)` | `text`（UTF-8 の NUL 終端 byte 列）を QR コードの画像に符号化して `dst` へ入れる。`dst` は結果に応じて丸ごと置き換わり、8 bit 1 channel の正方形になる |
| `ocvu_qr_decode(ocvu_mat_handle src, char* buffer, int32_t buffer_size, int32_t* out_required_size)` | `src` に写っている QR コードを 1 つ検出して復号し、`buffer` へ UTF-8・NUL 終端で書く。**2 回呼ぶ**（下記） |
| `ocvu_orb_detect(ocvu_mat_handle src, int32_t max_features, ocvu_keypoint* out_keypoints, int32_t capacity, int32_t* out_count)` | `src` から ORB の特徴点を検出する。**1 回呼び**（下記） |

**`ocvu_qr_decode` は `ocvu_imdecode` と同じ 2 回呼びの作法だが、「見つからない」を
表す status が別にある。** QR コードが写っていない画像は `OCVU_STATUS_NOT_FOUND` を
返す —— `OCVU_STATUS_OK` + 長さ 0 だと「空文字列を符号化した QR コード」と
区別が付かないためである。それ以外の失敗・`BufferTooSmall` の扱いは
`ocvu_imencode` / `ocvu_imdecode` と同じ。検出の前に白い余白（quiet zone）を必ず
足し、短いほうの辺が 200 px 未満の画像はさらに最近傍補間で拡大してから検出する
（`src` 自体は変更しない、内部で作る加工済みのコピーに対して行う）。

**`ocvu_orb_detect` は 1 回呼びである。** 出力される特徴点の個数は事前に分からないが、
**上限は呼ぶ側が渡す `max_features` で決まる**ので、その上限ぶんの buffer を
最初から用意させれば 2 回呼ぶ理由が無い。`capacity` が `max_features` に満たなければ
何も書かずに `OCVU_STATUS_BUFFER_TOO_SMALL` を返し、`out_count` に `max_features` を
入れる。`max_features` は 1 以上 `OCVU_ORB_MAX_FEATURES`（10000）以下でなければ
`OCVU_STATUS_INVALID_ARGUMENT`。buffer の所有権は最初から最後まで呼ぶ側にある。

`ocvu_keypoint` の各フィールド（`cv::KeyPoint` をそのまま写した固定サイズ型）:

| フィールド | 型 | 内容 |
| --- | --- | --- |
| `x` / `y` | `float` | 画像座標系での位置 |
| `size` | `float` | 特徴点の直径に相当する近傍のサイズ |
| `angle` | `float` | 支配的な向き（度）。算出できない場合 -1 |
| `response` | `float` | 強さ（フィルタ・ソートに使う） |
| `octave` | `int32_t` | 検出されたピラミッドの階層 |
| `class_id` | `int32_t` | クラスタや物体の ID。ORB 単体では常に -1 |

status:

| 条件 | status |
| --- | --- |
| `text` / `out_required_size` / `out_count` が NULL | `OCVU_STATUS_NULL_POINTER` |
| `capacity` が 1 以上なのに `out_keypoints` が NULL | `OCVU_STATUS_NULL_POINTER` |
| `src` / `dst` の handle が無効（0、解放済み、未知） | `OCVU_STATUS_INVALID_HANDLE` |
| `src` が空（現在の ABI では `ocvu_mat_create` が空を作れないので到達しない防御） | `OCVU_STATUS_INVALID_ARGUMENT` |
| `text` が空文字列 | `OCVU_STATUS_INVALID_ARGUMENT` |
| handle が無効 | `OCVU_STATUS_INVALID_HANDLE` |
| `ocvu_qr_decode` の `buffer_size` が必要量に満たない | `OCVU_STATUS_BUFFER_TOO_SMALL`（**buffer は書かない**） |
| QR コードが写っていない | `OCVU_STATUS_NOT_FOUND`（**失敗ではない**） |
| `max_features` が範囲外（1 未満、または `OCVU_ORB_MAX_FEATURES` 超） | `OCVU_STATUS_INVALID_ARGUMENT` |
| `ocvu_orb_detect` の `capacity` が `max_features` に満たない | `OCVU_STATUS_BUFFER_TOO_SMALL`（`out_count` に `max_features`。**buffer は書かない**） |
| OpenCV 由来の失敗（符号化できない長さの `text` など） | `OCVU_STATUS_OPENCV_ERROR` |

### この allowlist に含まれないもの

`ocvu_get_abi_version` / last-error 取得 / status 表の照会 / `ocvu_get_opencv_version` /
`ocvu_get_build_information` / `ocvu_debug_throw` / `ocvu_debug_crash` は存在するが、
M0/M1 由来の診断・conformance test 用 API であり、この allowlist（M2 の 9 本 + M3.5 の
2 本 + M5 の 3 本 = 14 本）の対象外。C# 側では `CvNative` の一部メンバがこれらを
包んでいるので、公開 C# API としての契約は §2.4 に記載する。

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
`InvalidHandle = 7`、`NotFound = 8`（M5 で追加）。native 側の `OCVU_STATUS_LIST` と
数値が一致することを L3 の `StatusCodeSyncTests` が検査する。`BufferTooSmall` は
失敗ではなく、出力バッファの必要サイズを問い合わせる正規の使い方の結果である。
**M3.5 以降、これは診断 API だけの話ではない** —— `ocvu_imencode` が同じ作法で
画像データの必要量を返す。**`NotFound` も失敗ではない** —— `ocvu_qr_decode` が
「QR コードが写っていない」ことを表すために使う（§1「objdetect / features」）。

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

### 2.8 `CvUnity.CvQrCode`

`static class`（`CvUnity.Core` アセンブリ、M5 で追加）。QR コードの符号化と復号
（OpenCV の `objdetect`）。**`CvOps` に入れていない** —— あちらは `imgproc` の
範囲である。クラスを分けてあるので、この plugin がどの OpenCV モジュールを
リンクしているかが C# 側から読み取れる。

| メンバ | 内容 |
| --- | --- |
| `static void Encode(string text, CvMat dst)` | `text` を QR コードの画像に符号化して `dst` に入れる。`dst` は呼び出し前の形状・型・内容を保持せず、結果に応じて丸ごと置き換わる |
| `static string Decode(CvMat src)` | `src` に写っている QR コードを 1 つ復号する。**写っていなければ `null` を返す**（例外にしない） |

`Encode` は `text` を自分で UTF-8 の NUL 終端 byte 列にしてから渡す —— `string` の
まま marshaller に任せると、境界の文字コード変換が既定の `CharSet` に依存する
（Mono と IL2CPP で違い得る）。`text` が `null` なら `ArgumentNullException`、
空文字列なら `ArgumentException`。

`Decode` は `ocvu_qr_decode` の 2 回呼びを隠す。1 回目のサイズ問い合わせが
`OCVU_STATUS_NOT_FOUND` を返したときだけ `null` を返し、それ以外の失敗
（無効な handle など）は `CvNativeException` を投げる —— `null` を「検出できない
理由すべて」の意味に広げない。検出の前に白い余白（quiet zone）を必ず足し、
短いほうの辺が 200 px 未満の画像はさらに最近傍補間で拡大してから検出する
（この前処理は内部の加工済みコピーに対して行われ、`src` 自体は変更しない）。

### 2.9 `CvUnity.CvFeatures` / `CvUnity.CvKeyPoint`

`CvFeatures` は `static class`（`CvUnity.Core` アセンブリ、M5 で追加）。
特徴点の検出（OpenCV の `features`）。

| メンバ | 内容 |
| --- | --- |
| `static CvKeyPoint[] DetectOrb(CvMat src, int maxFeatures)` | `src` から ORB の特徴点を最大 `maxFeatures` 個検出する。`maxFeatures` が 1 未満、または上限（10000）を超えると `ArgumentOutOfRangeException` |

`maxFeatures` の上限は C 側の `OCVU_ORB_MAX_FEATURES` の**写しとして C# 側にも
複製されている** —— C# から C の `#define` を読む経路が無いためで、両側が
native に同じ値を問うテスト（`FeaturesTests.TheManagedUpperBoundMatchesWhatNativeAccepts`）
が二重定義の同期を守っている。

`CvKeyPoint`（`readonly struct`）は `ocvu_keypoint` に対応する読み取り専用の値:
`float X` / `Y` / `Size` / `Angle` / `Response`、`int Octave` / `ClassId`。
`DetectOrb` が返す配列は検出できた個数ぶんだけで、`maxFeatures` 分のダミー要素は
含まれない。

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

### 2.10 `CvUnity.CvGeometry` / `CvUnity.CvPoint2` / `CvUnity.CvHomographyMethod`

点の対応から変換を求める（OpenCV の `geometry`）。

| メンバ | 内容 |
| --- | --- |
| `CvGeometry.FindHomography(CvPoint2[] srcPoints, CvPoint2[] dstPoints, CvMat dst, CvHomographyMethod method = Default, double ransacThreshold = 3.0)` | 2 組の点の対応から射影変換（3x3）を求めて `dst` に入れる。求まったら true、点が退化していて求まらなければ **false**（誤りではない） |
| `CvPoint2(float x, float y)` | 画像上の点。`X` / `Y` を持つ |
| `CvHomographyMethod` | `Default`（全点の最小二乗）/ `LeastMedianOfSquares` / `Ransac`（外れ値を捨てる） |

**`dst` は結果に応じて丸ごと置き換わり、64 bit 1 channel の 3x3 になる** ——
呼び出し前に持っていた形状・型・内容は保持されない。

**`UnityEngine.Vector2` ではなく `CvPoint2` を使う。** `Runtime/Core` は
`UnityEngine` を参照してはならない（参照するとビルドで強制している
netstandard2.1 shim が落ち、Unity を起動しない L3 レーンが失われる）。
Unity 側で `Vector2` から詰め替えるのは呼ぶ側の仕事である。

**2 つの点列は同じ長さでなければならない。** C ABI に渡すのは点数 1 つだけなので、
食い違っていても native からは見えず、短いほうの配列の終端を越えて読むことになる。
**C# の入口が唯一それを見られる場所である。**

求めた変換を画像に当てるには透視変換が要るが、**それはまだ C ABI に出していない**
（`imgproc` にはあるがラップしていない）。

## 3. 対象外（この文書に書かないもの）

`Mat` の部分参照（ROI）、型変換・算術演算、チャンネル分離、**`imgcodecs` のファイルパス
経路**、記述子（descriptor）を伴う特徴点マッチング、`aruco`、`calib`、**透視変換の適用**（`warpPerspective`）—
いずれも `docs/abi-ownership-and-versioning.md` §3 が「まだ作らないもの」として明記
しており、この API リファレンスにも存在しない。契約が固まり実装されたマイルストーンで、
この文書に追記する形にする。
**メモリ上の byte 列の encode / decode は M3.5 で足したので、上の §1「imgcodecs」と
§2.3 にある。`WebCamTexture` 連携は M4 で足したので §2.6 にある。QR コードの符号化・
復号と ORB 特徴点検出、および射影変換の推定は M5 で足したので §1「objdetect / features / geometry」と §2.8・§2.9・§2.10 にある**
—— いずれもここには残っていない。

## 参照

- `docs/abi-ownership-and-versioning.md` — 所有権契約・versioning・API allowlist の正本
- [API 対応表](./api-map.md) — いま境界に在るものの機械的な一覧（`bindings/spec/*.json` からの生成物）
- `native/include/opencv_unity_native.h` — C ABI ヘッダの入口（型・定数・status。**関数宣言は `native/include/ocvu/*.h` にあり、生成物である**）
- `Packages/com.ayutaz.opencv-unity-native/Samples~/BasicUsage/` — この API を使う最小サンプル
- `CLAUDE.md` — リポジトリ全体の不変条件と現在地
