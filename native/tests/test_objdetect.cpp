#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <string>
#include <vector>

namespace {

// テスト用の Mat を 1 つ作って、抜けるときに必ず解放する。
class ScopedMat {
public:
    // 既定は 1x1。ocvu_qr_encode は dst の形状を上書きするので、
    // 符号化の受け皿としてはこれで足りる。
    explicit ScopedMat(int rows = 1, int cols = 1) {
        EXPECT_EQ(ocvu_mat_create(rows, cols, OCVU_MAT_TYPE_8UC1, &handle_), OCVU_STATUS_OK);
    }
    ~ScopedMat() { ocvu_mat_release(handle_); }
    ScopedMat(const ScopedMat&) = delete;
    ScopedMat& operator=(const ScopedMat&) = delete;

    ocvu_mat_handle get() const { return handle_; }

private:
    ocvu_mat_handle handle_ = OCVU_MAT_HANDLE_NONE;
};

}  // namespace

TEST(Objdetect, EncodeProducesASquareSingleChannelImage) {
    ScopedMat dst;
    ASSERT_EQ(ocvu_qr_encode("OpenCVUnityNative", dst.get()), OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &info), OCVU_STATUS_OK);
    EXPECT_GT(info.rows, 0);
    EXPECT_EQ(info.rows, info.cols) << "QR は正方形である";
    EXPECT_EQ(info.channels, 1);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_8UC1);
}

TEST(Objdetect, EncodeRejectsInvalidArguments) {
    ScopedMat dst;

    EXPECT_EQ(ocvu_qr_encode(nullptr, dst.get()), OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_qr_encode("", dst.get()), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_qr_encode("x", OCVU_MAT_HANDLE_NONE), OCVU_STATUS_INVALID_HANDLE);
}

TEST(Objdetect, EncodeLeavesTheDestinationUntouchedWhenItFails) {
    ScopedMat dst;

    // 先に成功させて、既知の形にしておく。
    ASSERT_EQ(ocvu_qr_encode("first", dst.get()), OCVU_STATUS_OK);
    ocvu_mat_info before{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &before), OCVU_STATUS_OK);

    // 失敗する呼び出しが dst を書き換えないこと。
    EXPECT_EQ(ocvu_qr_encode(nullptr, dst.get()), OCVU_STATUS_NULL_POINTER);

    ocvu_mat_info after{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &after), OCVU_STATUS_OK);
    EXPECT_EQ(before.rows, after.rows);
    EXPECT_EQ(before.cols, after.cols);
}

TEST(Objdetect, EncodeReportsAnOpenCvErrorForTextThatDoesNotFit) {
    ScopedMat dst;

    // QR コードの最大容量を超える長さ。OpenCV 5.0.0 実測:
    // cv::Exception "(-5:Bad argument) The given input exceeds the maximum
    // capacity of a QR code" を投げる。spec は「符号化できない長さの text は
    // OCVU_STATUS_OPENCV_ERROR になる」と約束しているので、ここでその契約を
    // 確かめる（OCVU_TRY_END 任せだと std::exception 経由で UNKNOWN_ERROR に
    // なってしまう。ocvu_imgcodecs.cpp の catch (const cv::Exception&) と同じ形）。
    const std::string oversized(5000, 'x');
    EXPECT_EQ(ocvu_qr_encode(oversized.c_str(), dst.get()), OCVU_STATUS_OPENCV_ERROR);
}

TEST(Objdetect, DecodeRoundTripsWhatEncodeProduced) {
    const std::string payload = "OpenCVUnityNative";

    ScopedMat img;
    ASSERT_EQ(ocvu_qr_encode(payload.c_str(), img.get()), OCVU_STATUS_OK);

    // 1 回目: 大きさを問い合わせる。buffer に NULL を渡すのは正常な呼び方である。
    int32_t needed = 0;
    ASSERT_EQ(ocvu_qr_decode(img.get(), nullptr, 0, &needed),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(needed, static_cast<int32_t>(payload.size()) + 1) << "NUL の分を含む";

    // 2 回目: その大きさで受け取る。
    std::vector<char> buffer(static_cast<size_t>(needed), '\0');
    ASSERT_EQ(ocvu_qr_decode(img.get(), buffer.data(), needed, &needed),
              OCVU_STATUS_OK);
    EXPECT_STREQ(buffer.data(), payload.c_str());
}

TEST(Objdetect, DecodeReportsNotFoundOnAnImageWithoutAQrCode) {
    // 何も書き込んでいない 64x64。QR は写っていない。
    ocvu_mat_handle blank = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(64, 64, OCVU_MAT_TYPE_8UC1, &blank), OCVU_STATUS_OK);

    int32_t needed = 4321;  // 0 以外で汚す
    EXPECT_EQ(ocvu_qr_decode(blank, nullptr, 0, &needed), OCVU_STATUS_NOT_FOUND);
    EXPECT_EQ(needed, 0) << "見つからなかったときは 0 を書くこと";

    ocvu_mat_release(blank);
}

TEST(Objdetect, DecodeRejectsInvalidArgumentsAndAlwaysWritesZero) {
    ScopedMat img;
    ASSERT_EQ(ocvu_qr_encode("payload", img.get()), OCVU_STATUS_OK);

    // out_required_size が NULL なら、他のどの引数より先に断る。
    EXPECT_EQ(ocvu_qr_decode(img.get(), nullptr, 0, nullptr), OCVU_STATUS_NULL_POINTER);

    // **0 ではない値で汚してから呼ぶ。** 0 で初期化していると
    // 「書いていない」と「0 を書いた」が区別できない（M3.5 で実測。
    // 代入を消しても 16 件が緑のまま通った）。
    int32_t needed = 12345;
    EXPECT_EQ(ocvu_qr_decode(OCVU_MAT_HANDLE_NONE, nullptr, 0, &needed),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(needed, 0);

    needed = 12345;
    EXPECT_EQ(ocvu_qr_decode(img.get(), nullptr, -1, &needed),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(needed, 0);

    // buffer_size > 0 なのに buffer が NULL。
    needed = 12345;
    EXPECT_EQ(ocvu_qr_decode(img.get(), nullptr, 8, &needed),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(needed, 0);
}

TEST(Objdetect, DecodeRejectsATooSmallBufferWithoutWriting) {
    const std::string payload = "OpenCVUnityNative";

    ScopedMat img;
    ASSERT_EQ(ocvu_qr_encode(payload.c_str(), img.get()), OCVU_STATUS_OK);

    int32_t needed = 0;
    ASSERT_EQ(ocvu_qr_decode(img.get(), nullptr, 0, &needed),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    ASSERT_GT(needed, 1);

    // ちょうど 1 バイト足りない buffer を 0xAB で埋めて渡す。
    std::vector<char> buffer(static_cast<size_t>(needed), '\xAB');
    EXPECT_EQ(ocvu_qr_decode(img.get(), buffer.data(), needed - 1, &needed),
              OCVU_STATUS_BUFFER_TOO_SMALL);

    // **1 バイトも書かれていないこと。** 部分的に書くと、呼ぶ側は
    // 途中まで正しい buffer を掴むことになり、壊れ方が
    // 「その場では気づけない」形になる。
    for (const char c : buffer) {
        ASSERT_EQ(c, '\xAB') << "足りない buffer には何も書かないこと";
    }
}
