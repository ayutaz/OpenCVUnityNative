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
