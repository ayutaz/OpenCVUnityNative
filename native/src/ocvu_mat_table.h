#ifndef OCVU_MAT_TABLE_H
#define OCVU_MAT_TABLE_H

#include <cstddef>

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
 * 保持してはならない — その handle が release されると無効になる。
 *
 * 一方で、**他の handle の create や release では無効にならない**。
 * Mat は table の配列とは別の場所に置いてあり、配列が伸びても本体は
 * 動かない。これが無いと、別スレッドが自分の Mat を作っただけで、
 * こちらが使用中のポインタが解放済みメモリを指すことになる
 * （native/tests/test_mat_table_stability.cpp が固定している）。
 */
cv::Mat* mat_table_get(ocvu_mat_handle handle);

/*
 * table の内部配列が確保している容量を返す（テスト用）。
 *
 * **要素数ではなく容量である。** 容量が増えることは、std::vector が
 * 再配置を行った——つまり既存の要素を新しい記憶域へ移した——ことと同値で
 * ある。要素数の増加では足りない: 容量に余りがあれば、要素を足しても
 * 既存の要素は 1 つも動かない。
 *
 * これが要る理由: test_mat_table_stability が固定しようとしている不変条件は
 * 「再配置が起きても Mat のアドレスが動かないこと」である。再配置が
 * 起きなければ、そのテストはバグが再発していても通る。「1024 個作れば
 * 再配置されるだろう」を前提にせず、起きたことを測る。
 */
size_t mat_table_slot_capacity();

/* 解放する。handle が無効なら false を返す（二重解放の検出）。 */
bool mat_table_release(ocvu_mat_handle handle);

}  // namespace ocvu

#endif  /* OCVU_MAT_TABLE_H */
