// stereo module。**この plugin がこの module を使う唯一の場所である。**
//
// **stereo は tools/opencv-config.psd1 の Modules に無い。** それでもビルド
// されているのは calib が推移的に引くためで、cmake/FindOpenCvUnityDeps.cmake の
// COMPONENTS への追加も desktop では実際のリンク行を変えない（geometry と
// 同じ形。native/tests/test_module_linkage.cpp の StereoIsLinked に実測がある）。
// **ただし iOS と Web では違う** —— 静的ライブラリを束ねる分岐は要求した
// COMPONENTS だけから OpenCV_LIBS を作るので、足さないと束ねられない。

#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/stereo.hpp>

#include <cstdint>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

// 境界に出す型の値は OpenCV のものをそのまま使う。写し間違いをコンパイル時に
// 落とす（ocvu_mat.cpp と同じ形。**あちらに在っても、この翻訳単位で
// OCVU_MAT_TYPE_* を cv:: の値と比べる以上、ここでも固定する**）。
static_assert(OCVU_MAT_TYPE_8UC1 == CV_8UC1, "OCVU_MAT_TYPE_8UC1 が CV_8UC1 と違う");
static_assert(OCVU_MAT_TYPE_16SC1 == CV_16SC1, "OCVU_MAT_TYPE_16SC1 が CV_16SC1 と違う");

namespace {

// **OCVU_STEREO_BM / OCVU_STEREO_SGBM に static_assert が無い理由。**
// cv::StereoBM と cv::StereoSGBM はクラスであって定数ではないので、
// 固定する相手が上流に存在しない。この 2 つはこちらが決めた値である
// （OCVU_MAT_TYPE_* や OCVU_NORM_* は OpenCV の写しなので static_assert が付く）。
bool IsKnownAlgorithm(int32_t algorithm) {
    return algorithm == OCVU_STEREO_BM || algorithm == OCVU_STEREO_SGBM;
}

// 照合する窓の 1 辺の下限。OpenCV の StereoBM は 5 未満を拒むが、
// SGBM は何も言わない。**この ABI は両方に同じ下限をかける**（下の理由）。
constexpr int32_t kMinBlockSize = 5;

// 視差の幅の刻み。同上。
constexpr int32_t kDisparityStep = 16;

}  // namespace

extern "C" ocvu_status ocvu_compute_disparity(ocvu_mat_handle left, ocvu_mat_handle right, ocvu_mat_handle dst, int32_t algorithm, int32_t num_disparities, int32_t block_size) {
    OCVU_TRY_BEGIN
    // **知らない algorithm は素通しにしない。** 既定へ黙って倒すと、
    // 呼ぶ側は「BM を頼んだつもりで SGBM の結果を見ている」ことに気づけない。
    if (!IsKnownAlgorithm(algorithm)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_compute_disparity: algorithm must be OCVU_STEREO_BM or OCVU_STEREO_SGBM");
    }

    // **この 2 つは OpenCV の要求ではない。** 実測（2026-09-05）では
    // 強制するのは BM だけで、SGBM は block_size を一切検査せず
    // （0 / -1 / 2 / 3 のいずれも例外にならない）、num_disparities の
    // 16 倍数性も見ない。BM も num_disparities = 0 は落とさず、内部で
    // 64 に読み替える。
    //
    // **それでも両方に同じ制限をかける。** algorithm を差し替えたときに
    // 引数の作り方まで変わる ABI は、呼ぶ側にとって 2 つの関数と変わらない。
    // 厳しいほうへ揃えれば、BM で通る引数は SGBM でも必ず通る。
    // **したがってこれは「OpenCV がそう要求している」ではなく
    // 「この ABI がそう決めた」である** —— spec の summary もそう書いてある。
    if (num_disparities <= 0 || num_disparities % kDisparityStep != 0) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_compute_disparity: num_disparities must be a positive multiple of 16");
    }
    if (block_size < kMinBlockSize || block_size % 2 == 0) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_compute_disparity: block_size must be an odd number of at least 5");
    }

    const cv::Mat* left_mat = ::ocvu::mat_table_get(left);
    if (left_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_compute_disparity: left handle is invalid");
    }
    const cv::Mat* right_mat = ::ocvu::mat_table_get(right);
    if (right_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_compute_disparity: right handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_compute_disparity: dst handle is invalid");
    }

    // **入力の型もこの ABI が決める。** BM は CV_8UC1 しか受けないが、
    // SGBM は 8 bit なら 3 channel でも受ける。素通しにすると
    // 「同じ引数で BM だけが OPENCV_ERROR になる」形が残るので、
    // 厳しいほうへ揃えて呼ぶ側が直せる誤りとして先に断る。
    //
    // **大きさの一致はここで見ない。** あちらは 2 つの入力の関係で、
    // OpenCV が具体的な理由つきで投げてくれる（下の catch が
    // OCVU_STATUS_OPENCV_ERROR にする）。type は「この ABI の語彙
    // （OCVU_MAT_TYPE_8UC1）で言える単独の性質」なので、こちらで言う。
    if (left_mat->type() != OCVU_MAT_TYPE_8UC1 || right_mat->type() != OCVU_MAT_TYPE_8UC1) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_compute_disparity: left and right must both be OCVU_MAT_TYPE_8UC1");
    }

    // **求めてから dst に入れる。** 直接 dst_mat へ書かせると、
    // 失敗したときに dst が途中まで書き換わった状態で残りうる
    // （ocvu_geometry.cpp / ocvu_calibration.cpp と同じ作法）。
    cv::Mat result;
    try {
        // **照合器は毎回作り直す。** cv::StereoMatcher の handle を境界に
        // 出さない判断の帰結である（docs/abi-ownership-and-versioning.md §1 の
        // 所有権の形を増やさない。ocvu_detect_and_compute の検出器と同じ）。
        cv::Ptr<cv::StereoMatcher> matcher;
        if (algorithm == OCVU_STEREO_BM) {
            matcher = cv::StereoBM::create(num_disparities, block_size);
        } else {
            matcher = cv::StereoSGBM::create(0, num_disparities, block_size);
        }

        cv::Mat disparity;
        matcher->compute(*left_mat, *right_mat, disparity);

        // **確かめて弾くのではなく変換する。** OpenCV は既定で 16 bit
        // 固定小数の視差を返すが、契約として名乗っているのは
        // OCVU_MAT_TYPE_16SC1 なので、違ったら変換して契約のほうを守る
        // （native/src/ocvu_calibration.cpp の camera_matrix / rvecs と
        // 同じ作法）。**弾くと、上流が型を変えた日に呼ぶ側から見て
        // 理由の分からない失敗になる。**
        //
        // **変換も try の内側に置く。** convertTo も cv::Exception を
        // 投げうるので、外に出すと OCVU_TRY_END が拾って
        // UNKNOWN_ERROR になり、summary の約束がそこだけ破れる。
        if (disparity.type() == OCVU_MAT_TYPE_16SC1) {
            result = disparity;
        } else {
            disparity.convertTo(result, CV_16SC1);
        }
    } catch (const cv::Exception& e) {
        // **cv::Exception を個別に受ける。** OCVU_TRY_END に任せると
        // std::exception として UNKNOWN_ERROR に落ち、
        // summary が約束する OPENCV_ERROR が嘘になる（実測で確かめてある）。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    // ここまで来て初めて dst を置き換える。**失敗しうる経路はもう無い。**
    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
