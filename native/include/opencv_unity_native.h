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

#define OCVU_STATUS_OK                0
#define OCVU_STATUS_INVALID_ARGUMENT  1
#define OCVU_STATUS_NULL_POINTER      2
#define OCVU_STATUS_OUT_OF_MEMORY     3
#define OCVU_STATUS_OPENCV_ERROR      4
#define OCVU_STATUS_UNKNOWN_ERROR     5

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
 * この関数自身は last-error を変更しない。
 */
OCVU_API ocvu_status ocvu_get_last_error_message(char* buffer,
                                                 int32_t buffer_size,
                                                 int32_t* out_required_size);

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
