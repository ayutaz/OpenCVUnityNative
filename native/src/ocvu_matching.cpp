// features module のうち「記述子」に関わるもの。
//
// **ocvu_features.cpp に足していない。** あちらは記述子を計算しない
// ocvu_orb_detect 1 本で、こちらは記述子を Mat に入れて対応づける。

#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/features.hpp>

#include <cstddef>
#include <cstdint>
#include <vector>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

// **境界に出る struct の大きさと並びを固定する。**
// C# 側の OcvuDMatch とは L3 が Marshal.SizeOf と Marshal.OffsetOf の
// **両方**で突き合わせる —— 合計だけを固定した検査は、同じ型のフィールドを
// 入れ替えても通る（M5 で ocvu_keypoint について実測した）。
static_assert(sizeof(ocvu_dmatch) == 16, "ocvu_dmatch の大きさが変わった");
static_assert(offsetof(ocvu_dmatch, query_index) == 0, "query_index の位置が変わった");
static_assert(offsetof(ocvu_dmatch, train_index) == 4, "train_index の位置が変わった");
static_assert(offsetof(ocvu_dmatch, image_index) == 8, "image_index の位置が変わった");
static_assert(offsetof(ocvu_dmatch, distance) == 12, "distance の位置が変わった");

// 境界に出す距離の値は OpenCV のものをそのまま使う。
// 写し間違いをコンパイル時に落とす（ocvu_geometry.cpp と同じ形）。
static_assert(OCVU_NORM_HAMMING == cv::NORM_HAMMING, "OCVU_NORM_HAMMING が cv::NORM_HAMMING と違う");
static_assert(OCVU_NORM_L2 == cv::NORM_L2, "OCVU_NORM_L2 が cv::NORM_L2 と違う");

namespace {

bool IsKnownDetector(int32_t detector) {
    return detector == OCVU_FEATURE_ORB || detector == OCVU_FEATURE_SIFT;
}

// **正規化に使う値は受け付けない。** OCVU_NORM_* は
// ocvu_normalize（値域の変換）と ocvu_match_descriptors（距離）の
// 両方が読む一覧なので、こちらは距離として意味のある 2 つだけを通す。
bool IsKnownMatchNorm(int32_t norm_type) {
    return norm_type == OCVU_NORM_HAMMING || norm_type == OCVU_NORM_L2;
}

}  // namespace

extern "C" ocvu_status ocvu_detect_and_compute(ocvu_mat_handle src, int32_t detector, int32_t max_features, ocvu_keypoint* out_keypoints, int32_t capacity, ocvu_mat_handle out_descriptors, int32_t* out_count) {
    OCVU_TRY_BEGIN
    // **out_count を最初に見る。** max_features は上限ではないので、
    // 呼ぶ側は必要量を事前に知り得ない —— これが無いと溢れたときに
    // 回復できない。
    if (out_count == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_detect_and_compute: out_count is NULL");
    }
    // どの経路で返っても、呼ぶ側が読む値が前回の残りにならないようにする。
    *out_count = 0;

    if (!IsKnownDetector(detector)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_detect_and_compute: detector is not one of OCVU_FEATURE_ORB or OCVU_FEATURE_SIFT");
    }
    if (max_features < 1 || max_features > OCVU_ORB_MAX_FEATURES) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_detect_and_compute: max_features must be between 1 and OCVU_ORB_MAX_FEATURES");
    }
    if (capacity < 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_detect_and_compute: capacity is negative");
    }
    // **capacity が 0 のときだけ NULL を通す。** そちらは個数の問い合わせで
    // あって、断ると 1 回目が呼べなくなる（ocvu_imencode と同じ作法）。
    if (capacity > 0 && out_keypoints == nullptr) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_NULL_POINTER,
            "ocvu_detect_and_compute: out_keypoints is NULL but capacity is positive");
    }
    // **入力を読みながら同じ Mat を置き換えることになる。** 先に断る。
    if (src == out_descriptors) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_detect_and_compute: src and out_descriptors must be different handles");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_detect_and_compute: src handle is invalid");
    }
    cv::Mat* descriptors_mat = ::ocvu::mat_table_get(out_descriptors);
    if (descriptors_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_detect_and_compute: out_descriptors handle is invalid");
    }

    std::vector<cv::KeyPoint> keypoints;
    // **結果は一時の Mat に求める。** 失敗したときに out_descriptors が
    // 途中まで書き換わっていない状態を、構造として保証する。
    cv::Mat descriptors;
    try {
        // **検出器は呼び出しのたびに作り直す。** cv::Feature2D の handle を
        // 境界に出さない判断の帰結である（docs/abi-ownership-and-versioning.md
        // §1 が持つ所有権の形を 1 つも増やさない）。
        cv::Ptr<cv::Feature2D> feature;
        if (detector == OCVU_FEATURE_ORB) {
            feature = cv::ORB::create(max_features);
        } else {
            feature = cv::SIFT::create(max_features);
        }
        feature->detectAndCompute(*src_mat, cv::noArray(), keypoints, descriptors);
    } catch (const cv::Exception& e) {
        // **cv::Exception を個別に受ける。** OCVU_TRY_END に任せると
        // std::exception として UNKNOWN_ERROR に落ち、原因が読めなくなる。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    const int64_t found = static_cast<int64_t>(keypoints.size());
    if (found > INT32_MAX) {
        // int32_t に入らない個数は ABI で表現できないので、切り詰めずに断る。
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_detect_and_compute: the result is too large to describe through this ABI");
    }
    if (found > static_cast<int64_t>(capacity)) {
        // **ここまで来ても、まだ 1 バイトも書いていない。**
        //
        // **out_descriptors も置き換えない。** ここで記述子だけ入れると、
        // 呼ぶ側は「個数は 240 なのに記述子は元の Mat のまま」という
        // もっともらしい嘘を掴む —— 誤りが status ではなく結果として現れる。
        *out_count = static_cast<int32_t>(found);
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_detect_and_compute: capacity (elements) is smaller than the number of keypoints found");
    }

    // ここから書き出す。**失敗しうる経路はもう無い。**
    for (int64_t i = 0; i < found; ++i) {
        const cv::KeyPoint& k = keypoints[static_cast<size_t>(i)];
        ocvu_keypoint& out = out_keypoints[i];
        out.x        = k.pt.x;
        out.y        = k.pt.y;
        out.size     = k.size;
        out.angle    = k.angle;
        out.response = k.response;
        out.octave   = static_cast<int32_t>(k.octave);
        out.class_id = static_cast<int32_t>(k.class_id);
    }

    *descriptors_mat = descriptors;
    *out_count = static_cast<int32_t>(found);
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_match_descriptors(ocvu_mat_handle query, ocvu_mat_handle train, int32_t norm_type, int32_t cross_check, ocvu_dmatch* out_matches, int32_t capacity, int32_t* out_count) {
    OCVU_TRY_BEGIN
    if (out_count == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_match_descriptors: out_count is NULL");
    }
    *out_count = 0;

    if (!IsKnownMatchNorm(norm_type)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_match_descriptors: norm_type must be OCVU_NORM_HAMMING or OCVU_NORM_L2");
    }
    if (capacity < 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_match_descriptors: capacity is negative");
    }
    // capacity が 0 のときだけ NULL を通す（個数の問い合わせ）。
    if (capacity > 0 && out_matches == nullptr) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_NULL_POINTER,
            "ocvu_match_descriptors: out_matches is NULL but capacity is positive");
    }

    const cv::Mat* query_mat = ::ocvu::mat_table_get(query);
    if (query_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_match_descriptors: query handle is invalid");
    }
    const cv::Mat* train_mat = ::ocvu::mat_table_get(train);
    if (train_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_match_descriptors: train handle is invalid");
    }

    std::vector<cv::DMatch> matches;
    try {
        // **記述子の型と norm_type の組み合わせは OpenCV が見る。**
        // ハミング距離を浮動小数の記述子に当てた場合も、query と train の
        // 型が食い違う場合も、ここで例外になる（2026-09-05 に実測）。
        const cv::Ptr<cv::BFMatcher> matcher =
            cv::BFMatcher::create(norm_type, cross_check != 0);
        matcher->match(*query_mat, *train_mat, matches);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    const int64_t found = static_cast<int64_t>(matches.size());
    if (found > INT32_MAX) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_match_descriptors: the result is too large to describe through this ABI");
    }
    if (found > static_cast<int64_t>(capacity)) {
        *out_count = static_cast<int32_t>(found);
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_match_descriptors: capacity (elements) is smaller than the number of matches");
    }

    for (int64_t i = 0; i < found; ++i) {
        const cv::DMatch& m = matches[static_cast<size_t>(i)];
        ocvu_dmatch& out = out_matches[i];
        out.query_index = m.queryIdx;
        out.train_index = m.trainIdx;
        out.image_index = m.imgIdx;
        out.distance    = m.distance;
    }

    *out_count = static_cast<int32_t>(found);
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
