#include <new>
#include <stdexcept>

#include "ocvu_error.h"

extern "C" ocvu_status ocvu_debug_throw(int32_t kind) {
    OCVU_TRY_BEGIN
    switch (kind) {
        case 0:
            throw std::runtime_error("ocvu_debug_throw: std::runtime_error");
        case 1:
            throw std::bad_alloc();
        case 2:
            throw 42;
        case 3:
            return OCVU_STATUS_OK;
        default:
            return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                          "ocvu_debug_throw: unknown kind");
    }
    OCVU_TRY_END
}

extern "C" void ocvu_debug_crash(int32_t kind) {
    // OCVU_TRY_BEGIN で囲まない。囲む対象は「例外を status に変える」関数であり、
    // これは意図的に落とすための関数で、status を返さない（hook の検査対象外）。
    if (kind == 0) {
        volatile int* p = nullptr;
        *p = 1;  // 意図的な不正アクセス
    } else {
        for (;;) {
            // 意図的に戻らない。ハング検出の対象。
        }
    }
}
