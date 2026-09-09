#pragma once

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

}  // namespace ocvu
