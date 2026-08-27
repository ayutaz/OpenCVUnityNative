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
