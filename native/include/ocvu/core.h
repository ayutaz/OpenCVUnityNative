/*
 * このファイルは生成物である。手で編集しないこと。
 * 正本: bindings/spec/core.json
 * 生成: ./tools/dev.ps1 generate
 */
#ifndef OCVU_CORE_H
#define OCVU_CORE_H

#include "opencv_unity_native.h"

#ifdef __cplusplus
extern "C" {
#endif

/* rows x cols、指定 type の Mat を確保し、handle を out_handle に書く。rows / cols が 1 未満、または type が未知なら OCVU_STATUS_INVALID_ARGUMENT を返し out_handle は変更しない。out_handle が NULL なら OCVU_STATUS_NULL_POINTER。 */
OCVU_API ocvu_status ocvu_mat_create(int32_t rows, int32_t cols, int32_t type, ocvu_mat_handle* out_handle);

/* handle を解放する。解放済み、または未知の handle なら OCVU_STATUS_INVALID_HANDLE を返す（落とさない）。 */
OCVU_API ocvu_status ocvu_mat_release(ocvu_mat_handle handle);

/* src の内容を複製した独立の handle を作る。src と複製は別の記憶域を持つ。 */
OCVU_API ocvu_status ocvu_mat_clone(ocvu_mat_handle src, ocvu_mat_handle* out_handle);

/* handle の形状を out_info に書く。out_info が NULL なら OCVU_STATUS_NULL_POINTER。 */
OCVU_API ocvu_status ocvu_mat_get_info(ocvu_mat_handle handle, ocvu_mat_info* out_info);

/* 外部 buffer から Mat へコピーする。src は呼び出しの内側でだけ読む借用で、戻った後 native は一切保持しない。長さと stride は書く前にすべて検証し、1 つでも合わなければ何も書かずに返す。src_stride は Mat の step と異なってよく、行ごとにコピーする。 */
OCVU_API ocvu_status ocvu_mat_copy_from_buffer(ocvu_mat_handle dst, const uint8_t* src, int64_t src_length, int64_t src_stride);

/* Mat から外部 buffer へコピーする。借用と検証の規則は ocvu_mat_copy_from_buffer と同じである。 */
OCVU_API ocvu_status ocvu_mat_copy_to_buffer(ocvu_mat_handle src, uint8_t* dst, int64_t dst_length, int64_t dst_stride);

/* src の 1 つの channel を取り出して dst に入れる。dst は結果に応じて丸ごと置き換わり、src と同じ大きさの 1 channel になる。channel_index は 0 以上かつ src の channel 数未満でなければならず、範囲外なら OCVU_STATUS_INVALID_ARGUMENT を返す。src と dst に同じ handle を渡してはならない（自分自身から channel を取り出す意味が無いので OCVU_STATUS_INVALID_ARGUMENT を返す）。handle が無効なら OCVU_STATUS_INVALID_HANDLE で、この判定は同じ handle かどうかの判定より先に行う。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返す。失敗したときは dst を書き換えない。 */
OCVU_API ocvu_status ocvu_extract_channel(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t channel_index);

/* src（1 channel）を dst の 1 つの channel へ差し込む。dst は置き換わるのではなく、その channel だけが書き換わる —— これはこの ABI で dst を丸ごと置き換えない唯一の関数である。src は 1 channel で、dst と同じ大きさ・同じ要素型でなければならない（違えば OpenCV が例外を投げるので OCVU_STATUS_OPENCV_ERROR になる）。channel_index は 0 以上かつ dst の channel 数未満でなければならず、範囲外なら OCVU_STATUS_INVALID_ARGUMENT を返す。src と dst に同じ handle を渡してはならない。handle が無効なら OCVU_STATUS_INVALID_HANDLE で、この判定は同じ handle かどうかの判定より先に行う。失敗したときは dst を 1 バイトも書き換えない。 */
OCVU_API ocvu_status ocvu_insert_channel(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t channel_index);

/* src の最小値・最大値と、それぞれが最初に現れる位置を返す。位置は out_min_x / out_min_y / out_max_x / out_max_y に画素座標で書く。6 つの出力はどれも NULL でよい（最大値だけ欲しいことは普通にある）が、6 つとも NULL なら OCVU_STATUS_NULL_POINTER を返す —— 何も受け取らずに計算だけさせる意味が無いためである。どの失敗経路でも、NULL でないすべての出力に 0 を書く。位置の 4 つがすべて NULL なら OpenCV にも位置を要求しないので、複数 channel の src でも値だけなら取得できる（値は全 channel を通した最小・最大である）。複数 channel で位置を 1 つでも要求すると、位置が一意に決まらないので OpenCV が拒み OCVU_STATUS_OPENCV_ERROR になる。handle が無効なら OCVU_STATUS_INVALID_HANDLE。出力の所有権は最初から最後まで呼ぶ側にある。 */
OCVU_API ocvu_status ocvu_min_max_loc(ocvu_mat_handle src, double* out_min_value, double* out_max_value, int32_t* out_min_x, int32_t* out_min_y, int32_t* out_max_x, int32_t* out_max_y);

/* src の各画素が lower と upper の間（両端を含む）にあるかを調べ、入っていれば 255、外れていれば 0 を dst に書く。dst は結果に応じて丸ごと置き換わり、src と同じ大きさの 8 bit 1 channel になる。lower と upper は src の channel 数ぶんの double を並べた配列で、lower_length と upper_length はその バイト数 である（要素数でも channel 数でもない）。呼ぶ側を信用せず、src の channel 数ぶんに満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。複数 channel の場合は、すべての channel が範囲に入っている画素だけが 255 になる。src と dst に同じ handle を渡してもよい。lower か upper が NULL なら OCVU_STATUS_NULL_POINTER、handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、失敗したときは dst を書き換えない。 */
OCVU_API ocvu_status ocvu_in_range(ocvu_mat_handle src, ocvu_mat_handle dst, const double* lower, int64_t lower_length, const double* upper, int64_t upper_length);

/* src の値域を正規化して dst に入れる。dst は結果に応じて丸ごと置き換わり、src と同じ型になる（この ABI は型変換を持ち込まないので、出力の型を選ぶ引数を出していない）。norm_type は OCVU_NORM_INF / OCVU_NORM_L1 / OCVU_NORM_L2 / OCVU_NORM_MINMAX のいずれかで、それ以外は OCVU_STATUS_INVALID_ARGUMENT を返す —— OCVU_NORM_HAMMING は記述子どうしの距離を測るためのもので、ここでは受け付けない。OCVU_NORM_MINMAX のときは値域を alpha と beta の間へ線形に写す（画像を見えるようにするのはふつうこれである）。他の 3 つのときは指定したノルムが alpha になるように割り、beta は使わない。src と dst に同じ handle を渡してもよい。handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、失敗したときは dst を書き換えない。 */
OCVU_API ocvu_status ocvu_normalize(ocvu_mat_handle src, ocvu_mat_handle dst, double alpha, double beta, int32_t norm_type);

/* src1 と src2 のビット演算（AND / OR / XOR）、または src1 のビット反転（NOT）を dst に入れる。dst は結果に応じて丸ごと置き換わり、src1 と同じ形状・型になる。op は OCVU_BITWISE_AND / OCVU_BITWISE_OR / OCVU_BITWISE_XOR / OCVU_BITWISE_NOT のいずれかで、それ以外は OCVU_STATUS_INVALID_ARGUMENT を返す。OCVU_BITWISE_NOT のときは src2 を一切見ない —— 無効な handle を渡しても成功する（黙って無視するのではなく、そう決めてある）。他の 3 つでは src2 の handle が無効なら OCVU_STATUS_INVALID_HANDLE を返す。src1 と src2 は同じ形状・同じ型でなければならず、違えば OCVU_STATUS_INVALID_ARGUMENT を返す —— **この検査はこの ABI が自分で行う。** OpenCV に任せると、src2 が 1 要素のときにそれを scalar とみなして全画素へ黙って展開し、OCVU_STATUS_OK ともっともらしい結果を返すためである（実測）。src と dst に同じ handle を渡してもよい。失敗したときは dst を書き換えない。 */
OCVU_API ocvu_status ocvu_bitwise(ocvu_mat_handle src1, ocvu_mat_handle src2, ocvu_mat_handle dst, int32_t op);

/* src の各画素の値を表で引いた値に置き換えて dst に入れる。dst は結果に応じて丸ごと置き換わり、src と同じ形状・型になる。table は 8 bit の値域（0 から 255）を全部覆う 256 バイト以上でなければならず、table_length はその バイト数 である（読むのは先頭の 256 バイトだけで、それより長い分は使わない）。256 に満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。src は 8 bit でなければならず、そうでなければ OpenCV が例外を投げるので OCVU_STATUS_OPENCV_ERROR になる。複数 channel の src には同じ表がすべての channel に適用される。table が NULL なら OCVU_STATUS_NULL_POINTER、handle が無効なら OCVU_STATUS_INVALID_HANDLE。src と dst に同じ handle を渡してもよい。失敗したときは dst を書き換えない。 */
OCVU_API ocvu_status ocvu_lut(ocvu_mat_handle src, ocvu_mat_handle dst, const uint8_t* table, int64_t table_length);

/* src の周囲に余白を足して dst に入れる。dst は結果に応じて丸ごと置き換わり、高さが src の高さ + top + bottom、幅が src の幅 + left + right で、src と同じ型になる。top / bottom / left / right はいずれも 0 以上でなければならず、負なら OCVU_STATUS_INVALID_ARGUMENT を返す。出来上がりの高さか幅が int32_t に収まらない場合も OCVU_STATUS_INVALID_ARGUMENT を返す（OpenCV に渡すと int の中で桁あふれする）。border_type は OCVU_BORDER_CONSTANT / OCVU_BORDER_REPLICATE / OCVU_BORDER_REFLECT / OCVU_BORDER_WRAP / OCVU_BORDER_REFLECT_101 のいずれかで、それ以外は拒否する。border_value は OCVU_BORDER_CONSTANT のときにだけ使う埋め値で、全 channel に同じ値が入る（channel ごとに違う値を入れる経路は出していない）。src と dst に同じ handle を渡してもよい。handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、失敗したときは dst を書き換えない。 */
OCVU_API ocvu_status ocvu_copy_make_border(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t top, int32_t bottom, int32_t left, int32_t right, int32_t border_type, double border_value);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* OCVU_CORE_H */
