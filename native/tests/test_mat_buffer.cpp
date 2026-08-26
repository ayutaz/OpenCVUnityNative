#include <gtest/gtest.h>

#include <cstdint>
#include <vector>

#include "opencv_unity_native.h"

namespace {

class MatBufferTest : public ::testing::Test {
protected:
    void SetUp() override {
        ASSERT_EQ(ocvu_mat_create(3, 4, OCVU_MAT_TYPE_8UC1, &handle_), OCVU_STATUS_OK);
    }
    void TearDown() override {
        if (handle_ != OCVU_MAT_HANDLE_NONE) { ocvu_mat_release(handle_); }
    }
    ocvu_mat_handle handle_ = OCVU_MAT_HANDLE_NONE;
};

}  // namespace

TEST_F(MatBufferTest, RoundTripsContentThroughAnExternalBuffer) {
    std::vector<uint8_t> in(3 * 4);
    for (size_t i = 0; i < in.size(); ++i) { in[i] = static_cast<uint8_t>(i + 1); }

    ASSERT_EQ(ocvu_mat_copy_from_buffer(handle_, in.data(),
                                        static_cast<int64_t>(in.size()), 4),
              OCVU_STATUS_OK);

    std::vector<uint8_t> out(in.size(), 0);
    ASSERT_EQ(ocvu_mat_copy_to_buffer(handle_, out.data(),
                                      static_cast<int64_t>(out.size()), 4),
              OCVU_STATUS_OK);
    EXPECT_EQ(in, out);
}

TEST_F(MatBufferTest, HonoursAStrideLargerThanTheRow) {
    // Unity のテクスチャは行が整列されていることがあり、stride > cols になる。
    // 一括 memcpy ではなく行ごとにコピーしていないとここで壊れる。
    const int64_t stride = 8;  // 1 行 4 バイトのデータを 8 バイト間隔で置く
    std::vector<uint8_t> padded(static_cast<size_t>(stride * 3), 0xEE);
    for (int row = 0; row < 3; ++row) {
        for (int col = 0; col < 4; ++col) {
            padded[static_cast<size_t>(row * stride + col)] =
                static_cast<uint8_t>(row * 10 + col);
        }
    }

    ASSERT_EQ(ocvu_mat_copy_from_buffer(handle_, padded.data(),
                                        static_cast<int64_t>(padded.size()), stride),
              OCVU_STATUS_OK);

    std::vector<uint8_t> tight(3 * 4, 0);
    ASSERT_EQ(ocvu_mat_copy_to_buffer(handle_, tight.data(),
                                      static_cast<int64_t>(tight.size()), 4),
              OCVU_STATUS_OK);

    for (int row = 0; row < 3; ++row) {
        for (int col = 0; col < 4; ++col) {
            EXPECT_EQ(tight[static_cast<size_t>(row * 4 + col)],
                      static_cast<uint8_t>(row * 10 + col))
                << "row " << row << " col " << col;
        }
    }
}

TEST_F(MatBufferTest, RejectsABufferShorterThanStrideTimesRows) {
    std::vector<uint8_t> tooSmall(3 * 4 - 1);
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle_, tooSmall.data(),
                                        static_cast<int64_t>(tooSmall.size()), 4),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_mat_copy_to_buffer(handle_, tooSmall.data(),
                                      static_cast<int64_t>(tooSmall.size()), 4),
              OCVU_STATUS_INVALID_ARGUMENT);
}

TEST_F(MatBufferTest, RejectsAStrideSmallerThanOneRow) {
    std::vector<uint8_t> buffer(3 * 4);
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle_, buffer.data(),
                                        static_cast<int64_t>(buffer.size()), 3),
              OCVU_STATUS_INVALID_ARGUMENT);
}

TEST_F(MatBufferTest, RejectsNegativeLengthAndStride) {
    std::vector<uint8_t> buffer(3 * 4);
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle_, buffer.data(), -1, 4),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle_, buffer.data(),
                                        static_cast<int64_t>(buffer.size()), -4),
              OCVU_STATUS_INVALID_ARGUMENT);
}

TEST_F(MatBufferTest, RejectsNullPointers) {
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle_, nullptr, 12, 4), OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_mat_copy_to_buffer(handle_, nullptr, 12, 4), OCVU_STATUS_NULL_POINTER);
}

TEST_F(MatBufferTest, RejectsAReleasedHandleWithoutTouchingTheBuffer) {
    std::vector<uint8_t> buffer(3 * 4, 0x5A);
    ocvu_mat_handle dead = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(3, 4, OCVU_MAT_TYPE_8UC1, &dead), OCVU_STATUS_OK);
    ASSERT_EQ(ocvu_mat_release(dead), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_mat_copy_to_buffer(dead, buffer.data(),
                                      static_cast<int64_t>(buffer.size()), 4),
              OCVU_STATUS_INVALID_HANDLE);
    for (uint8_t b : buffer) {
        EXPECT_EQ(b, 0x5A) << "the buffer must not be written when validation fails";
    }
}
