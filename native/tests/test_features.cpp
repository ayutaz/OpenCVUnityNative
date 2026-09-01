#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <cstdint>
#include <cstring>
#include <vector>

namespace {

// ORB が特徴点を見つけられる、角のある画像を作る。
// 一様な画像では 0 件になるので、市松模様を書き込む。
ocvu_mat_handle MakeCheckerboard(int size, int cell) {
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(size, size, OCVU_MAT_TYPE_8UC1, &handle), OCVU_STATUS_OK);

    std::vector<uint8_t> pixels(static_cast<size_t>(size) * static_cast<size_t>(size), 0);
    for (int y = 0; y < size; ++y) {
        for (int x = 0; x < size; ++x) {
            const bool white = ((x / cell) + (y / cell)) % 2 == 0;
            pixels[static_cast<size_t>(y) * static_cast<size_t>(size) + static_cast<size_t>(x)] =
                white ? 255 : 0;
        }
    }
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(),
                                        static_cast<int64_t>(pixels.size()),
                                        static_cast<int64_t>(size)),
              OCVU_STATUS_OK);
    return handle;
}

}  // namespace

TEST(Features, DetectFindsKeypointsOnACheckerboard) {
    const ocvu_mat_handle img = MakeCheckerboard(128, 16);

    constexpr int32_t kMax = 64;
    std::vector<ocvu_keypoint> keypoints(kMax);
    int32_t count = 0;

    ASSERT_EQ(ocvu_orb_detect(img, kMax, keypoints.data(), kMax, &count), OCVU_STATUS_OK);
    EXPECT_GT(count, 0) << "市松模様には角がある";
    EXPECT_LE(count, kMax);

    // 見つかった分の座標が画像の中に収まっていること。
    for (int32_t i = 0; i < count; ++i) {
        EXPECT_GE(keypoints[static_cast<size_t>(i)].x, 0.0f);
        EXPECT_LE(keypoints[static_cast<size_t>(i)].x, 128.0f);
        EXPECT_GE(keypoints[static_cast<size_t>(i)].y, 0.0f);
        EXPECT_LE(keypoints[static_cast<size_t>(i)].y, 128.0f);
    }

    ocvu_mat_release(img);
}

TEST(Features, DetectRejectsATooSmallBufferWithoutWriting) {
    const ocvu_mat_handle img = MakeCheckerboard(128, 16);

    constexpr int32_t kMax = 64;
    // capacity を 1 つ足りなくして、0xAB で埋める。
    std::vector<ocvu_keypoint> keypoints(kMax);
    std::memset(keypoints.data(), 0xAB, keypoints.size() * sizeof(ocvu_keypoint));

    int32_t count = 999;
    EXPECT_EQ(ocvu_orb_detect(img, kMax, keypoints.data(), kMax - 1, &count),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(count, kMax) << "必要量を返すこと";

    const auto* bytes = reinterpret_cast<const uint8_t*>(keypoints.data());
    for (size_t i = 0; i < keypoints.size() * sizeof(ocvu_keypoint); ++i) {
        ASSERT_EQ(bytes[i], 0xAB) << "足りない buffer には何も書かないこと";
    }

    ocvu_mat_release(img);
}

TEST(Features, DetectRejectsInvalidArgumentsAndAlwaysWritesZero) {
    const ocvu_mat_handle img = MakeCheckerboard(64, 8);
    std::vector<ocvu_keypoint> keypoints(8);

    EXPECT_EQ(ocvu_orb_detect(img, 8, keypoints.data(), 8, nullptr), OCVU_STATUS_NULL_POINTER);

    // **0 以外で汚してから呼ぶ。**
    int32_t count = 4321;
    EXPECT_EQ(ocvu_orb_detect(img, 0, keypoints.data(), 8, &count), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    count = 4321;
    EXPECT_EQ(ocvu_orb_detect(img, OCVU_ORB_MAX_FEATURES + 1, keypoints.data(), 8, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    count = 4321;
    EXPECT_EQ(ocvu_orb_detect(OCVU_MAT_HANDLE_NONE, 8, keypoints.data(), 8, &count),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(count, 0);

    count = 4321;
    EXPECT_EQ(ocvu_orb_detect(img, 8, nullptr, 8, &count), OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(count, 0);

    count = 4321;
    EXPECT_EQ(ocvu_orb_detect(img, 8, keypoints.data(), -1, &count), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    ocvu_mat_release(img);
}

TEST(Features, TheKeypointStructHasTheLayoutTheAbiPromises) {
    // C# 側の OcvuKeyPoint と突き合わせる根拠になる。
    EXPECT_EQ(sizeof(ocvu_keypoint), 28u);
}
