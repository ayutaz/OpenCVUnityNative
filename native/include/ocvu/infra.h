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

/* 直近のエラーメッセージを UTF-8・NUL 終端で buffer に書く。buffer に NULL を渡して必要サイズだけを聞くのが正規の 1 回目で、そのとき返る OCVU_STATUS_BUFFER_TOO_SMALL は失敗ではない。out_required_size が NULL なら OCVU_STATUS_NULL_POINTER。この関数自身は last-error を変更しない。 */
/* 例外バリアで囲まない: OCVU_TRY_BEGIN は clear_last_error() を呼ぶので、報告すべきエラーを自分で消してしまう */
OCVU_API ocvu_status ocvu_get_last_error_message(char* buffer, int32_t buffer_size, int32_t* out_required_size);

/* ネイティブ側が定義している status code の個数を返す。失敗しない。C# の CvStatus との同期を L3 で検証するために公開している。 */
/* 例外バリアで囲まない: ocvu_status を返さないので囲めない */
OCVU_API int32_t ocvu_get_status_count(void);

/* index 番目の status code の数値を out_value に書く。並び順は OCVU_STATUS_LIST の記述順。範囲外の index は OCVU_STATUS_INVALID_ARGUMENT、out_value が NULL なら OCVU_STATUS_NULL_POINTER。 */
OCVU_API ocvu_status ocvu_get_status_value(int32_t index, int32_t* out_value);

/* リンクされている OpenCV のバージョン文字列（例 5.0.0）を UTF-8 で書く。バッファ規約は ocvu_get_last_error_message と同一である。 */
OCVU_API ocvu_status ocvu_get_opencv_version(char* buffer, int32_t buffer_size, int32_t* out_required_size);

/* cv::getBuildInformation() の内容を UTF-8 で書く。どの依存が有効なリンクになっているかを実行時に確認するために使う。バッファ規約は ocvu_get_opencv_version と同一である。 */
OCVU_API ocvu_status ocvu_get_build_information(char* buffer, int32_t buffer_size, int32_t* out_required_size);

/* conformance test 用に、内部で意図的に例外を投げる。kind は 0 が std::runtime_error、1 が std::bad_alloc、2 が非標準例外、3 が投げない。例外が ABI 境界を越えないことの検証に使う。 */
OCVU_API ocvu_status ocvu_debug_throw(int32_t kind);

/* conformance test 用に、意図的にプロセスを壊す。kind は 0 が不正アクセスで即死、1 が戻ってこない（無限ループ）。managed 側からネイティブが死んだときに L3 が有限時間で赤くなるかを確かめるためだけに存在し、通常の経路からは決して呼ばれない。 */
/* 例外バリアで囲まない: 戻ってこないので status に変換する相手がいない */
OCVU_API void ocvu_debug_crash(int32_t kind);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* OCVU_INFRA_H */
