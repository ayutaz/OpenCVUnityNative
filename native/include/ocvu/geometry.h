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

/* 2 組の点の対応から射影変換（3x3）を求めて dst に入れる。dst は結果に応じて丸ごと置き換わり、64 bit 1 channel の 3x3 になる。src_points と dst_points はどちらも x と y が交互に並ぶ float の配列で、src_length と dst_length はその配列の**バイト数**である（要素数でも点数でもない —— この ABI の length はすべてバイト数で統一してある）。**呼ぶ側を信用せず、長さが point_count * 2 * sizeof(float) に満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。** point_count は 4 以上でなければならない（4 点未満では射影変換が決まらない）。method は OCVU_HOMOGRAPHY_METHOD_* のいずれかで、それ以外は拒否する。ransac_threshold は RANSAC のときだけ使う画素単位のしきい値である。点が退化していて解が求まらないときは OCVU_STATUS_NOT_FOUND を返し、これは誤りではない（どの入力がそうなるかは OpenCV が決める。実測では全部同じ点と軸に平行な直線が NOT_FOUND で、斜めの直線は rank 不足の行列がそのまま返り OCVU_STATUS_OK になる —— 共線判定はしていない）。失敗したときは dst を書き換えない。 */
OCVU_API ocvu_status ocvu_find_homography(const float* src_points, int64_t src_length, const float* dst_points, int64_t dst_length, int32_t point_count, int32_t method, double ransac_threshold, ocvu_mat_handle dst);

/* 既知の 3D 点と、その画像上の対応点、カメラの内部パラメータから 1 枚ぶんの姿勢を求める。object_points は 1 点 3 float（x, y, z）、image_points は 1 点 2 float（x, y）で、同じ順に並べる。object_points_length と image_points_length と camera_matrix_length と dist_coeffs_length はいずれもその配列の**バイト数**である（要素数でも点数でもない —— この ABI の length はすべてバイト数で統一してある）。**呼ぶ側を信用せず、長さが必要量に満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。** point_count は 4 以上 OCVU_PNP_MAX_POINTS 以下でなければならない。camera_matrix は行優先の 3x3（double 9 個）である。dist_coeffs は長さ 0 で「歪み無し」を指定でき、そのとき NULL を渡してよい。長さが 0 でないのに NULL なら OCVU_STATUS_NULL_POINTER を返し、長さが 0 でないなら OpenCV が受ける個数（4 / 5 / 8 / 12 / 14 個の double）でなければならない。method は OCVU_SOLVEPNP_* のいずれかで、それ以外は拒否する。出力の rvec_capacity と tvec_capacity は**配列の要素数**で（バイト数ではない）、どちらも 3 以上が要る —— 足りなければ**何も書かずに** OCVU_STATUS_BUFFER_TOO_SMALL を返す。out_rvec は Rodrigues の回転ベクトル（向きが回転軸、長さが回転角のラジアン）、out_tvec は並進で、単位は object_points に渡したものと同じである。camera_matrix の [0] と [4]（fx と fy）はどちらも 0 であってはならず、0 なら OCVU_STATUS_INVALID_ARGUMENT を返す —— OpenCV は焦点距離が 0 のカメラ行列を検出せず、有限だが無意味な姿勢を成功として返すためである（実測）。これは一般的な特異性の検査ではなく、見ているのはその 2 要素だけである。姿勢が求まらないとき、および求まった 6 つの値のいずれかが有限でないときは OCVU_STATUS_NOT_FOUND を返し、これは誤りではない。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、その理由は last-error のメッセージに入る。**どの失敗経路でも out_rvec と out_tvec は 1 バイトも書き換えない。** これらの所有権は最初から最後まで呼ぶ側にある。 */
OCVU_API ocvu_status ocvu_solve_pnp(const float* object_points, int64_t object_points_length, const float* image_points, int64_t image_points_length, int32_t point_count, const double* camera_matrix, int64_t camera_matrix_length, const double* dist_coeffs, int64_t dist_coeffs_length, int32_t method, double* out_rvec, int32_t rvec_capacity, double* out_tvec, int32_t tvec_capacity);

/* Rodrigues の回転ベクトル（3 要素。向きが回転軸、長さが回転角のラジアン）を 3x3 の回転行列に直し、行優先で out_matrix へ書く。rotation_vector_length は入力配列の**バイト数**で（要素数ではない）、double 3 個ぶんに満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。matrix_capacity は出力配列の**要素数**で（バイト数ではない）、9 未満なら**何も書かずに** OCVU_STATUS_BUFFER_TOO_SMALL を返す。ポインタが NULL なら OCVU_STATUS_NULL_POINTER を返す。OpenCV が例外を投げた場合、および結果が 3x3 でなかった場合は OCVU_STATUS_OPENCV_ERROR を返す。**どの失敗経路でも out_matrix は 1 バイトも書き換えない。** out_matrix の所有権は最初から最後まで呼ぶ側にある。 */
OCVU_API ocvu_status ocvu_rodrigues_to_matrix(const double* rotation_vector, int64_t rotation_vector_length, double* out_matrix, int32_t matrix_capacity);

/* 3x3 の回転行列（行優先の double 9 個）を Rodrigues の回転ベクトル（3 要素）に直して out_vector へ書く。rotation_matrix_length は入力配列の**バイト数**で（要素数ではない）、double 9 個ぶんに満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。vector_capacity は出力配列の**要素数**で（バイト数ではない）、3 未満なら**何も書かずに** OCVU_STATUS_BUFFER_TOO_SMALL を返す。ポインタが NULL なら OCVU_STATUS_NULL_POINTER を返す。入力が回転行列でない場合の扱いは OpenCV に委ねており、例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返す。**どの失敗経路でも out_vector は 1 バイトも書き換えない。** out_vector の所有権は最初から最後まで呼ぶ側にある。 */
OCVU_API ocvu_status ocvu_rodrigues_to_vector(const double* rotation_matrix, int64_t rotation_matrix_length, double* out_vector, int32_t vector_capacity);

/* 3D の点を、与えた姿勢とカメラの内部パラメータで画像平面へ投影する。object_points は 1 点 3 float（x, y, z）で、object_points_length と rvec_length と tvec_length と camera_matrix_length と dist_coeffs_length はいずれもその配列の**バイト数**である（要素数でも点数でもない）。**呼ぶ側を信用せず、長さが必要量に満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。** point_count は 1 以上 OCVU_PNP_MAX_POINTS 以下でなければならない（姿勢は与えられているので 4 点は要らない）。rvec は Rodrigues の回転ベクトル（3 要素）、tvec は並進（3 要素）、camera_matrix は行優先の 3x3（9 要素）である。camera_matrix の [0] と [4]（fx と fy）はどちらも 0 であってはならず、0 なら OCVU_STATUS_INVALID_ARGUMENT を返す（ocvu_solve_pnp と同じ理由である）。dist_coeffs は長さ 0 で歪み無しを指定でき、そのとき NULL を渡してよい。長さが 0 でないのに NULL なら OCVU_STATUS_NULL_POINTER を返し、長さが 0 でないなら 4 / 5 / 8 / 12 / 14 個の double でなければならない。out_capacity は出力配列の**要素数**で（バイト数ではない）、point_count の 2 倍未満なら**何も書かずに** OCVU_STATUS_BUFFER_TOO_SMALL を返す。出力は x と y が交互に並ぶ float である。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返す。**どの失敗経路でも out_image_points は 1 バイトも書き換えない。** out_image_points の所有権は最初から最後まで呼ぶ側にある。 */
OCVU_API ocvu_status ocvu_project_points(const float* object_points, int64_t object_points_length, int32_t point_count, const double* rvec, int64_t rvec_length, const double* tvec, int64_t tvec_length, const double* camera_matrix, int64_t camera_matrix_length, const double* dist_coeffs, int64_t dist_coeffs_length, float* out_image_points, int32_t out_capacity);

/* ちょうど 4 点の対応から射影変換（3x3）を厳密に求めて dst に入れる。dst は結果に応じて丸ごと置き換わり、OCVU_MAT_TYPE_64FC1 の 3x3 になる。src_points と dst_points はどちらも x と y が交互に並ぶ float 8 個（4 点）で、src_length と dst_length はその配列のバイト数である（要素数でも点数でもない —— この ABI の length はすべてバイト数で統一してある）。呼ぶ側を信用せず、4 点ぶん（32 バイト）に満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。それより長い配列は通し、先頭の 4 点だけを読む。ocvu_find_homography との違いは、こちらがちょうど 4 点を厳密に通すのに対し、あちらは 4 点以上から当てはめる点である —— 外れ値がありうる対応には ocvu_find_homography を使うこと。求めた行列は ocvu_warp_perspective にそのまま渡せる。src_points か dst_points が NULL なら OCVU_STATUS_NULL_POINTER。dst の handle が無効なら OCVU_STATUS_INVALID_HANDLE。点が退化しているときに何が起きるかは OpenCV が決める —— 例外を投げた場合と空の行列を返した場合はどちらも OCVU_STATUS_OPENCV_ERROR を返すが、退化した 4 点で必ずそのどちらかになるとは約束しない（ocvu_find_homography と違い、そこは実測していない）。失敗したときは dst を書き換えない。 */
OCVU_API ocvu_status ocvu_get_perspective_transform(const float* src_points, int64_t src_length, const float* dst_points, int64_t dst_length, ocvu_mat_handle dst);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* OCVU_GEOMETRY_H */
