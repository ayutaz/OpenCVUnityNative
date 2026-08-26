#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

/*
 * ABI に出す定数が OpenCV の値と一致していることを、写し間違いではなく
 * コンパイル時に固定する。OpenCV 側が値を変えたらビルドが落ちる。
 */
static_assert(OCVU_CVT_BGRA2BGR == cv::COLOR_BGRA2BGR, "cvt code drift");
static_assert(OCVU_CVT_RGBA2BGRA == cv::COLOR_RGBA2BGRA, "cvt code drift");
static_assert(OCVU_CVT_BGR2GRAY == cv::COLOR_BGR2GRAY, "cvt code drift");
static_assert(OCVU_INTER_NEAREST == cv::INTER_NEAREST, "interpolation drift");
static_assert(OCVU_INTER_LINEAR == cv::INTER_LINEAR, "interpolation drift");

namespace {

/*
 * src / dst handle を解決する。同一 handle は拒否する。
 * 失敗した場合は *out_status に理由を入れて false を返す。
 */
bool resolve_pair(ocvu_mat_handle src, ocvu_mat_handle dst,
                  cv::Mat** out_src, cv::Mat** out_dst, ocvu_status* out_status) {
    if (src == dst) {
        *out_status = ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "src and dst must be different handles (in-place is not supported)");
        return false;
    }
    cv::Mat* s = ::ocvu::mat_table_get(src);
    if (s == nullptr) {
        *out_status = ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                             "src handle is invalid");
        return false;
    }
    cv::Mat* d = ::ocvu::mat_table_get(dst);
    if (d == nullptr) {
        *out_status = ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                             "dst handle is invalid");
        return false;
    }
    *out_src = s;
    *out_dst = d;
    return true;
}

}  // namespace

extern "C" ocvu_status ocvu_cvt_color(ocvu_mat_handle src, ocvu_mat_handle dst,
                                      int32_t code) {
    OCVU_TRY_BEGIN
    cv::Mat* s = nullptr;
    cv::Mat* d = nullptr;
    ocvu_status failure = OCVU_STATUS_OK;
    if (!resolve_pair(src, dst, &s, &d, &failure)) { return failure; }

    try {
        cv::cvtColor(*s, *d, code);
    } catch (const cv::Exception& e) {
        // OCVU_TRY_END でも捕まるが、そこでは UNKNOWN_ERROR になってしまう。
        // OpenCV 由来だと分かる status を返すためにここで先に受ける。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_resize(ocvu_mat_handle src, ocvu_mat_handle dst,
                                   int32_t width, int32_t height,
                                   int32_t interpolation) {
    OCVU_TRY_BEGIN
    if (width < 1 || height < 1) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "width and height must be >= 1");
    }
    cv::Mat* s = nullptr;
    cv::Mat* d = nullptr;
    ocvu_status failure = OCVU_STATUS_OK;
    if (!resolve_pair(src, dst, &s, &d, &failure)) { return failure; }

    try {
        cv::resize(*s, *d, cv::Size(width, height), 0.0, 0.0, interpolation);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_gaussian_blur(ocvu_mat_handle src, ocvu_mat_handle dst,
                                          int32_t ksize_width, int32_t ksize_height,
                                          double sigma_x, double sigma_y) {
    OCVU_TRY_BEGIN
    if (ksize_width < 1 || ksize_height < 1 ||
        (ksize_width % 2) == 0 || (ksize_height % 2) == 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "kernel size must be a positive odd number");
    }
    cv::Mat* s = nullptr;
    cv::Mat* d = nullptr;
    ocvu_status failure = OCVU_STATUS_OK;
    if (!resolve_pair(src, dst, &s, &d, &failure)) { return failure; }

    try {
        cv::GaussianBlur(*s, *d, cv::Size(ksize_width, ksize_height), sigma_x, sigma_y);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
