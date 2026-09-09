#pragma once

#include <cstddef>
#include <memory>
#include <opencv2/dnn.hpp>

#include "opencv_unity_native.h"

namespace ocvu {

// **Slot は値ではなく unique_ptr を持つ。**
//
// 値で持つと、表が伸びたときに再配置が起き、先に解決したポインタが
// 全部ぶら下がる。**壊れるのは伸ばした側ではなく、無関係な handle を
// 使っている側**である（M3 の PR #8 で mat_table が実際に踏んだ）。
ocvu_net_handle net_table_add(std::unique_ptr<cv::dnn::Net> net);

// 無効な handle には nullptr を返す。**落とさない。**
cv::dnn::Net* net_table_get(ocvu_net_handle handle);

// 解放できたら true。既に解放済み・未知なら false。**落とさない。**
bool net_table_remove(ocvu_net_handle handle);

// table の内部配列が確保している容量を返す（テスト用）。
//
// **要素数ではなく容量である。** ocvu_mat_table.h の同名関数とまったく
// 同じ理由で要る —— 「4096 個足せば再配置されるだろう」という前提に頼らず、
// 再配置が実際に起きたことを容量の変化で測る。test_dnn.cpp が
// net_table の 2 人目の利用者になった時点で、この table が
// test_dnn_table_stability.cpp 専用（＝常に空から始まる）という前提は
// 崩れる。容量を実測しないと、その回の実行だけ偶然 4096 個で再配置が
// 起きず、「何も検証していないテスト」が静かに緑になり得る。
size_t net_table_slot_capacity();

}  // namespace ocvu
