#include <opencv2/core.hpp>
#include <opencv2/imgcodecs.hpp>

#include <cstring>
#include <string>
#include <vector>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

/*
 * ABI に出す定数が OpenCV の値と一致していることを、写し間違いではなく
 * コンパイル時に固定する。ocvu_imgproc.cpp と同じ扱い。
 */
static_assert(OCVU_IMREAD_UNCHANGED == cv::IMREAD_UNCHANGED, "imread flag drift");
static_assert(OCVU_IMREAD_GRAYSCALE == cv::IMREAD_GRAYSCALE, "imread flag drift");
static_assert(OCVU_IMREAD_COLOR == cv::IMREAD_COLOR, "imread flag drift");

/*
 * **ここでの検証は ocvu_mat_buffer.cpp の validate() とは別形である。**
 * あちらは画像の行（length と stride と rows の整合）を見るが、符号化された
 * blob には行も stride も無い。長さと NULL だけを見る。
 */

extern "C" ocvu_status ocvu_imencode(ocvu_mat_handle src, const char* ext, uint8_t* buffer, int32_t buffer_size, int32_t* out_required_size) {
    OCVU_TRY_BEGIN
    // out_required_size は必須。これが無いと呼ぶ側は 2 回目の大きさを決められない。
    if (out_required_size == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "out_required_size must not be null");
    }
    *out_required_size = 0;

    if (ext == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER, "ext must not be null");
    }
    if (ext[0] == '\0') {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ext must not be empty");
    }
    if (buffer_size < 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "buffer_size must be >= 0");
    }
    // 「長さがあるのに buffer が無い」は呼ぶ側の取り違えなので、書く前に断る。
    if (buffer_size > 0 && buffer == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "buffer must not be null when buffer_size > 0");
    }

    cv::Mat* mat = ::ocvu::mat_table_get(src);
    if (mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE, "src handle is invalid");
    }

    std::vector<uchar> encoded;
    try {
        if (!cv::imencode(std::string(ext), *mat, encoded)) {
            // 例外にならずに false が返る経路もある。
            return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR,
                                          "imencode returned false");
        }
    } catch (const cv::Exception& e) {
        // OCVU_TRY_END でも捕まるが、そこでは UNKNOWN_ERROR になる。
        // OpenCV 由来だと分かる status を返すためにここで先に受ける。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    // ABI は int32_t で大きさを返す。超える画像は表現できないので断る。
    if (encoded.size() > static_cast<size_t>(INT32_MAX)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "encoded image does not fit in int32_t");
    }

    const int32_t needed = static_cast<int32_t>(encoded.size());
    *out_required_size = needed;

    // **足りないときは何も書かない。** 部分的に書くと、呼ぶ側は途中まで
    // 正しい buffer を掴むことになり、壊れ方が分かりにくくなる。
    if (buffer_size < needed) { return OCVU_STATUS_BUFFER_TOO_SMALL; }

    std::memcpy(buffer, encoded.data(), static_cast<size_t>(needed));
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_imdecode(const uint8_t* data, int64_t length, int32_t flags, ocvu_mat_handle dst) {
    OCVU_TRY_BEGIN
    if (data == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER, "data must not be null");
    }
    if (length <= 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT, "length must be >= 1");
    }
    // cv::Mat の列数は int なので、そこへ収まらない長さは受けない。
    if (length > static_cast<int64_t>(INT32_MAX)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "length does not fit in int32_t");
    }

    cv::Mat* out = ::ocvu::mat_table_get(dst);
    if (out == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE, "dst handle is invalid");
    }

    try {
        // 呼ぶ側の buffer をその場で包むだけ。cv::imdecode は自前のメモリに
        // 結果を作るので、この view は関数を抜ける前に用済みになる。
        const cv::Mat view(1, static_cast<int>(length), CV_8UC1,
                           const_cast<uint8_t*>(data));
        cv::Mat decoded = cv::imdecode(view, flags);
        if (decoded.empty()) {
            // 壊れた入力はここに来る。例外ではなく空の Mat が返る。
            return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR,
                                          "imdecode could not decode the given bytes");
        }
        *out = decoded;  // 借用はここで終わる。decoded は自分のメモリを持つ。
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
