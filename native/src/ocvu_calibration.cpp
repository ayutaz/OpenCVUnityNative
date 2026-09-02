#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/calib.hpp>
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

// ---------------------------------------------------------------------------
// ocvu_calibrate_camera —— 校正の輪を閉じる段。**calib module を要るのはここだけ。**
// ---------------------------------------------------------------------------

namespace {

// 1 view につき 6 個の double（回転ベクトル 3 個のあと並進ベクトル 3 個）。
// **この並びは spec の summary が呼ぶ側に約束している。**
constexpr int32_t kPoseStride = 6;

// カメラ行列は 3x3 を行優先で書く。
constexpr int32_t kCameraMatrixElements = 9;

}  // namespace

extern "C" ocvu_status ocvu_calibrate_camera(const float* object_points,
                                             int64_t object_points_length,
                                             const float* image_points,
                                             int64_t image_points_length,
                                             int32_t view_count,
                                             int32_t points_per_view,
                                             int32_t image_width,
                                             int32_t image_height,
                                             double* out_camera_matrix,
                                             int32_t camera_matrix_capacity,
                                             double* out_dist_coeffs,
                                             int32_t dist_coeffs_capacity,
                                             int32_t* out_dist_coeffs_count,
                                             double* out_view_poses,
                                             int32_t view_poses_capacity,
                                             double* out_rms) {
    OCVU_TRY_BEGIN
    if (out_dist_coeffs_count == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_calibrate_camera: out_dist_coeffs_count is NULL");
    }
    // どの経路で返っても、呼ぶ側が読む値が前回の残りにならないようにする。
    *out_dist_coeffs_count = 0;

    if (object_points == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_calibrate_camera: object_points is NULL");
    }
    if (image_points == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_calibrate_camera: image_points is NULL");
    }
    if (out_camera_matrix == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_calibrate_camera: out_camera_matrix is NULL");
    }
    if (out_dist_coeffs == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_calibrate_camera: out_dist_coeffs is NULL");
    }
    if (out_view_poses == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_calibrate_camera: out_view_poses is NULL");
    }
    if (out_rms == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_calibrate_camera: out_rms is NULL");
    }

    // 平面パターンの校正は 1 枚では解けない。**2 枚以上を要求する。**
    if (view_count < 2) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_calibrate_camera: view_count must be at least 2");
    }
    if (points_per_view < 4) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_calibrate_camera: points_per_view must be at least 4");
    }
    if (image_width < 1 || image_height < 1) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_calibrate_camera: image_width and image_height must be at least 1");
    }

    // **int32_t のまま掛けない。** 符号付き整数の乗算オーバーフローは未定義動作で、
    // 折り返した負の値は下の容量の門を素通りする。
    const int64_t total_points =
        static_cast<int64_t>(view_count) * static_cast<int64_t>(points_per_view);
    if (total_points > OCVU_CALIB_MAX_POINTS) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_calibrate_camera: view_count * points_per_view exceeds OCVU_CALIB_MAX_POINTS");
    }

    // 長さは**バイト数**である（この ABI の length はすべてそう）。
    const int64_t needed_object_bytes = total_points * 3 * static_cast<int64_t>(sizeof(float));
    const int64_t needed_image_bytes = total_points * 2 * static_cast<int64_t>(sizeof(float));
    if (object_points_length < needed_object_bytes) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_calibrate_camera: object_points_length is smaller than "
            "view_count * points_per_view * 3 * sizeof(float)");
    }
    if (image_points_length < needed_image_bytes) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_calibrate_camera: image_points_length is smaller than "
            "view_count * points_per_view * 2 * sizeof(float)");
    }

    // 容量は**要素数**である（ocvu_orb_detect と同じ「capacity == 配列長」）。
    // **検出より先に見る** —— 「何も書かない」契約は、書く前に返ることでしか守れない。
    const int64_t needed_poses = static_cast<int64_t>(view_count) * kPoseStride;
    if (camera_matrix_capacity < kCameraMatrixElements) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_calibrate_camera: camera_matrix_capacity is smaller than 9");
    }
    if (view_poses_capacity < needed_poses) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_calibrate_camera: view_poses_capacity is smaller than view_count * 6");
    }
    // 歪み係数の個数は OpenCV が決めるので、ここでは「最小でも 4 個は要る」
    // ことだけを見る。実際に返る個数が capacity を超えたら、下で書く前に断る。
    if (dist_coeffs_capacity < 4) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_calibrate_camera: dist_coeffs_capacity is smaller than 4");
    }

    // ここまでで検証は終わり。**ここから初めて入力を読む。**
    const int32_t per_view = points_per_view;
    std::vector<std::vector<cv::Point3f>> object_views(static_cast<size_t>(view_count));
    std::vector<std::vector<cv::Point2f>> image_views(static_cast<size_t>(view_count));
    for (int32_t v = 0; v < view_count; ++v) {
        std::vector<cv::Point3f>& obj = object_views[static_cast<size_t>(v)];
        std::vector<cv::Point2f>& img = image_views[static_cast<size_t>(v)];
        obj.reserve(static_cast<size_t>(per_view));
        img.reserve(static_cast<size_t>(per_view));
        for (int32_t i = 0; i < per_view; ++i) {
            const int64_t obj_base = (static_cast<int64_t>(v) * per_view + i) * 3;
            const int64_t img_base = (static_cast<int64_t>(v) * per_view + i) * 2;
            obj.emplace_back(object_points[obj_base + 0], object_points[obj_base + 1],
                             object_points[obj_base + 2]);
            img.emplace_back(image_points[img_base + 0], image_points[img_base + 1]);
        }
    }

    cv::Mat camera_matrix;
    cv::Mat dist_coeffs;
    std::vector<cv::Mat> rvecs;
    std::vector<cv::Mat> tvecs;
    double rms = 0.0;
    try {
        rms = cv::calibrateCamera(object_views, image_views,
                                  cv::Size(image_width, image_height),
                                  camera_matrix, dist_coeffs, rvecs, tvecs);
    } catch (const cv::Exception& e) {
        // **cv::Exception を個別に受ける。** OCVU_TRY_END に任せると
        // std::exception として UNKNOWN_ERROR に落ち、原因が読めなくなる。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    // OpenCV は 64F の 3x3 と 1xN を返すが、**契約は自分でも確かめる。**
    const cv::Mat camera64 = camera_matrix.type() == CV_64F
                                 ? camera_matrix
                                 : [&] { cv::Mat m; camera_matrix.convertTo(m, CV_64F); return m; }();
    const cv::Mat dist64 = dist_coeffs.type() == CV_64F
                               ? dist_coeffs
                               : [&] { cv::Mat m; dist_coeffs.convertTo(m, CV_64F); return m; }();

    if (camera64.total() != static_cast<size_t>(kCameraMatrixElements)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_UNKNOWN_ERROR,
            "ocvu_calibrate_camera: OpenCV returned a camera matrix that is not 3x3");
    }
    if (rvecs.size() != static_cast<size_t>(view_count) ||
        tvecs.size() != static_cast<size_t>(view_count)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_UNKNOWN_ERROR,
            "ocvu_calibrate_camera: OpenCV returned a pose count that does not match view_count");
    }

    const int64_t coeff_count = static_cast<int64_t>(dist64.total());
    if (coeff_count > dist_coeffs_capacity) {
        // **ここまで来ても、まだ 1 バイトも書いていない。**
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_calibrate_camera: dist_coeffs_capacity is smaller than the coefficient count "
            "OpenCV produced");
    }

    // ここから書き出す。**失敗しうる経路はもう無い。**
    const double* camera_data = camera64.ptr<double>();
    for (int32_t i = 0; i < kCameraMatrixElements; ++i) {
        out_camera_matrix[i] = camera_data[i];
    }

    const double* dist_data = dist64.ptr<double>();
    for (int64_t i = 0; i < coeff_count; ++i) {
        out_dist_coeffs[i] = dist_data[i];
    }

    for (int32_t v = 0; v < view_count; ++v) {
        cv::Mat rvec64;
        cv::Mat tvec64;
        rvecs[static_cast<size_t>(v)].convertTo(rvec64, CV_64F);
        tvecs[static_cast<size_t>(v)].convertTo(tvec64, CV_64F);

        const double* r = rvec64.ptr<double>();
        const double* t = tvec64.ptr<double>();
        const int64_t base = static_cast<int64_t>(v) * kPoseStride;

        // **回転が先、並進が後。** この順は spec の summary が約束している。
        out_view_poses[base + 0] = r[0];
        out_view_poses[base + 1] = r[1];
        out_view_poses[base + 2] = r[2];
        out_view_poses[base + 3] = t[0];
        out_view_poses[base + 4] = t[1];
        out_view_poses[base + 5] = t[2];
    }

    *out_dist_coeffs_count = static_cast<int32_t>(coeff_count);
    *out_rms = rms;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
