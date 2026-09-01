# API 対応表

<!-- このファイルは生成物である。手で編集しないこと。 -->
<!-- 正本: bindings/spec/*.json  生成: ./tools/dev.ps1 generate -->

**公開している C ABI は 24 本**である。C# の P/Invoke 宣言は 26 本ある。

**差の 2 本は C ABI を増やさない。** 既にある C の entry point へ
別の引数の形で入る C# 側の入口で、C 側に対応する宣言が無い。
下の表ではその行の **C ABI** の列が空欄になる。

- `ocvu_mat_copy_from_buffer_ptr` → `ocvu_mat_copy_from_buffer`
- `ocvu_mat_copy_to_buffer_ptr` → `ocvu_mat_copy_to_buffer`

**「OpenCV 全対応」とは書かない。** 何が在って何が無いかは、この表が示す。
ここに無い関数は**まだ無い**のであって、隠れているのではない。
範囲を決めているのは [C ABI の所有権と versioning](./abi-ownership-and-versioning.md)、
使い方は [API リファレンス](./api-reference.md) にある。

| module | C ABI | C# の宣言 | 到達性 | 内容 |
| --- | --- | --- | --- | --- |
| `core` | `ocvu_mat_create` | `ocvu_mat_create` | 呼ぶ | rows x cols、指定 type の Mat を確保し、handle を out_handle に書く。rows / cols が 1 未満、または type が未知なら OCVU_STATUS_INVALID_ARGUMENT を返し out_handle は変更しない。out_handle が NULL なら OCVU_STATUS_NULL_POINTER。 |
| `core` | `ocvu_mat_release` | `ocvu_mat_release` | 呼ぶ | handle を解放する。解放済み、または未知の handle なら OCVU_STATUS_INVALID_HANDLE を返す（落とさない）。 |
| `core` | `ocvu_mat_clone` | `ocvu_mat_clone` | 呼ぶ | src の内容を複製した独立の handle を作る。src と複製は別の記憶域を持つ。 |
| `core` | `ocvu_mat_get_info` | `ocvu_mat_get_info` | 呼ぶ | handle の形状を out_info に書く。out_info が NULL なら OCVU_STATUS_NULL_POINTER。 |
| `core` | `ocvu_mat_copy_from_buffer` | `ocvu_mat_copy_from_buffer` | 呼ぶ | 外部 buffer から Mat へコピーする。src は呼び出しの内側でだけ読む借用で、戻った後 native は一切保持しない。長さと stride は書く前にすべて検証し、1 つでも合わなければ何も書かずに返す。src_stride は Mat の step と異なってよく、行ごとにコピーする。 |
| `core` |  | `ocvu_mat_copy_from_buffer_ptr` | 呼ぶ | ocvu_mat_copy_from_buffer にアドレスを直接渡す C# 側の入口。NativeArray や Texture2D の生データを managed 配列へ写さずに渡すためにある。領域はこの呼び出しが戻るまで生きていなければならない。 |
| `core` | `ocvu_mat_copy_to_buffer` | `ocvu_mat_copy_to_buffer` | 呼ぶ | Mat から外部 buffer へコピーする。借用と検証の規則は ocvu_mat_copy_from_buffer と同じである。 |
| `core` |  | `ocvu_mat_copy_to_buffer_ptr` | 呼ぶ | ocvu_mat_copy_to_buffer にアドレスを直接渡す C# 側の入口。借用の契約は ocvu_mat_copy_from_buffer_ptr と同じである。 |
| `features` | `ocvu_orb_detect` | `ocvu_orb_detect` | 呼ぶ | src から ORB の特徴点を検出して out_keypoints へ書き、見つかった個数を out_count に返す。呼ぶ側は必要量を事前に知り得るので 2 回呼ぶ必要は無い（上限は max_features で、capacity がそれに満たなければ何も書かずに OCVU_STATUS_BUFFER_TOO_SMALL を返し out_count に max_features を入れる）。max_features は 1 以上 OCVU_ORB_MAX_FEATURES 以下でなければならない。buffer の所有権は最初から最後まで呼ぶ側にある。 |
| `geometry` | `ocvu_find_homography` | `ocvu_find_homography` | 呼ぶ | 2 組の点の対応から射影変換（3x3）を求めて dst に入れる。dst は結果に応じて丸ごと置き換わり、64 bit 1 channel の 3x3 になる。src_points と dst_points はどちらも x と y が交互に並ぶ float の配列で、長さは point_count の 2 倍でなければならない。point_count は 4 以上（4 点未満では射影変換が決まらない）。method は OCVU_HOMOGRAPHY_METHOD_* のいずれかで、それ以外は拒否する。ransac_threshold は RANSAC のときだけ使う画素単位のしきい値である。点が退化していて解が求まらないときは OCVU_STATUS_NOT_FOUND を返し、これは誤りではない。失敗したときは dst を書き換えない。 |
| `imgcodecs` | `ocvu_imencode` | `ocvu_imencode` | 呼ぶ | Mat を画像形式に符号化し buffer へ書く。符号化後の大きさは呼ぶ側に分からないので 2 回呼ぶ（1 回目は buffer に NULL を渡して out_required_size に必要バイト数を受け取る。そのとき返る OCVU_STATUS_BUFFER_TOO_SMALL は失敗ではない）。buffer の所有権は最初から最後まで呼ぶ側にあり、足りなければ何も書かない。ext は .png のように先頭のドットを含む拡張子で、NULL と空文字列は拒否する。 |
| `imgcodecs` | `ocvu_imdecode` | `ocvu_imdecode` | 呼ぶ | 符号化された画像 byte 列を復号して dst に入れる。dst の形状と型は結果に応じて上書きされる。data はこの呼び出しの内側でのみ読む借用で、native は保持しない。length は 1 以上 INT32_MAX 以下でなければならず、画像として解釈できない byte 列は OCVU_STATUS_OPENCV_ERROR になる（メモリは壊さない）。flags は OCVU_IMREAD_* である。 |
| `imgproc` | `ocvu_cvt_color` | `ocvu_cvt_color` | 呼ぶ | 色空間を変換する。dst の形状と型は結果に応じて上書きされる。src と dst が同じ handle なら OCVU_STATUS_INVALID_ARGUMENT を返す（OpenCV の in-place 対応は関数ごとに異なり、曖昧さを ABI に持ち込まない）。OpenCV 由来の失敗は OCVU_STATUS_OPENCV_ERROR になる。 |
| `imgproc` | `ocvu_resize` | `ocvu_resize` | 呼ぶ | width x height に拡大縮小する。width / height が 1 未満なら OCVU_STATUS_INVALID_ARGUMENT。src と dst に同じ handle を渡した場合も同様に拒否する。 |
| `imgproc` | `ocvu_gaussian_blur` | `ocvu_gaussian_blur` | 呼ぶ | Gaussian ぼかしを掛ける。ksize は正の奇数でなければならず、そうでなければ OCVU_STATUS_INVALID_ARGUMENT。sigma に 0 を渡すと OpenCV が ksize から算出する。 |
| `infra` | `ocvu_get_abi_version` | `ocvu_get_abi_version` | 呼ぶ | 現在の C ABI バージョンを返す。失敗しない。 |
| `infra` | `ocvu_get_last_error_status` | `ocvu_get_last_error_status` | 呼ぶ | 直近のエラー status を返す。呼び出しスレッドごとに独立している。 |
| `infra` | `ocvu_get_last_error_message` | `ocvu_get_last_error_message` | 呼ぶ | 直近のエラーメッセージを UTF-8・NUL 終端で buffer に書く。buffer に NULL を渡して必要サイズだけを聞くのが正規の 1 回目で、そのとき返る OCVU_STATUS_BUFFER_TOO_SMALL は失敗ではない。out_required_size が NULL なら OCVU_STATUS_NULL_POINTER。この関数自身は last-error を変更しない。 |
| `infra` | `ocvu_get_status_count` | `ocvu_get_status_count` | 呼ぶ | ネイティブ側が定義している status code の個数を返す。失敗しない。C# の CvStatus との同期を L3 で検証するために公開している。 |
| `infra` | `ocvu_get_status_value` | `ocvu_get_status_value` | 呼ぶ | index 番目の status code の数値を out_value に書く。並び順は OCVU_STATUS_LIST の記述順。範囲外の index は OCVU_STATUS_INVALID_ARGUMENT、out_value が NULL なら OCVU_STATUS_NULL_POINTER。 |
| `infra` | `ocvu_get_opencv_version` | `ocvu_get_opencv_version` | 呼ぶ | リンクされている OpenCV のバージョン文字列（例 5.0.0）を UTF-8 で書く。バッファ規約は ocvu_get_last_error_message と同一である。 |
| `infra` | `ocvu_get_build_information` | `ocvu_get_build_information` | 呼ぶ | cv::getBuildInformation() の内容を UTF-8 で書く。どの依存が有効なリンクになっているかを実行時に確認するために使う。バッファ規約は ocvu_get_opencv_version と同一である。 |
| `infra` | `ocvu_debug_throw` | `ocvu_debug_throw` | 呼ぶ | conformance test 用に、内部で意図的に例外を投げる。kind は 0 が std::runtime_error、1 が std::bad_alloc、2 が非標準例外、3 が投げない。例外が ABI 境界を越えないことの検証に使う。 |
| `infra` | `ocvu_debug_crash` | `ocvu_debug_crash` | 呼ばない | conformance test 用に、意図的にプロセスを壊す。kind は 0 が不正アクセスで即死、1 が戻ってこない（無限ループ）。managed 側からネイティブが死んだときに L3 が有限時間で赤くなるかを確かめるためだけに存在し、通常の経路からは決して呼ばれない。 |
| `objdetect` | `ocvu_qr_encode` | `ocvu_qr_encode` | 呼ぶ | text を QR コードの画像に符号化して dst に入れる。dst の形状と型は結果に応じて上書きされ、8 bit 1 channel の正方形になる。text は NUL 終端の UTF-8 byte 列で、NULL と空文字列は拒否する。符号化できない長さの text は OCVU_STATUS_OPENCV_ERROR になる。失敗したときは dst を書き換えない。 |
| `objdetect` | `ocvu_qr_decode` | `ocvu_qr_decode` | 呼ぶ | src に写っている QR コードを 1 つ検出して復号し、NUL 終端の UTF-8 byte 列として buffer へ書く。検出の前に白い余白（quiet zone）を必ず足し、短いほうの辺が 200 px 未満の画像はさらに最近傍補間で拡大してから検出する。復号後の長さは呼ぶ側に分からないので 2 回呼ぶ（1 回目は buffer に NULL を渡して out_required_size に NUL を含む必要バイト数を受け取る。そのとき返る OCVU_STATUS_BUFFER_TOO_SMALL は失敗ではない）。buffer の所有権は最初から最後まで呼ぶ側にあり、足りなければ何も書かない。QR が写っていなければ OCVU_STATUS_NOT_FOUND を返し、これは誤りではない。 |

## 到達性

**到達性** の列は、spec から生成される到達性テスト
（`tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs`）が
その宣言を実際に呼ぶかを示す。IL2CPP の stripping は呼ばれない P/Invoke
宣言を消せるので、**呼ばれない宣言は消えても誰も気づかない。**

**到達性テストが呼ばない関数は 1 本ある。** 理由は spec の
`reachableNote` にある（印だけ付けて理由が無い spec は生成器が拒む）。

- `ocvu_debug_crash` —— 呼ぶと戻ってこない（kind 0 は即死、kind 1 は無限ループ）。到達性テストは全 entry point を 1 回ずつ呼ぶので、これを含めるとテストプロセスごと死ぬ。この 1 本だけは生成された呼び出しから外す。stripping で消えても壊れるものは無い —— 通常の経路から呼ぶ側が無く、L3 の test-managed-probe が名指しで P/Invoke するのは Player ではなく素の .NET だからである。
