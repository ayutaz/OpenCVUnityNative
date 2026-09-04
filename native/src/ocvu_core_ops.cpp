// core module の基本演算。
//
// **ocvu_mat.cpp にも ocvu_mat_buffer.cpp にも足していない。** あちらは Mat の
// ライフサイクルと buffer の受け渡しで、こちらは画素に対する演算である。
//
// 8 本のうち 7 本は「求めてから dst に丸ごと入れる」形で、失敗したときに dst が
// 途中まで書き換わることが無い。**ocvu_insert_channel だけが違う** —— あれは
// dst の 1 つの channel だけを書き換える関数なので、写しに対して行ってから戻す。

#include <opencv_unity_native.h>

#include <opencv2/core.hpp>

#include <cstdint>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

// 境界に出す値は OpenCV のものをそのまま使う。写し間違いをコンパイル時に落とす
// （ocvu_imgcodecs.cpp / ocvu_imgproc.cpp / ocvu_geometry.cpp と同じ形）。
//
// **OCVU_BITWISE_* にはこれが無い。** cv::bitwise_and などは関数であって定数では
// ないので、固定する相手が上流に存在しない（ヘッダのコメントにも書いてある）。
static_assert(OCVU_NORM_INF == cv::NORM_INF, "OCVU_NORM_INF が cv::NORM_INF と違う");
static_assert(OCVU_NORM_L1 == cv::NORM_L1, "OCVU_NORM_L1 が cv::NORM_L1 と違う");
static_assert(OCVU_NORM_L2 == cv::NORM_L2, "OCVU_NORM_L2 が cv::NORM_L2 と違う");
static_assert(OCVU_NORM_MINMAX == cv::NORM_MINMAX, "OCVU_NORM_MINMAX が cv::NORM_MINMAX と違う");
static_assert(OCVU_BORDER_CONSTANT == cv::BORDER_CONSTANT,
              "OCVU_BORDER_CONSTANT が cv::BORDER_CONSTANT と違う");
static_assert(OCVU_BORDER_REPLICATE == cv::BORDER_REPLICATE,
              "OCVU_BORDER_REPLICATE が cv::BORDER_REPLICATE と違う");
static_assert(OCVU_BORDER_REFLECT == cv::BORDER_REFLECT,
              "OCVU_BORDER_REFLECT が cv::BORDER_REFLECT と違う");
static_assert(OCVU_BORDER_WRAP == cv::BORDER_WRAP, "OCVU_BORDER_WRAP が cv::BORDER_WRAP と違う");
static_assert(OCVU_BORDER_REFLECT_101 == cv::BORDER_REFLECT_101,
              "OCVU_BORDER_REFLECT_101 が cv::BORDER_REFLECT_101 と違う");

namespace {

// LUT の表は 8 bit の値域を全部覆う必要がある。
constexpr int64_t kLutTableBytes = 256;

// **知らない値は素通しにしない。** OpenCV に落とすと「原因不明」になるか、
// 黙って別の意味に解釈される。
//
// **範囲ではなく名指しで判定する。** cv::BorderTypes には BORDER_TRANSPARENT（5）と
// BORDER_ISOLATED（16）も在るが、この ABI は出していない —— 0 以上 4 以下という
// 範囲検査にすると、値が 1 つ増えた日に黙って通り始める。
bool IsKnownBorderType(int32_t border_type) {
    return border_type == OCVU_BORDER_CONSTANT ||
           border_type == OCVU_BORDER_REPLICATE ||
           border_type == OCVU_BORDER_REFLECT ||
           border_type == OCVU_BORDER_WRAP ||
           border_type == OCVU_BORDER_REFLECT_101;
}

// **OCVU_NORM_HAMMING は入っていない。** あれは記述子どうしの距離を測るためのもので、
// cv::normalize に渡す値ではない。
bool IsKnownNormType(int32_t norm_type) {
    return norm_type == OCVU_NORM_INF ||
           norm_type == OCVU_NORM_L1 ||
           norm_type == OCVU_NORM_L2 ||
           norm_type == OCVU_NORM_MINMAX;
}

bool IsKnownBitwiseOp(int32_t op) {
    return op == OCVU_BITWISE_AND ||
           op == OCVU_BITWISE_OR ||
           op == OCVU_BITWISE_XOR ||
           op == OCVU_BITWISE_NOT;
}

}  // namespace

extern "C" ocvu_status ocvu_extract_channel(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t channel_index) {
    OCVU_TRY_BEGIN
    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_extract_channel: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_extract_channel: dst handle is invalid");
    }

    // **handle の妥当性を先に見る。** 両方とも 0（未初期化の変数を渡した場合）だと
    // src == dst も成り立つので、こちらを先に見ないと「同じ handle です」という
    // 的外れな診断になり、本当の誤りが隠れる。
    if (src == dst) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_extract_channel: src and dst must be different handles");
    }

    // **範囲は自分で見る。** OpenCV に落とすと例外になるが、呼ぶ側が直せる
    // 誤りなので INVALID_ARGUMENT で返す。
    if (channel_index < 0 || channel_index >= src_mat->channels()) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_extract_channel: channel_index is out of range for src");
    }

    // **求めてから入れる。** 直接 dst_mat へ書かせると、失敗したときに dst が
    // 途中まで書き換わった状態で残りうる。
    cv::Mat result;
    try {
        cv::extractChannel(*src_mat, result, channel_index);
    } catch (const cv::Exception& e) {
        // OCVU_TRY_END でも捕まるが、そこでは UNKNOWN_ERROR になる。
        // OpenCV 由来だと分かる status を返すためにここで先に受ける。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_insert_channel(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t channel_index) {
    OCVU_TRY_BEGIN
    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_insert_channel: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_insert_channel: dst handle is invalid");
    }
    if (src == dst) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_insert_channel: src and dst must be different handles");
    }

    // 差し込む先は dst なので、範囲は dst の channel 数で決まる。
    if (channel_index < 0 || channel_index >= dst_mat->channels()) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_insert_channel: channel_index is out of range for dst");
    }

    // **この 1 本だけは dst を置き換えず、その場を書き換える。**
    // 失敗したときに dst が途中まで変わりうるので、写しに対して行ってから戻す。
    cv::Mat working = dst_mat->clone();
    try {
        cv::insertChannel(*src_mat, working, channel_index);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = working;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_min_max_loc(ocvu_mat_handle src, double* out_min_value, double* out_max_value, int32_t* out_min_x, int32_t* out_min_y, int32_t* out_max_x, int32_t* out_max_y) {
    OCVU_TRY_BEGIN
    // **NULL でないものには、何よりも先に 0 を書く。** どの経路で返っても、
    // 呼ぶ側が読む値が前回のまま残らないようにする（ocvu_imencode の
    // out_required_size と同じ規則である）。以降のすべての早期 return は
    // この後ろに来る。
    if (out_min_value != nullptr) { *out_min_value = 0.0; }
    if (out_max_value != nullptr) { *out_max_value = 0.0; }
    if (out_min_x != nullptr) { *out_min_x = 0; }
    if (out_min_y != nullptr) { *out_min_y = 0; }
    if (out_max_x != nullptr) { *out_max_x = 0; }
    if (out_max_y != nullptr) { *out_max_y = 0; }

    // **6 つとも NULL は誤りである。** 何も受け取らずに計算だけさせる意味が無い。
    if (out_min_value == nullptr && out_max_value == nullptr &&
        out_min_x == nullptr && out_min_y == nullptr &&
        out_max_x == nullptr && out_max_y == nullptr) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_NULL_POINTER,
            "ocvu_min_max_loc: at least one output must not be NULL");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_min_max_loc: src handle is invalid");
    }

    // **位置を頼まれていないなら、OpenCV にも頼まない。**
    // cv::minMaxLoc は複数 channel でも値は返すが、位置を要求されたときだけ
    // 拒む（cn > 1 では minIdx / maxIdx が両方 NULL であることを要求する）。
    // 常に位置を要求すると、**値だけを求めた呼び出しまで失敗する。**
    const bool wants_min_location = (out_min_x != nullptr || out_min_y != nullptr);
    const bool wants_max_location = (out_max_x != nullptr || out_max_y != nullptr);

    // **求めてから書く。** 例外になったときに一部だけ書かれた状態にしない。
    double min_value = 0.0;
    double max_value = 0.0;
    cv::Point min_point;
    cv::Point max_point;
    try {
        cv::minMaxLoc(*src_mat, &min_value, &max_value,
                      wants_min_location ? &min_point : nullptr,
                      wants_max_location ? &max_point : nullptr);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    if (out_min_value != nullptr) { *out_min_value = min_value; }
    if (out_max_value != nullptr) { *out_max_value = max_value; }
    if (out_min_x != nullptr) { *out_min_x = min_point.x; }
    if (out_min_y != nullptr) { *out_min_y = min_point.y; }
    if (out_max_x != nullptr) { *out_max_x = max_point.x; }
    if (out_max_y != nullptr) { *out_max_y = max_point.y; }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_in_range(ocvu_mat_handle src, ocvu_mat_handle dst, const double* lower, int64_t lower_length, const double* upper, int64_t upper_length) {
    OCVU_TRY_BEGIN
    if (lower == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER, "ocvu_in_range: lower is NULL");
    }
    if (upper == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER, "ocvu_in_range: upper is NULL");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_in_range: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_in_range: dst handle is invalid");
    }

    // **必要量は src の channel 数で決まる。** handle を引いてからでないと分からない。
    // **積は int64_t に上げてから作る。** channels() は高々 4 なので実際には
    // 溢れないが、桁あふれを「収まるはずだから安全」で済ませないのがこの境界の
    // 作法である（M2 で stride の積が反転して踏んだ）。
    //
    // **単位はバイトである。** この ABI の *_length はすべてバイト数なので、
    // ここだけ要素数にすると、既存に慣れた呼び手が 8 分の 1 の値を渡して
    // 検査を通過する方向に倒れる。
    const int64_t needed =
        static_cast<int64_t>(src_mat->channels()) * static_cast<int64_t>(sizeof(double));
    if (lower_length < needed) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_in_range: lower_length (bytes) is too small for the channel count of src");
    }
    if (upper_length < needed) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_in_range: upper_length (bytes) is too small for the channel count of src");
    }

    // cv::Scalar は 4 要素固定。channel 数ぶんだけ写し、残りは 0 のままにする。
    // 借用はこの呼び出しの内側で完結する。
    cv::Scalar lower_scalar;
    cv::Scalar upper_scalar;
    const int channels = src_mat->channels();
    for (int i = 0; i < channels && i < 4; ++i) {
        lower_scalar[i] = lower[i];
        upper_scalar[i] = upper[i];
    }

    cv::Mat result;
    try {
        cv::inRange(*src_mat, lower_scalar, upper_scalar, result);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_normalize(ocvu_mat_handle src, ocvu_mat_handle dst, double alpha, double beta, int32_t norm_type) {
    OCVU_TRY_BEGIN
    if (!IsKnownNormType(norm_type)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_normalize: norm_type is not one of OCVU_NORM_*");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_normalize: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_normalize: dst handle is invalid");
    }

    cv::Mat result;
    try {
        // **dtype は -1 に固定する。** 出力の型を選べるようにすると、
        // 「8 bit の画像を 32 bit 浮動小数へ正規化する」といった、呼ぶ側が
        // 用意した dst の型と食い違う出力が作れてしまう。src と同じ型に揃える。
        cv::normalize(*src_mat, result, alpha, beta, norm_type, -1);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_bitwise(ocvu_mat_handle src1, ocvu_mat_handle src2, ocvu_mat_handle dst, int32_t op) {
    OCVU_TRY_BEGIN
    if (!IsKnownBitwiseOp(op)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_bitwise: op is not one of OCVU_BITWISE_*");
    }

    const cv::Mat* src1_mat = ::ocvu::mat_table_get(src1);
    if (src1_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_bitwise: src1 handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_bitwise: dst handle is invalid");
    }

    // **OCVU_BITWISE_NOT のときだけ src2 を見ない。** 黙って無視するのではなく、
    // そう決めてある（summary に書いてあり、L1 が無効な handle で実証している）。
    const cv::Mat* src2_mat = nullptr;
    if (op != OCVU_BITWISE_NOT) {
        src2_mat = ::ocvu::mat_table_get(src2);
        if (src2_mat == nullptr) {
            return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                          "ocvu_bitwise: src2 handle is invalid");
        }
    }

    cv::Mat result;
    try {
        switch (op) {
            case OCVU_BITWISE_AND: cv::bitwise_and(*src1_mat, *src2_mat, result); break;
            case OCVU_BITWISE_OR:  cv::bitwise_or(*src1_mat, *src2_mat, result); break;
            case OCVU_BITWISE_XOR: cv::bitwise_xor(*src1_mat, *src2_mat, result); break;
            // op は上で OCVU_BITWISE_* のいずれかであることを確かめてあるので、
            // ここに来るのは OCVU_BITWISE_NOT だけである。
            default:               cv::bitwise_not(*src1_mat, result); break;
        }
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_lut(ocvu_mat_handle src, ocvu_mat_handle dst, const uint8_t* table, int64_t table_length) {
    OCVU_TRY_BEGIN
    if (table == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER, "ocvu_lut: table is NULL");
    }
    // **8 bit の値域を全部覆う必要がある。** 足りない表を渡されると
    // cv::LUT が表の外を読む。負の長さもここに捕まる。
    if (table_length < kLutTableBytes) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_lut: table_length (bytes) must be at least 256");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_lut: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_lut: dst handle is invalid");
    }

    // 借用はこの呼び出しの内側で完結する。cv::Mat で包むだけで所有はしない。
    // **読むのは先頭の 256 バイトだけである**（それより長い表を渡されても
    // 残りは使わない）。
    const cv::Mat table_view(1, 256, CV_8U, const_cast<uint8_t*>(table));

    cv::Mat result;
    try {
        cv::LUT(*src_mat, table_view, result);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_copy_make_border(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t top, int32_t bottom, int32_t left, int32_t right, int32_t border_type, double border_value) {
    OCVU_TRY_BEGIN
    if (top < 0 || bottom < 0 || left < 0 || right < 0) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_copy_make_border: top, bottom, left and right must not be negative");
    }
    if (!IsKnownBorderType(border_type)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_copy_make_border: border_type is not one of OCVU_BORDER_*");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_copy_make_border: src handle is invalid");
    }
    cv::Mat* dst_mat = ::ocvu::mat_table_get(dst);
    if (dst_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_copy_make_border: dst handle is invalid");
    }

    // **和を int の中で作らせない。** cv::copyMakeBorder は
    // src.rows + top + bottom を int で計算するので、大きな余白を渡されると
    // 符号つき整数の桁あふれ（未定義動作）になる。int64_t に上げてから断る。
    const int64_t new_rows =
        static_cast<int64_t>(src_mat->rows) + static_cast<int64_t>(top) + static_cast<int64_t>(bottom);
    const int64_t new_cols =
        static_cast<int64_t>(src_mat->cols) + static_cast<int64_t>(left) + static_cast<int64_t>(right);
    if (new_rows > INT32_MAX || new_cols > INT32_MAX) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_copy_make_border: the bordered size does not fit in int32_t");
    }

    cv::Mat result;
    try {
        cv::copyMakeBorder(*src_mat, result, top, bottom, left, right, border_type,
                           cv::Scalar::all(border_value));
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    *dst_mat = result;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
