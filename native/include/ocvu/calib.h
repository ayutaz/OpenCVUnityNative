/*
 * このファイルは生成物である。手で編集しないこと。
 * 正本: bindings/spec/calib.json
 * 生成: ./tools/dev.ps1 generate
 */
#ifndef OCVU_CALIB_H
#define OCVU_CALIB_H

#include "opencv_unity_native.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 複数の view から撮った既知の立体パターン（通常はチェスボード）の対応点から、カメラの内部パラメータと歪み係数、および各 view の姿勢を求める。object_points は 1 点 3 float（x, y, z）、image_points は 1 点 2 float（x, y）で、**どちらも view-major に並べる**（1 枚目の全点、続いて 2 枚目の全点、…）。object_points_length と image_points_length はその配列の**バイト数**である（要素数でも点数でもない —— この ABI の length はすべてバイト数で統一してある）。**呼ぶ側を信用せず、長さが必要量に満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。** view_count は 2 以上、points_per_view は 4 以上でなければならず、その積が OCVU_CALIB_MAX_POINTS を超える場合も OCVU_STATUS_INVALID_ARGUMENT を返す（int32 の乗算オーバーフローを避けるための歯止めであり、実用上の校正がこれを超えることは無い）。image_width と image_height はどちらも 1 以上でなければならない。出力の capacity は 3 つとも**配列の要素数**である（バイト数ではない）—— out_camera_matrix は 9 以上（3x3 を行優先で書く）、out_view_poses は view_count * 6 以上（**1 view につき 6 個で、回転ベクトル 3 個のあとに並進ベクトル 3 個が続く**）、out_dist_coeffs は OpenCV が返す係数の個数以上が要る。どれか 1 つでも足りなければ**何も書かずに** OCVU_STATUS_BUFFER_TOO_SMALL を返す。成功したときは書いた歪み係数の個数を out_dist_coeffs_count に、再投影誤差（RMS、画素）を out_rms に入れる。**これらいずれの失敗経路でも out_dist_coeffs_count には 0 を書く。** out_camera_matrix / out_dist_coeffs / out_view_poses / out_rms の所有権は最初から最後まで呼ぶ側にある。 */
OCVU_API ocvu_status ocvu_calibrate_camera(const float* object_points, int64_t object_points_length, const float* image_points, int64_t image_points_length, int32_t view_count, int32_t points_per_view, int32_t image_width, int32_t image_height, double* out_camera_matrix, int32_t camera_matrix_capacity, double* out_dist_coeffs, int32_t dist_coeffs_capacity, int32_t* out_dist_coeffs_count, double* out_view_poses, int32_t view_poses_capacity, double* out_rms);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* OCVU_CALIB_H */
