#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/objdetect.hpp>

#include <cstdint>
#include <vector>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

namespace {

// カメラ行列は 3x3 で固定である。
constexpr int64_t kCameraMatrixBytes = 9 * static_cast<int64_t>(sizeof(double));

// OpenCV が受け付ける歪み係数の個数。**この一覧は OpenCV の都合であって
// こちらの判断ではない** —— 減らすと、その係数を持つ利用者だけが使えなくなる。
bool IsAcceptedCoefficientCount(int64_t count) {
    return count == 4 || count == 5 || count == 8 || count == 12 || count == 14;
}

}  // namespace

extern "C" ocvu_status ocvu_undistort(ocvu_mat_handle src, const double* camera_matrix, int64_t camera_matrix_length, const double* dist_coeffs, int64_t dist_coeffs_length, ocvu_mat_handle dst) {
    OCVU_TRY_BEGIN
    if (camera_matrix == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_undistort: camera_matrix is NULL");
    }
    if (dist_coeffs == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_undistort: dist_coeffs is NULL");
    }

    // **呼ぶ側を信用しない。** 単位はバイトで、この ABI の length は全部そうである。
    // カメラ行列は「足りない」だけでなく「多い」も断る —— 3x3 は固定長なので、
    // 違う長さを渡してきた呼ぶ側は何かを取り違えている。
    if (camera_matrix_length != kCameraMatrixBytes) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_undistort: camera_matrix_length must be exactly 9 doubles");
    }

    if (dist_coeffs_length < 0 ||
        dist_coeffs_length % static_cast<int64_t>(sizeof(double)) != 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_undistort: dist_coeffs_length is not a whole number of doubles");
    }
    const int64_t coeff_count = dist_coeffs_length / static_cast<int64_t>(sizeof(double));
    if (!IsAcceptedCoefficientCount(coeff_count)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_undistort: dist_coeffs must hold 4, 5, 8, 12 or 14 doubles");
    }

    cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_undistort: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_undistort: dst handle is invalid");
    }

    // 借用はこの呼び出しの内側で完結する。cv::Mat で包むだけで所有はしない。
    const cv::Mat camera_view(3, 3, CV_64F, const_cast<double*>(camera_matrix));
    const cv::Mat coeffs_view(1, static_cast<int>(coeff_count), CV_64F,
                              const_cast<double*>(dist_coeffs));

    // **補正してから dst に入れる。** 直接 dst_mat へ書かせると、
    // 失敗したときに dst が途中まで書き換わった状態で残りうるうえ、
    // src と dst が同じ handle のとき cv::undistort 内部の
    // CV_Assert(dst.data != src.data) に落ちる
    // （Calibration.UndistortAcceptsTheSameHandleForSourceAndDestination で固定）。
    cv::Mat corrected;
    try {
        cv::undistort(*src_mat, corrected, camera_view, coeffs_view);
    } catch (const cv::Exception& e) {
        // OCVU_TRY_END でも捕まるが、そこでは UNKNOWN_ERROR になる。
        // OpenCV 由来だと分かる status を返すためにここで先に受ける。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = corrected;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
