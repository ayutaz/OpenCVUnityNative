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
 * conformance test 用に、内部で意図的に例外を投げる。
 * kind: 0 = std::runtime_error, 1 = std::bad_alloc,
 *       2 = 非標準例外, 3 = 例外を投げない
 * 例外が ABI 境界を越えないことの検証に使う。
 */
OCVU_API ocvu_status ocvu_debug_throw(int32_t kind);

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
