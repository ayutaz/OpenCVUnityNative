#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/objdetect.hpp>

#include <algorithm>
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

extern "C" ocvu_status ocvu_find_chessboard_corners(ocvu_mat_handle src, int32_t pattern_cols, int32_t pattern_rows, float* out_corners, int32_t capacity, int32_t* out_count) {
    OCVU_TRY_BEGIN
    if (out_count == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_find_chessboard_corners: out_count is NULL");
    }
    // どの経路で返っても、呼ぶ側が読む値が前回の残りにならないようにする。
    *out_count = 0;

    // 格子は 2x2 以上でなければ格子にならない。
    if (pattern_cols < 2 || pattern_rows < 2) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_find_chessboard_corners: pattern_cols and pattern_rows must be at least 2");
    }

    // **int64_t で計算し、上限を設ける。** pattern_cols * pattern_rows を
    // int32_t のまま掛けると符号付き整数の乗算オーバーフロー（未定義動作）に
    // なりうる。折り返して負の値になった needed は、この先の capacity 比較の
    // 門をすり抜けてしまう（レビュー I3）。
    const int64_t point_count = static_cast<int64_t>(pattern_cols) * pattern_rows;
    if (point_count > OCVU_CHESSBOARD_MAX_CORNERS) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_find_chessboard_corners: pattern_cols * pattern_rows exceeds OCVU_CHESSBOARD_MAX_CORNERS");
    }

    if (capacity < 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_find_chessboard_corners: capacity is negative");
    }
    if (capacity > 0 && out_corners == nullptr) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_NULL_POINTER,
            "ocvu_find_chessboard_corners: out_corners is NULL but capacity is positive");
    }

    cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_find_chessboard_corners: src handle is invalid");
    }
    if (src_mat->empty()) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_find_chessboard_corners: src is empty");
    }

    // **capacity は out_corners の float の個数である**（点の個数ではない）。
    // x と y が交互に並ぶので、必要な float 数は point_count * 2。
    // point_count は上で OCVU_CHESSBOARD_MAX_CORNERS 以下と確かめてあるので、
    // ここでの *2 は int64_t の範囲で安全である（オーバーフローしない）。
    //
    // **検出より先に容量を見る。** 足りないと分かっている呼び出しで検出まで
    // 走らせるのは無駄で、しかも「何も書かない」契約は書く前に返ることでしか守れない。
    const int64_t needed = point_count * 2;
    if (static_cast<int64_t>(capacity) < needed) {
        // needed <= OCVU_CHESSBOARD_MAX_CORNERS * 2 は int32_t に収まる
        // （OCVU_CHESSBOARD_MAX_CORNERS の値がそれを保証する）。
        *out_count = static_cast<int32_t>(needed);
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_find_chessboard_corners: capacity is smaller than pattern_cols * pattern_rows * 2");
    }

    std::vector<cv::Point2f> corners;
    bool found = false;
    try {
        found = cv::findChessboardCorners(*src_mat, cv::Size(pattern_cols, pattern_rows),
                                          corners);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    // **見つからないのは誤りではない。** 格子が写っていなかっただけである。
    if (!found || corners.empty()) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_NOT_FOUND,
            "ocvu_find_chessboard_corners: no chessboard was found in src");
    }

    // OpenCV は pattern の点数ちょうどを返すが、契約は自分でも守る。
    const int64_t n = std::min<int64_t>(static_cast<int64_t>(corners.size()), point_count);
    for (int64_t i = 0; i < n; ++i) {
        out_corners[i * 2] = corners[static_cast<size_t>(i)].x;
        out_corners[(i * 2) + 1] = corners[static_cast<size_t>(i)].y;
    }
    *out_count = static_cast<int32_t>(n * 2);
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
