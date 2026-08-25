#include <cstring>
#include <string>

#include <opencv2/core/utility.hpp>
#include <opencv2/core/version.hpp>

#include "ocvu_error.h"

namespace {

/*
 * 文字列を返す ABI の共通実装。
 * out_required_size は常に「NUL を含むバイト数」を受け取る。
 * buffer が不足している場合は BUFFER_TOO_SMALL を返すが、これは
 * サイズ問い合わせの正常な結果であって失敗ではない
 * （opencv_unity_native.h の OCVU_STATUS_LIST の注記を参照）。
 */
ocvu_status write_string(const std::string& value,
                         char* buffer,
                         int32_t buffer_size,
                         int32_t* out_required_size) {
    if (out_required_size == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "out_required_size is NULL");
    }

    const size_t length = value.size();
    const int32_t required = static_cast<int32_t>(length) + 1;
    *out_required_size = required;

    if (buffer == nullptr || buffer_size < required) {
        return OCVU_STATUS_BUFFER_TOO_SMALL;
    }

    std::memcpy(buffer, value.c_str(), length);
    buffer[length] = '\0';
    return OCVU_STATUS_OK;
}

}  // namespace

extern "C" ocvu_status ocvu_get_opencv_version(char* buffer,
                                               int32_t buffer_size,
                                               int32_t* out_required_size) {
    OCVU_TRY_BEGIN
    return write_string(CV_VERSION, buffer, buffer_size, out_required_size);
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_get_build_information(char* buffer,
                                                  int32_t buffer_size,
                                                  int32_t* out_required_size) {
    OCVU_TRY_BEGIN
    return write_string(cv::getBuildInformation(), buffer, buffer_size,
                        out_required_size);
    OCVU_TRY_END
}
