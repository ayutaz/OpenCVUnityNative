/*
 * このファイルは生成物である。手で編集しないこと。
 * 正本: bindings/spec/geometry.json
 * 生成: ./tools/dev.ps1 generate
 */
#ifndef OCVU_GEOMETRY_H
#define OCVU_GEOMETRY_H

#include "opencv_unity_native.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 2 組の点の対応から射影変換（3x3）を求めて dst に入れる。dst は結果に応じて丸ごと置き換わり、64 bit 1 channel の 3x3 になる。src_points と dst_points はどちらも x と y が交互に並ぶ float の配列で、src_length と dst_length はその要素数である（点数ではない）。**呼ぶ側を信用せず、長さが point_count の 2 倍に満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。** point_count は 4 以上でなければならない（4 点未満では射影変換が決まらない）。method は OCVU_HOMOGRAPHY_METHOD_* のいずれかで、それ以外は拒否する。ransac_threshold は RANSAC のときだけ使う画素単位のしきい値である。点が退化していて解が求まらないときは OCVU_STATUS_NOT_FOUND を返し、これは誤りではない。失敗したときは dst を書き換えない。 */
OCVU_API ocvu_status ocvu_find_homography(const float* src_points, int64_t src_length, const float* dst_points, int64_t dst_length, int32_t point_count, int32_t method, double ransac_threshold, ocvu_mat_handle dst);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* OCVU_GEOMETRY_H */
