#include "ocvu_error.h"

#include <cstring>
#include <string>

namespace {

thread_local ocvu_status g_last_status = OCVU_STATUS_OK;
thread_local std::string g_last_message;

}  // namespace

namespace ocvu {

ocvu_status set_last_error(ocvu_status status, const char* message) {
    g_last_status = status;
    g_last_message = (message != nullptr) ? message : "";
    return status;
}

void clear_last_error() {
    g_last_status = OCVU_STATUS_OK;
    g_last_message.clear();
}

}  // namespace ocvu

extern "C" ocvu_status ocvu_get_last_error_status(void) {
    return g_last_status;
}

extern "C" ocvu_status ocvu_get_last_error_message(char* buffer,
                                                   int32_t buffer_size,
                                                   int32_t* out_required_size) {
    if (out_required_size == nullptr) {
        return OCVU_STATUS_NULL_POINTER;
    }

    const size_t length = g_last_message.size();
    const int32_t required = static_cast<int32_t>(length) + 1;
    *out_required_size = required;

    if (buffer == nullptr || buffer_size < required) {
        return OCVU_STATUS_INVALID_ARGUMENT;
    }

    std::memcpy(buffer, g_last_message.c_str(), length);
    buffer[length] = '\0';
    return OCVU_STATUS_OK;
}
