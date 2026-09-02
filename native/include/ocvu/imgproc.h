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

/* src の歪みを camera_matrix と dist_coeffs で補正して dst に入れる。dst は結果に応じて丸ごと置き換わり、src と同じ形状・型になる。camera_matrix は行優先の 3x3（double 9 個）、dist_coeffs は OpenCV が受ける長さ（4 / 5 / 8 / 12 / 14 個）でなければならない。camera_matrix_length と dist_coeffs_length はどちらもバイト数で、この ABI の length は全部そうである。呼ぶ側を信用せず、長さが合わなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。失敗したときは dst を書き換えない。src と dst に同じ handle を渡してもよい（結果を求めてから入れ替えるので、cvtColor と違い in-place 呼び出しを禁じていない）。 */
OCVU_API ocvu_status ocvu_undistort(ocvu_mat_handle src, const double* camera_matrix, int64_t camera_matrix_length, const double* dist_coeffs, int64_t dist_coeffs_length, ocvu_mat_handle dst);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* OCVU_IMGPROC_H */
