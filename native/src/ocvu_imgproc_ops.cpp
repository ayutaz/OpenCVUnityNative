// imgproc のうち「画素を作る」もの —— 二値化・エッジ検出・形態素演算・
// テンプレート照合・射影変換の適用。
//
// **ocvu_imgproc.cpp に足していない。** あちらは M2 の 3 本（cvtColor / resize /
// GaussianBlur）で、そこへ 5 本足すと 1 ファイルが持つ責務が広くなりすぎる。
//
// **cv::getPerspectiveTransform はここに無い。** OpenCV 5 では geometry module に
// 在るので、実装は native/src/ocvu_geometry.cpp が持つ（変換を求めるのが geometry、
// 当てるのが imgproc という分かれ方で、用途は 1 つでも module は 2 つである）。

#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>

#include <cstdint>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

// 境界に出す値は OpenCV のものをそのまま使う。
// 写し間違いをコンパイル時に落とす（ocvu_imgproc.cpp / ocvu_geometry.cpp と同じ形）。
static_assert(OCVU_THRESH_BINARY == cv::THRESH_BINARY, "THRESH_BINARY がずれている");
static_assert(OCVU_THRESH_BINARY_INV == cv::THRESH_BINARY_INV, "THRESH_BINARY_INV がずれている");
static_assert(OCVU_THRESH_TRUNC == cv::THRESH_TRUNC, "THRESH_TRUNC がずれている");
static_assert(OCVU_THRESH_TOZERO == cv::THRESH_TOZERO, "THRESH_TOZERO がずれている");
static_assert(OCVU_THRESH_TOZERO_INV == cv::THRESH_TOZERO_INV, "THRESH_TOZERO_INV がずれている");
static_assert(OCVU_THRESH_OTSU == cv::THRESH_OTSU, "THRESH_OTSU がずれている");
static_assert(OCVU_MORPH_ERODE == cv::MORPH_ERODE, "MORPH_ERODE がずれている");
static_assert(OCVU_MORPH_DILATE == cv::MORPH_DILATE, "MORPH_DILATE がずれている");
static_assert(OCVU_MORPH_OPEN == cv::MORPH_OPEN, "MORPH_OPEN がずれている");
static_assert(OCVU_MORPH_CLOSE == cv::MORPH_CLOSE, "MORPH_CLOSE がずれている");
static_assert(OCVU_MORPH_GRADIENT == cv::MORPH_GRADIENT, "MORPH_GRADIENT がずれている");
static_assert(OCVU_MORPH_TOPHAT == cv::MORPH_TOPHAT, "MORPH_TOPHAT がずれている");
static_assert(OCVU_MORPH_BLACKHAT == cv::MORPH_BLACKHAT, "MORPH_BLACKHAT がずれている");
static_assert(OCVU_MORPH_SHAPE_RECT == cv::MORPH_RECT, "MORPH_RECT がずれている");
static_assert(OCVU_MORPH_SHAPE_CROSS == cv::MORPH_CROSS, "MORPH_CROSS がずれている");
static_assert(OCVU_MORPH_SHAPE_ELLIPSE == cv::MORPH_ELLIPSE, "MORPH_ELLIPSE がずれている");
static_assert(OCVU_TM_SQDIFF == cv::TM_SQDIFF, "TM_SQDIFF がずれている");
static_assert(OCVU_TM_SQDIFF_NORMED == cv::TM_SQDIFF_NORMED, "TM_SQDIFF_NORMED がずれている");
static_assert(OCVU_TM_CCORR == cv::TM_CCORR, "TM_CCORR がずれている");
static_assert(OCVU_TM_CCORR_NORMED == cv::TM_CCORR_NORMED, "TM_CCORR_NORMED がずれている");
static_assert(OCVU_TM_CCOEFF == cv::TM_CCOEFF, "TM_CCOEFF がずれている");
static_assert(OCVU_TM_CCOEFF_NORMED == cv::TM_CCOEFF_NORMED, "TM_CCOEFF_NORMED がずれている");
static_assert(OCVU_BORDER_CONSTANT == cv::BORDER_CONSTANT, "BORDER_CONSTANT がずれている");
static_assert(OCVU_BORDER_REPLICATE == cv::BORDER_REPLICATE, "BORDER_REPLICATE がずれている");
static_assert(OCVU_BORDER_REFLECT == cv::BORDER_REFLECT, "BORDER_REFLECT がずれている");
static_assert(OCVU_BORDER_WRAP == cv::BORDER_WRAP, "BORDER_WRAP がずれている");
static_assert(OCVU_BORDER_REFLECT_101 == cv::BORDER_REFLECT_101, "BORDER_REFLECT_101 がずれている");
static_assert(OCVU_INTER_NEAREST == cv::INTER_NEAREST, "INTER_NEAREST がずれている");
static_assert(OCVU_INTER_LINEAR == cv::INTER_LINEAR, "INTER_LINEAR がずれている");
static_assert(OCVU_MAT_TYPE_32FC1 == CV_32FC1, "OCVU_MAT_TYPE_32FC1 が CV_32FC1 と違う");

namespace {

// **知らない値を素通しにしない。** OpenCV に落とすと「原因不明」になるか、
// 黙って既定の挙動になる（ocvu_find_homography と同じ理由づけ）。
bool IsKnownThresholdType(int32_t type) {
    // OCVU_THRESH_OTSU は or して渡す指定なので、外した残りを見る。
    // **cv::THRESH_TRIANGLE（16）は出していない**ので、それが立っていれば
    // base が 4 を超えてここで断たれる。
    const int32_t base = type & ~static_cast<int32_t>(OCVU_THRESH_OTSU);
    return base >= OCVU_THRESH_BINARY && base <= OCVU_THRESH_TOZERO_INV;
}

bool IsKnownMorphOp(int32_t op) {
    return op >= OCVU_MORPH_ERODE && op <= OCVU_MORPH_BLACKHAT;
}

bool IsKnownMorphShape(int32_t shape) {
    return shape >= OCVU_MORPH_SHAPE_RECT && shape <= OCVU_MORPH_SHAPE_ELLIPSE;
}

bool IsKnownTemplateMatchMethod(int32_t method) {
    return method >= OCVU_TM_SQDIFF && method <= OCVU_TM_CCOEFF_NORMED;
}

bool IsKnownBorderMode(int32_t mode) {
    return mode >= OCVU_BORDER_CONSTANT && mode <= OCVU_BORDER_REFLECT_101;
}

bool IsKnownInterpolation(int32_t interpolation) {
    return interpolation == OCVU_INTER_NEAREST || interpolation == OCVU_INTER_LINEAR;
}

}  // namespace

extern "C" ocvu_status ocvu_threshold(ocvu_mat_handle src, ocvu_mat_handle dst, double threshold_value, double max_value, int32_t type, double* out_computed_threshold) {
    OCVU_TRY_BEGIN

    // **NULL でないなら、何よりも先に 0 を書く。** どの経路で返っても、
    // 呼ぶ側が読む値が前回のまま残らないようにする（ocvu_imencode の
    // out_required_size と同じ規則で、以降のすべての早期 return がこの後ろに来る）。
    if (out_computed_threshold != nullptr) {
        *out_computed_threshold = 0.0;
    }

    if (!IsKnownThresholdType(type)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_threshold: type is not one of OCVU_THRESH_* (optionally or-ed with OCVU_THRESH_OTSU)");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_threshold: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_threshold: dst handle is invalid");
    }

    // **求めてから入れる。** src と dst が同じ handle でも壊れず、
    // 失敗したときに dst が途中まで書き換わることも無い。
    cv::Mat result;
    double used = 0.0;
    try {
        used = cv::threshold(*src_mat, result, threshold_value, max_value, type);
    } catch (const cv::Exception& e) {
        // OCVU_TRY_END でも捕まるが、そこでは UNKNOWN_ERROR になる。
        // OpenCV 由来だと分かる status を返すためにここで先に受ける。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    if (out_computed_threshold != nullptr) {
        *out_computed_threshold = used;
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_canny(ocvu_mat_handle src, ocvu_mat_handle dst, double threshold1, double threshold2, int32_t aperture_size, int32_t l2_gradient) {
    OCVU_TRY_BEGIN
    if (threshold1 < 0.0 || threshold2 < 0.0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_canny: thresholds must not be negative");
    }
    // OpenCV が受けるのは 3 / 5 / 7 だけである。落とすと例外になるのでここで断る。
    if (aperture_size != 3 && aperture_size != 5 && aperture_size != 7) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_canny: aperture_size must be 3, 5 or 7");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_canny: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_canny: dst handle is invalid");
    }

    cv::Mat result;
    try {
        cv::Canny(*src_mat, result, threshold1, threshold2, aperture_size, l2_gradient != 0);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_morphology_ex(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t op, int32_t kernel_shape, int32_t kernel_width, int32_t kernel_height, int32_t iterations) {
    OCVU_TRY_BEGIN
    if (!IsKnownMorphOp(op)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_morphology_ex: op is not one of OCVU_MORPH_*");
    }
    if (!IsKnownMorphShape(kernel_shape)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_morphology_ex: kernel_shape is not one of OCVU_MORPH_SHAPE_*");
    }
    if (kernel_width < 1 || kernel_height < 1) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_morphology_ex: kernel_width and kernel_height must be at least 1");
    }
    if (iterations < 1) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_morphology_ex: iterations must be at least 1");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_morphology_ex: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_morphology_ex: dst handle is invalid");
    }

    cv::Mat result;
    try {
        // 構造要素の大きさが極端に大きい場合、確保に失敗して OpenCV が
        // 例外を投げる。それは下の catch が OPENCV_ERROR にする。
        const cv::Mat kernel =
            cv::getStructuringElement(kernel_shape, cv::Size(kernel_width, kernel_height));
        cv::morphologyEx(*src_mat, result, op, kernel, cv::Point(-1, -1), iterations);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_match_template(ocvu_mat_handle image, ocvu_mat_handle templ, ocvu_mat_handle dst, int32_t method) {
    OCVU_TRY_BEGIN
    if (!IsKnownTemplateMatchMethod(method)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_match_template: method is not one of OCVU_TM_*");
    }

    const cv::Mat* image_mat = ::ocvu::mat_table_get(image);
    if (image_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_match_template: image handle is invalid");
    }
    const cv::Mat* templ_mat = ::ocvu::mat_table_get(templ);
    if (templ_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_match_template: templ handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_match_template: dst handle is invalid");
    }

    // **大きさは自分で見る。** 実測（2026-09-05）: cv::matchTemplate は templ が
    // image より**両方向とも**大きいとき例外を投げず、image と templ を
    // 入れ替えて計算する（5x5 の image に 9x9 の templ を渡すと 5x5 が返る）。
    // OpenCV に任せると、summary が約束した出力の形が黙って破られる ——
    // status ではなく「もっともらしい結果」として誤りが現れる形なので、
    // ここで断つ。
    if (image_mat->rows < templ_mat->rows || image_mat->cols < templ_mat->cols) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_match_template: templ must not be larger than image in either dimension");
    }

    cv::Mat result;
    try {
        cv::matchTemplate(*image_mat, *templ_mat, result, method);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    // **確かめるのではなく変換する**（ocvu_calibration.cpp と同じ作法）。
    // OpenCV は 32 bit 浮動小数 1 channel を返すと文書化しているが、
    // summary が約束しているのはこちらなので、違えば合わせる。
    if (result.type() != CV_32FC1) {
        cv::Mat converted;
        result.convertTo(converted, CV_32FC1);
        result = converted;
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_warp_perspective(ocvu_mat_handle src, ocvu_mat_handle dst, ocvu_mat_handle transform, int32_t width, int32_t height, int32_t interpolation, int32_t border_mode) {
    OCVU_TRY_BEGIN
    if (width < 1 || height < 1) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_warp_perspective: width and height must be at least 1");
    }
    if (!IsKnownInterpolation(interpolation)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_warp_perspective: interpolation is not one of OCVU_INTER_*");
    }
    if (!IsKnownBorderMode(border_mode)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_warp_perspective: border_mode is not one of OCVU_BORDER_*");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_warp_perspective: src handle is invalid");
    }
    const cv::Mat* transform_mat = ::ocvu::mat_table_get(transform);
    if (transform_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_warp_perspective: transform handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_warp_perspective: dst handle is invalid");
    }

    // **形を自分で確かめる。** OpenCV に落とすと例外になるが、呼ぶ側が直せる
    // 誤りなので INVALID_ARGUMENT で返す。
    if (transform_mat->rows != 3 || transform_mat->cols != 3) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_warp_perspective: transform must be a 3x3 matrix");
    }

    cv::Mat result;
    try {
        cv::warpPerspective(*src_mat, result, *transform_mat, cv::Size(width, height),
                            interpolation, border_mode);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
