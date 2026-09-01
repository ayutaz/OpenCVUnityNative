#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/objdetect.hpp>

#include <string>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

extern "C" ocvu_status ocvu_qr_encode(const char* text, ocvu_mat_handle dst) {
    OCVU_TRY_BEGIN
    if (text == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_qr_encode: text is NULL");
    }
    if (text[0] == '\0') {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_qr_encode: text is empty");
    }

    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_qr_encode: dst handle is invalid");
    }

    // **符号化してから dst に入れる。** 直接 dst_mat へ encode させると、
    // 失敗したときに dst が途中まで書き換わった状態で残りうる。
    cv::Mat encoded;
    cv::Ptr<cv::QRCodeEncoder> encoder = cv::QRCodeEncoder::create();
    try {
        encoder->encode(std::string(text), encoded);
    } catch (const cv::Exception& e) {
        // OCVU_TRY_END でも捕まるが、そこでは UNKNOWN_ERROR になる。
        // OpenCV 由来だと分かる status を返すためにここで先に受ける
        // （ocvu_imgcodecs.cpp の ocvu_imencode / ocvu_imdecode と同じ形）。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    if (encoded.empty()) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR,
                                      "ocvu_qr_encode: the encoder produced an empty image");
    }

    *dst_mat = encoded;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
