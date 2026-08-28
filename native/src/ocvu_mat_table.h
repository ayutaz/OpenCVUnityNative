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
 * table が確保した slot の総数を返す（テスト用）。
 *
 * 解放しても減らない — 索引は free list に戻って再利用されるだけである。
 * つまりこの値が増えたことは、内部の配列が実際に伸びたことを意味する。
 *
 * これが要る理由: test_mat_table_stability は「たくさん作れば配列が伸びる
 * だろう」という前提で書かれていた。前提が崩れても（例えば他のテストが
 * 大量の索引を free list に残すようになっても）テストは緑のまま、
 * 何も検証しなくなる。伸びたことを数えれば、前提ではなく実測になる。
 */
size_t mat_table_slot_count();

/* 解放する。handle が無効なら false を返す（二重解放の検出）。 */
bool mat_table_release(ocvu_mat_handle handle);

}  // namespace ocvu

#endif  /* OCVU_MAT_TABLE_H */
