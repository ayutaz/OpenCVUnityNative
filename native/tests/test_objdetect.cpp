#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <string>

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
