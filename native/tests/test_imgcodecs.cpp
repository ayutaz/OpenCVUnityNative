#include <gtest/gtest.h>

#include <cstdint>
#include <vector>

#include "opencv_unity_native.h"

/*
 * imgcodecs（画像 byte 列の encode / decode）の契約テスト。
 *
 * **ファイルパスを native へ渡す形は用意しない。** Windows の文字コードの扱いが
 * 増えるうえ、Android では StreamingAssets が APK の中にあってパスで開けない。
 * 扱うのはメモリ上の byte 列だけで、ファイルを開くのは呼ぶ側の仕事である。
 *
 * encode は**出力サイズを呼ぶ側が知り得ない**最初の ABI 関数である。native が
 * 確保した blob を handle で返す形は採らない —— それは
 * docs/abi-ownership-and-versioning.md §1 に無い新しい所有権の種類を増やす。
 * 代わりに、last-error / OpenCV version と同じ**2 回呼びの作法**
 * （OCVU_STATUS_BUFFER_TOO_SMALL + out_required_size）を使う。
 */

namespace {

ocvu_mat_handle MakeMat(int rows, int cols, int32_t type) {
    ocvu_mat_handle h = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(rows, cols, type, &h), OCVU_STATUS_OK);
    return h;
}

// 既知の画素で埋めた 4x4 の BGR を作る。
ocvu_mat_handle MakeKnownBgr() {
    ocvu_mat_handle src = MakeMat(4, 4, OCVU_MAT_TYPE_8UC3);
    std::vector<uint8_t> pixels(4 * 4 * 3, 0);
    pixels[0] = 10;  // B
    pixels[1] = 20;  // G
    pixels[2] = 30;  // R
    EXPECT_EQ(ocvu_mat_copy_from_buffer(src, pixels.data(),
                                        static_cast<int64_t>(pixels.size()), 4 * 3),
              OCVU_STATUS_OK);
    return src;
}

}  // namespace

TEST(Imgcodecs, EncodeReportsRequiredSizeWithoutWriting) {
    ocvu_mat_handle src = MakeKnownBgr();

    // 1 回目: buffer を渡さずに必要サイズだけ問う。
    // **BUFFER_TOO_SMALL は失敗ではない。**
    int32_t needed = 0;
    EXPECT_EQ(ocvu_imencode(src, ".png", nullptr, 0, &needed),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_GT(needed, 0);

    ocvu_mat_release(src);
}

TEST(Imgcodecs, EncodeThenDecodeRoundTripsPixels) {
    ocvu_mat_handle src = MakeKnownBgr();

    int32_t needed = 0;
    ASSERT_EQ(ocvu_imencode(src, ".png", nullptr, 0, &needed),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    ASSERT_GT(needed, 0);

    std::vector<uint8_t> blob(static_cast<size_t>(needed));
    int32_t written = 0;
    ASSERT_EQ(ocvu_imencode(src, ".png", blob.data(), needed, &written),
              OCVU_STATUS_OK);
    // 成功時は「実際に書いたバイト数」が入る。PNG は決定的なので needed と一致する。
    EXPECT_EQ(written, needed);

    ocvu_mat_handle dst = MakeMat(1, 1, OCVU_MAT_TYPE_8UC1);
    ASSERT_EQ(ocvu_imdecode(blob.data(), static_cast<int64_t>(blob.size()),
                            OCVU_IMREAD_COLOR, dst),
              OCVU_STATUS_OK);

    // decode は dst の大きさと型を置き換える。
    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 4);
    EXPECT_EQ(info.cols, 4);
    EXPECT_EQ(info.channels, 3);

    std::vector<uint8_t> out(4 * 4 * 3, 0);
    ASSERT_EQ(ocvu_mat_copy_to_buffer(dst, out.data(),
                                      static_cast<int64_t>(out.size()), 4 * 3),
              OCVU_STATUS_OK);
    // PNG は可逆なので、画素が一致する。
    EXPECT_EQ(out[0], 10);
    EXPECT_EQ(out[1], 20);
    EXPECT_EQ(out[2], 30);

    ocvu_mat_release(src);
    ocvu_mat_release(dst);
}

TEST(Imgcodecs, EncodeRejectsTooSmallBufferWithoutWriting) {
    ocvu_mat_handle src = MakeKnownBgr();

    int32_t needed = 0;
    ASSERT_EQ(ocvu_imencode(src, ".png", nullptr, 0, &needed),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    ASSERT_GT(needed, 1);

    // 必要量より 1 バイト少ない buffer。**何も書かずに**断ること。
    std::vector<uint8_t> tooSmall(static_cast<size_t>(needed - 1), 0xAB);
    int32_t reported = 0;
    EXPECT_EQ(ocvu_imencode(src, ".png", tooSmall.data(), needed - 1, &reported),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(reported, needed);
    for (uint8_t b : tooSmall) { EXPECT_EQ(b, 0xAB) << "buffer が書き換えられた"; }

    ocvu_mat_release(src);
}

TEST(Imgcodecs, EncodeRejectsInvalidArguments) {
    int32_t needed = 0;

    // out_required_size は必須。
    ocvu_mat_handle src = MakeKnownBgr();
    EXPECT_EQ(ocvu_imencode(src, ".png", nullptr, 0, nullptr), OCVU_STATUS_NULL_POINTER);

    // ext は必須で、空文字列は受け付けない。
    EXPECT_EQ(ocvu_imencode(src, nullptr, nullptr, 0, &needed), OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_imencode(src, "", nullptr, 0, &needed), OCVU_STATUS_INVALID_ARGUMENT);

    // 負の buffer_size。
    EXPECT_EQ(ocvu_imencode(src, ".png", nullptr, -1, &needed), OCVU_STATUS_INVALID_ARGUMENT);

    // buffer_size > 0 なのに buffer が NULL。
    EXPECT_EQ(ocvu_imencode(src, ".png", nullptr, 16, &needed), OCVU_STATUS_NULL_POINTER);

    // 解放済み handle。
    ocvu_mat_release(src);
    EXPECT_EQ(ocvu_imencode(src, ".png", nullptr, 0, &needed), OCVU_STATUS_INVALID_HANDLE);

    // NONE handle。
    EXPECT_EQ(ocvu_imencode(OCVU_MAT_HANDLE_NONE, ".png", nullptr, 0, &needed),
              OCVU_STATUS_INVALID_HANDLE);
}

TEST(Imgcodecs, EncodeRejectsUnknownExtension) {
    ocvu_mat_handle src = MakeKnownBgr();
    int32_t needed = 0;
    // 対応していない拡張子は OpenCV 由来の失敗として報告する。
    EXPECT_EQ(ocvu_imencode(src, ".notanimage", nullptr, 0, &needed),
              OCVU_STATUS_OPENCV_ERROR);
    ocvu_mat_release(src);
}

TEST(Imgcodecs, DecodeRejectsInvalidArguments) {
    ocvu_mat_handle dst = MakeMat(1, 1, OCVU_MAT_TYPE_8UC1);
    const uint8_t bytes[] = {1, 2, 3, 4, 5, 6, 7, 8};

    EXPECT_EQ(ocvu_imdecode(nullptr, 8, OCVU_IMREAD_COLOR, dst), OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_imdecode(bytes, 0, OCVU_IMREAD_COLOR, dst), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_imdecode(bytes, -1, OCVU_IMREAD_COLOR, dst), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_imdecode(bytes, 8, OCVU_IMREAD_COLOR, OCVU_MAT_HANDLE_NONE),
              OCVU_STATUS_INVALID_HANDLE);

    ocvu_mat_release(dst);
}

TEST(Imgcodecs, DecodeRejectsGarbageBytes) {
    ocvu_mat_handle dst = MakeMat(1, 1, OCVU_MAT_TYPE_8UC1);
    // 画像ではない byte 列。**壊れた入力でメモリを壊さず、status で断ること。**
    const uint8_t garbage[] = {1, 2, 3, 4, 5, 6, 7, 8};
    EXPECT_EQ(ocvu_imdecode(garbage, static_cast<int64_t>(sizeof(garbage)),
                            OCVU_IMREAD_COLOR, dst),
              OCVU_STATUS_OPENCV_ERROR);
    ocvu_mat_release(dst);
}

TEST(Imgcodecs, DecodeGrayscaleFlagProducesOneChannel) {
    ocvu_mat_handle src = MakeKnownBgr();

    int32_t needed = 0;
    ASSERT_EQ(ocvu_imencode(src, ".png", nullptr, 0, &needed),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    std::vector<uint8_t> blob(static_cast<size_t>(needed));
    ASSERT_EQ(ocvu_imencode(src, ".png", blob.data(), needed, &needed), OCVU_STATUS_OK);

    ocvu_mat_handle dst = MakeMat(1, 1, OCVU_MAT_TYPE_8UC3);
    ASSERT_EQ(ocvu_imdecode(blob.data(), static_cast<int64_t>(blob.size()),
                            OCVU_IMREAD_GRAYSCALE, dst),
              OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.channels, 1);

    ocvu_mat_release(src);
    ocvu_mat_release(dst);
}
