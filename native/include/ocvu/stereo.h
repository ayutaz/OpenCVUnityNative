/*
 * このファイルは生成物である。手で編集しないこと。
 * 正本: bindings/spec/stereo.json
 * 生成: ./tools/dev.ps1 generate
 */
#ifndef OCVU_STEREO_H
#define OCVU_STEREO_H

#include "opencv_unity_native.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 平行に並べた左右の画像から視差の画像を作って dst に入れる。dst は結果に応じて丸ごと置き換わり、入力と同じ大きさの OCVU_MAT_TYPE_16SC1（16 bit 符号つきの 1 channel）になる —— ocvu_mat_copy_to_buffer で読み出すときは 1 画素 2 バイトとして扱うこと。**値は実際の視差の 16 倍である**（OpenCV が固定小数で返す。視差が求まらなかった画素には負の値が入る）。left と right はどちらも OCVU_MAT_TYPE_8UC1 でなければならず、それ以外は OCVU_STATUS_INVALID_ARGUMENT を返す。**2 枚はあらかじめ平行化されていなければならない** —— この package は平行化を持っていないので、守らなくても誰も止めないが結果は無意味になる。algorithm は OCVU_STEREO_BM か OCVU_STEREO_SGBM で、それ以外は OCVU_STATUS_INVALID_ARGUMENT を返す —— BM は速いが粗く、SGBM は遅いが滑らかである。num_disparities は探索する視差の幅で正の 16 の倍数、block_size は照合する窓の 1 辺で 5 以上の奇数でなければならない。**この 2 つは OpenCV の要求ではなく、この ABI が自分で決めた、より厳しい契約である** —— OpenCV が同じ制限を課すのは BM だけで、SGBM は block_size も num_disparities も検査しない。両方に同じ制限をかけてあるので、algorithm を変えても呼ぶ側の引数の作り方は変わらない。左右の大きさが違う場合は OpenCV が例外を投げるので OCVU_STATUS_OPENCV_ERROR を返す。handle が無効なら OCVU_STATUS_INVALID_HANDLE。**失敗したときは dst を 1 バイトも書き換えない。** 照合器は呼び出しのたびに作り直される —— この ABI の粒度は 1 対の画像を処理することであって、照合器を保持することではない。 */
OCVU_API ocvu_status ocvu_compute_disparity(ocvu_mat_handle left, ocvu_mat_handle right, ocvu_mat_handle dst, int32_t algorithm, int32_t num_disparities, int32_t block_size);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* OCVU_STEREO_H */
