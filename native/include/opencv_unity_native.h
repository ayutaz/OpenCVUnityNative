#ifndef OPENCV_UNITY_NATIVE_H
#define OPENCV_UNITY_NATIVE_H

#include <stdint.h>

/*
 * OCVU_STATIC: 実装を静的リンクする側（L1 テスト）が定義する。
 * OCVU_BUILDING_DLL: 共有ライブラリ自身のビルド時のみ定義する。
 */
#if defined(OCVU_STATIC)
#  define OCVU_API
#elif defined(_WIN32)
#  if defined(OCVU_BUILDING_DLL)
#    define OCVU_API __declspec(dllexport)
#  else
#    define OCVU_API __declspec(dllimport)
#  endif
#else
#  define OCVU_API __attribute__((visibility("default")))
#endif

/* C# 側は CallingConvention.Cdecl を使う */
#define OCVU_ABI_VERSION 1

typedef int32_t ocvu_status;

/*
 * status code の唯一の定義元。
 *
 * 追加するときはこのリストに 1 行足すだけでよい。下の定数と、
 * ocvu_get_status_count / ocvu_get_status_value が公開する表が同時に増える。
 * C# 側（CvUnity.CvStatus）へは自動では伝播しないので必ず手で追随すること。
 * 追随し忘れは L3 の StatusCodeSyncTests が赤にする。
 *
 * すべての非 OK が「失敗」ではない。OCVU_STATUS_BUFFER_TOO_SMALL は
 * サイズ問い合わせの正常な結果であって、呼び出し側の誤りではない。
 * 出力バッファを取る関数は、buffer に NULL を渡して必要サイズだけを聞く
 * 使い方を正規の経路として認めており、そのとき返るのがこの status である。
 * status を一律に例外へ変換する wrapper は、これを失敗として扱ってはならない
 * （C# 側の対応は CvNative.IsFailure）。M5 の generator もこの区別を読む前提で書くこと。
 */
#define OCVU_STATUS_LIST(X)               \
    X(OCVU_STATUS_OK,                  0) \
    X(OCVU_STATUS_INVALID_ARGUMENT,    1) \
    X(OCVU_STATUS_NULL_POINTER,        2) \
    X(OCVU_STATUS_OUT_OF_MEMORY,       3) \
    X(OCVU_STATUS_OPENCV_ERROR,        4) \
    X(OCVU_STATUS_UNKNOWN_ERROR,       5) \
    X(OCVU_STATUS_BUFFER_TOO_SMALL,    6) \
    X(OCVU_STATUS_INVALID_HANDLE,      7)

#define OCVU_STATUS_ENUMERATOR_(name, value) name = value,
enum { OCVU_STATUS_LIST(OCVU_STATUS_ENUMERATOR_) };
#undef OCVU_STATUS_ENUMERATOR_

#ifdef __cplusplus
extern "C" {
#endif

/* 現在の C ABI バージョンを返す。失敗しない。 */
OCVU_API int32_t ocvu_get_abi_version(void);

/* 直近のエラー status を返す。呼び出しスレッドごとに独立している。 */
OCVU_API ocvu_status ocvu_get_last_error_status(void);

/*
 * 直近のエラーメッセージを UTF-8・NUL 終端で buffer に書く。
 *
 * out_required_size は必須で、NUL を含む必要バイト数が常に書かれる。
 * buffer が NULL、または buffer_size が必要量未満の場合は
 * OCVU_STATUS_BUFFER_TOO_SMALL を返す。これは失敗ではなく、
 * 必要サイズを問い合わせる正規の使い方の結果である（buffer に NULL を
 * 渡してサイズだけ聞き、その大きさで確保して呼び直す）。
 * out_required_size が NULL の場合は OCVU_STATUS_NULL_POINTER を返す。
 * こちらは呼び出し側の誤りである。
 *
 * 保持できるメッセージ長には上限があり、超過分は UTF-8 の文字境界で
 * 切り詰められる（native/src/ocvu_error.h を参照）。切り詰めが起きても
 * out_required_size は「実際に取得できるバイト数 + NUL」を返すので、
 * 上の契約はそのまま成立する。
 *
 * この関数自身は last-error を変更しない。
 */
OCVU_API ocvu_status ocvu_get_last_error_message(char* buffer,
                                                 int32_t buffer_size,
                                                 int32_t* out_required_size);

/*
 * ネイティブ側が定義している status code の個数を返す。失敗しない。
 * C# の CvStatus との同期を L3 で検証するために公開している。
 */
OCVU_API int32_t ocvu_get_status_count(void);

/*
 * index 番目の status code の数値を out_value に書く。
 * 並び順は OCVU_STATUS_LIST の記述順。
 * index が範囲外なら OCVU_STATUS_INVALID_ARGUMENT、
 * out_value が NULL なら OCVU_STATUS_NULL_POINTER を返す。
 */
OCVU_API ocvu_status ocvu_get_status_value(int32_t index, int32_t* out_value);

/*
 * Mat の不透明 handle。
 *
 * 生ポインタではない。上位 32 bit が世代、下位 32 bit が table の索引である。
 * 解放のたびに世代が進むので、解放済みの handle をもう一度渡しても
 * OCVU_STATUS_INVALID_HANDLE として弾かれる。生ポインタなら未定義動作になり、
 * sanitizer の無い環境（配布された Unity Player）では黙って壊れる。
 *
 * 0 は常に無効である。ゼロ初期化した変数を誤って渡した場合を確実に捕まえる。
 *
 * この handle が指すメモリは常に native が確保し native が解放する。
 * Unity が所有するメモリを指す handle は存在しない
 * （docs/abi-ownership-and-versioning.md §1）。
 *
 * スレッドについて: **別々の handle は、別々のスレッドから同時に使ってよい。**
 * handle の table は内部で保護されており、ある handle が指す Mat のアドレスは
 * 他の handle の作成・解放で動かない。
 *
 * ただし **同じ handle** を複数のスレッドから同時に渡してはならず、他の
 * スレッドが使っている最中に ocvu_mat_release を呼んでもならない。前者は
 * cv::Mat 自体のデータ競合、後者は解放済みメモリへのアクセスになる。
 * どちらも世代検査では捕まらない（規約でしか守れない。理由と経緯は
 * docs/abi-ownership-and-versioning.md §1.5）。
 */
typedef uint64_t ocvu_mat_handle;
#define OCVU_MAT_HANDLE_NONE ((ocvu_mat_handle)0)

/* OpenCV の CV_8UC1 等に対応する。ABI に cv:: の定数を露出させないための写し。 */
#define OCVU_MAT_TYPE_8UC1  0
#define OCVU_MAT_TYPE_8UC3 16
#define OCVU_MAT_TYPE_8UC4 24

/* ocvu_mat_get_info の出力。固定サイズ型のみで構成する。 */
typedef struct ocvu_mat_info {
    int32_t rows;
    int32_t cols;
    int32_t type;        /* OCVU_MAT_TYPE_* */
    int32_t channels;
    int64_t step;        /* 1 行のバイト数 */
    int64_t total_bytes; /* rows * step */
} ocvu_mat_info;

/*
 * rows x cols、指定 type の Mat を確保し、handle を out_handle に書く。
 * rows / cols が 1 未満、または type が未知なら OCVU_STATUS_INVALID_ARGUMENT を返し、
 * out_handle は変更しない。out_handle が NULL なら OCVU_STATUS_NULL_POINTER。
 */
OCVU_API ocvu_status ocvu_mat_create(int32_t rows, int32_t cols, int32_t type,
                                     ocvu_mat_handle* out_handle);

/*
 * handle を解放する。解放済み、または未知の handle なら
 * OCVU_STATUS_INVALID_HANDLE を返す（落とさない）。
 */
OCVU_API ocvu_status ocvu_mat_release(ocvu_mat_handle handle);

/* src の内容を複製した独立の handle を作る。src と dst は別の記憶域を持つ。 */
OCVU_API ocvu_status ocvu_mat_clone(ocvu_mat_handle src, ocvu_mat_handle* out_handle);

/* handle の形状を out_info に書く。out_info が NULL なら OCVU_STATUS_NULL_POINTER。 */
OCVU_API ocvu_status ocvu_mat_get_info(ocvu_mat_handle handle, ocvu_mat_info* out_info);

/*
 * 外部 buffer から Mat へコピーする。
 *
 * src は呼び出しの内側でだけ読む借用である。この関数が戻った後、native 側は
 * src を一切保持しない（docs/abi-ownership-and-versioning.md §1）。
 *
 * 書く前にすべて検証する。1 つでも合わなければ何も書かずに返す:
 *   src が NULL              -> OCVU_STATUS_NULL_POINTER
 *   handle が無効            -> OCVU_STATUS_INVALID_HANDLE
 *   src_length / src_stride が負          -> OCVU_STATUS_INVALID_ARGUMENT
 *   src_stride が Mat の 1 行より小さい    -> OCVU_STATUS_INVALID_ARGUMENT
 *   src_length が stride * rows 分の長さに満たない -> OCVU_STATUS_INVALID_ARGUMENT
 *     （実装は stride > src_length / rows で判定する。src_stride * rows を計算すると
 *      桁あふれで負に反転し、検査が素通りする — M2 で実際に起きた）
 *
 * src_stride は Mat の step と異なってよい（Unity のテクスチャは行が整列されて
 * いることがある）。行ごとにコピーする。
 */
OCVU_API ocvu_status ocvu_mat_copy_from_buffer(ocvu_mat_handle dst,
                                               const uint8_t* src,
                                               int64_t src_length,
                                               int64_t src_stride);

/* Mat から外部 buffer へコピーする。検証規則は copy_from_buffer と同じ。 */
OCVU_API ocvu_status ocvu_mat_copy_to_buffer(ocvu_mat_handle src,
                                             uint8_t* dst,
                                             int64_t dst_length,
                                             int64_t dst_stride);

/* cvtColor の変換コード。cv::COLOR_* の値をそのまま使う（写し間違いを避けるため
 * 実装側で static_assert する）。M2 で必要な 3 つだけを公開する。 */
#define OCVU_CVT_BGRA2BGR   1
#define OCVU_CVT_RGBA2BGRA  5
#define OCVU_CVT_BGR2GRAY   6

/* resize の補間方法。 */
#define OCVU_INTER_NEAREST  0
#define OCVU_INTER_LINEAR   1

/*
 * 色空間を変換する。dst の形状と型は結果に応じて上書きされる。
 * src と dst が同じ handle の場合は OCVU_STATUS_INVALID_ARGUMENT を返す
 * (OpenCV の in-place 対応は関数ごとに異なり、曖昧さを ABI に持ち込まない)。
 * OpenCV 由来の失敗は OCVU_STATUS_OPENCV_ERROR になる。
 */
OCVU_API ocvu_status ocvu_cvt_color(ocvu_mat_handle src, ocvu_mat_handle dst,
                                    int32_t code);

/*
 * width x height に拡大縮小する。width / height が 1 未満なら
 * OCVU_STATUS_INVALID_ARGUMENT。src と dst の同一 handle も同様に拒否する。
 */
OCVU_API ocvu_status ocvu_resize(ocvu_mat_handle src, ocvu_mat_handle dst,
                                 int32_t width, int32_t height,
                                 int32_t interpolation);

/*
 * Gaussian ぼかしを掛ける。ksize は正の奇数でなければならず、
 * そうでなければ OCVU_STATUS_INVALID_ARGUMENT。
 * sigma に 0 を渡すと OpenCV が ksize から算出する。
 */
OCVU_API ocvu_status ocvu_gaussian_blur(ocvu_mat_handle src, ocvu_mat_handle dst,
                                        int32_t ksize_width, int32_t ksize_height,
                                        double sigma_x, double sigma_y);

/* imdecode の読み込み方。cv::IMREAD_* の値をそのまま使う（実装側で static_assert）。 */
#define OCVU_IMREAD_UNCHANGED (-1)
#define OCVU_IMREAD_GRAYSCALE   0
#define OCVU_IMREAD_COLOR       1

/*
 * Mat を画像形式に符号化し、buffer へ書く。
 *
 * **2 回呼ぶ。** 符号化後の大きさは呼ぶ側に分からないため、1 回目は
 * buffer=NULL / buffer_size=0 で呼んで out_required_size に必要バイト数を
 * 受け取り（戻り値は OCVU_STATUS_BUFFER_TOO_SMALL。これは失敗ではない）、
 * 2 回目にその大きさの buffer を渡す。last-error や OpenCV version の
 * 取得と同じ作法である。
 *
 * **native は buffer を保持しない。** 出力の所有権は最初から最後まで呼ぶ側に
 * ある。native が確保した blob を handle で返す形は採らない —— それは
 * docs/abi-ownership-and-versioning.md §1 に無い所有権の種類を増やすため。
 *
 * out_required_size は必須で、成功時は実際に書いたバイト数、
 * OCVU_STATUS_BUFFER_TOO_SMALL のときは必要バイト数が入る。
 * **それ以外のどの失敗でも 0 が入る** —— 呼ぶ側が変数を使い回していても、
 * 前回の値が残って「失敗したのに前回のサイズを信じる」経路ができないようにする。
 * buffer_size が足りない場合、buffer には**何も書かない**。
 *
 * ext は ".png" のように先頭のドットを含む拡張子で、NULL・空文字列は拒否する。
 * OpenCV が扱えない拡張子は OCVU_STATUS_OPENCV_ERROR になる。
 */
OCVU_API ocvu_status ocvu_imencode(ocvu_mat_handle src, const char* ext,
                                   uint8_t* buffer, int32_t buffer_size,
                                   int32_t* out_required_size);

/*
 * 符号化された画像 byte 列を復号して dst に入れる。dst の形状と型は
 * 結果に応じて上書きされる。
 *
 * data は**この呼び出しの内側でのみ読む**（借用）。native は保持しない。
 * length は 1 以上 INT32_MAX 以下でなければならず、そうでなければ
 * OCVU_STATUS_INVALID_ARGUMENT。画像として解釈できない byte 列は
 * OCVU_STATUS_OPENCV_ERROR になる（メモリは壊さない）。
 *
 * flags は OCVU_IMREAD_*。
 */
OCVU_API ocvu_status ocvu_imdecode(const uint8_t* data, int64_t length,
                                   int32_t flags, ocvu_mat_handle dst);

/*
 * conformance test 用に、内部で意図的に例外を投げる。
 * kind: 0 = std::runtime_error, 1 = std::bad_alloc,
 *       2 = 非標準例外, 3 = 例外を投げない
 * 例外が ABI 境界を越えないことの検証に使う。
 */
OCVU_API ocvu_status ocvu_debug_throw(int32_t kind);

/*
 * conformance test 用に、意図的にプロセスを壊す。
 * kind: 0 = 不正アクセスで即死、1 = 戻ってこない（無限ループ）
 *
 * ocvu_debug_throw と違い、これは status を返さない — 戻ってこないからである。
 * L3 のハーネスが、managed 側からネイティブが死んだときに有限時間で赤くなるかを
 * 確かめるためだけに存在する。通常の経路からは決して呼ばれない。
 */
OCVU_API void ocvu_debug_crash(int32_t kind);

/*
 * リンクされている OpenCV のバージョン文字列（例 "5.0.0"）を UTF-8 で書く。
 * バッファ規約は ocvu_get_last_error_message と同一。buffer が NULL または
 * 小さすぎる場合は OCVU_STATUS_BUFFER_TOO_SMALL を返し、これは失敗ではない。
 */
OCVU_API ocvu_status ocvu_get_opencv_version(char* buffer,
                                             int32_t buffer_size,
                                             int32_t* out_required_size);

/*
 * cv::getBuildInformation() の内容を UTF-8 で書く。
 * どの依存が有効なリンクになっているかを実行時に確認するために使う。
 * バッファ規約は ocvu_get_opencv_version と同一。
 */
OCVU_API ocvu_status ocvu_get_build_information(char* buffer,
                                                int32_t buffer_size,
                                                int32_t* out_required_size);

#ifdef __cplusplus
}
#endif

#endif /* OPENCV_UNITY_NATIVE_H */
