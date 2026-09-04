// objdetect module のうち ArUco マーカーに関わるもの。
//
// **ocvu_objdetect.cpp に足していない。** あちらは QR コードで、辞書も検出器も
// 別物である。同じ module に居るのは OpenCV 5 が objdetect にまとめているため
// であって、実装として共有するものは 1 つも無い。

#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/objdetect/aruco_detector.hpp>
#include <opencv2/objdetect/aruco_dictionary.hpp>

#include <cstdint>
#include <vector>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

// 境界に出す辞書の値は OpenCV のものをそのまま使う。
// 写し間違いをコンパイル時に落とす（ocvu_mat.cpp / ocvu_geometry.cpp と同じ形）。
static_assert(OCVU_ARUCO_DICT_4X4_50 == cv::aruco::DICT_4X4_50, "DICT_4X4_50 がずれている");
static_assert(OCVU_ARUCO_DICT_4X4_100 == cv::aruco::DICT_4X4_100, "DICT_4X4_100 がずれている");
static_assert(OCVU_ARUCO_DICT_4X4_250 == cv::aruco::DICT_4X4_250, "DICT_4X4_250 がずれている");
static_assert(OCVU_ARUCO_DICT_4X4_1000 == cv::aruco::DICT_4X4_1000, "DICT_4X4_1000 がずれている");
static_assert(OCVU_ARUCO_DICT_5X5_50 == cv::aruco::DICT_5X5_50, "DICT_5X5_50 がずれている");
static_assert(OCVU_ARUCO_DICT_5X5_100 == cv::aruco::DICT_5X5_100, "DICT_5X5_100 がずれている");
static_assert(OCVU_ARUCO_DICT_5X5_250 == cv::aruco::DICT_5X5_250, "DICT_5X5_250 がずれている");
static_assert(OCVU_ARUCO_DICT_5X5_1000 == cv::aruco::DICT_5X5_1000, "DICT_5X5_1000 がずれている");
static_assert(OCVU_ARUCO_DICT_6X6_50 == cv::aruco::DICT_6X6_50, "DICT_6X6_50 がずれている");
static_assert(OCVU_ARUCO_DICT_6X6_100 == cv::aruco::DICT_6X6_100, "DICT_6X6_100 がずれている");
static_assert(OCVU_ARUCO_DICT_6X6_250 == cv::aruco::DICT_6X6_250, "DICT_6X6_250 がずれている");
static_assert(OCVU_ARUCO_DICT_6X6_1000 == cv::aruco::DICT_6X6_1000, "DICT_6X6_1000 がずれている");
static_assert(OCVU_ARUCO_DICT_7X7_50 == cv::aruco::DICT_7X7_50, "DICT_7X7_50 がずれている");
static_assert(OCVU_ARUCO_DICT_7X7_100 == cv::aruco::DICT_7X7_100, "DICT_7X7_100 がずれている");
static_assert(OCVU_ARUCO_DICT_7X7_250 == cv::aruco::DICT_7X7_250, "DICT_7X7_250 がずれている");
static_assert(OCVU_ARUCO_DICT_7X7_1000 == cv::aruco::DICT_7X7_1000, "DICT_7X7_1000 がずれている");
static_assert(OCVU_ARUCO_DICT_ARUCO_ORIGINAL == cv::aruco::DICT_ARUCO_ORIGINAL,
              "DICT_ARUCO_ORIGINAL がずれている");

namespace {

// **AprilTag 系は出していない。** cv::aruco の enum はこの後ろに続くが、
// この plugin では検証していないので素通しにしない。
bool IsKnownDictionary(int32_t dictionary_id) {
    return dictionary_id >= OCVU_ARUCO_DICT_4X4_50 &&
           dictionary_id <= OCVU_ARUCO_DICT_ARUCO_ORIGINAL;
}

// **検出が受け取る画素の型は、こちら側で決めて弾く。**
// 8 bit 以外を OpenCV に落とすと cv::Exception になり、呼ぶ側には「原因不明」に
// 近い形でしか届かない。直せる誤りなので INVALID_ARGUMENT で返す。
bool IsAcceptedDetectionType(const cv::Mat& image) {
    const int channels = image.channels();
    return image.depth() == CV_8U && (channels == 1 || channels == 3 || channels == 4);
}

// **グレースケールは自分で作る。** 検出器が何 channel を受けるかは OpenCV の
// 版に依るが、**Unity のテクスチャは 4 channel である**
// （Runtime/UnityIntegration の TextureConverter / WebCamTextureConverter は
// どちらも Bgra32 の CvMat を作る）。「呼ぶ側が先に落とすこと」を要求すると、
// **いちばん普通の使い方が通らない ABI になる。** 変換の仕方をこちらで決めて
// おけば、どの版でも同じ入力が検出器に渡る。
//
// cv::Exception を投げうるので、呼ぶ側が try の内側で使うこと。
cv::Mat ToDetectionGrey(const cv::Mat& image) {
    if (image.channels() == 1) {
        // 1 channel はそのまま使う。**複製しない** —— 読むだけである。
        return image;
    }
    cv::Mat grey;
    cv::cvtColor(image, grey,
                 image.channels() == 4 ? cv::COLOR_BGRA2GRAY : cv::COLOR_BGR2GRAY);
    return grey;
}

}  // namespace

extern "C" ocvu_status ocvu_aruco_generate_marker(int32_t dictionary_id, int32_t marker_id, int32_t side_pixels, int32_t border_bits, ocvu_mat_handle dst) {
    OCVU_TRY_BEGIN
    if (!IsKnownDictionary(dictionary_id)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_aruco_generate_marker: dictionary_id is not one of OCVU_ARUCO_DICT_*");
    }
    if (side_pixels < 1 || side_pixels > OCVU_ARUCO_MAX_MARKER_PIXELS) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_aruco_generate_marker: side_pixels must be between 1 and OCVU_ARUCO_MAX_MARKER_PIXELS");
    }
    if (border_bits < 1) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_aruco_generate_marker: border_bits must be at least 1");
    }

    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_aruco_generate_marker: dst handle is invalid");
    }

    const cv::aruco::Dictionary dictionary = cv::aruco::getPredefinedDictionary(dictionary_id);

    // **辞書ごとに ID の個数が違う。** DICT_4X4_50 は 50 個しか持たない。
    // bytesList は 1 行が 1 マーカーなので、その行数が辞書の大きさである
    // （cv::aruco::Dictionary の doc コメントが「bytesList.rows is the dictionary
    // size」と述べている）。OpenCV に落とすと例外になるが、呼ぶ側が直せる誤りな
    // ので INVALID_ARGUMENT で返す。
    if (marker_id < 0 || marker_id >= dictionary.bytesList.rows) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_aruco_generate_marker: marker_id is out of range for this dictionary");
    }

    // **格子 1 つが 1 画素未満になる大きさは受け付けない。** マーカーは
    // markerSize x markerSize の格子と、その外側 border_bits 分の黒枠でできて
    // いる。side_pixels がその合計に満たないと、描く先が格子より小さくなる。
    // **これはこの ABI が自分で決めた契約である** —— OpenCV 側も受け付けないが、
    // そちらの挙動を根拠にはしていない。
    //
    // **2 倍する前に int64_t へ上げる。** border_bits は呼ぶ側が決める int32_t
    // なので、int32_t のまま 2 倍すると符号付きオーバーフロー（未定義動作）に
    // なり、負に反転してこの検査を素通りしうる。
    const int64_t minimum_side =
        static_cast<int64_t>(dictionary.markerSize) + 2 * static_cast<int64_t>(border_bits);
    if (static_cast<int64_t>(side_pixels) < minimum_side) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_aruco_generate_marker: side_pixels is smaller than the marker grid plus its border");
    }

    // **作ってから入れる。** 直接 dst_mat へ描かせると、失敗したときに dst が
    // 途中まで書き換わった状態で残りうる。
    cv::Mat image;
    try {
        dictionary.generateImageMarker(marker_id, side_pixels, image, border_bits);
    } catch (const cv::Exception& e) {
        // OCVU_TRY_END でも捕まるが、そこでは UNKNOWN_ERROR になる。
        // OpenCV 由来だと分かる status を返すためにここで先に受ける
        // （ocvu_objdetect.cpp / ocvu_imgcodecs.cpp と同じ形）。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    if (image.empty()) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_OPENCV_ERROR,
            "ocvu_aruco_generate_marker: the dictionary produced an empty image");
    }

    *dst_mat = image;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_aruco_detect_markers(ocvu_mat_handle src, int32_t dictionary_id, int32_t* out_ids, int32_t ids_capacity, float* out_corners, int32_t corners_capacity, int32_t* out_count) {
    OCVU_TRY_BEGIN
    // **out_count を最初に見る。** 無いと呼ぶ側は溢れたときの必要量を決められ
    // ないので、他のどの引数より先に断る（ocvu_qr_decode と同じ作法）。
    if (out_count == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_aruco_detect_markers: out_count is NULL");
    }
    // **通ったら何よりも先に 0 を書く。** どの経路で返っても、呼ぶ側が読む値が
    // 前回の呼び出しの残りにならないようにする。以降のすべての早期 return は
    // この後ろに来る。
    *out_count = 0;

    if (!IsKnownDictionary(dictionary_id)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_aruco_detect_markers: dictionary_id is not one of OCVU_ARUCO_DICT_*");
    }
    if (ids_capacity < 0 || corners_capacity < 0) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_aruco_detect_markers: capacities must not be negative");
    }
    // **容量 0 と NULL の組み合わせは正常な問い合わせなので通す。**「何個
    // 写っているか」を先に知るための 1 回目の呼び出しがこの形になる
    // （ocvu_orb_detect / ocvu_find_chessboard_corners と同じ扱い）。
    // 「NULL なら常に拒否」と書くと、その 1 回目が呼べなくなる。
    if (ids_capacity > 0 && out_ids == nullptr) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_NULL_POINTER,
            "ocvu_aruco_detect_markers: out_ids is NULL but ids_capacity is positive");
    }
    if (corners_capacity > 0 && out_corners == nullptr) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_NULL_POINTER,
            "ocvu_aruco_detect_markers: out_corners is NULL but corners_capacity is positive");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_aruco_detect_markers: src handle is invalid");
    }
    if (src_mat->empty()) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_aruco_detect_markers: src is empty");
    }
    if (!IsAcceptedDetectionType(*src_mat)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_aruco_detect_markers: src must be 8 bit with 1, 3 or 4 channels");
    }

    std::vector<std::vector<cv::Point2f> > corners;
    std::vector<int> ids;
    try {
        const cv::Mat grey = ToDetectionGrey(*src_mat);
        const cv::aruco::Dictionary dictionary = cv::aruco::getPredefinedDictionary(dictionary_id);
        const cv::aruco::ArucoDetector detector(dictionary);
        detector.detectMarkers(grey, corners, ids);
    } catch (const cv::Exception& e) {
        // OCVU_TRY_END でも捕まるが、そこでは UNKNOWN_ERROR になる。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    const int64_t found = static_cast<int64_t>(ids.size());
    if (found != static_cast<int64_t>(corners.size())) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_OPENCV_ERROR,
            "ocvu_aruco_detect_markers: ids and corners have different lengths");
    }
    // 個数は int32_t で返す約束なので、表現できない大きさは切り詰めずに断る
    // （ocvu_qr_decode の INT32_MAX の検査と同じ形。実際には到達しない防御である）。
    if (found > static_cast<int64_t>(INT32_MAX)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_OPENCV_ERROR,
            "ocvu_aruco_detect_markers: the number of markers does not fit in int32_t");
    }

    // **書く前に、4 隅であることを全部確かめる。** 途中まで書いてから断ると、
    // 呼ぶ側は「一部だけ正しい配列」を掴むことになる。
    for (int64_t i = 0; i < found; ++i) {
        if (corners[static_cast<size_t>(i)].size() != 4) {
            // ここまで来て 4 隅でないのは OpenCV 側の前提が変わったということである。
            return ::ocvu::set_last_error(
                OCVU_STATUS_OPENCV_ERROR,
                "ocvu_aruco_detect_markers: a detected marker does not have 4 corners");
        }
    }

    // **溢れたことは、見つかった数と一緒に伝える。** 呼ぶ側はそれで確保し直して
    // 呼び直せる（ocvu_orb_detect と同じ作法）。**積は int64_t で作る** ——
    // found は OpenCV 由来なので上限を仮定しない。
    const int64_t corners_needed = found * 8;
    if (found > static_cast<int64_t>(ids_capacity) ||
        corners_needed > static_cast<int64_t>(corners_capacity)) {
        *out_count = static_cast<int32_t>(found);
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_aruco_detect_markers: ids_capacity or corners_capacity is too small");
    }

    for (int64_t i = 0; i < found; ++i) {
        out_ids[i] = ids[static_cast<size_t>(i)];
        const std::vector<cv::Point2f>& quad = corners[static_cast<size_t>(i)];
        for (int64_t c = 0; c < 4; ++c) {
            out_corners[i * 8 + c * 2] = quad[static_cast<size_t>(c)].x;
            out_corners[i * 8 + c * 2 + 1] = quad[static_cast<size_t>(c)].y;
        }
    }

    *out_count = static_cast<int32_t>(found);
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
