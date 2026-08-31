/*
 * このファイルは生成物である。手で編集しないこと。
 * 正本: bindings/spec/imgcodecs.json
 * 生成: ./tools/dev.ps1 generate
 */
#ifndef OCVU_IMGCODECS_H
#define OCVU_IMGCODECS_H

#include "opencv_unity_native.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Mat を画像形式に符号化し buffer へ書く。符号化後の大きさは呼ぶ側に分からないので 2 回呼ぶ（1 回目は buffer に NULL を渡して out_required_size に必要バイト数を受け取る。そのとき返る OCVU_STATUS_BUFFER_TOO_SMALL は失敗ではない）。buffer の所有権は最初から最後まで呼ぶ側にあり、足りなければ何も書かない。ext は .png のように先頭のドットを含む拡張子で、NULL と空文字列は拒否する。 */
OCVU_API ocvu_status ocvu_imencode(ocvu_mat_handle src, const char* ext, uint8_t* buffer, int32_t buffer_size, int32_t* out_required_size);

/* 符号化された画像 byte 列を復号して dst に入れる。dst の形状と型は結果に応じて上書きされる。data はこの呼び出しの内側でのみ読む借用で、native は保持しない。length は 1 以上 INT32_MAX 以下でなければならず、画像として解釈できない byte 列は OCVU_STATUS_OPENCV_ERROR になる（メモリは壊さない）。flags は OCVU_IMREAD_* である。 */
OCVU_API ocvu_status ocvu_imdecode(const uint8_t* data, int64_t length, int32_t flags, ocvu_mat_handle dst);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* OCVU_IMGCODECS_H */
