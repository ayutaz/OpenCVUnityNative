#ifndef OCVU_ERROR_H
#define OCVU_ERROR_H

#include <exception>
#include <new>
#include <stdexcept>

#include "opencv_unity_native.h"

namespace ocvu {

/* last-error を設定し、渡された status をそのまま返す。 */
ocvu_status set_last_error(ocvu_status status, const char* message);

void clear_last_error();

}  // namespace ocvu

/*
 * ABI 関数の本体を囲む例外バリア。
 * すべての公開 ABI 関数はこの対で本体を囲むこと。
 * M2 で cv::Exception のハンドラをここに追加する。
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
