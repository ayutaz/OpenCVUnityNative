#include <cstring>

#include <opencv2/core.hpp>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

namespace {

/*
 * 外部 buffer と Mat の整合を検証する。合格したときだけ true を返し、
 * row_bytes に 1 行の実バイト数を書く。
 *
 * 呼ぶ側を信用しないための関門であり、この関数を通らない書き込み経路を
 * 作らないこと（docs/abi-ownership-and-versioning.md §3）。
 */
bool validate(const cv::Mat& mat, int64_t length, int64_t stride,
              int64_t* out_row_bytes, ocvu_status* out_status) {
    // 負値は下の 2 つの検査にも必ず捕まる（負の stride は row_bytes 未満、
    // 負の length は非負の stride * rows 未満）ので、この検査は冗長である。
    // 意図を明示する価値と、算出順が変われば冗長でなくなることから残している。
    // 冗長なので、これを消しても L1 は緑のままである（実測・意図どおり）。
    if (length < 0 || stride < 0) {
        *out_status = ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                             "length and stride must not be negative");
        return false;
    }

    const int64_t row_bytes = static_cast<int64_t>(mat.cols) * mat.elemSize();
    if (stride < row_bytes) {
        *out_status = ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                             "stride is smaller than one row of the mat");
        return false;
    }
    // stride * rows を「計算してから比較する」と桁あふれで検査が反転する。
    // stride は呼び出し側が自由に決める int64_t なので、2^62 のような値を渡すと
    // 積が負になり、この比較が偽になって関門を通過する。上の stride < row_bytes も
    // 巨大な stride では通るため、両方を抜けて memcpy に到達し、任意アドレスへ
    // 書き込む（実測: 3x4 の Mat に stride=2^62 でアクセス違反、プロセス即死）。
    //
    // これは docs/abi-ownership-and-versioning.md §1 が「最も危険」と名指しした
    // 壊れ方そのものである。借用 handle を廃してもこの経路には残っていた。
    //
    // 割り算に直すと桁あふれしない。rows >= 1 は cv::Mat の不変条件だが、
    // 0 除算を構造的に不可能にするため明示的に確かめる。
    if (mat.rows < 1) {
        *out_status = ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                             "mat has no rows");
        return false;
    }
    if (stride > length / mat.rows) {
        *out_status = ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                             "buffer is shorter than stride * rows");
        return false;
    }

    *out_row_bytes = row_bytes;
    return true;
}

}  // namespace

extern "C" ocvu_status ocvu_mat_copy_from_buffer(ocvu_mat_handle dst,
                                                 const uint8_t* src,
                                                 int64_t src_length,
                                                 int64_t src_stride) {
    OCVU_TRY_BEGIN
    if (src == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER, "src is NULL");
    }
    cv::Mat* mat = ::ocvu::mat_table_get(dst);
    if (mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE, "dst handle is invalid");
    }

    int64_t row_bytes = 0;
    ocvu_status failure = OCVU_STATUS_OK;
    if (!validate(*mat, src_length, src_stride, &row_bytes, &failure)) {
        return failure;
    }

    for (int row = 0; row < mat->rows; ++row) {
        std::memcpy(mat->ptr(row), src + static_cast<size_t>(row * src_stride),
                    static_cast<size_t>(row_bytes));
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_mat_copy_to_buffer(ocvu_mat_handle src,
                                               uint8_t* dst,
                                               int64_t dst_length,
                                               int64_t dst_stride) {
    OCVU_TRY_BEGIN
    if (dst == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER, "dst is NULL");
    }
    cv::Mat* mat = ::ocvu::mat_table_get(src);
    if (mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE, "src handle is invalid");
    }

    int64_t row_bytes = 0;
    ocvu_status failure = OCVU_STATUS_OK;
    if (!validate(*mat, dst_length, dst_stride, &row_bytes, &failure)) {
        return failure;
    }

    for (int row = 0; row < mat->rows; ++row) {
        std::memcpy(dst + static_cast<size_t>(row * dst_stride), mat->ptr(row),
                    static_cast<size_t>(row_bytes));
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
