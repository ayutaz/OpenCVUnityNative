// **有効な ONNX を手で組むのは現実的でない。** だからこのテストは
// **壊れた入力に対する振る舞い**を固定する。正常系は L3 が、
// 実物の小さなモデルを使って見る（Task 5）。
#include <gtest/gtest.h>
#include <cstdint>
#include <memory>
#include <vector>

#include <opencv2/dnn.hpp>

// **内部 table への直接アクセス。** `ocvu_dnn_net_forward` の入口検証
// （net -> input -> output の順）を試すには「有効な net handle」が要るが、
// 実物の ONNX が無いので `ocvu_dnn_net_read_onnx` では作れない。
// `net_table_add` で空の `cv::dnn::Net` を直接 table に入れる ——
// `native/tests/test_dnn_table_stability.cpp` が同じ table に対して
// 行っている white-box アクセスと同じ形である。handle の有効性は
// generation + 索引だけで決まるので、中身が空でも「有効な net handle」
// として機能する。
#include "ocvu_dnn_table.h"
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

    EXPECT_EQ(
        ocvu_dnn_blob_from_image(src, blob, 1.0, 1 << 20, 1 << 20, 0.0, 0.0, 0.0, 0, 0),
        OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(
        ocvu_dnn_blob_from_image(src, blob, 1.0, 0, 8, 0.0, 0.0, 0.0, 0, 0),
        OCVU_STATUS_INVALID_ARGUMENT);

    ocvu_mat_release(src);
    ocvu_mat_release(blob);
}

TEST(Dnn, BlobFromImageRejectsInvalidSrcHandle) {
    ocvu_mat_handle dst = 0;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_32FC1, &dst), OCVU_STATUS_OK);

    EXPECT_EQ(
        ocvu_dnn_blob_from_image(0xDEADBEEF, dst, 1.0, 8, 8, 0.0, 0.0, 0.0, 0, 0),
        OCVU_STATUS_INVALID_HANDLE);

    ocvu_mat_release(dst);
}

TEST(Dnn, BlobFromImageRejectsInvalidDstHandle) {
    ocvu_mat_handle src = 0;
    ASSERT_EQ(ocvu_mat_create(8, 8, OCVU_MAT_TYPE_8UC3, &src), OCVU_STATUS_OK);

    EXPECT_EQ(
        ocvu_dnn_blob_from_image(src, 0xDEADBEEF, 1.0, 8, 8, 0.0, 0.0, 0.0, 0, 0),
        OCVU_STATUS_INVALID_HANDLE);

    ocvu_mat_release(src);
}

// **検証の順序をロックする。** spec の summary は「width / height の範囲を
// 先に見る」と約束している。無効な src/dst handle と範囲外の width を
// 同時に渡し、返るのが OCVU_STATUS_INVALID_HANDLE ではなく
// OCVU_STATUS_INVALID_ARGUMENT であることを見る —— これが崩れたら、
// 順序を変えた変更がここで初めて赤くなる（レビュー指摘 M1）。
TEST(Dnn, BlobFromImageChecksDimensionsBeforeHandles) {
    EXPECT_EQ(
        ocvu_dnn_blob_from_image(0xDEADBEEF, 0xDEADBEEF, 1.0, 0, 8, 0.0, 0.0, 0.0, 0, 0),
        OCVU_STATUS_INVALID_ARGUMENT);
}

TEST(Dnn, ForwardRejectsInvalidInputHandle) {
    const ocvu_net_handle net = ::ocvu::net_table_add(std::make_unique<cv::dnn::Net>());
    ocvu_mat_handle output = 0;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_32FC1, &output), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_dnn_net_forward(net, 0xDEADBEEF, output), OCVU_STATUS_INVALID_HANDLE);

    ocvu_mat_release(output);
    ::ocvu::net_table_remove(net);
}

TEST(Dnn, ForwardRejectsInvalidOutputHandle) {
    const ocvu_net_handle net = ::ocvu::net_table_add(std::make_unique<cv::dnn::Net>());
    ocvu_mat_handle input = 0;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_32FC1, &input), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_dnn_net_forward(net, input, 0xDEADBEEF), OCVU_STATUS_INVALID_HANDLE);

    ocvu_mat_release(input);
    ::ocvu::net_table_remove(net);
}

// **これが Unity の実際の壊れ方に一番近い**（`OnDestroy` が net を解放し、
// 生き残ったコルーチンが 1 回だけ forward を呼ぶ）。`ocvu_dnn_net_release`
// という公開関数で解放してから forward を呼ぶ、実際の使用順序をそのまま
// 再現する。
//
// **ここで使う net は実物の ONNX から読んだものではない**（`net_table_add`
// で直接作った空の `cv::dnn::Net`）。handle の有効性は generation と索引
// だけで決まり、中身が空か読み込み済みかには依らないので、この検査で
// 見ている「解放後は INVALID_HANDLE になる」という性質は実物の net でも
// 変わらないはずである —— ただし forward() が実際に走る経路
// （setInput 以降）まではここでは実証していない。実物の ONNX を使った
// 検証は後続タスクの担当。
TEST(Dnn, ForwardOnAReleasedNetIsRejectedWithoutCrashing) {
    const ocvu_net_handle net = ::ocvu::net_table_add(std::make_unique<cv::dnn::Net>());
    ASSERT_EQ(ocvu_dnn_net_release(net), OCVU_STATUS_OK);

    ocvu_mat_handle input = 0, output = 0;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_32FC1, &input), OCVU_STATUS_OK);
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_32FC1, &output), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_dnn_net_forward(net, input, output), OCVU_STATUS_INVALID_HANDLE);

    ocvu_mat_release(input);
    ocvu_mat_release(output);
}
