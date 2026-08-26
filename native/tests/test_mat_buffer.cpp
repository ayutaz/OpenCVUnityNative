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

/*
 * 拒否された呼び出しが、渡された領域を 1 バイトも汚さないことを固定する。
 *
 * 出発点は「負値検査を if (false) に置換しても test-native が exit 0 のまま」
 * という観測だった。当初これをテストの弱さと読んだが、実際は違った。負値は
 * 後続の 2 つの検査に必ず捕まる:
 *   負の stride -> 必ず row_bytes 未満なので stride < row_bytes で落ちる
 *   負の length -> stride * rows は非負なので stride * rows > length で落ちる
 * つまり validate() の先頭にある負値検査は**冗長**であり、それを消しても
 * 挙動が変わらないのは正しい。テストでは固定できないし、する必要も無い。
 *
 * 冗長な検査は残してある。読む人に意図（負値は不正である）を示す価値があり、
 * 将来 row_bytes の算出や順序が変われば冗長でなくなるためである。
 *
 * 代わりにここで固定するのは、より重要な性質である: 検証に落ちた呼び出しは
 * 出力領域へ一切書かない。番兵で前後を挟み、全バイトが無傷であることを見る。
 * ポインタが後方や前方へ飛ぶ誤りは、書き込み先が「渡した範囲の外」になるので、
 * 範囲だけを見るテストでは捕まらない。
 */
TEST_F(MatBufferTest, RejectedNegativeStrideLeavesTheArenaUntouched) {
    // 後方に飛んだ書き込みを検出できるよう、前後に番兵を置いた領域の
    // 真ん中を渡す。範囲内だけを見ていると、負の stride で前方へ飛ぶ
    // 書き込みは見逃す。
    std::vector<uint8_t> arena(1024, 0xC3);
    uint8_t* middle = arena.data() + 512;

    // length は意図的に大きく取る。負値検査が無ければ stride * rows は負になり、
    // 「buffer が短い」判定にも「stride が 1 行より小さい」判定にも掛からない。
    EXPECT_EQ(ocvu_mat_copy_to_buffer(handle_, middle, 512, -1),
              OCVU_STATUS_INVALID_ARGUMENT);

    for (size_t i = 0; i < arena.size(); ++i) {
        ASSERT_EQ(arena[i], 0xC3)
            << "rejected call wrote to the arena at offset " << i;
    }
}

TEST_F(MatBufferTest, RejectedNegativeLengthLeavesTheArenaUntouched) {
    // length が負の場合も同様に、領域が無傷であることまで見る。
    std::vector<uint8_t> arena(1024, 0xA5);
    uint8_t* middle = arena.data() + 512;

    EXPECT_EQ(ocvu_mat_copy_to_buffer(handle_, middle, -1, 4),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(::ocvu_get_last_error_status(), OCVU_STATUS_INVALID_ARGUMENT);

    for (size_t i = 0; i < arena.size(); ++i) {
        ASSERT_EQ(arena[i], 0xA5)
            << "rejected call wrote to the arena at offset " << i;
    }
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
