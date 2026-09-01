#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/objdetect.hpp>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <string>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

namespace {
// QR の仕様が求める quiet zone は最低 4 module。cv::QRCodeEncoder は
// 1 module = 1 pixel で描くので、4 module 分なら 4 px で足りるはずだが、
// 実測で検出が安定しなかったため余裕を持たせてある。
constexpr int kQrQuietZonePixels = 40;
// cv::QRCodeEncoder の出力は 1 module = 1 pixel で、finder pattern が
// 数 pixel 四方に収まってしまうため QRCodeDetector が検出できないことが
// 実測で分かった（quiet zone を足すだけでは直らなかった）。検出前に
// 最近傍補間で拡大し、1 module を複数 pixel に太らせる。倍率は
// 「小さい画像のときだけ」効くよう、拡大後の一辺がこの下限を下回る
// ときにだけ適用する —— 実物の写真のような、既に十分大きい画像を
// 毎回拡大するのは無駄が大きい。
constexpr int kQrMinDetectableSide = 200;
}  // namespace

extern "C" ocvu_status ocvu_qr_encode(const char* text, ocvu_mat_handle dst) {
    OCVU_TRY_BEGIN
    if (text == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_qr_encode: text is NULL");
    }
    if (text[0] == '\0') {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_qr_encode: text is empty");
    }

    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_qr_encode: dst handle is invalid");
    }

    // **符号化してから dst に入れる。** 直接 dst_mat へ encode させると、
    // 失敗したときに dst が途中まで書き換わった状態で残りうる。
    cv::Mat encoded;
    cv::Ptr<cv::QRCodeEncoder> encoder = cv::QRCodeEncoder::create();
    try {
        encoder->encode(std::string(text), encoded);
    } catch (const cv::Exception& e) {
        // OCVU_TRY_END でも捕まるが、そこでは UNKNOWN_ERROR になる。
        // OpenCV 由来だと分かる status を返すためにここで先に受ける
        // （ocvu_imgcodecs.cpp の ocvu_imencode / ocvu_imdecode と同じ形）。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    if (encoded.empty()) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR,
                                      "ocvu_qr_encode: the encoder produced an empty image");
    }

    *dst_mat = encoded;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_qr_decode(ocvu_mat_handle src, char* buffer, int32_t buffer_size, int32_t* out_required_size) {
    OCVU_TRY_BEGIN
    // **これを最初に見る。** 無いと呼ぶ側は 2 回目の大きさを決められないので、
    // 他のどの引数より先に断る。
    if (out_required_size == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_qr_decode: out_required_size is NULL");
    }
    // **何よりも先に 0 を書く。** どの経路で返っても、呼ぶ側が読む値が
    // 前回の呼び出しの残りにならないようにする。以降の早期 return は
    // すべてこの後ろに来る。
    *out_required_size = 0;

    if (buffer_size < 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_qr_decode: buffer_size is negative");
    }
    // buffer == NULL かつ buffer_size == 0 は正常な問い合わせなので通す。
    if (buffer_size > 0 && buffer == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_qr_decode: buffer is NULL but buffer_size is positive");
    }

    cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_qr_decode: src handle is invalid");
    }
    if (src_mat->empty()) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_qr_decode: src is empty");
    }

    std::string text;
    try {
        // **小さい画像は最近傍で拡大してから検出する。** cv::QRCodeEncoder が
        // 作る画像は 1 module = 1 pixel で、finder pattern が数 pixel 四方に
        // 収まってしまい QRCodeDetector が検出できないことが実測で分かった
        // （quiet zone を足すだけでは直らず、ocvu_qr_encode の出力をそのまま
        // detectAndDecode に渡すと DecodeRoundTripsWhatEncodeProduced が
        // NOT_FOUND になって落ちた）。実物の写真のようにすでに十分大きい
        // 画像まで毎回拡大するのは無駄なので、一辺が下限を下回るときだけ
        // 整数倍（最近傍）で拡大する。
        cv::Mat scaled = *src_mat;
        const int shorterSide = std::min(src_mat->cols, src_mat->rows);
        if (shorterSide > 0 && shorterSide < kQrMinDetectableSide) {
            const int scaleFactor = (kQrMinDetectableSide + shorterSide - 1) / shorterSide;
            cv::resize(*src_mat, scaled, cv::Size(), scaleFactor, scaleFactor, cv::INTER_NEAREST);
        }

        // **quiet zone は無条件で足す。** 上の拡大とは直している失敗が違う。
        // 拡大は「module が小さすぎて解像できない」を直すので大きさと
        // 相関し、大きい画像には不要（だから条件付き）。quiet zone は
        // 「余白が無くて finder pattern を切り出せない」を直すので大きさと
        // 相関しない —— 大きく切り詰められた（余白の無い）QR 画像は、
        // 大きくても余白が無い。ここを条件付きにすると、その種の画像だけ
        // 検出できなくなる。cv::QRCodeEncoder が作る画像は仕様上必要な
        // 周囲の余白（quiet zone）を持たない。decode は「encode が作った
        // 画像を含め、渡された画像から検出を試みる」責務なので、ここで
        // 余白を足してから検出する（呼ぶ側に quiet zone の用意を要求
        // しない）。無条件のコピー 1 回分のコストは受け入れている
        // ——実測でボトルネックになったら見直す。
        cv::Mat padded;
        cv::copyMakeBorder(scaled, padded, kQrQuietZonePixels, kQrQuietZonePixels,
                            kQrQuietZonePixels, kQrQuietZonePixels,
                            cv::BORDER_CONSTANT, cv::Scalar::all(255));
        cv::QRCodeDetector detector;
        text = detector.detectAndDecode(padded);
    } catch (const cv::Exception& e) {
        // OCVU_TRY_END でも捕まるが、そこでは UNKNOWN_ERROR になる。
        // OpenCV 由来だと分かる status を返すためにここで先に受ける。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }
    if (text.empty()) {
        // **誤りではない。** 画像に QR が写っていなかっただけである。
        return ::ocvu::set_last_error(OCVU_STATUS_NOT_FOUND,
                                      "ocvu_qr_decode: no QR code was found in src");
    }

    const size_t needed = text.size() + 1;  // NUL を含む
    if (needed > static_cast<size_t>(INT32_MAX)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_qr_decode: the decoded text does not fit in int32_t");
    }
    *out_required_size = static_cast<int32_t>(needed);

    if (static_cast<size_t>(buffer_size) < needed) {
        // 必要量を入れてから返す。buffer には 1 バイトも書かない。
        return ::ocvu::set_last_error(OCVU_STATUS_BUFFER_TOO_SMALL,
                                      "ocvu_qr_decode: buffer is too small for the decoded text");
    }

    std::memcpy(buffer, text.c_str(), needed);
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
