#include <gtest/gtest.h>

#include "opencv_unity_native.h"

TEST(MatLifecycle, CreateProducesAUsableHandle) {
    ocvu_mat_handle h = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(4, 6, OCVU_MAT_TYPE_8UC3, &h), OCVU_STATUS_OK);
    EXPECT_NE(h, OCVU_MAT_HANDLE_NONE);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(h, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 4);
    EXPECT_EQ(info.cols, 6);
    EXPECT_EQ(info.channels, 3);
    EXPECT_EQ(info.step, 6 * 3);
    EXPECT_EQ(info.total_bytes, 4 * 6 * 3);

    EXPECT_EQ(ocvu_mat_release(h), OCVU_STATUS_OK);
}

TEST(MatLifecycle, ReleasedHandleIsRejectedRatherThanCrashing) {
    ocvu_mat_handle h = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(2, 2, OCVU_MAT_TYPE_8UC1, &h), OCVU_STATUS_OK);
    ASSERT_EQ(ocvu_mat_release(h), OCVU_STATUS_OK);

    // 二重解放も、解放後の照会も、落ちずに status になる。
    EXPECT_EQ(ocvu_mat_release(h), OCVU_STATUS_INVALID_HANDLE);

    ocvu_mat_info info{};
    EXPECT_EQ(ocvu_mat_get_info(h, &info), OCVU_STATUS_INVALID_HANDLE);
}

TEST(MatLifecycle, ZeroHandleIsAlwaysInvalid) {
    ocvu_mat_info info{};
    EXPECT_EQ(ocvu_mat_get_info(OCVU_MAT_HANDLE_NONE, &info), OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_mat_release(OCVU_MAT_HANDLE_NONE), OCVU_STATUS_INVALID_HANDLE);
}

TEST(MatLifecycle, ReusedSlotDoesNotResurrectAnOldHandle) {
    // 解放した slot が再利用されても、古い handle は世代が合わず弾かれる。
    // これが世代番号を持つ理由そのものなので、明示的に固定する。
    ocvu_mat_handle first = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &first), OCVU_STATUS_OK);
    ASSERT_EQ(ocvu_mat_release(first), OCVU_STATUS_OK);

    ocvu_mat_handle second = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &second), OCVU_STATUS_OK);
    EXPECT_NE(first, second) << "a fresh handle must not equal a released one";

    ocvu_mat_info info{};
    EXPECT_EQ(ocvu_mat_get_info(first, &info), OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_mat_get_info(second, &info), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_mat_release(second), OCVU_STATUS_OK);
}

TEST(MatLifecycle, CloneCopiesContentIntoAnIndependentHandle) {
    ocvu_mat_handle src = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(3, 3, OCVU_MAT_TYPE_8UC1, &src), OCVU_STATUS_OK);

    ocvu_mat_handle dst = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_clone(src, &dst), OCVU_STATUS_OK);
    EXPECT_NE(dst, src);

    // src を解放しても dst は生きている（別の記憶域である）。
    ASSERT_EQ(ocvu_mat_release(src), OCVU_STATUS_OK);

    ocvu_mat_info info{};
    EXPECT_EQ(ocvu_mat_get_info(dst, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 3);

    EXPECT_EQ(ocvu_mat_release(dst), OCVU_STATUS_OK);
}

TEST(MatLifecycle, NullOutParametersAreRejected) {
    EXPECT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, nullptr), OCVU_STATUS_NULL_POINTER);

    ocvu_mat_handle h = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &h), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_mat_get_info(h, nullptr), OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_mat_clone(h, nullptr), OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_mat_release(h), OCVU_STATUS_OK);
}

TEST(MatLifecycle, InvalidDimensionsAreRejected) {
    ocvu_mat_handle h = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(0, 4, OCVU_MAT_TYPE_8UC1, &h), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_mat_create(4, 0, OCVU_MAT_TYPE_8UC1, &h), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_mat_create(-1, 4, OCVU_MAT_TYPE_8UC1, &h), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(h, OCVU_MAT_HANDLE_NONE) << "out_handle must be left untouched on failure";
}

// **OCVU_MAT_TYPE_* の翻訳表が互いの逆であることを固定する。**
//
// **static_assert では固定できない。** OCVU_MAT_TYPE_* は OpenCV の値の写しでは
// なく、ocvu_mat.cpp の 2 つの switch が翻訳する ABI 独自の番号である ——
// 2026-09-05 に「写しである」と思って static_assert を置いたら 8UC3 と 8UC4 が
// 落ちた（OpenCV 5 は CV_CN_SHIFT を 3 から 5 に変えており、いまの CV_8UC3 は
// 64 である。この ABI の 16 は OpenCV 4 の値のまま残っていた）。
//
// **したがって、ここに書ける不変条件は「往復すると元に戻る」だけである。**
// create が受けた型が get_info でそのまま返ることを、全 6 種類について見る。
TEST(MatLifecycle, EveryMatTypeSurvivesARoundTripThroughTheTranslationTable) {
    struct Case { int32_t type; int32_t expected_channels; int64_t bytes_per_pixel; };
    const Case cases[] = {
        {OCVU_MAT_TYPE_8UC1,  1, 1},
        {OCVU_MAT_TYPE_8UC3,  3, 3},
        {OCVU_MAT_TYPE_8UC4,  4, 4},
        {OCVU_MAT_TYPE_16SC1, 1, 2},
        {OCVU_MAT_TYPE_32FC1, 1, 4},
        {OCVU_MAT_TYPE_64FC1, 1, 8},
    };

    for (const Case& c : cases) {
        ocvu_mat_handle h = OCVU_MAT_HANDLE_NONE;
        ASSERT_EQ(ocvu_mat_create(2, 3, c.type, &h), OCVU_STATUS_OK)
            << "type " << c.type << " を create できない";

        ocvu_mat_info info{};
        ASSERT_EQ(ocvu_mat_get_info(h, &info), OCVU_STATUS_OK);
        EXPECT_EQ(info.type, c.type) << "翻訳表が往復していない（type " << c.type << "）";
        EXPECT_EQ(info.channels, c.expected_channels) << "type " << c.type;
        // step は 1 行のバイト数。cols * 1 画素のバイト数と一致する。
        EXPECT_EQ(info.step, 3 * c.bytes_per_pixel) << "type " << c.type;

        EXPECT_EQ(ocvu_mat_release(h), OCVU_STATUS_OK);
    }
}

// **未知の型は create できない。** 翻訳表に無い番号を素通しにすると、
// cv::Mat が別の型で作られて後から無関係な場所が壊れる。
TEST(MatLifecycle, AnUnknownMatTypeIsRejected) {
    ocvu_mat_handle h = OCVU_MAT_HANDLE_NONE;
    // 64 は OpenCV 5 の CV_8UC3 だが、**この ABI の番号ではない**。
    EXPECT_EQ(ocvu_mat_create(2, 3, 64, &h), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_mat_create(2, 3, -1, &h), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(h, OCVU_MAT_HANDLE_NONE) << "断ったのに out_handle を書いている";
}
