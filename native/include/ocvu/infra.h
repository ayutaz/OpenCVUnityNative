/*
 * このファイルは生成物である。手で編集しないこと。
 * 正本: bindings/spec/infra.json
 * 生成: ./tools/dev.ps1 generate
 */
#ifndef OCVU_INFRA_H
#define OCVU_INFRA_H

#include "opencv_unity_native.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 現在の C ABI バージョンを返す。失敗しない。 */
/* 例外バリアで囲まない: ocvu_status を返さないので囲めない */
OCVU_API int32_t ocvu_get_abi_version(void);

/* 直近のエラー status を返す。呼び出しスレッドごとに独立している。 */
/* 例外バリアで囲まない: OCVU_TRY_BEGIN は clear_last_error() を呼ぶので、報告すべきエラーを自分で消してしまう */
OCVU_API ocvu_status ocvu_get_last_error_status(void);

/* status 表の件数を返す。 */
/* 例外バリアで囲まない: ocvu_status を返さないので囲めない */
OCVU_API int32_t ocvu_get_status_count(void);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* OCVU_INFRA_H */
