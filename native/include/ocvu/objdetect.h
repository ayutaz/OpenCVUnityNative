/*
 * このファイルは生成物である。手で編集しないこと。
 * 正本: bindings/spec/objdetect.json
 * 生成: ./tools/dev.ps1 generate
 */
#ifndef OCVU_OBJDETECT_H
#define OCVU_OBJDETECT_H

#include "opencv_unity_native.h"

#ifdef __cplusplus
extern "C" {
#endif

/* text を QR コードの画像に符号化して dst に入れる。dst の形状と型は結果に応じて上書きされ、8 bit 1 channel の正方形になる。text は NUL 終端の UTF-8 byte 列で、NULL と空文字列は拒否する。符号化できない長さの text は OCVU_STATUS_OPENCV_ERROR になる。失敗したときは dst を書き換えない。 */
OCVU_API ocvu_status ocvu_qr_encode(const char* text, ocvu_mat_handle dst);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* OCVU_OBJDETECT_H */
