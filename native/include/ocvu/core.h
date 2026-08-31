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

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* OCVU_CORE_H */
