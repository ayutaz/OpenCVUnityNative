// **有効な ONNX を手で組むのは現実的でない。** だからこのテストは
// **壊れた入力に対する振る舞い**を固定する。正常系は L3 が、
// 実物の小さなモデルを使って見る（Task 5）。
#include <gtest/gtest.h>
#include <cstdint>
#include <vector>

#include "opencv_unity_native.h"

TEST(Dnn, ReadingGarbageAsOnnxFailsWithoutCrashing) {
    std::vector<uint8_t> garbage(64, 0xAB);
    ocvu_net_handle handle = 0;

    ocvu_status st = ocvu_dnn_net_read_onnx(
        garbage.data(), static_cast<int32_t>(garbage.size()), &handle);

    // **OPENCV_ERROR を要求する。**
    // OCVU_TRY_END は cv::Exception を UNKNOWN_ERROR に変換するので、
    // この関数は自分で catch (const cv::Exception&) を書かなければならない。
    EXPECT_EQ(st, OCVU_STATUS_OPENCV_ERROR);
    EXPECT_EQ(handle, 0u) << "失敗したのに handle が書かれた";
}

TEST(Dnn, ANullBufferIsRejected) {
    ocvu_net_handle handle = 0;
    EXPECT_EQ(ocvu_dnn_net_read_onnx(nullptr, 16, &handle), OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(handle, 0u);
}

TEST(Dnn, ANullOutHandleIsRejected) {
    std::vector<uint8_t> bytes(16, 0);
    EXPECT_EQ(ocvu_dnn_net_read_onnx(bytes.data(), 16, nullptr),
              OCVU_STATUS_NULL_POINTER);
}

TEST(Dnn, ANegativeOrZeroLengthIsRejected) {
    std::vector<uint8_t> bytes(16, 0);
    ocvu_net_handle handle = 0;
    EXPECT_EQ(ocvu_dnn_net_read_onnx(bytes.data(), 0, &handle),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_dnn_net_read_onnx(bytes.data(), -1, &handle),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(handle, 0u);
}

TEST(Dnn, ReleasingAnUnknownHandleIsRejectedWithoutCrashing) {
    EXPECT_EQ(ocvu_dnn_net_release(0), OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_dnn_net_release(0xDEADBEEF), OCVU_STATUS_INVALID_HANDLE);
}

TEST(Dnn, ForwardOnAnUnknownHandleIsRejected) {
    ocvu_mat_handle input = 0, output = 0;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_32FC1, &input), OCVU_STATUS_OK);
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_32FC1, &output), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_dnn_net_forward(0xDEADBEEF, input, output),
              OCVU_STATUS_INVALID_HANDLE);

    ocvu_mat_release(input);
    ocvu_mat_release(output);
}

// **blob の寸法は呼ぶ側が渡す int32_t で、OpenCV の中で寸法になる。**
// cv::cornerSubPix の win_size で踏んだのと同じ形なので、上限を置く
// （add-abi-function skill の「buffer ではないのに上限が要る引数」）。
TEST(Dnn, AnAbsurdBlobSizeIsRejectedRatherThanAttempted) {
    ocvu_mat_handle src = 0, blob = 0;
    ASSERT_EQ(ocvu_mat_create(8, 8, OCVU_MAT_TYPE_8UC3, &src), OCVU_STATUS_OK);
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_32FC1, &blob), OCVU_STATUS_OK);

    const double mean[3] = {0.0, 0.0, 0.0};
    EXPECT_EQ(
        ocvu_dnn_blob_from_image(src, blob, 1.0, 1 << 20, 1 << 20, mean, 0, 0),
        OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(
        ocvu_dnn_blob_from_image(src, blob, 1.0, 0, 8, mean, 0, 0),
        OCVU_STATUS_INVALID_ARGUMENT);

    ocvu_mat_release(src);
    ocvu_mat_release(blob);
}
