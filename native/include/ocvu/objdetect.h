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

/* src に写っている QR コードを 1 つ検出して復号し、NUL 終端の UTF-8 byte 列として buffer へ書く。復号後の長さは呼ぶ側に分からないので 2 回呼ぶ（1 回目は buffer に NULL を渡して out_required_size に NUL を含む必要バイト数を受け取る。そのとき返る OCVU_STATUS_BUFFER_TOO_SMALL は失敗ではない）。buffer の所有権は最初から最後まで呼ぶ側にあり、足りなければ何も書かない。QR が写っていなければ OCVU_STATUS_NOT_FOUND を返し、これは誤りではない。 */
OCVU_API ocvu_status ocvu_qr_decode(ocvu_mat_handle src, char* buffer, int32_t buffer_size, int32_t* out_required_size);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* OCVU_OBJDETECT_H */
