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

/*
 * ABI に出す Mat の型。
 *
 * **これは OpenCV の値の写しではない。** ocvu_mat.cpp の 2 つの switch が
 * 翻訳するので、cv:: の値と一致している必要が無い —— OCVU_CVT_* や
 * OCVU_THRESH_* が「OpenCV の値をそのまま出す」のとは扱いが違う。
 *
 * **16 と 24 は OpenCV 4 の CV_8UC3 / CV_8UC4 の値である。** OpenCV 5 は
 * CV_CN_SHIFT を 3 から 5 に変えたので、いまの CV_8UC3 は 64 である
 * （2026-09-05 に実測。static_assert を置こうとして落ちて分かった）。
 * **値を合わせ直すことはしない** —— 境界に出ている番号を変えるのは
 * 破壊的変更で、OCVU_ABI_VERSION の bump が要る。
 */
#define OCVU_MAT_TYPE_8UC1  0
#define OCVU_MAT_TYPE_8UC3 16
#define OCVU_MAT_TYPE_8UC4 24

/*
 * 8 bit ではない 1 channel の 3 つ。
 *
 * **これらは「画像」ではなく、OpenCV の関数が返す中間結果である。**
 * ocvu_compute_disparity は 16 bit 符号つき（視差 x 16）、
 * ocvu_match_template は 32 bit 浮動小数（照合の応答）、
 * ocvu_get_perspective_transform は 64 bit 浮動小数（3x3 の変換）を返す。
 *
 * **足した理由は「読めるようにするため」である。** 足す前は from_cv_type が
 * これらに -1 を返し、それでも ocvu_mat_get_info は OCVU_STATUS_OK を返して
 * いた —— 呼ぶ側は「型が -1 の Mat」を受け取り、1 画素が何バイトかを
 * 知る手立てが無かった。**status では気づけず、読み出した byte 列の解釈だけが
 * 静かに狂う**形だったので、名前を与えて閉じた。
 *
 * **この 3 つは偶然 OpenCV 5 の値と一致している**（CV_16SC1 = 3 など）が、
 * 上の 3 つと同じく**翻訳表が正本である。** 一致を根拠にしないこと。
 */
#define OCVU_MAT_TYPE_16SC1  3
#define OCVU_MAT_TYPE_32FC1  5
#define OCVU_MAT_TYPE_64FC1  6

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

/* ocvu_find_homography の method。OpenCV の値をそのまま出す
 * （実装 .cpp の static_assert が写し間違いをコンパイル時に落とす）。
 *
 * DEFAULT は全点を使う最小二乗で、外れ値があると引きずられる。
 * RANSAC と LMEDS は外れ値を捨てる —— 特徴点の対応のように
 * 誤対応が混ざる入力ではそちらを使う。 */
#define OCVU_HOMOGRAPHY_METHOD_DEFAULT 0
#define OCVU_HOMOGRAPHY_METHOD_LMEDS   4
#define OCVU_HOMOGRAPHY_METHOD_RANSAC  8

/* ocvu_orb_detect の max_features の上限。
 * 呼ぶ側が過大な値を渡したときに native 側で確保しないための歯止めである。 */
#define OCVU_ORB_MAX_FEATURES 10000

/* ocvu_find_chessboard_corners の pattern_cols * pattern_rows（点の個数）の上限。
 * これを縛らないと、大きな pattern_cols / pattern_rows で int32_t の乗算が
 * 符号付きオーバーフロー（未定義動作）を起こしうる。実用上のチェスボード
 * パターン（せいぜい数十 x 数十）はこれを大きく下回る。 */
#define OCVU_CHESSBOARD_MAX_CORNERS 10000

/* ocvu_calibrate_camera の view_count * points_per_view（点の総数）の上限。
 * OCVU_CHESSBOARD_MAX_CORNERS と同じ理由で、int32_t の乗算が符号付き
 * オーバーフロー（未定義動作）を起こさないための歯止めである。校正は
 * 1 枚ぶんではなく複数 view の総数を扱うので、上限は 1 桁大きく取る
 * （20 枚 x 大きめの盤でもこれには届かない）。 */
#define OCVU_CALIB_MAX_POINTS 100000

/* ocvu_solve_pnp / ocvu_project_points が受け取る点数の上限。
 * OCVU_CALIB_MAX_POINTS と同じ理由 —— 点数から配列の必要バイト数を作るときに
 * int32_t の乗算が符号付きオーバーフロー（未定義動作）を起こさないための歯止め。
 * 1 枚ぶんの姿勢推定に 1 万点を使うことは実用上ありえない。 */
#define OCVU_PNP_MAX_POINTS 10000

/* ocvu_corner_sub_pix が受け取る点数の上限。同じ理由である。 */
#define OCVU_CORNER_MAX_POINTS 10000

/* ocvu_aruco_generate_marker の side_pixels の上限。
 * **これだけは意味が違う** —— 上の 2 つは「入力の個数から長さを作る」ための
 * 歯止めだが、こちらは native 側が side_pixels * side_pixels のバイト数を
 * 実際に確保するので、縛らないと 4 GB 級の要求が通ってしまう。 */
#define OCVU_ARUCO_MAX_MARKER_PIXELS 4096

/* ocvu_solve_pnp の method。cv::SolvePnPMethod の値をそのまま出す
 * （実装 .cpp の static_assert が写し間違いをコンパイル時に落とす）。
 *
 * ITERATIVE は既定で、平面上の 4 点でも非平面の 6 点でも解ける。
 * IPPE_SQUARE は 1 辺が既知の正方形マーカー専用で、**点の並び順が決まっている**
 * （左上・右上・右下・左下）。ArUco の 4 隅はその順で返るのでそのまま渡せる。 */
#define OCVU_SOLVEPNP_ITERATIVE   0
#define OCVU_SOLVEPNP_EPNP        1
#define OCVU_SOLVEPNP_P3P         2
#define OCVU_SOLVEPNP_AP3P        3
#define OCVU_SOLVEPNP_IPPE        4
#define OCVU_SOLVEPNP_IPPE_SQUARE 5
#define OCVU_SOLVEPNP_SQPNP       6

/* ocvu_aruco_* の辞書。cv::aruco::PredefinedDictionaryType の値をそのまま出す。
 *
 * 名前の 4X4 / 5X5 / 6X6 / 7X7 はマーカー内部の格子の細かさ、後ろの数字は
 * その辞書が持つ ID の個数である。**細かいほど遠くから読みにくく、
 * 個数が多いほど誤検出しやすい。** 決まっていないなら 4X4_50 でよい。
 *
 * **AprilTag 系の 5 つは出していない。** cv::aruco には在るが検証していない。 */
#define OCVU_ARUCO_DICT_4X4_50          0
#define OCVU_ARUCO_DICT_4X4_100         1
#define OCVU_ARUCO_DICT_4X4_250         2
#define OCVU_ARUCO_DICT_4X4_1000        3
#define OCVU_ARUCO_DICT_5X5_50          4
#define OCVU_ARUCO_DICT_5X5_100         5
#define OCVU_ARUCO_DICT_5X5_250         6
#define OCVU_ARUCO_DICT_5X5_1000        7
#define OCVU_ARUCO_DICT_6X6_50          8
#define OCVU_ARUCO_DICT_6X6_100         9
#define OCVU_ARUCO_DICT_6X6_250        10
#define OCVU_ARUCO_DICT_6X6_1000       11
#define OCVU_ARUCO_DICT_7X7_50         12
#define OCVU_ARUCO_DICT_7X7_100        13
#define OCVU_ARUCO_DICT_7X7_250        14
#define OCVU_ARUCO_DICT_7X7_1000       15
#define OCVU_ARUCO_DICT_ARUCO_ORIGINAL 16

/* threshold の種類。cv::ThresholdTypes の値をそのまま使う。
 *
 * OCVU_THRESH_OTSU は上の 5 つのいずれかと **or して**渡す —— しきい値を
 * 画像から自動で選ばせる指定である（渡した threshold_value は無視され、
 * 実際に選ばれた値が out_computed_threshold に入る）。 */
#define OCVU_THRESH_BINARY     0
#define OCVU_THRESH_BINARY_INV 1
#define OCVU_THRESH_TRUNC      2
#define OCVU_THRESH_TOZERO     3
#define OCVU_THRESH_TOZERO_INV 4
#define OCVU_THRESH_OTSU       8

/* 形態素演算の種類。cv::MorphTypes の値をそのまま使う。 */
#define OCVU_MORPH_ERODE    0
#define OCVU_MORPH_DILATE   1
#define OCVU_MORPH_OPEN     2
#define OCVU_MORPH_CLOSE    3
#define OCVU_MORPH_GRADIENT 4
#define OCVU_MORPH_TOPHAT   5
#define OCVU_MORPH_BLACKHAT 6

/* 形態素演算の構造要素の形。cv::MorphShapes の値をそのまま使う。 */
#define OCVU_MORPH_SHAPE_RECT    0
#define OCVU_MORPH_SHAPE_CROSS   1
#define OCVU_MORPH_SHAPE_ELLIPSE 2

/* テンプレート照合の方法。cv::TemplateMatchModes の値をそのまま使う。
 * SQDIFF 系は**小さいほど似ている**、他は大きいほど似ている。 */
#define OCVU_TM_SQDIFF        0
#define OCVU_TM_SQDIFF_NORMED 1
#define OCVU_TM_CCORR         2
#define OCVU_TM_CCORR_NORMED  3
#define OCVU_TM_CCOEFF        4
#define OCVU_TM_CCOEFF_NORMED 5

/* 輪郭の取り出し方。cv::RetrievalModes の値をそのまま使う。
 * **RETR_FLOODFILL は出していない** —— 32 bit の入力を要求するので、
 * この関数が受ける 8 bit の 2 値画像では使えない。 */
#define OCVU_RETR_EXTERNAL 0
#define OCVU_RETR_LIST     1
#define OCVU_RETR_CCOMP    2
#define OCVU_RETR_TREE     3

/* 輪郭の点の間引き方。cv::ContourApproximationModes の値をそのまま使う。 */
#define OCVU_CHAIN_APPROX_NONE   1
#define OCVU_CHAIN_APPROX_SIMPLE 2

/* 画像の外側をどう埋めるか。cv::BorderTypes の値をそのまま使う。 */
#define OCVU_BORDER_CONSTANT    0
#define OCVU_BORDER_REPLICATE   1
#define OCVU_BORDER_REFLECT     2
#define OCVU_BORDER_WRAP        3
#define OCVU_BORDER_REFLECT_101 4

/* 正規化の仕方。cv::NormTypes の値をそのまま使う。
 *
 * MINMAX は値域を [alpha, beta] へ線形に写す。**画像を見えるようにするのは
 * ふつうこれである。** INF / L1 / L2 はノルムが alpha になるように割る。
 * HAMMING は記述子どうしの距離を測るためのもので、正規化には使わない。 */
#define OCVU_NORM_INF     1
#define OCVU_NORM_L1      2
#define OCVU_NORM_L2      4
#define OCVU_NORM_HAMMING 6
#define OCVU_NORM_MINMAX 32

/* ocvu_bitwise の演算。
 *
 * **これは OpenCV の定数の写しではない。** cv::bitwise_and などは関数であって
 * 定数ではないので、対応する値が上流に存在しない。**この 4 つはこちらが決めた値**
 * であり、したがって static_assert で固定する相手が無い。
 *
 * OCVU_BITWISE_NOT のときだけ src2 を見ない。 */
#define OCVU_BITWISE_AND 0
#define OCVU_BITWISE_OR  1
#define OCVU_BITWISE_XOR 2
#define OCVU_BITWISE_NOT 3

/* ocvu_detect_and_compute が使う検出器。
 *
 * **これも OpenCV の定数の写しではない**（cv::ORB / cv::SIFT はクラスである）。
 *
 * ORB は速く、記述子が 32 バイトの 2 値である（ハミング距離で比べる）。
 * SIFT は遅いが回転と拡大縮小に強く、記述子が 128 次元の float である
 * （L2 距離で比べる）。**距離の選び方が変わる**ので、ocvu_match_descriptors の
 * norm_type を検出器に合わせること。 */
#define OCVU_FEATURE_ORB  0
#define OCVU_FEATURE_SIFT 1

/* ocvu_compute_disparity のアルゴリズム。
 *
 * **これも OpenCV の定数の写しではない**（cv::StereoBM / cv::StereoSGBM は
 * クラスである）。BM は速いが粗く、SGBM は遅いが滑らかである。 */
#define OCVU_STEREO_BM   0
#define OCVU_STEREO_SGBM 1

/*
 * 記述子どうしの対応 1 つ。境界に出るので固定サイズ型だけで構成する。
 *
 * cv::DMatch をそのまま出すことはできない（C++ のクラスで、layout の
 * 保証も無い）。**この struct の layout がこちら側の正本である。**
 * 実装 .cpp に static_assert を置いて大きさと並びを固定してあり、
 * C# 側の OcvuDMatch とは L3 が Marshal.SizeOf と Marshal.OffsetOf の
 * **両方**で突き合わせる —— **合計だけを固定した検査は、同じ型の
 * フィールドを入れ替えても通る**（M5 で ocvu_keypoint について実測した）。
 *
 * query_index は問い合わせ側の記述子の索引、train_index は照合先の索引、
 * image_index は照合先が複数の画像から来るときの識別に使うもの
 * （この ABI は 1 対 1 の照合しか出していないので常に 0 である）、
 * distance は 2 つの記述子の距離で **小さいほど似ている。**
 */
typedef struct ocvu_dmatch {
    int32_t query_index;
    int32_t train_index;
    int32_t image_index;
    float   distance;
} ocvu_dmatch;

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
#include "ocvu/features.h"
#include "ocvu/geometry.h"
#include "ocvu/calib.h"
#include "ocvu/stereo.h"

#endif /* OPENCV_UNITY_NATIVE_H */
