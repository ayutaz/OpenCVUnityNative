/*
 * このファイルは生成物である。手で編集しないこと。
 * 正本: bindings/spec/imgproc.json
 * 生成: ./tools/dev.ps1 generate
 */
#ifndef OCVU_IMGPROC_H
#define OCVU_IMGPROC_H

#include "opencv_unity_native.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 色空間を変換する。dst の形状と型は結果に応じて上書きされる。src と dst が同じ handle なら OCVU_STATUS_INVALID_ARGUMENT を返す（OpenCV の in-place 対応は関数ごとに異なり、曖昧さを ABI に持ち込まない）。OpenCV 由来の失敗は OCVU_STATUS_OPENCV_ERROR になる。 */
OCVU_API ocvu_status ocvu_cvt_color(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t code);

/* width x height に拡大縮小する。width / height が 1 未満なら OCVU_STATUS_INVALID_ARGUMENT。src と dst に同じ handle を渡した場合も同様に拒否する。 */
OCVU_API ocvu_status ocvu_resize(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t width, int32_t height, int32_t interpolation);

/* Gaussian ぼかしを掛ける。ksize は正の奇数でなければならず、そうでなければ OCVU_STATUS_INVALID_ARGUMENT。sigma に 0 を渡すと OpenCV が ksize から算出する。 */
OCVU_API ocvu_status ocvu_gaussian_blur(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t ksize_width, int32_t ksize_height, double sigma_x, double sigma_y);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* OCVU_IMGPROC_H */
