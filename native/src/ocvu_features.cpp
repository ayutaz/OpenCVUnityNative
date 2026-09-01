#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/features.hpp>

#include <algorithm>
#include <cstdint>
#include <vector>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

// 境界に出る struct の大きさを固定する。C# の OcvuKeyPoint と食い違うと
// marshalling だけが壊れるので、写し間違いをコンパイル時に落とす。
static_assert(sizeof(ocvu_keypoint) == 28,
              "ocvu_keypoint の layout が変わった。C# の OcvuKeyPoint も直すこと");

extern "C" ocvu_status ocvu_orb_detect(ocvu_mat_handle src, int32_t max_features, ocvu_keypoint* out_keypoints, int32_t capacity, int32_t* out_count) {
    OCVU_TRY_BEGIN
    if (out_count == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_orb_detect: out_count is NULL");
    }
    // どの経路で返っても、呼ぶ側が読む値が前回の残りにならないようにする。
    *out_count = 0;

    if (max_features <= 0 || max_features > OCVU_ORB_MAX_FEATURES) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_orb_detect: max_features is out of range");
    }
    if (capacity < 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_orb_detect: capacity is negative");
    }
    if (capacity > 0 && out_keypoints == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_orb_detect: out_keypoints is NULL but capacity is positive");
    }

    cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_orb_detect: src handle is invalid");
    }
    if (src_mat->empty()) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_orb_detect: src is empty");
    }

    // **検出より先に容量を見る。** 足りないと分かっている呼び出しで
    // 検出まで走らせるのは無駄で、しかも「何も書かない」契約は
    // 書く前に返ることでしか守れない。
    if (capacity < max_features) {
        *out_count = max_features;
        return ::ocvu::set_last_error(OCVU_STATUS_BUFFER_TOO_SMALL,
                                      "ocvu_orb_detect: capacity is smaller than max_features");
    }

    std::vector<cv::KeyPoint> found;
    try {
        cv::Ptr<cv::ORB> orb = cv::ORB::create(max_features);
        orb->detect(*src_mat, found);
    } catch (const cv::Exception& e) {
        // OCVU_TRY_END でも捕まるが、そこでは UNKNOWN_ERROR になる。
        // OpenCV 由来だと分かる status を返すためにここで先に受ける。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    // ORB は nfeatures を超えないが、契約は自分でも守る。
    const int32_t n = static_cast<int32_t>(
        std::min<size_t>(found.size(), static_cast<size_t>(max_features)));
    for (int32_t i = 0; i < n; ++i) {
        const cv::KeyPoint& k = found[static_cast<size_t>(i)];
        ocvu_keypoint& out = out_keypoints[i];
        out.x        = k.pt.x;
        out.y        = k.pt.y;
        out.size     = k.size;
        out.angle    = k.angle;
        out.response = k.response;
        out.octave   = static_cast<int32_t>(k.octave);
        out.class_id = static_cast<int32_t>(k.class_id);
    }
    *out_count = n;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
