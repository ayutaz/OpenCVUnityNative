#ifndef OPENCV_UNITY_NATIVE_H
#define OPENCV_UNITY_NATIVE_H

#include <stdint.h>

/*
 * OCVU_STATIC: 実装を静的リンクする側（L1 テスト）が定義する。
 * OCVU_BUILDING_DLL: 共有ライブラリ自身のビルド時のみ定義する。
 */
#if defined(OCVU_STATIC)
#  define OCVU_API
#elif defined(_WIN32)
#  if defined(OCVU_BUILDING_DLL)
#    define OCVU_API __declspec(dllexport)
#  else
#    define OCVU_API __declspec(dllimport)
#  endif
#else
#  define OCVU_API __attribute__((visibility("default")))
#endif

/* C# 側は CallingConvention.Cdecl を使う */
#define OCVU_ABI_VERSION 1

typedef int32_t ocvu_status;

/*
 * status code の唯一の定義元。
 *
 * 追加するときはこのリストに 1 行足すだけでよい。下の定数と、
 * ocvu_get_status_count / ocvu_get_status_value が公開する表が同時に増える。
 * C# 側（CvUnity.CvStatus）へは自動では伝播しないので必ず手で追随すること。
 * 追随し忘れは L3 の StatusCodeSyncTests が赤にする。
 *
 * すべての非 OK が「失敗」ではない。OCVU_STATUS_BUFFER_TOO_SMALL は
 * サイズ問い合わせの正常な結果であって、呼び出し側の誤りではない。
 * 出力バッファを取る関数は、buffer に NULL を渡して必要サイズだけを聞く
 * 使い方を正規の経路として認めており、そのとき返るのがこの status である。
 * status を一律に例外へ変換する wrapper は、これを失敗として扱ってはならない
 * （C# 側の対応は CvNative.IsFailure）。M5 の generator もこの区別を読む前提で書くこと。
 */
#define OCVU_STATUS_LIST(X)               \
    X(OCVU_STATUS_OK,                  0) \
    X(OCVU_STATUS_INVALID_ARGUMENT,    1) \
    X(OCVU_STATUS_NULL_POINTER,        2) \
    X(OCVU_STATUS_OUT_OF_MEMORY,       3) \
    X(OCVU_STATUS_OPENCV_ERROR,        4) \
    X(OCVU_STATUS_UNKNOWN_ERROR,       5) \
    X(OCVU_STATUS_BUFFER_TOO_SMALL,    6) \
    X(OCVU_STATUS_INVALID_HANDLE,      7) \
    X(OCVU_STATUS_NOT_FOUND,           8)

#define OCVU_STATUS_ENUMERATOR_(name, value) name = value,
enum { OCVU_STATUS_LIST(OCVU_STATUS_ENUMERATOR_) };
#undef OCVU_STATUS_ENUMERATOR_

/*
 * Mat の不透明 handle。
 *
 * 生ポインタではない。上位 32 bit が世代、下位 32 bit が table の索引である。
 * 解放のたびに世代が進むので、解放済みの handle をもう一度渡しても
 * OCVU_STATUS_INVALID_HANDLE として弾かれる。生ポインタなら未定義動作になり、
 * sanitizer の無い環境（配布された Unity Player）では黙って壊れる。
 *
 * 0 は常に無効である。ゼロ初期化した変数を誤って渡した場合を確実に捕まえる。
 *
 * この handle が指すメモリは常に native が確保し native が解放する。
 * Unity が所有するメモリを指す handle は存在しない
 * （docs/abi-ownership-and-versioning.md §1）。
 *
 * スレッドについて: **別々の handle は、別々のスレッドから同時に使ってよい。**
 * handle の table は内部で保護されており、ある handle が指す Mat のアドレスは
 * 他の handle の作成・解放で動かない。
 *
 * ただし **同じ handle** を複数のスレッドから同時に渡してはならず、他の
 * スレッドが使っている最中に ocvu_mat_release を呼んでもならない。前者は
 * cv::Mat 自体のデータ競合、後者は解放済みメモリへのアクセスになる。
 * どちらも世代検査では捕まらない（規約でしか守れない。理由と経緯は
 * docs/abi-ownership-and-versioning.md §1.5）。
 */
typedef uint64_t ocvu_mat_handle;
#define OCVU_MAT_HANDLE_NONE ((ocvu_mat_handle)0)

/* OpenCV の CV_8UC1 等に対応する。ABI に cv:: の定数を露出させないための写し。 */
#define OCVU_MAT_TYPE_8UC1  0
#define OCVU_MAT_TYPE_8UC3 16
#define OCVU_MAT_TYPE_8UC4 24

/* ocvu_mat_get_info の出力。固定サイズ型のみで構成する。 */
typedef struct ocvu_mat_info {
    int32_t rows;
    int32_t cols;
    int32_t type;        /* OCVU_MAT_TYPE_* */
    int32_t channels;
    int64_t step;        /* 1 行のバイト数 */
    int64_t total_bytes; /* rows * step */
} ocvu_mat_info;

/*
 * 特徴点 1 つ。境界に出るので固定サイズ型だけで構成する。
 *
 * cv::KeyPoint をそのまま出すことはできない（C++ のクラスで、
 * layout の保証も無い）。**この struct の layout がこちら側の正本である。**
 * 実装 .cpp に static_assert を置いて大きさを固定してあり、
 * C# 側の OcvuKeyPoint とは L3 が Marshal.SizeOf で突き合わせる。
 *
 * x / y は画素座標、size は特徴点の直径、angle は度（見つからない場合は -1）、
 * response は応答の強さ、octave は検出したピラミッドの段、
 * class_id は分類の識別子（ORB は使わないので -1 になる）。
 */
typedef struct ocvu_keypoint {
    float   x;
    float   y;
    float   size;
    float   angle;
    float   response;
    int32_t octave;
    int32_t class_id;
} ocvu_keypoint;

/* ocvu_orb_detect の max_features の上限。
 * 呼ぶ側が過大な値を渡したときに native 側で確保しないための歯止めである。 */
#define OCVU_ORB_MAX_FEATURES 10000

/* cvtColor の変換コード。cv::COLOR_* の値をそのまま使う（写し間違いを避けるため
 * 実装側で static_assert する）。M2 で必要な 3 つだけを公開する。 */
#define OCVU_CVT_BGRA2BGR   1
#define OCVU_CVT_RGBA2BGRA  5
#define OCVU_CVT_BGR2GRAY   6

/* resize の補間方法。 */
#define OCVU_INTER_NEAREST  0
#define OCVU_INTER_LINEAR   1

/* imdecode の読み込み方。cv::IMREAD_* の値をそのまま使う（実装側で static_assert）。 */
#define OCVU_IMREAD_UNCHANGED (-1)
#define OCVU_IMREAD_GRAYSCALE   0
#define OCVU_IMREAD_COLOR       1

/*
 * module ごとの宣言は生成物である（bindings/spec/*.json を正本として
 * ./tools/dev.ps1 generate が書き出す）。**ここに手で足さないこと。**
 * 足しても次の generate で消える。
 *
 * ocvu/*.h はこのヘッダを include し、こちらもそれらを include するので
 * 循環するが、include guard があるので展開は止まる。ocvu/*.h 側の
 * include は、それ単体を include する利用者のために残してある。
 */
#include "ocvu/infra.h"
#include "ocvu/core.h"
#include "ocvu/imgproc.h"
#include "ocvu/imgcodecs.h"
#include "ocvu/objdetect.h"

#endif /* OPENCV_UNITY_NATIVE_H */
