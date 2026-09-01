#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/geometry.hpp>

#include <cstdint>
#include <vector>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

// 境界に出す method の値は OpenCV のものをそのまま使う。
// 写し間違いをコンパイル時に落とす（ocvu_imgcodecs.cpp / ocvu_imgproc.cpp と同じ形）。
static_assert(OCVU_HOMOGRAPHY_METHOD_LMEDS == cv::LMEDS,
              "OCVU_HOMOGRAPHY_METHOD_LMEDS が cv::LMEDS と違う");
static_assert(OCVU_HOMOGRAPHY_METHOD_RANSAC == cv::RANSAC,
              "OCVU_HOMOGRAPHY_METHOD_RANSAC が cv::RANSAC と違う");

namespace {

// 射影変換は 4 点で決まる。それ未満は解が無いのではなく、問いが成立しない。
constexpr int32_t kMinPointsForHomography = 4;

bool IsKnownMethod(int32_t method) {
    return method == OCVU_HOMOGRAPHY_METHOD_DEFAULT ||
           method == OCVU_HOMOGRAPHY_METHOD_LMEDS ||
           method == OCVU_HOMOGRAPHY_METHOD_RANSAC;
}

}  // namespace

extern "C" ocvu_status ocvu_find_homography(const float* src_points, int64_t src_length, const float* dst_points, int64_t dst_length, int32_t point_count, int32_t method, double ransac_threshold, ocvu_mat_handle dst) {
    OCVU_TRY_BEGIN
    if (src_points == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_find_homography: src_points is NULL");
    }
    if (dst_points == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_find_homography: dst_points is NULL");
    }
    if (point_count < kMinPointsForHomography) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_find_homography: point_count must be at least 4");
    }

    // **呼ぶ側を信用しない。** point_count だけを受け取ると、配列の終端を
    // 越えて読んでも native からは分からない。長さを明示的に受け取り、
    // 必要量に足りなければ何も読まずに断る
    // （ocvu_imdecode / ocvu_mat_copy_from_buffer と同じ契約）。
    //
    // **単位はバイトである。** この ABI の *_length はすべてバイト数で
    // （ocvu_mat_copy_from_buffer / ocvu_mat_copy_to_buffer / ocvu_imdecode）、
    // ここだけ要素数にすると、既存に慣れた呼び手が 4 倍の値を渡して
    // **検査を通過する**方向に倒れる。
    //
    // **積は int64_t に上げてから作る。** point_count は int32_t なので
    // 2 * sizeof(float) 倍しても int64_t には収まるが、桁あふれを
    // 「収まるはずだから安全」で済ませないのがこの境界の作法である
    // （M2 で stride の積が反転して踏んだ）。
    const int64_t needed =
        static_cast<int64_t>(point_count) * 2 * static_cast<int64_t>(sizeof(float));
    if (src_length < needed) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_find_homography: src_length (bytes) is too small for point_count");
    }
    if (dst_length < needed) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_find_homography: dst_length (bytes) is too small for point_count");
    }
    // **知らない method は素通しにしない。** OpenCV に落とすと
    // 「原因不明」（UNKNOWN_ERROR）になるか、黙って既定の挙動になる。
    if (!IsKnownMethod(method)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_find_homography: method is not one of OCVU_HOMOGRAPHY_METHOD_*");
    }

    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_find_homography: dst handle is invalid");
    }

    // 借用はこの呼び出しの内側で完結する。cv::Mat で包むだけで所有はしない。
    const cv::Mat src_view(point_count, 2, CV_32F, const_cast<float*>(src_points));
    const cv::Mat dst_view(point_count, 2, CV_32F, const_cast<float*>(dst_points));

    // **求めてから dst に入れる。** 直接 dst_mat へ書かせると、
    // 失敗したときに dst が途中まで書き換わった状態で残りうる。
    cv::Mat homography;
    try {
        homography = cv::findHomography(src_view, dst_view, method, ransac_threshold);
    } catch (const cv::Exception& e) {
        // OCVU_TRY_END でも捕まるが、そこでは UNKNOWN_ERROR になる。
        // OpenCV 由来だと分かる status を返すためにここで先に受ける。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    // **空は誤りではない。** 点が退化していて解が求まらなかっただけである。
    // 入力の形は正しいので INVALID_ARGUMENT ではなく NOT_FOUND で返す。
    //
    // **どの入力で空になるかは OpenCV が決める。実測（2026-09-01）:**
    //   全部同じ点               -> 空（NOT_FOUND）
    //   軸に平行な直線上の 4 点  -> 空（NOT_FOUND）
    //   **斜めの直線上の 4 点    -> 空でない（OK）**
    // OpenCV は x 方向と y 方向の広がりを別々に見ており、**どちらかが 0 の
    // ときだけ**空を返す。したがって「一直線なら NOT_FOUND」は成り立たない ——
    // 斜めの直線は rank 不足の行列がそのまま返る。**共線判定はしていない。**
    if (homography.empty()) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_NOT_FOUND,
            "ocvu_find_homography: no homography could be estimated from these points");
    }

    *dst_mat = homography;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
