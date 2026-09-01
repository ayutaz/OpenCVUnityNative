/*
 * このファイルは生成物である。手で編集しないこと。
 * 正本: bindings/spec/features.json
 * 生成: ./tools/dev.ps1 generate
 */
#ifndef OCVU_FEATURES_H
#define OCVU_FEATURES_H

#include "opencv_unity_native.h"

#ifdef __cplusplus
extern "C" {
#endif

/* src から ORB の特徴点を検出して out_keypoints へ書き、見つかった個数を out_count に返す。呼ぶ側は必要量を事前に知り得るので 2 回呼ぶ必要は無い（上限は max_features で、capacity がそれに満たなければ何も書かずに OCVU_STATUS_BUFFER_TOO_SMALL を返し out_count に max_features を入れる）。max_features は 1 以上 OCVU_ORB_MAX_FEATURES 以下でなければならない。buffer の所有権は最初から最後まで呼ぶ側にある。 */
OCVU_API ocvu_status ocvu_orb_detect(ocvu_mat_handle src, int32_t max_features, ocvu_keypoint* out_keypoints, int32_t capacity, int32_t* out_count);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* OCVU_FEATURES_H */
