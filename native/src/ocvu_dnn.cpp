// dnn module。**bindings/spec/dnn.json の "profile": "dnn" を初めて
// 本物の spec で実運用する場所である**（(b) が作った機構自体は合成 spec で
// 実証済みだった。docs/abi-ownership-and-versioning.md §4）。
//
// **engine / backend を選ぶ引数も定数も出さない**（設計 D7）。上流の 5.1 で
// `enum EngineType` の値が総入れ替えになったので（docs/roadmap.md の M7 節）、
// 5.1 で意味が変わる数字を境界の外へ出さない。
//
// **`cv::dnn::Net::forward()` が返すのは 4 次元の blob（NCHW）だが、この ABI の
// Mat は 2 次元までしか表現できない。** 4 次元を 2 次元へ潰す（決定 A。
// docs/superpowers/plans/2026-09-05-m7c-dnn-profile.md「この計画で最も
// 難しいところ」）。分類モデルの 1×N の出力を想定していて、検出モデルの
// ような出力では N と C の区別が失われる —— spec の summary と
// docs/api-reference.md の両方に明記してある。
//
// **`ocvu_dnn_blob_from_image` は潰さない。** cv::dnn::Net::setInput が
// 要求するのは 4 次元の NCHW そのものなので、ocvu_dnn_net_forward に渡す
// までは形を保つ。cv::Mat は内部で 2 次元より多い次元を表現できるので、
// この handle へ割り当てること自体は合法である —— ただし
// ocvu_mat_get_info のような 2 次元前提の関数へこの handle を渡した
// 結果は未定義とする。

#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/dnn.hpp>

#include <cstdint>
#include <memory>
#include <vector>

#include "ocvu_dnn_table.h"
#include "ocvu_error.h"
#include "ocvu_mat_table.h"

extern "C" ocvu_status ocvu_dnn_net_read_onnx(const uint8_t* data, int32_t length, ocvu_net_handle* out_handle) {
    OCVU_TRY_BEGIN
    if (data == nullptr || out_handle == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_dnn_net_read_onnx: data or out_handle is NULL");
    }
    if (length < 1) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_dnn_net_read_onnx: length must be at least 1");
    }

    // **OCVU_TRY_END は cv::Exception を UNKNOWN_ERROR に変換する。**
    // OPENCV_ERROR を返したいので、ここで自分で捕まえる
    // （ocvu_stereo.cpp / ocvu_calibration.cpp と同じ作法）。
    try {
        std::vector<uint8_t> buffer(data, data + length);
        auto net = std::make_unique<cv::dnn::Net>(cv::dnn::readNetFromONNX(buffer));
        if (net->empty()) {
            return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR,
                                          "ocvu_dnn_net_read_onnx: ONNX が空のネットワークになった");
        }
        // **成功してから初めて out_handle に書く。**
        *out_handle = ::ocvu::net_table_add(std::move(net));
        return OCVU_STATUS_OK;
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_dnn_net_release(ocvu_net_handle net) {
    OCVU_TRY_BEGIN
    if (!::ocvu::net_table_remove(net)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_dnn_net_release: handle is unknown or already released");
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_dnn_blob_from_image(ocvu_mat_handle src, ocvu_mat_handle dst, double scale, int32_t width, int32_t height, const double* mean, int32_t swap_rb, int32_t crop) {
    OCVU_TRY_BEGIN
    if (mean == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_dnn_blob_from_image: mean is NULL");
    }
    // **width / height は buffer の長さではなく、native（cv::dnn::blobFromImage）が
    // その寸法でメモリを確保する引数である。** cv::cornerSubPix の win_size で
    // 踏んだのと同じ形なので上限を置く（add-abi-function skill の
    // 「buffer ではないのに上限が要る引数」）。
    if (width < 1 || width > OCVU_DNN_MAX_BLOB_DIM ||
        height < 1 || height > OCVU_DNN_MAX_BLOB_DIM) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_dnn_blob_from_image: width and height must be between 1 and OCVU_DNN_MAX_BLOB_DIM");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_dnn_blob_from_image: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_dnn_blob_from_image: dst handle is invalid");
    }

    // **求めてから dst に入れる。** 失敗経路で dst を途中まで書き換えない
    // （ocvu_stereo.cpp / ocvu_calibration.cpp と同じ作法）。
    cv::Mat result;
    try {
        const cv::Scalar mean_scalar(mean[0], mean[1], mean[2]);
        result = cv::dnn::blobFromImage(*src_mat, scale, cv::Size(width, height),
                                        mean_scalar, swap_rb != 0, crop != 0);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_dnn_net_forward(ocvu_net_handle net, ocvu_mat_handle input, ocvu_mat_handle output) {
    OCVU_TRY_BEGIN
    cv::dnn::Net* net_ptr = ::ocvu::net_table_get(net);
    if (net_ptr == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_dnn_net_forward: net handle is invalid");
    }
    const cv::Mat* input_mat = ::ocvu::mat_table_get(input);
    if (input_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_dnn_net_forward: input handle is invalid");
    }
    cv::Mat* output_mat = ::ocvu::mat_table_get(output);
    if (output_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_dnn_net_forward: output handle is invalid");
    }

    // **求めてから output に入れる。** 失敗経路で output を途中まで
    // 書き換えない（ocvu_stereo.cpp / ocvu_calibration.cpp と同じ作法）。
    cv::Mat result;
    try {
        net_ptr->setInput(*input_mat);
        cv::Mat raw = net_ptr->forward();
        if (raw.empty() || raw.dims < 1) {
            return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR,
                                          "ocvu_dnn_net_forward: forward() produced an empty result");
        }

        // **4 次元の出力を 2 次元へ潰す（決定 A）。** 最後の次元を列数として
        // 残りをすべて行数へ畳み込む。分類モデルの典型的な (1, N) は
        // そのまま 1 x N になる。検出モデルのような (1, C, H, W) では
        // N と C の区別が失われ、C*H 行 x W 列になる —— これは
        // 「分類の 1 x N を想定している」という契約の帰結である。
        const int last_dim = raw.size[raw.dims - 1];
        if (last_dim <= 0) {
            return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR,
                                          "ocvu_dnn_net_forward: forward() produced a degenerate shape");
        }
        const int rows = static_cast<int>(raw.total() / static_cast<size_t>(last_dim));
        result = raw.reshape(1, rows);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *output_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
