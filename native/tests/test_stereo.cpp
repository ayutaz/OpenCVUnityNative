// stereo module（ocvu_compute_disparity）の契約テスト。
//
// **視差の値そのものは検証しない。** どの画素にどの視差が入るかは
// アルゴリズムの実装の詳細で、上流の更新で変わりうる。ここで見るのは
// 契約 —— 「呼べて、summary が名乗ったとおりの形と型の結果が返り、
// 断るべき引数を断り、失敗したときに dst を書き換えない」ことである。
//
// **入力は自分で描いた模様にする。** 外部の画像に依存しない。

#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <cstdint>
#include <initializer_list>
#include <vector>

namespace {

// 1 つの handle を持ち、抜けるときに必ず解放する。
// **ASSERT_* は関数から抜けるので、明示的な release では取りこぼす。**
class ScopedMat {
public:
    ScopedMat() {
        EXPECT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &handle_), OCVU_STATUS_OK);
    }
    explicit ScopedMat(ocvu_mat_handle handle) : handle_(handle) {}
    ~ScopedMat() { ocvu_mat_release(handle_); }
    ScopedMat(const ScopedMat&) = delete;
    ScopedMat& operator=(const ScopedMat&) = delete;

    ocvu_mat_handle get() const { return handle_; }

private:
    ocvu_mat_handle handle_ = OCVU_MAT_HANDLE_NONE;
};

// 縦縞のグレー画像。offset_x だけ横にずらす（= 視差のある左右の対を作れる）。
//
// **Mat の作成は画素を初期化しないので、全画素を明示的に書く。**
// **stride はバイト数である**（8 bit 1 channel なので width と同じ値になる）。
ocvu_mat_handle MakeStripes(int32_t width, int32_t height, int32_t offset_x) {
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(height, width, OCVU_MAT_TYPE_8UC1, &handle), OCVU_STATUS_OK);

    std::vector<uint8_t> pixels(static_cast<size_t>(width) * static_cast<size_t>(height), 0);
    for (int32_t r = 0; r < height; ++r) {
        for (int32_t c = 0; c < width; ++c) {
            const int32_t sc = c + offset_x;
            pixels[static_cast<size_t>(r) * static_cast<size_t>(width) +
                   static_cast<size_t>(c)] = ((sc / 5) % 2 == 0) ? 220 : 30;
        }
    }
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(),
                                        static_cast<int64_t>(pixels.size()), width),
              OCVU_STATUS_OK);
    return handle;
}

// **繰り返さない**模様のグレー画像。offset_x だけ横にずらす。
//
// **縞では駄目である。** 最初はここを周期 10 の縦縞にしていたが、
// ステレオ照合は**繰り返す模様では視差が一意に決まらない** ——
// StereoBM の uniqueness 検査が候補を全部弾き、**視差が 1 画素も
// 求まらないまま「形も型も正しい Mat」が返った**（2026-09-05 に実測）。
// **形と型しか見ていなかった当時のテストは、それで緑だった。**
//
// 決定的な擬似乱数で列ごとの明るさを作る（Date や rand を使わない）。
// 行方向にも変化を付けるのは、StereoBM が縦方向のテクスチャも見るためである。
ocvu_mat_handle MakeTexture(int32_t width, int32_t height, int32_t offset_x) {
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(height, width, OCVU_MAT_TYPE_8UC1, &handle), OCVU_STATUS_OK);

    std::vector<uint8_t> pixels(static_cast<size_t>(width) * static_cast<size_t>(height), 0);
    for (int32_t r = 0; r < height; ++r) {
        for (int32_t c = 0; c < width; ++c) {
            // 列と行から作る決定的なハッシュ。**offset_x は列にだけ効く** ——
            // それが「横にずれた同じ模様」= 視差のある左右の対になる。
            const uint32_t x = static_cast<uint32_t>(c + offset_x);
            const uint32_t y = static_cast<uint32_t>(r);
            uint32_t h = x * 2654435761u ^ (y * 2246822519u);
            h ^= h >> 13;
            h *= 3266489917u;
            h ^= h >> 16;
            pixels[static_cast<size_t>(r) * static_cast<size_t>(width) +
                   static_cast<size_t>(c)] = static_cast<uint8_t>(h & 0xFFu);
        }
    }
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(),
                                        static_cast<int64_t>(pixels.size()), width),
              OCVU_STATUS_OK);
    return handle;
}

// 全画素が同じ値の 8 bit 1 channel。**0 では埋めない** ——
// 「書いていない」と「0 を書いた」を区別できなくなる。
ocvu_mat_handle MakeFilled(int32_t rows, int32_t cols, uint8_t value) {
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(rows, cols, OCVU_MAT_TYPE_8UC1, &handle), OCVU_STATUS_OK);

    const std::vector<uint8_t> pixels(
        static_cast<size_t>(rows) * static_cast<size_t>(cols), value);
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(),
                                        static_cast<int64_t>(pixels.size()), cols),
              OCVU_STATUS_OK);
    return handle;
}

constexpr int32_t kWidth = 128;
constexpr int32_t kHeight = 64;

// 失敗経路を確かめるための dst の大きさと中身。
constexpr int32_t kSentinelSide = 4;
constexpr uint8_t kSentinelValue = 0xAB;

// dst が呼び出し前とまったく同じであることを見る。
// **形と型だけでは足りない** —— 画素まで読み直す。
void ExpectSentinelUntouched(ocvu_mat_handle dst) {
    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst, &info), OCVU_STATUS_OK);
    ASSERT_EQ(info.rows, kSentinelSide);
    ASSERT_EQ(info.cols, kSentinelSide);
    ASSERT_EQ(info.type, OCVU_MAT_TYPE_8UC1);

    std::vector<uint8_t> pixels(
        static_cast<size_t>(kSentinelSide) * static_cast<size_t>(kSentinelSide), 0);
    ASSERT_EQ(ocvu_mat_copy_to_buffer(dst, pixels.data(),
                                      static_cast<int64_t>(pixels.size()), kSentinelSide),
              OCVU_STATUS_OK);
    for (size_t i = 0; i < pixels.size(); ++i) {
        EXPECT_EQ(pixels[i], kSentinelValue)
            << "失敗したのに dst を書き換えている（画素 " << i << "）";
    }
}

}  // namespace

TEST(Stereo, ComputeDisparityProducesA16BitImageOfTheSameShape) {
    // **繰り返さない模様を使う**（MakeStripes ではない。理由はその定義の上に書いた）。
    const ScopedMat left(MakeTexture(kWidth, kHeight, 0));
    const ScopedMat right(MakeTexture(kWidth, kHeight, 4));
    ScopedMat dst;

    ASSERT_EQ(ocvu_compute_disparity(left.get(), right.get(), dst.get(),
                                     OCVU_STEREO_BM, 16, 21),
              OCVU_STATUS_OK);

    // **summary が名乗った型をそのまま確かめる。** 形だけを見ると、
    // 呼ぶ側が 1 画素を何バイトとして読めばよいかが未検査のまま残る。
    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, kHeight);
    EXPECT_EQ(info.cols, kWidth);
    EXPECT_EQ(info.channels, 1);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_16SC1);
    EXPECT_EQ(info.step, static_cast<int64_t>(kWidth) * 2);

    // **1 画素 2 バイトとして実際に読み出せることまで見る。**
    // summary はこの読み方を約束しているので、約束の側だけを書いて
    // 確かめないままにしない。
    std::vector<int16_t> disparity(
        static_cast<size_t>(kWidth) * static_cast<size_t>(kHeight), 0);
    ASSERT_EQ(ocvu_mat_copy_to_buffer(
                  dst.get(), reinterpret_cast<uint8_t*>(disparity.data()),
                  static_cast<int64_t>(disparity.size() * sizeof(int16_t)),
                  static_cast<int64_t>(kWidth) * 2),
              OCVU_STATUS_OK);

    // **読み出すだけでは「視差が 1 画素も求まっていない」を捕まえられない。**
    // 全画素が無効視差の印（最小視差 - 1 を 16 倍した -16）で埋まっていても、
    // 上のここまでは全部通る —— **形と型は正しいまま、中身が空という壊れ方**である。
    //
    // 値そのものは狭く縛らない（アルゴリズムの実装しだいで動く）が、
    // **有効な視差が 1 画素以上あることと、それが要求した範囲に収まること**は
    // 入力によらず成り立つ。左右に 4 画素ずらした縞なので、視差は必ず見つかる。
    constexpr int16_t kInvalid = -16;
    int valid = 0;
    for (int16_t d : disparity) {
        if (d == kInvalid) { continue; }
        ++valid;
        // 値は実際の視差の 16 倍である（summary がそう書いている）。
        EXPECT_GE(d, 0) << "視差が負である";
        EXPECT_LE(d, 16 * 16) << "num_disparities = 16 を超える視差が返っている";
    }
    EXPECT_GT(valid, 0)
        << "視差が 1 画素も求まっていない（全部が無効視差の印で埋まっている）";
}

TEST(Stereo, ComputeDisparitySupportsSgbm) {
    const ScopedMat left(MakeStripes(kWidth, kHeight, 0));
    const ScopedMat right(MakeStripes(kWidth, kHeight, 4));
    ScopedMat dst;

    // **BM で通る引数は SGBM でも通る。** この ABI は 2 つに同じ制限を
    // かけているので、algorithm を差し替えるだけでよい。
    ASSERT_EQ(ocvu_compute_disparity(left.get(), right.get(), dst.get(),
                                     OCVU_STEREO_SGBM, 16, 5),
              OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, kHeight);
    EXPECT_EQ(info.cols, kWidth);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_16SC1);
}

TEST(Stereo, ComputeDisparityRejectsUnknownAlgorithms) {
    const ScopedMat left(MakeStripes(kWidth, kHeight, 0));
    const ScopedMat right(MakeStripes(kWidth, kHeight, 4));
    ScopedMat dst;

    EXPECT_EQ(ocvu_compute_disparity(left.get(), right.get(), dst.get(), 99, 16, 21),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_compute_disparity(left.get(), right.get(), dst.get(), -1, 16, 21),
              OCVU_STATUS_INVALID_ARGUMENT);
}

TEST(Stereo, ComputeDisparityRejectsDisparityWidthsThisAbiDoesNotAccept) {
    // **これは OpenCV の要求ではなく、この ABI が決めた契約である。**
    // 実測では SGBM は num_disparities の 16 倍数性を見ず、BM も 0 を
    // 落とさずに 64 と読み替える。**だから両方に当てて確かめる** ——
    // 片方だけ見ると「BM がたまたま落としていただけ」と区別できない。
    const ScopedMat left(MakeStripes(kWidth, kHeight, 0));
    const ScopedMat right(MakeStripes(kWidth, kHeight, 4));
    ScopedMat dst;

    for (const int32_t algorithm : {OCVU_STEREO_BM, OCVU_STEREO_SGBM}) {
        EXPECT_EQ(ocvu_compute_disparity(left.get(), right.get(), dst.get(),
                                         algorithm, 0, 21),
                  OCVU_STATUS_INVALID_ARGUMENT)
            << "algorithm=" << algorithm << " で num_disparities=0 を通した";
        EXPECT_EQ(ocvu_compute_disparity(left.get(), right.get(), dst.get(),
                                         algorithm, 17, 21),
                  OCVU_STATUS_INVALID_ARGUMENT)
            << "algorithm=" << algorithm << " で num_disparities=17 を通した";
        EXPECT_EQ(ocvu_compute_disparity(left.get(), right.get(), dst.get(),
                                         algorithm, -16, 21),
                  OCVU_STATUS_INVALID_ARGUMENT)
            << "algorithm=" << algorithm << " で num_disparities=-16 を通した";
    }
}

TEST(Stereo, ComputeDisparityRejectsBlockSizesThisAbiDoesNotAccept) {
    // 同上。**SGBM は block_size を一切検査しない**（0 / -1 / 2 / 3 の
    // いずれも例外にならないことを 2026-09-05 に実測した）ので、
    // ここが唯一の門である。
    const ScopedMat left(MakeStripes(kWidth, kHeight, 0));
    const ScopedMat right(MakeStripes(kWidth, kHeight, 4));
    ScopedMat dst;

    for (const int32_t algorithm : {OCVU_STEREO_BM, OCVU_STEREO_SGBM}) {
        EXPECT_EQ(ocvu_compute_disparity(left.get(), right.get(), dst.get(),
                                         algorithm, 16, 20),
                  OCVU_STATUS_INVALID_ARGUMENT)
            << "algorithm=" << algorithm << " で偶数の block_size を通した";
        EXPECT_EQ(ocvu_compute_disparity(left.get(), right.get(), dst.get(),
                                         algorithm, 16, 3),
                  OCVU_STATUS_INVALID_ARGUMENT)
            << "algorithm=" << algorithm << " で 5 未満の block_size を通した";
        EXPECT_EQ(ocvu_compute_disparity(left.get(), right.get(), dst.get(),
                                         algorithm, 16, 0),
                  OCVU_STATUS_INVALID_ARGUMENT)
            << "algorithm=" << algorithm << " で block_size=0 を通した";
    }
}

TEST(Stereo, ComputeDisparityRejectsInvalidHandles) {
    const ScopedMat left(MakeStripes(kWidth, kHeight, 0));
    const ScopedMat right(MakeStripes(kWidth, kHeight, 4));
    ScopedMat dst;

    EXPECT_EQ(ocvu_compute_disparity(OCVU_MAT_HANDLE_NONE, right.get(), dst.get(),
                                     OCVU_STEREO_BM, 16, 21),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_compute_disparity(left.get(), OCVU_MAT_HANDLE_NONE, dst.get(),
                                     OCVU_STEREO_BM, 16, 21),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_compute_disparity(left.get(), right.get(), OCVU_MAT_HANDLE_NONE,
                                     OCVU_STEREO_BM, 16, 21),
              OCVU_STATUS_INVALID_HANDLE);
}

TEST(Stereo, ComputeDisparityRejectsInputsThatAreNotEightBitSingleChannel) {
    // **この制限もこの ABI のものである。** BM は 8 bit 1 channel しか
    // 受けないが、SGBM は 8 bit なら 3 channel でも受ける。素通しにすると
    // 「同じ引数で BM だけが OPENCV_ERROR になる」形が残るので、
    // 厳しいほうへ揃えて INVALID_ARGUMENT で断る。
    const ScopedMat gray(MakeStripes(kWidth, kHeight, 0));

    ocvu_mat_handle color_handle = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(kHeight, kWidth, OCVU_MAT_TYPE_8UC3, &color_handle),
              OCVU_STATUS_OK);
    const ScopedMat color(color_handle);
    ScopedMat dst;

    for (const int32_t algorithm : {OCVU_STEREO_BM, OCVU_STEREO_SGBM}) {
        EXPECT_EQ(ocvu_compute_disparity(color.get(), gray.get(), dst.get(),
                                         algorithm, 16, 21),
                  OCVU_STATUS_INVALID_ARGUMENT)
            << "algorithm=" << algorithm << " で 3 channel の left を通した";
        EXPECT_EQ(ocvu_compute_disparity(gray.get(), color.get(), dst.get(),
                                         algorithm, 16, 21),
                  OCVU_STATUS_INVALID_ARGUMENT)
            << "algorithm=" << algorithm << " で 3 channel の right を通した";
    }
}

TEST(Stereo, ComputeDisparityReportsMismatchedSizesAsAnOpenCvError) {
    // **左右の大きさが違うのは呼ぶ側の誤りである。** ここは OpenCV に
    // 言わせている（2 つの入力の関係で、向こうが具体的な理由を持つため）。
    //
    // **見たいのは「OPENCV_ERROR であって UNKNOWN_ERROR ではない」ことである。**
    // cv::Exception を個別に catch しないと OCVU_TRY_END が
    // std::exception として拾い、summary の約束が黙って嘘になる。
    const ScopedMat left(MakeStripes(kWidth, kHeight, 0));
    const ScopedMat right(MakeStripes(kWidth / 2, kHeight, 4));
    ScopedMat dst;

    const ocvu_status status = ocvu_compute_disparity(
        left.get(), right.get(), dst.get(), OCVU_STEREO_BM, 16, 21);
    EXPECT_EQ(status, OCVU_STATUS_OPENCV_ERROR)
        << "cv::Exception を個別に catch していないと、ここは UNKNOWN_ERROR になる";

    // 理由が読める形で残っていること。**status だけでは呼ぶ側は直せない。**
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_OPENCV_ERROR);
    int32_t needed = 0;
    EXPECT_EQ(ocvu_get_last_error_message(nullptr, 0, &needed),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_GT(needed, 1) << "OpenCV の理由が last-error に入っていない";
}

TEST(Stereo, ComputeDisparityLeavesDstUntouchedWhenItFails) {
    // **「失敗したら dst を書き換えない」は、書き換わっていないことを
    // 見る検査でしか確かめられない。** dst を 0 ではない値で埋めてから呼ぶ。
    const ScopedMat left(MakeStripes(kWidth, kHeight, 0));
    const ScopedMat right(MakeStripes(kWidth, kHeight, 4));
    const ScopedMat mismatched(MakeStripes(kWidth / 2, kHeight, 4));

    // 引数の検証で断る経路。
    {
        const ScopedMat dst(MakeFilled(kSentinelSide, kSentinelSide, kSentinelValue));
        EXPECT_EQ(ocvu_compute_disparity(left.get(), right.get(), dst.get(), 99, 16, 21),
                  OCVU_STATUS_INVALID_ARGUMENT);
        ExpectSentinelUntouched(dst.get());
    }

    // **OpenCV が投げる経路。** ここが本題である —— 結果を一時の Mat に
    // 求めてから入れないと、この経路で dst が置き換わりうる。
    {
        const ScopedMat dst(MakeFilled(kSentinelSide, kSentinelSide, kSentinelValue));
        EXPECT_EQ(ocvu_compute_disparity(left.get(), mismatched.get(), dst.get(),
                                         OCVU_STEREO_BM, 16, 21),
                  OCVU_STATUS_OPENCV_ERROR);
        ExpectSentinelUntouched(dst.get());
    }
}
