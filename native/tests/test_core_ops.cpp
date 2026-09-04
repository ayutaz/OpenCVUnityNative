// core module の基本演算 8 本の契約テスト。
//
// **期待値はすべて手で決められる。** 画素の値を自分で置いた小さい画像だけを使い、
// OpenCV に期待値を作らせない。
//
// **ocvu_mat_copy_from_buffer / ocvu_mat_copy_to_buffer の stride はバイト単位である。**
// ここで扱う Mat はすべて 8 bit なので「cols * channels」がそのまま 1 行のバイト数に
// なるが、それは 8 bit だからであって一般には成り立たない（ReadPixels がその前提を
// 明示的に確かめる）。

#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <array>
#include <cstdint>
#include <vector>

namespace {

// handle を持ち、抜けるときに必ず解放する。
//
// **ASSERT_* は関数からその場で return する。** 明示的な release を末尾に置くと、
// 失敗したテストが handle を漏らし、Linux の LeakSanitizer レーンだけが後から
// 赤くなる（ローカルの MSVC ASan には LSan が無いので気づけない）。
class ScopedMat {
public:
    ScopedMat() = default;
    explicit ScopedMat(ocvu_mat_handle handle) : handle_(handle) {}
    ScopedMat(ScopedMat&& other) noexcept : handle_(other.handle_) {
        other.handle_ = OCVU_MAT_HANDLE_NONE;
    }
    ~ScopedMat() {
        if (handle_ != OCVU_MAT_HANDLE_NONE) {
            ocvu_mat_release(handle_);
        }
    }
    ScopedMat(const ScopedMat&) = delete;
    ScopedMat& operator=(const ScopedMat&) = delete;
    ScopedMat& operator=(ScopedMat&&) = delete;

    ocvu_mat_handle get() const { return handle_; }

private:
    ocvu_mat_handle handle_ = OCVU_MAT_HANDLE_NONE;
};

// 書き込み先として渡す Mat。中身は毎回まるごと置き換わるので 1x1 でよい。
//
// **ocvu_mat_create は画素を初期化しない。** ここでは中身を一度も読まないので
// それでよいが、「何も写っていない画像」が要る場面では明示的にゼロを入れること。
ScopedMat MakeDestination() {
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &handle), OCVU_STATUS_OK);
    return ScopedMat(handle);
}

// 2x2 の 4 channel 画像。画素 i の channel c に (i * 10 + c) を入れる。
ScopedMat MakeFourChannel() {
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(2, 2, OCVU_MAT_TYPE_8UC4, &handle), OCVU_STATUS_OK);
    std::array<uint8_t, 16> pixels{};
    for (int i = 0; i < 4; ++i) {
        for (int c = 0; c < 4; ++c) {
            pixels[static_cast<size_t>(i) * 4 + static_cast<size_t>(c)] =
                static_cast<uint8_t>(i * 10 + c);
        }
    }
    // 1 行は 2 画素 x 4 channel = 8 バイト。
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(), 16, 8), OCVU_STATUS_OK);
    return ScopedMat(handle);
}

// 全画素が同じ値の 1 channel 画像。
ScopedMat MakeUniform(int32_t rows, int32_t cols, uint8_t value) {
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(rows, cols, OCVU_MAT_TYPE_8UC1, &handle), OCVU_STATUS_OK);
    std::vector<uint8_t> pixels(static_cast<size_t>(rows) * static_cast<size_t>(cols), value);
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(),
                                        static_cast<int64_t>(pixels.size()), cols),
              OCVU_STATUS_OK);
    return ScopedMat(handle);
}

// 3x3 の 1 channel 画像。左上に 5、中央に 200、残る 7 画素は 100。
ScopedMat MakeExtremes() {
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(3, 3, OCVU_MAT_TYPE_8UC1, &handle), OCVU_STATUS_OK);
    std::array<uint8_t, 9> pixels{};
    for (uint8_t& p : pixels) {
        p = 100;
    }
    pixels[0] = 5;            // (x=0, y=0)
    pixels[1 * 3 + 1] = 200;  // (x=1, y=1)
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(), 9, 3), OCVU_STATUS_OK);
    return ScopedMat(handle);
}

// 8 bit の Mat の中身を全部読む。
//
// **この helper は 1 画素 1 channel が 1 バイトであることを前提にしている。**
// 前提のほうを assertion にしてある —— 黙って成り立たなくなると、読んだ byte 列の
// 解釈だけが静かに狂う（16SC1 や 32FC1 を渡した場合がそれである）。
std::vector<uint8_t> ReadPixels(ocvu_mat_handle handle) {
    ocvu_mat_info info{};
    EXPECT_EQ(ocvu_mat_get_info(handle, &info), OCVU_STATUS_OK);
    const int64_t row_bytes = static_cast<int64_t>(info.cols) * info.channels;
    EXPECT_EQ(info.step, row_bytes) << "ReadPixels は 8 bit の Mat だけを読む";
    std::vector<uint8_t> pixels(static_cast<size_t>(info.rows) * static_cast<size_t>(row_bytes));
    EXPECT_EQ(ocvu_mat_copy_to_buffer(handle, pixels.data(),
                                      static_cast<int64_t>(pixels.size()), row_bytes),
              OCVU_STATUS_OK);
    return pixels;
}

}  // namespace

// ---------------------------------------------------------------------------
// ocvu_extract_channel / ocvu_insert_channel
// ---------------------------------------------------------------------------

TEST(CoreOps, ExtractChannelTakesTheRequestedChannel) {
    const ScopedMat src = MakeFourChannel();
    const ScopedMat dst = MakeDestination();

    ASSERT_EQ(ocvu_extract_channel(src.get(), dst.get(), 2), OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 2);
    EXPECT_EQ(info.cols, 2);
    EXPECT_EQ(info.channels, 1);

    // channel 2 なので、画素 i の値は i * 10 + 2 である。**手で数えられる。**
    const std::vector<uint8_t> pixels = ReadPixels(dst.get());
    ASSERT_EQ(pixels.size(), 4u);
    for (int i = 0; i < 4; ++i) {
        EXPECT_EQ(pixels[static_cast<size_t>(i)], i * 10 + 2) << "画素 " << i;
    }
}

TEST(CoreOps, InsertChannelReplacesOnlyTheRequestedChannel) {
    const ScopedMat target = MakeFourChannel();
    const ScopedMat replacement = MakeUniform(2, 2, 99);

    ASSERT_EQ(ocvu_insert_channel(replacement.get(), target.get(), 1), OCVU_STATUS_OK);

    // **dst は置き換わらない。** channel 1 だけが 99 になり、他は元のままである。
    const std::vector<uint8_t> pixels = ReadPixels(target.get());
    ASSERT_EQ(pixels.size(), 16u);
    for (int i = 0; i < 4; ++i) {
        const size_t base = static_cast<size_t>(i) * 4;
        EXPECT_EQ(pixels[base + 0], i * 10 + 0) << "画素 " << i;
        EXPECT_EQ(pixels[base + 1], 99) << "画素 " << i;
        EXPECT_EQ(pixels[base + 2], i * 10 + 2) << "画素 " << i;
        EXPECT_EQ(pixels[base + 3], i * 10 + 3) << "画素 " << i;
    }
}

TEST(CoreOps, ChannelFunctionsRejectBadArguments) {
    const ScopedMat src = MakeFourChannel();
    const ScopedMat single = MakeUniform(2, 2, 5);
    const ScopedMat dst = MakeDestination();

    // channel の索引が範囲外。**4 channel なので 0..3 だけが有効である。**
    EXPECT_EQ(ocvu_extract_channel(src.get(), dst.get(), -1), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_extract_channel(src.get(), dst.get(), 4), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_insert_channel(single.get(), src.get(), -1), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_insert_channel(single.get(), src.get(), 4), OCVU_STATUS_INVALID_ARGUMENT);

    EXPECT_EQ(ocvu_extract_channel(OCVU_MAT_HANDLE_NONE, dst.get(), 0),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_extract_channel(src.get(), OCVU_MAT_HANDLE_NONE, 0),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_insert_channel(OCVU_MAT_HANDLE_NONE, src.get(), 0),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_insert_channel(single.get(), OCVU_MAT_HANDLE_NONE, 0),
              OCVU_STATUS_INVALID_HANDLE);

    // **handle の検査が src == dst の検査より先に来る。** どちらも無効な
    // handle（0）を渡したときに「同じ handle です」と報告すると、本当の誤り
    // （そもそも handle が無効であること）を隠す。順序をここで固定しておく。
    EXPECT_EQ(ocvu_extract_channel(OCVU_MAT_HANDLE_NONE, OCVU_MAT_HANDLE_NONE, 0),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_insert_channel(OCVU_MAT_HANDLE_NONE, OCVU_MAT_HANDLE_NONE, 0),
              OCVU_STATUS_INVALID_HANDLE);

    // **src と dst が同じ handle なのは誤りである** —— channel を自分自身から
    // 取り出したり差し込んだりする意味が無く、OpenCV の挙動も保証されない。
    EXPECT_EQ(ocvu_extract_channel(src.get(), src.get(), 0), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_insert_channel(src.get(), src.get(), 0), OCVU_STATUS_INVALID_ARGUMENT);
}

TEST(CoreOps, InsertChannelReportsAnOpenCvErrorWhenTheSizesDiffer) {
    const ScopedMat target = MakeFourChannel();           // 2x2
    const ScopedMat replacement = MakeUniform(3, 3, 42);  // 3x3

    // **OPENCV_ERROR は約束しただけでは実在しない。** cv::Exception を個別に
    // 受けていなければ UNKNOWN_ERROR になるので、そこを実際に通す。
    EXPECT_EQ(ocvu_insert_channel(replacement.get(), target.get(), 1),
              OCVU_STATUS_OPENCV_ERROR);

    // 失敗したので target は 1 バイトも変わっていない。
    const std::vector<uint8_t> pixels = ReadPixels(target.get());
    ASSERT_EQ(pixels.size(), 16u);
    for (int i = 0; i < 4; ++i) {
        for (int c = 0; c < 4; ++c) {
            EXPECT_EQ(pixels[static_cast<size_t>(i) * 4 + static_cast<size_t>(c)],
                      i * 10 + c)
                << "画素 " << i << " channel " << c;
        }
    }
}

// ---------------------------------------------------------------------------
// ocvu_min_max_loc
// ---------------------------------------------------------------------------

TEST(CoreOps, MinMaxLocFindsBothExtremesAndTheirPositions) {
    const ScopedMat src = MakeExtremes();

    double min_value = -1.0;
    double max_value = -1.0;
    int32_t min_x = -1;
    int32_t min_y = -1;
    int32_t max_x = -1;
    int32_t max_y = -1;

    ASSERT_EQ(ocvu_min_max_loc(src.get(), &min_value, &max_value,
                               &min_x, &min_y, &max_x, &max_y),
              OCVU_STATUS_OK);

    EXPECT_DOUBLE_EQ(min_value, 5.0);
    EXPECT_DOUBLE_EQ(max_value, 200.0);
    EXPECT_EQ(min_x, 0);
    EXPECT_EQ(min_y, 0);
    EXPECT_EQ(max_x, 1);
    EXPECT_EQ(max_y, 1);
}

TEST(CoreOps, MinMaxLocAllowsAskingForOnlySomeOutputs) {
    const ScopedMat src = MakeExtremes();

    // 最大値だけ欲しいのは普通のことなので、他は NULL でよい。
    double max_value = -1.0;
    EXPECT_EQ(ocvu_min_max_loc(src.get(), nullptr, &max_value,
                               nullptr, nullptr, nullptr, nullptr),
              OCVU_STATUS_OK);
    EXPECT_DOUBLE_EQ(max_value, 200.0);

    // 位置の片方だけでもよい。
    int32_t max_x = -1;
    EXPECT_EQ(ocvu_min_max_loc(src.get(), nullptr, nullptr,
                               nullptr, nullptr, &max_x, nullptr),
              OCVU_STATUS_OK);
    EXPECT_EQ(max_x, 1);

    // **6 つとも NULL は誤りである** —— 何も受け取らずに計算だけさせる意味が無い。
    EXPECT_EQ(ocvu_min_max_loc(src.get(), nullptr, nullptr,
                               nullptr, nullptr, nullptr, nullptr),
              OCVU_STATUS_NULL_POINTER);
}

TEST(CoreOps, MinMaxLocReturnsValuesForMultiChannelButRefusesPositions) {
    const ScopedMat src = MakeFourChannel();

    // **複数 channel でも値は返る。** cv::minMaxLoc が拒むのは位置を要求した
    // ときだけなので、位置を頼まれていなければ OpenCV にも頼まない ——
    // そうしないと「値だけを求めた呼び出し」まで失敗する。
    // 値は全 channel を通した最小・最大で、0 と 33 である（画素 i の channel c が
    // i * 10 + c なので、最小は画素 0 の channel 0、最大は画素 3 の channel 3）。
    double min_value = -1.0;
    double max_value = -1.0;
    EXPECT_EQ(ocvu_min_max_loc(src.get(), &min_value, &max_value,
                               nullptr, nullptr, nullptr, nullptr),
              OCVU_STATUS_OK);
    EXPECT_DOUBLE_EQ(min_value, 0.0);
    EXPECT_DOUBLE_EQ(max_value, 33.0);

    // 位置を 1 つでも頼むと OpenCV が拒む。
    int32_t min_x = 12345;
    EXPECT_EQ(ocvu_min_max_loc(src.get(), nullptr, nullptr,
                               &min_x, nullptr, nullptr, nullptr),
              OCVU_STATUS_OPENCV_ERROR);
    EXPECT_EQ(min_x, 0) << "失敗時は 0 を書くこと";
}

TEST(CoreOps, MinMaxLocZeroesTheOutputsOnFailure) {
    // **0 ではない値で汚してから呼ぶ。** 0 で初期化すると「書いていない」と
    // 「0 を書いた」が区別できない。
    double min_value = 12345.0;
    double max_value = 12345.0;
    int32_t min_x = 12345;
    int32_t min_y = 12345;
    int32_t max_x = 12345;
    int32_t max_y = 12345;

    EXPECT_EQ(ocvu_min_max_loc(OCVU_MAT_HANDLE_NONE, &min_value, &max_value,
                               &min_x, &min_y, &max_x, &max_y),
              OCVU_STATUS_INVALID_HANDLE);

    EXPECT_DOUBLE_EQ(min_value, 0.0) << "失敗時は 0 を書くこと";
    EXPECT_DOUBLE_EQ(max_value, 0.0) << "失敗時は 0 を書くこと";
    EXPECT_EQ(min_x, 0) << "失敗時は 0 を書くこと";
    EXPECT_EQ(min_y, 0) << "失敗時は 0 を書くこと";
    EXPECT_EQ(max_x, 0) << "失敗時は 0 を書くこと";
    EXPECT_EQ(max_y, 0) << "失敗時は 0 を書くこと";
}

// ---------------------------------------------------------------------------
// ocvu_in_range
// ---------------------------------------------------------------------------

TEST(CoreOps, InRangeMarksThePixelsInsideTheBounds) {
    const ScopedMat src = MakeExtremes();
    const ScopedMat dst = MakeDestination();

    // 50..150 の間だけ 255 にする。5 と 200 は外れ、100 が 7 個残る。
    const std::array<double, 1> lower{50.0};
    const std::array<double, 1> upper{150.0};

    ASSERT_EQ(ocvu_in_range(src.get(), dst.get(),
                            lower.data(), static_cast<int64_t>(sizeof(lower)),
                            upper.data(), static_cast<int64_t>(sizeof(upper))),
              OCVU_STATUS_OK);

    const std::vector<uint8_t> pixels = ReadPixels(dst.get());
    ASSERT_EQ(pixels.size(), 9u);
    int lit = 0;
    for (uint8_t p : pixels) {
        if (p == 255) {
            ++lit;
        }
    }
    EXPECT_EQ(lit, 7) << "100 の画素が 7 個あるはずである";
    EXPECT_EQ(pixels[0], 0) << "5 は範囲外である";
    EXPECT_EQ(pixels[1 * 3 + 1], 0) << "200 は範囲外である";
}

TEST(CoreOps, InRangeRequiresOneBoundPerChannel) {
    const ScopedMat src = MakeFourChannel();
    const ScopedMat dst = MakeDestination();

    const std::array<double, 4> lower{0.0, 0.0, 0.0, 0.0};
    const std::array<double, 4> upper{5.0, 5.0, 5.0, 5.0};
    const int64_t four = static_cast<int64_t>(sizeof(lower));  // double 4 個 = 32 バイト

    // **必要量は src の channel 数で決まる。** 1 個ぶんでは足りない。
    EXPECT_EQ(ocvu_in_range(src.get(), dst.get(),
                            lower.data(), static_cast<int64_t>(sizeof(double)),
                            upper.data(), four),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_in_range(src.get(), dst.get(),
                            lower.data(), four,
                            upper.data(), static_cast<int64_t>(sizeof(double))),
              OCVU_STATUS_INVALID_ARGUMENT);

    ASSERT_EQ(ocvu_in_range(src.get(), dst.get(), lower.data(), four, upper.data(), four),
              OCVU_STATUS_OK);

    // **すべての channel が範囲に入っている画素だけ**が 255 になる。画素 0 の
    // channel は 0/1/2/3 なので通り、画素 1 以降は 10 以上なので落ちる。
    const std::vector<uint8_t> pixels = ReadPixels(dst.get());
    ASSERT_EQ(pixels.size(), 4u);
    EXPECT_EQ(pixels[0], 255);
    EXPECT_EQ(pixels[1], 0);
    EXPECT_EQ(pixels[2], 0);
    EXPECT_EQ(pixels[3], 0);
}

TEST(CoreOps, InRangeRejectsBadArguments) {
    const ScopedMat src = MakeExtremes();
    const ScopedMat dst = MakeDestination();
    const std::array<double, 1> bound{50.0};
    const int64_t bytes = static_cast<int64_t>(sizeof(bound));

    EXPECT_EQ(ocvu_in_range(src.get(), dst.get(), nullptr, bytes, bound.data(), bytes),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_in_range(src.get(), dst.get(), bound.data(), bytes, nullptr, bytes),
              OCVU_STATUS_NULL_POINTER);

    // **長さはバイト数である。** src の channel 数ぶんの double が要る（ここでは 1 個）。
    EXPECT_EQ(ocvu_in_range(src.get(), dst.get(), bound.data(), bytes - 1, bound.data(), bytes),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_in_range(src.get(), dst.get(), bound.data(), bytes, bound.data(), bytes - 1),
              OCVU_STATUS_INVALID_ARGUMENT);
    // 負の長さも同じ関門に捕まる。
    EXPECT_EQ(ocvu_in_range(src.get(), dst.get(), bound.data(), -1, bound.data(), bytes),
              OCVU_STATUS_INVALID_ARGUMENT);

    EXPECT_EQ(ocvu_in_range(OCVU_MAT_HANDLE_NONE, dst.get(),
                            bound.data(), bytes, bound.data(), bytes),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_in_range(src.get(), OCVU_MAT_HANDLE_NONE,
                            bound.data(), bytes, bound.data(), bytes),
              OCVU_STATUS_INVALID_HANDLE);
}

// ---------------------------------------------------------------------------
// ocvu_bitwise
// ---------------------------------------------------------------------------

TEST(CoreOps, BitwiseAndOrXorProduceTheExpectedValues) {
    // 0b1100 と 0b1010 の組み合わせ。**手で計算できる。**
    const ScopedMat a = MakeUniform(2, 2, 0b1100);
    const ScopedMat b = MakeUniform(2, 2, 0b1010);
    const ScopedMat dst = MakeDestination();

    ASSERT_EQ(ocvu_bitwise(a.get(), b.get(), dst.get(), OCVU_BITWISE_AND), OCVU_STATUS_OK);
    for (uint8_t p : ReadPixels(dst.get())) {
        EXPECT_EQ(p, 0b1000);
    }

    ASSERT_EQ(ocvu_bitwise(a.get(), b.get(), dst.get(), OCVU_BITWISE_OR), OCVU_STATUS_OK);
    for (uint8_t p : ReadPixels(dst.get())) {
        EXPECT_EQ(p, 0b1110);
    }

    ASSERT_EQ(ocvu_bitwise(a.get(), b.get(), dst.get(), OCVU_BITWISE_XOR), OCVU_STATUS_OK);
    for (uint8_t p : ReadPixels(dst.get())) {
        EXPECT_EQ(p, 0b0110);
    }
}

TEST(CoreOps, BitwiseNotIgnoresTheSecondSource) {
    const ScopedMat a = MakeUniform(2, 2, 0b00001111);
    const ScopedMat dst = MakeDestination();

    // **NOT は src2 を見ない。** 無効な handle を渡しても通ることで、
    // 「無視する」という契約を実証する。
    ASSERT_EQ(ocvu_bitwise(a.get(), OCVU_MAT_HANDLE_NONE, dst.get(), OCVU_BITWISE_NOT),
              OCVU_STATUS_OK);
    for (uint8_t p : ReadPixels(dst.get())) {
        EXPECT_EQ(p, 0b11110000);
    }
}

TEST(CoreOps, BitwiseRejectsBadArguments) {
    const ScopedMat a = MakeUniform(2, 2, 1);
    const ScopedMat b = MakeUniform(2, 2, 2);
    const ScopedMat dst = MakeDestination();

    EXPECT_EQ(ocvu_bitwise(a.get(), b.get(), dst.get(), 99), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_bitwise(a.get(), b.get(), dst.get(), -1), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_bitwise(OCVU_MAT_HANDLE_NONE, b.get(), dst.get(), OCVU_BITWISE_AND),
              OCVU_STATUS_INVALID_HANDLE);
    // **AND では src2 が要る。** NOT と違ってここは無効を通さない。
    EXPECT_EQ(ocvu_bitwise(a.get(), OCVU_MAT_HANDLE_NONE, dst.get(), OCVU_BITWISE_AND),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_bitwise(a.get(), b.get(), OCVU_MAT_HANDLE_NONE, OCVU_BITWISE_AND),
              OCVU_STATUS_INVALID_HANDLE);
    // NOT でも dst は要る。
    EXPECT_EQ(ocvu_bitwise(a.get(), b.get(), OCVU_MAT_HANDLE_NONE, OCVU_BITWISE_NOT),
              OCVU_STATUS_INVALID_HANDLE);
}

TEST(CoreOps, BitwiseReportsAnOpenCvErrorWhenTheSizesDiffer) {
    const ScopedMat a = MakeUniform(2, 2, 1);
    const ScopedMat b = MakeUniform(3, 3, 2);
    const ScopedMat dst = MakeDestination();

    EXPECT_EQ(ocvu_bitwise(a.get(), b.get(), dst.get(), OCVU_BITWISE_AND),
              OCVU_STATUS_OPENCV_ERROR);

    // 失敗したので dst は置き換わっていない（作ったときの 1x1 のままである）。
    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 1);
    EXPECT_EQ(info.cols, 1);
}

// ---------------------------------------------------------------------------
// ocvu_lut
// ---------------------------------------------------------------------------

TEST(CoreOps, LutReplacesEveryValueThroughTheTable) {
    const ScopedMat src = MakeUniform(2, 2, 3);
    const ScopedMat dst = MakeDestination();

    // 索引 i を 255 - i にする表。値 3 は 252 になる。
    std::array<uint8_t, 256> table{};
    for (int i = 0; i < 256; ++i) {
        table[static_cast<size_t>(i)] = static_cast<uint8_t>(255 - i);
    }

    ASSERT_EQ(ocvu_lut(src.get(), dst.get(), table.data(), 256), OCVU_STATUS_OK);
    for (uint8_t p : ReadPixels(dst.get())) {
        EXPECT_EQ(p, 252);
    }
}

TEST(CoreOps, LutRejectsBadArguments) {
    const ScopedMat src = MakeUniform(2, 2, 3);
    const ScopedMat dst = MakeDestination();
    std::array<uint8_t, 256> table{};

    EXPECT_EQ(ocvu_lut(src.get(), dst.get(), nullptr, 256), OCVU_STATUS_NULL_POINTER);
    // **表は 8 bit の値域を全部覆う 256 バイトが要る。**
    EXPECT_EQ(ocvu_lut(src.get(), dst.get(), table.data(), 255), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_lut(src.get(), dst.get(), table.data(), 0), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_lut(src.get(), dst.get(), table.data(), -1), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_lut(OCVU_MAT_HANDLE_NONE, dst.get(), table.data(), 256),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_lut(src.get(), OCVU_MAT_HANDLE_NONE, table.data(), 256),
              OCVU_STATUS_INVALID_HANDLE);
}

TEST(CoreOps, LutReportsAnOpenCvErrorForANonEightBitSource) {
    ocvu_mat_handle raw = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(2, 2, OCVU_MAT_TYPE_16SC1, &raw), OCVU_STATUS_OK);
    const ScopedMat src(raw);
    const ScopedMat dst = MakeDestination();
    std::array<uint8_t, 256> table{};

    // 表は 8 bit の値域しか覆えないので、src が 8 bit でなければ引きようがない。
    EXPECT_EQ(ocvu_lut(src.get(), dst.get(), table.data(), 256), OCVU_STATUS_OPENCV_ERROR);
}

// ---------------------------------------------------------------------------
// ocvu_normalize
// ---------------------------------------------------------------------------

TEST(CoreOps, NormalizeMinMaxStretchesToTheGivenRange) {
    // 5 と 200 を含む画像を 0..255 へ引き伸ばすと、最小が 0、最大が 255 になる。
    const ScopedMat src = MakeExtremes();
    const ScopedMat dst = MakeDestination();

    ASSERT_EQ(ocvu_normalize(src.get(), dst.get(), 0.0, 255.0, OCVU_NORM_MINMAX),
              OCVU_STATUS_OK);

    // **出力は src と同じ型である**（型変換をこの ABI に持ち込んでいない）。
    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_8UC1);

    double min_value = -1.0;
    double max_value = -1.0;
    ASSERT_EQ(ocvu_min_max_loc(dst.get(), &min_value, &max_value,
                               nullptr, nullptr, nullptr, nullptr),
              OCVU_STATUS_OK);
    EXPECT_DOUBLE_EQ(min_value, 0.0);
    EXPECT_DOUBLE_EQ(max_value, 255.0);
}

TEST(CoreOps, NormalizeRejectsBadArguments) {
    const ScopedMat src = MakeExtremes();
    const ScopedMat dst = MakeDestination();

    EXPECT_EQ(ocvu_normalize(src.get(), dst.get(), 0.0, 255.0, 99),
              OCVU_STATUS_INVALID_ARGUMENT);
    // **OCVU_NORM_HAMMING は記述子どうしの距離を測るためのもので、正規化には
    // 使えない。** 値の範囲で判定していると素通りするので、名指しで断る。
    EXPECT_EQ(ocvu_normalize(src.get(), dst.get(), 0.0, 255.0, OCVU_NORM_HAMMING),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_normalize(OCVU_MAT_HANDLE_NONE, dst.get(), 0.0, 255.0, OCVU_NORM_MINMAX),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_normalize(src.get(), OCVU_MAT_HANDLE_NONE, 0.0, 255.0, OCVU_NORM_MINMAX),
              OCVU_STATUS_INVALID_HANDLE);
}

// ---------------------------------------------------------------------------
// ocvu_copy_make_border
// ---------------------------------------------------------------------------

TEST(CoreOps, CopyMakeBorderGrowsTheImageByTheGivenAmounts) {
    // 2x2 に上 1 / 下 2 / 左 3 / 右 4 を足すと 5x9 になる。**手で数えられる。**
    const ScopedMat src = MakeUniform(2, 2, 128);
    const ScopedMat dst = MakeDestination();

    ASSERT_EQ(ocvu_copy_make_border(src.get(), dst.get(), 1, 2, 3, 4,
                                    OCVU_BORDER_CONSTANT, 7.0),
              OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 5);
    EXPECT_EQ(info.cols, 9);

    const std::vector<uint8_t> pixels = ReadPixels(dst.get());
    ASSERT_EQ(pixels.size(), 45u);
    // 左上の隅は余白なので border_value が入る。
    EXPECT_EQ(pixels[0], 7);
    // 元の画像は (row 1, col 3) から始まる。
    EXPECT_EQ(pixels[static_cast<size_t>(1) * 9 + 3], 128);
    // 右下の隅も余白である。
    EXPECT_EQ(pixels[44], 7);
}

TEST(CoreOps, CopyMakeBorderReplicatesTheEdgeWhenAsked) {
    // 左上が 5 の 3x3 に上 1 / 左 1 の余白を足すと、余白は隣の画素の写しになる。
    const ScopedMat src = MakeExtremes();
    const ScopedMat dst = MakeDestination();

    ASSERT_EQ(ocvu_copy_make_border(src.get(), dst.get(), 1, 0, 1, 0,
                                    OCVU_BORDER_REPLICATE, 7.0),
              OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 4);
    EXPECT_EQ(info.cols, 4);

    const std::vector<uint8_t> pixels = ReadPixels(dst.get());
    ASSERT_EQ(pixels.size(), 16u);
    // **border_value は使われない。** 左上の隅は元の左上（5）の写しである。
    EXPECT_EQ(pixels[0], 5);
    EXPECT_EQ(pixels[1 * 4 + 1], 5) << "元の左上がここに来る";
}

TEST(CoreOps, CopyMakeBorderRejectsBadArguments) {
    const ScopedMat src = MakeUniform(2, 2, 128);
    const ScopedMat dst = MakeDestination();

    // 負の余白は誤りである。
    EXPECT_EQ(ocvu_copy_make_border(src.get(), dst.get(), -1, 0, 0, 0,
                                    OCVU_BORDER_CONSTANT, 0.0),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_copy_make_border(src.get(), dst.get(), 0, -1, 0, 0,
                                    OCVU_BORDER_CONSTANT, 0.0),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_copy_make_border(src.get(), dst.get(), 0, 0, -1, 0,
                                    OCVU_BORDER_CONSTANT, 0.0),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_copy_make_border(src.get(), dst.get(), 0, 0, 0, -1,
                                    OCVU_BORDER_CONSTANT, 0.0),
              OCVU_STATUS_INVALID_ARGUMENT);

    EXPECT_EQ(ocvu_copy_make_border(src.get(), dst.get(), 1, 1, 1, 1, 99, 0.0),
              OCVU_STATUS_INVALID_ARGUMENT);
    // **cv::BORDER_TRANSPARENT（5）と cv::BORDER_ISOLATED（16）は出していない。**
    // 範囲ではなく名指しで判定していることを、隣の値で確かめる。
    EXPECT_EQ(ocvu_copy_make_border(src.get(), dst.get(), 1, 1, 1, 1, 5, 0.0),
              OCVU_STATUS_INVALID_ARGUMENT);

    // **出来上がりが int32_t に収まらない大きさは断る。** OpenCV に落とすと
    // rows + top + bottom が int の中で桁あふれし、未定義動作になる。
    EXPECT_EQ(ocvu_copy_make_border(src.get(), dst.get(), 2147483647, 2147483647, 0, 0,
                                    OCVU_BORDER_CONSTANT, 0.0),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_copy_make_border(src.get(), dst.get(), 0, 0, 2147483647, 2147483647,
                                    OCVU_BORDER_CONSTANT, 0.0),
              OCVU_STATUS_INVALID_ARGUMENT);

    EXPECT_EQ(ocvu_copy_make_border(OCVU_MAT_HANDLE_NONE, dst.get(), 1, 1, 1, 1,
                                    OCVU_BORDER_CONSTANT, 0.0),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_copy_make_border(src.get(), OCVU_MAT_HANDLE_NONE, 1, 1, 1, 1,
                                    OCVU_BORDER_CONSTANT, 0.0),
              OCVU_STATUS_INVALID_HANDLE);
}
