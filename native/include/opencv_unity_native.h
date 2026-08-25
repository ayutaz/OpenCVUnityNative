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
 */
#define OCVU_STATUS_LIST(X)            \
    X(OCVU_STATUS_OK,               0) \
    X(OCVU_STATUS_INVALID_ARGUMENT, 1) \
    X(OCVU_STATUS_NULL_POINTER,     2) \
    X(OCVU_STATUS_OUT_OF_MEMORY,    3) \
    X(OCVU_STATUS_OPENCV_ERROR,     4) \
    X(OCVU_STATUS_UNKNOWN_ERROR,    5)

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
 * OCVU_STATUS_INVALID_ARGUMENT を返す（サイズ問い合わせとして使える）。
 * out_required_size が NULL の場合は OCVU_STATUS_NULL_POINTER を返す。
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
 * conformance test 用に、内部で意図的に例外を投げる。
 * kind: 0 = std::runtime_error, 1 = std::bad_alloc,
 *       2 = 非標準例外, 3 = 例外を投げない
 * 例外が ABI 境界を越えないことの検証に使う。
 */
OCVU_API ocvu_status ocvu_debug_throw(int32_t kind);

#ifdef __cplusplus
}
#endif

#endif /* OPENCV_UNITY_NATIVE_H */
