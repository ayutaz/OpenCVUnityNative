#include <gtest/gtest.h>

#include <cstdint>
#include <vector>

#include "opencv_unity_native.h"

namespace {

ocvu_mat_handle MakeMat(int rows, int cols, int32_t type) {
    ocvu_mat_handle h = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(rows, cols, type, &h), OCVU_STATUS_OK);
    return h;
}

}  // namespace

TEST(Imgproc, CvtColorBgrToGrayProducesOneChannel) {
    ocvu_mat_handle src = MakeMat(2, 2, OCVU_MAT_TYPE_8UC3);
    ocvu_mat_handle dst = MakeMat(1, 1, OCVU_MAT_TYPE_8UC1);

    // BGR = (255, 255, 255) を 4 画素。灰色化すると 255 になる。
    std::vector<uint8_t> white(2 * 2 * 3, 255);
    ASSERT_EQ(ocvu_mat_copy_from_buffer(src, white.data(),
                                        static_cast<int64_t>(white.size()), 2 * 3),
              OCVU_STATUS_OK);

    ASSERT_EQ(ocvu_cvt_color(src, dst, OCVU_CVT_BGR2GRAY), OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.channels, 1);
    EXPECT_EQ(info.rows, 2);
    EXPECT_EQ(info.cols, 2);

    std::vector<uint8_t> gray(4, 0);
    ASSERT_EQ(ocvu_mat_copy_to_buffer(dst, gray.data(), 4, 2), OCVU_STATUS_OK);
    for (uint8_t v : gray) { EXPECT_EQ(v, 255); }

    ocvu_mat_release(src);
    ocvu_mat_release(dst);
}

TEST(Imgproc, ResizeChangesTheReportedShape) {
    ocvu_mat_handle src = MakeMat(4, 4, OCVU_MAT_TYPE_8UC1);
    ocvu_mat_handle dst = MakeMat(1, 1, OCVU_MAT_TYPE_8UC1);

    ASSERT_EQ(ocvu_resize(src, dst, 2, 8, OCVU_INTER_LINEAR), OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.cols, 2) << "width maps to cols";
    EXPECT_EQ(info.rows, 8) << "height maps to rows";

    ocvu_mat_release(src);
    ocvu_mat_release(dst);
}

TEST(Imgproc, GaussianBlurSpreadsASinglePixel) {
    ocvu_mat_handle src = MakeMat(5, 5, OCVU_MAT_TYPE_8UC1);
    ocvu_mat_handle dst = MakeMat(1, 1, OCVU_MAT_TYPE_8UC1);

    std::vector<uint8_t> dot(25, 0);
    dot[2 * 5 + 2] = 255;  // 中央だけ白
    ASSERT_EQ(ocvu_mat_copy_from_buffer(src, dot.data(), 25, 5), OCVU_STATUS_OK);

    ASSERT_EQ(ocvu_gaussian_blur(src, dst, 3, 3, 0.0, 0.0), OCVU_STATUS_OK);

    std::vector<uint8_t> blurred(25, 0);
    ASSERT_EQ(ocvu_mat_copy_to_buffer(dst, blurred.data(), 25, 5), OCVU_STATUS_OK);

    EXPECT_LT(blurred[2 * 5 + 2], 255) << "the centre must lose intensity";
    EXPECT_GT(blurred[2 * 5 + 1], 0) << "a neighbour must gain intensity";

    ocvu_mat_release(src);
    ocvu_mat_release(dst);
}

TEST(Imgproc, SameHandleForSourceAndDestinationIsRejected) {
    ocvu_mat_handle h = MakeMat(2, 2, OCVU_MAT_TYPE_8UC3);
    EXPECT_EQ(ocvu_cvt_color(h, h, OCVU_CVT_BGR2GRAY), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_resize(h, h, 4, 4, OCVU_INTER_LINEAR), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_gaussian_blur(h, h, 3, 3, 0.0, 0.0), OCVU_STATUS_INVALID_ARGUMENT);
    ocvu_mat_release(h);
}

TEST(Imgproc, InvalidHandlesAreRejected) {
    ocvu_mat_handle valid = MakeMat(2, 2, OCVU_MAT_TYPE_8UC3);
    EXPECT_EQ(ocvu_cvt_color(OCVU_MAT_HANDLE_NONE, valid, OCVU_CVT_BGR2GRAY),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_cvt_color(valid, OCVU_MAT_HANDLE_NONE, OCVU_CVT_BGR2GRAY),
              OCVU_STATUS_INVALID_HANDLE);
    ocvu_mat_release(valid);
}

TEST(Imgproc, OpenCvFailureBecomesOpenCvErrorNotUnknownError) {
    // 1 チャンネルの Mat に BGR2GRAY を掛けると OpenCV が例外を投げる。
    // 例外が ABI を越えないだけでなく、由来が分かる status になること。
    ocvu_mat_handle src = MakeMat(2, 2, OCVU_MAT_TYPE_8UC1);
    ocvu_mat_handle dst = MakeMat(1, 1, OCVU_MAT_TYPE_8UC1);

    EXPECT_EQ(ocvu_cvt_color(src, dst, OCVU_CVT_BGR2GRAY), OCVU_STATUS_OPENCV_ERROR);
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_OPENCV_ERROR);

    ocvu_mat_release(src);
    ocvu_mat_release(dst);
}

TEST(Imgproc, InvalidKernelSizeIsRejected) {
    ocvu_mat_handle src = MakeMat(4, 4, OCVU_MAT_TYPE_8UC1);
    ocvu_mat_handle dst = MakeMat(1, 1, OCVU_MAT_TYPE_8UC1);

    // GaussianBlur の kernel は正の奇数でなければならない。
    EXPECT_EQ(ocvu_gaussian_blur(src, dst, 2, 3, 0.0, 0.0), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_gaussian_blur(src, dst, 0, 3, 0.0, 0.0), OCVU_STATUS_INVALID_ARGUMENT);

    ocvu_mat_release(src);
    ocvu_mat_release(dst);
}

TEST(Imgproc, NonPositiveResizeTargetIsRejected) {
    ocvu_mat_handle src = MakeMat(4, 4, OCVU_MAT_TYPE_8UC1);
    ocvu_mat_handle dst = MakeMat(1, 1, OCVU_MAT_TYPE_8UC1);

    EXPECT_EQ(ocvu_resize(src, dst, 0, 4, OCVU_INTER_LINEAR), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_resize(src, dst, 4, -1, OCVU_INTER_LINEAR), OCVU_STATUS_INVALID_ARGUMENT);

    ocvu_mat_release(src);
    ocvu_mat_release(dst);
}
