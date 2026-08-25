#ifndef OCVU_ERROR_H
#define OCVU_ERROR_H

#include <cstddef>
#include <exception>
#include <new>
#include <stdexcept>

#include "opencv_unity_native.h"

namespace ocvu {

/*
 * last-error メッセージを保持する固定長バッファのサイズ（NUL 終端を含む）。
 * これを超えるメッセージは UTF-8 の文字境界で切り詰められる。
 */
constexpr std::size_t kLastErrorMessageCapacity = 1024;

/*
 * last-error を設定し、渡された status をそのまま返す。
 *
 * noexcept は飾りではなく契約である。この関数は OCVU_TRY_END の
 * catch(std::bad_alloc) の内側からも呼ばれるため、ここでアロケートすると
 * メモリ逼迫時に二次的な例外が extern "C" 関数を抜けて ABI 境界を越える。
 * よって固定長バッファへの bounded copy だけを行い、一切アロケートしない。
 */
ocvu_status set_last_error(ocvu_status status, const char* message) noexcept;

void clear_last_error() noexcept;

}  // namespace ocvu

/*
 * ABI 関数の本体を囲む例外バリア。
 * 公開 ABI 関数は原則この対で本体を囲むこと。
 * M2 で cv::Exception のハンドラをここに追加する。
 *
 * 例外（この対で囲んではならない関数）:
 *   - ocvu_get_last_error_status / ocvu_get_last_error_message
 *     OCVU_TRY_BEGIN は clear_last_error() を呼ぶ。エラー報告関数を囲むと、
 *     報告するために存在するエラーを読む直前に自分で消してしまう。
 *   - ocvu_get_abi_version / ocvu_get_status_count
 *     ocvu_status を返さないので OCVU_TRY_END の return と型が合わない。
 *     いずれも失敗せず、例外を投げ得る処理も含まない。
 * これらはいずれも throw し得ない実装であることが囲まない条件である。
 */
#define OCVU_TRY_BEGIN          \
    ::ocvu::clear_last_error(); \
    try {
#define OCVU_TRY_END                                                       \
    }                                                                      \
    catch (const std::bad_alloc&) {                                        \
        return ::ocvu::set_last_error(OCVU_STATUS_OUT_OF_MEMORY,           \
                                      "out of memory");                    \
    }                                                                      \
    catch (const std::exception& e) {                                      \
        return ::ocvu::set_last_error(OCVU_STATUS_UNKNOWN_ERROR, e.what());\
    }                                                                      \
    catch (...) {                                                          \
        return ::ocvu::set_last_error(OCVU_STATUS_UNKNOWN_ERROR,           \
                                      "unknown non-standard exception");   \
    }

#endif  // OCVU_ERROR_H
