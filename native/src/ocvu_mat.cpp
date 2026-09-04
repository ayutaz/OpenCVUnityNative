#include <opencv2/core.hpp>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

/*
 * **OCVU_MAT_TYPE_* は OpenCV の値の写しではない。** 下の switch が翻訳する
 * ので、一致している必要が無い —— これは OCVU_CVT_* や OCVU_THRESH_* と違う。
 *
 * **2026-09-05 にそれを実測で確かめた。** 「写しである」と思って
 * static_assert を置いたら、8UC3 と 8UC4 の 2 本が落ちた:
 *
 *   OpenCV 5 は CV_CN_SHIFT を 3 から **5** に変えている
 *   （third_party/.../core/hal/interface.h:51）。したがって
 *   CV_8UC3 は 2 << 5 = **64**、CV_8UC4 は 3 << 5 = **96** である。
 *
 * **この ABI の 16 と 24 は OpenCV 4 の値**で、M2 で写したときのものが
 * そのまま残っている。**気づかなかったのは switch が翻訳しているからで、
 * 実害は 1 度も出ていない。**
 *
 * したがって static_assert は置けない（置くと今のこの 2 本が落ちる）。
 * **値を OpenCV 5 に合わせることもしない** —— 境界に出ている番号を変えるのは
 * 破壊的変更で、OCVU_ABI_VERSION の bump が要る
 * （docs/abi-ownership-and-versioning.md §2）。
 *
 * **代わりに、下の 2 つの switch が互いの逆であることを L1 が確かめる**
 * （test_mat_lifecycle.cpp）。翻訳表が唯一の正本であり、
 * ここに書いてよい不変条件は「往復すると元に戻る」だけである。
 */

namespace {

/* ABI に出す type 定数から OpenCV の型へ。未知なら false。 */
bool to_cv_type(int32_t abi_type, int* out_cv_type) {
    switch (abi_type) {
        case OCVU_MAT_TYPE_8UC1: *out_cv_type = CV_8UC1; return true;
        case OCVU_MAT_TYPE_8UC3: *out_cv_type = CV_8UC3; return true;
        case OCVU_MAT_TYPE_8UC4: *out_cv_type = CV_8UC4; return true;
        case OCVU_MAT_TYPE_16SC1: *out_cv_type = CV_16SC1; return true;
        case OCVU_MAT_TYPE_32FC1: *out_cv_type = CV_32FC1; return true;
        case OCVU_MAT_TYPE_64FC1: *out_cv_type = CV_64FC1; return true;
        default: return false;
    }
}

int32_t from_cv_type(int cv_type) {
    switch (cv_type) {
        case CV_8UC1: return OCVU_MAT_TYPE_8UC1;
        case CV_8UC3: return OCVU_MAT_TYPE_8UC3;
        case CV_8UC4: return OCVU_MAT_TYPE_8UC4;
        case CV_16SC1: return OCVU_MAT_TYPE_16SC1;
        case CV_32FC1: return OCVU_MAT_TYPE_32FC1;
        case CV_64FC1: return OCVU_MAT_TYPE_64FC1;
        /* **-1 は「この ABI が名前を持たない型」という意味である。**
         * ocvu_mat_get_info はそれでも OCVU_STATUS_OK を返す —— rows / cols /
         * channels / step は正しく、step があれば byte 列としては読めるためである。 */
        default: return -1;
    }
}

}  // namespace

extern "C" ocvu_status ocvu_mat_create(int32_t rows, int32_t cols, int32_t type,
                                       ocvu_mat_handle* out_handle) {
    OCVU_TRY_BEGIN
    if (out_handle == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER, "out_handle is NULL");
    }
    if (rows < 1 || cols < 1) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "rows and cols must be >= 1");
    }
    int cv_type = 0;
    if (!to_cv_type(type, &cv_type)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT, "unknown mat type");
    }

    const ocvu_mat_handle handle = ::ocvu::mat_table_acquire(cv::Mat(rows, cols, cv_type));
    if (handle == OCVU_MAT_HANDLE_NONE) {
        return ::ocvu::set_last_error(OCVU_STATUS_OUT_OF_MEMORY, "mat table exhausted");
    }
    *out_handle = handle;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_mat_release(ocvu_mat_handle handle) {
    OCVU_TRY_BEGIN
    if (!::ocvu::mat_table_release(handle)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "handle is unknown or already released");
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_mat_clone(ocvu_mat_handle src, ocvu_mat_handle* out_handle) {
    OCVU_TRY_BEGIN
    if (out_handle == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER, "out_handle is NULL");
    }
    cv::Mat* mat = ::ocvu::mat_table_get(src);
    if (mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE, "src handle is invalid");
    }
    const ocvu_mat_handle handle = ::ocvu::mat_table_acquire(mat->clone());
    if (handle == OCVU_MAT_HANDLE_NONE) {
        return ::ocvu::set_last_error(OCVU_STATUS_OUT_OF_MEMORY, "mat table exhausted");
    }
    *out_handle = handle;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_mat_get_info(ocvu_mat_handle handle, ocvu_mat_info* out_info) {
    OCVU_TRY_BEGIN
    if (out_info == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER, "out_info is NULL");
    }
    cv::Mat* mat = ::ocvu::mat_table_get(handle);
    if (mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE, "handle is invalid");
    }
    out_info->rows = mat->rows;
    out_info->cols = mat->cols;
    out_info->type = from_cv_type(mat->type());
    out_info->channels = mat->channels();
    out_info->step = static_cast<int64_t>(mat->step);
    out_info->total_bytes = static_cast<int64_t>(mat->step) * mat->rows;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
