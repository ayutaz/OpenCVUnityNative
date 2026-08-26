#ifndef OCVU_MAT_TABLE_H
#define OCVU_MAT_TABLE_H

#include <opencv2/core.hpp>

#include "opencv_unity_native.h"

namespace ocvu {

/*
 * Mat を table に入れて handle を返す。handle は世代 + 索引である。
 * 確保できない場合は OCVU_MAT_HANDLE_NONE を返す。
 */
ocvu_mat_handle mat_table_acquire(cv::Mat mat);

/*
 * handle に対応する Mat を返す。世代が合わない（解放済み）、索引が範囲外、
 * handle が 0 のいずれかなら nullptr を返す。
 *
 * 戻り値は table が所有する Mat への借用ポインタである。呼び出し側は
 * 保持してはならない — 同じスレッドで release されると無効になる。
 */
cv::Mat* mat_table_get(ocvu_mat_handle handle);

/* 解放する。handle が無効なら false を返す（二重解放の検出）。 */
bool mat_table_release(ocvu_mat_handle handle);

}  // namespace ocvu

#endif  /* OCVU_MAT_TABLE_H */
