// imgproc のうち「画素を作る」5 本と、geometry の ocvu_get_perspective_transform の
// 契約テスト。
//
// **期待値は手で決められる入力だけを使う。** 4x4 と 5x5 の小さい画像に、
// 紙の上で数えられる演算だけを掛けている —— OpenCV に期待値を作らせると、
// 実装と期待値が同じだけ間違っていても緑になる。

#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <array>
#include <cmath>
#include <cstdint>
#include <vector>

namespace {

// Mat を 1 つ持ち、抜けるときに必ず解放する。ASSERT_* で途中脱出しても漏れない。
class ScopedMat {
public:
    explicit ScopedMat(int rows = 1, int cols = 1) {
        EXPECT_EQ(ocvu_mat_create(rows, cols, OCVU_MAT_TYPE_8UC1, &handle_), OCVU_STATUS_OK);
    }
    ~ScopedMat() { ocvu_mat_release(handle_); }
    ScopedMat(const ScopedMat&) = delete;
    ScopedMat& operator=(const ScopedMat&) = delete;

    ocvu_mat_handle get() const { return handle_; }

private:
    ocvu_mat_handle handle_ = OCVU_MAT_HANDLE_NONE;
};

// 8 bit 1 channel 以外の Mat を作る。**OPENCV_ERROR の経路を通すために要る** ——
// OpenCV が拒む型を渡さないと、summary が約束した status に到達できない。
class ScopedTypedMat {
public:
    ScopedTypedMat(int rows, int cols, int32_t type) {
        EXPECT_EQ(ocvu_mat_create(rows, cols, type, &handle_), OCVU_STATUS_OK);
    }
    ~ScopedTypedMat() { ocvu_mat_release(handle_); }
    ScopedTypedMat(const ScopedTypedMat&) = delete;
    ScopedTypedMat& operator=(const ScopedTypedMat&) = delete;

    ocvu_mat_handle get() const { return handle_; }

private:
    ocvu_mat_handle handle_ = OCVU_MAT_HANDLE_NONE;
};

// 左半分が 10、右半分が 200 の 4x4 グレー画像にする。
//
// **画素を明示的に入れる。** ocvu_mat_create は画素を初期化しないので、
// 入れずに使うと「何も写っていない画像」ではなく不定の画像になる。
void FillSplit(const ScopedMat& mat) {
    std::array<uint8_t, 16> pixels{};
    for (int r = 0; r < 4; ++r) {
        for (int c = 0; c < 4; ++c) {
            pixels[static_cast<size_t>(r) * 4 + static_cast<size_t>(c)] =
                (c < 2) ? static_cast<uint8_t>(10) : static_cast<uint8_t>(200);
        }
    }
    // **stride はバイト数である**（8 bit 1 channel の 4 列なので 4）。
    EXPECT_EQ(ocvu_mat_copy_from_buffer(mat.get(), pixels.data(), 16, 4), OCVU_STATUS_OK);
}

// 中央 1 画素だけが 255 の 5x5 画像にする。
void FillSingleDot(const ScopedMat& mat) {
    std::array<uint8_t, 25> pixels{};
    pixels[2 * 5 + 2] = 255;
    EXPECT_EQ(ocvu_mat_copy_from_buffer(mat.get(), pixels.data(), 25, 5), OCVU_STATUS_OK);
}

// 8 bit 1 channel の画素を、行を詰めて読み出す。
std::vector<uint8_t> ReadPixels(ocvu_mat_handle handle) {
    ocvu_mat_info info{};
    EXPECT_EQ(ocvu_mat_get_info(handle, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_8UC1) << "この補助関数は 8 bit 1 channel だけを読む";
    std::vector<uint8_t> pixels(static_cast<size_t>(info.rows) * static_cast<size_t>(info.cols));
    EXPECT_EQ(ocvu_mat_copy_to_buffer(handle, pixels.data(),
                                      static_cast<int64_t>(pixels.size()),
                                      static_cast<int64_t>(info.cols)),
              OCVU_STATUS_OK);
    return pixels;
}

// 32 bit 浮動小数 1 channel を読み出す（テンプレート照合の応答）。
std::vector<float> ReadFloats(ocvu_mat_handle handle) {
    ocvu_mat_info info{};
    EXPECT_EQ(ocvu_mat_get_info(handle, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_32FC1);
    std::vector<float> values(static_cast<size_t>(info.rows) * static_cast<size_t>(info.cols));
    EXPECT_EQ(ocvu_mat_copy_to_buffer(
                  handle, reinterpret_cast<uint8_t*>(values.data()),
                  static_cast<int64_t>(values.size() * sizeof(float)),
                  static_cast<int64_t>(info.cols) * static_cast<int64_t>(sizeof(float))),
              OCVU_STATUS_OK);
    return values;
}

// 64 bit 浮動小数 1 channel の 3x3 を読み出す（射影変換）。
std::vector<double> Read3x3(ocvu_mat_handle handle) {
    ocvu_mat_info info{};
    EXPECT_EQ(ocvu_mat_get_info(handle, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_64FC1);
    std::vector<double> values(9, 0.0);
    EXPECT_EQ(ocvu_mat_copy_to_buffer(handle, reinterpret_cast<uint8_t*>(values.data()),
                                      static_cast<int64_t>(values.size() * sizeof(double)),
                                      static_cast<int64_t>(3 * sizeof(double))),
              OCVU_STATUS_OK);
    return values;
}

double At(const std::vector<double>& m, int row, int col) {
    return m[static_cast<size_t>(row) * 3 + static_cast<size_t>(col)];
}

void ExpectShape(ocvu_mat_handle handle, int rows, int cols) {
    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(handle, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, rows);
    EXPECT_EQ(info.cols, cols);
}

// 失敗しても dst が書き換わっていないことを見る。
//
// **形だけを見ると弱い。** 作りたての ScopedMat は 1x1 なので、1x1 を返す
// 演算が成功した場合と区別が付かない。**型まで見る** —— どの関数も
// 成功すれば 8 bit 1 channel 以外か、少なくとも大きさが変わる。
void ExpectUntouchedDestination(ocvu_mat_handle handle) {
    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(handle, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 1);
    EXPECT_EQ(info.cols, 1);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_8UC1);
}

// 4 隅（左上から時計回り）。x と y が交互に並ぶ。
const std::array<float, 8> kFrom{0.0f, 0.0f, 3.0f, 0.0f, 3.0f, 3.0f, 0.0f, 3.0f};
const std::array<float, 8> kTo{0.0f, 0.0f, 7.0f, 0.0f, 7.0f, 7.0f, 0.0f, 7.0f};

constexpr int64_t kQuadBytes = 8 * static_cast<int64_t>(sizeof(float));

}  // namespace

// ---------------------------------------------------------------- ocvu_threshold

TEST(ImgprocOps, ThresholdSplitsAtTheGivenValue) {
    ScopedMat src(4, 4);
    FillSplit(src);
    ScopedMat dst;

    double computed = -1.0;
    ASSERT_EQ(ocvu_threshold(src.get(), dst.get(), 100.0, 255.0, OCVU_THRESH_BINARY, &computed),
              OCVU_STATUS_OK);

    // しきい値を明示したので、そのまま返る。
    EXPECT_DOUBLE_EQ(computed, 100.0);

    const std::vector<uint8_t> pixels = ReadPixels(dst.get());
    ASSERT_EQ(pixels.size(), static_cast<size_t>(16));
    for (int r = 0; r < 4; ++r) {
        const size_t base = static_cast<size_t>(r) * 4;
        EXPECT_EQ(pixels[base + 0], 0) << "10 は 100 以下なので 0";
        EXPECT_EQ(pixels[base + 1], 0);
        EXPECT_EQ(pixels[base + 2], 255) << "200 は 100 より大きいので max_value";
        EXPECT_EQ(pixels[base + 3], 255);
    }
}

TEST(ImgprocOps, ThresholdReportsTheValueOtsuChose) {
    // **Otsu はしきい値を自分で選ぶ。** 呼ぶ側はそれを知りたいので返す。
    ScopedMat src(4, 4);
    FillSplit(src);
    ScopedMat dst;

    double computed = -1.0;
    ASSERT_EQ(ocvu_threshold(src.get(), dst.get(), 0.0, 255.0,
                             OCVU_THRESH_BINARY | OCVU_THRESH_OTSU, &computed),
              OCVU_STATUS_OK);

    // **実測（2026-09-05）: ちょうど 10.0 が返る。** 2 山（10 と 200）だけの
    // ヒストグラムでは 10 以上 199 以下のどの分割も同じ分離になり、実装は
    // 最初に最大を取る値を返す。**したがって「10 より大きい」ことは要求できない。**
    // ここで見たいのは「Otsu が値を選んで返す」ことなので、選ばれた値そのものを
    // 狭く縛らない。
    EXPECT_GE(computed, 10.0);
    EXPECT_LT(computed, 200.0);
}

TEST(ImgprocOps, ThresholdRejectsBadArgumentsAndDoesNotWriteTheComputedValue) {
    ScopedMat src(4, 4);
    FillSplit(src);
    ScopedMat dst;

    // **0 ではない値で汚してから呼ぶ。** 0 で初期化すると「書いていない」と
    // 「0 を書いた」が区別できない。
    double computed = 12345.0;

    EXPECT_EQ(ocvu_threshold(OCVU_MAT_HANDLE_NONE, dst.get(), 100.0, 255.0,
                             OCVU_THRESH_BINARY, &computed),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_DOUBLE_EQ(computed, 0.0) << "失敗時は out_computed_threshold に 0 を書くこと";

    computed = 12345.0;
    EXPECT_EQ(ocvu_threshold(src.get(), OCVU_MAT_HANDLE_NONE, 100.0, 255.0,
                             OCVU_THRESH_BINARY, &computed),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_DOUBLE_EQ(computed, 0.0);

    // 知らない type を素通しにしない。
    computed = 12345.0;
    EXPECT_EQ(ocvu_threshold(src.get(), dst.get(), 100.0, 255.0, 99, &computed),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_DOUBLE_EQ(computed, 0.0);

    // cv::THRESH_TRIANGLE（16）は出していない。or して渡しても通さない。
    computed = 12345.0;
    EXPECT_EQ(ocvu_threshold(src.get(), dst.get(), 100.0, 255.0,
                             OCVU_THRESH_BINARY | 16, &computed),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_DOUBLE_EQ(computed, 0.0);

    // 負の type も断る。
    computed = 12345.0;
    EXPECT_EQ(ocvu_threshold(src.get(), dst.get(), 100.0, 255.0, -1, &computed),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_DOUBLE_EQ(computed, 0.0);

    // **失敗しても dst は書き換わっていない。**
    ExpectUntouchedDestination(dst.get());

    // out_computed_threshold は必須ではない —— NULL を許す。
    EXPECT_EQ(ocvu_threshold(src.get(), dst.get(), 100.0, 255.0, OCVU_THRESH_BINARY, nullptr),
              OCVU_STATUS_OK);

    // **src と dst が同じ handle でもよい。** 結果を一時に求めてから入れるので
    // 曖昧さが無い（cvtColor / resize と違って禁じない）。
    EXPECT_EQ(ocvu_threshold(src.get(), src.get(), 100.0, 255.0, OCVU_THRESH_BINARY, nullptr),
              OCVU_STATUS_OK);
    const std::vector<uint8_t> in_place = ReadPixels(src.get());
    ASSERT_EQ(in_place.size(), static_cast<size_t>(16));
    EXPECT_EQ(in_place[0], 0);
    EXPECT_EQ(in_place[3], 255);
}

// -------------------------------------------------------------------- ocvu_canny

TEST(ImgprocOps, CannyFindsTheEdgeBetweenTheHalves) {
    ScopedMat src(4, 4);
    FillSplit(src);
    ScopedMat dst;

    ASSERT_EQ(ocvu_canny(src.get(), dst.get(), 50.0, 150.0, 3, 0), OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 4);
    EXPECT_EQ(info.cols, 4);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_8UC1);

    // 段差があるので、どこかは 255 になる。**位置は OpenCV が決めるので数えない。**
    const std::vector<uint8_t> pixels = ReadPixels(dst.get());
    bool any_edge = false;
    for (uint8_t p : pixels) {
        if (p == 255) { any_edge = true; }
    }
    EXPECT_TRUE(any_edge) << "段差があるのにエッジが 1 画素も無い";
}

TEST(ImgprocOps, CannyRejectsBadArguments) {
    ScopedMat src(4, 4);
    FillSplit(src);
    ScopedMat dst;

    EXPECT_EQ(ocvu_canny(OCVU_MAT_HANDLE_NONE, dst.get(), 50.0, 150.0, 3, 0),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_canny(src.get(), OCVU_MAT_HANDLE_NONE, 50.0, 150.0, 3, 0),
              OCVU_STATUS_INVALID_HANDLE);

    // aperture_size は 3 / 5 / 7 のいずれかでなければならない。
    EXPECT_EQ(ocvu_canny(src.get(), dst.get(), 50.0, 150.0, 4, 0), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_canny(src.get(), dst.get(), 50.0, 150.0, 9, 0), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_canny(src.get(), dst.get(), 50.0, 150.0, 0, 0), OCVU_STATUS_INVALID_ARGUMENT);

    // しきい値が負なのは誤りである。
    EXPECT_EQ(ocvu_canny(src.get(), dst.get(), -1.0, 150.0, 3, 0), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_canny(src.get(), dst.get(), 50.0, -1.0, 3, 0), OCVU_STATUS_INVALID_ARGUMENT);

    // **失敗しても dst は書き換わっていない。**
    ExpectUntouchedDestination(dst.get());
}

// ------------------------------------------------------------ ocvu_morphology_ex

TEST(ImgprocOps, DilateGrowsTheDot) {
    // 3x3 の矩形で膨張させると、1 画素の点が 3x3 に広がる。**手で数えられる。**
    ScopedMat src(5, 5);
    FillSingleDot(src);
    ScopedMat dst;

    ASSERT_EQ(ocvu_morphology_ex(src.get(), dst.get(), OCVU_MORPH_DILATE,
                                 OCVU_MORPH_SHAPE_RECT, 3, 3, 1),
              OCVU_STATUS_OK);

    const std::vector<uint8_t> pixels = ReadPixels(dst.get());
    ASSERT_EQ(pixels.size(), static_cast<size_t>(25));
    int lit = 0;
    for (uint8_t p : pixels) {
        if (p == 255) { ++lit; }
    }
    EXPECT_EQ(lit, 9) << "3x3 の矩形で膨張したら 9 画素になる";

    // **どこが光ったかも手で決まる**（中央 (2, 2) の周り 3x3）。
    for (int r = 1; r <= 3; ++r) {
        for (int c = 1; c <= 3; ++c) {
            EXPECT_EQ(pixels[static_cast<size_t>(r) * 5 + static_cast<size_t>(c)], 255);
        }
    }
}

TEST(ImgprocOps, ErodeRemovesTheDot) {
    ScopedMat src(5, 5);
    FillSingleDot(src);
    ScopedMat dst;

    ASSERT_EQ(ocvu_morphology_ex(src.get(), dst.get(), OCVU_MORPH_ERODE,
                                 OCVU_MORPH_SHAPE_RECT, 3, 3, 1),
              OCVU_STATUS_OK);

    const std::vector<uint8_t> pixels = ReadPixels(dst.get());
    ASSERT_EQ(pixels.size(), static_cast<size_t>(25));
    for (uint8_t p : pixels) {
        EXPECT_EQ(p, 0) << "1 画素の点は 3x3 の収縮で消える";
    }
}

TEST(ImgprocOps, MorphologyUsesTheKernelWidthAndHeightSeparately) {
    // **非対称な構造要素で見る。** 5x5 の 1 画素点に幅 1 x 高さ 3 の矩形で
    // 膨張させると、光るのは**縦 3 画素**である。**幅と高さを入れ替えれば
    // 横 3 画素になるので、この検査は引数の取り違えを捕まえる。**
    ScopedMat src(5, 5);
    FillSingleDot(src);
    ScopedMat dst;

    ASSERT_EQ(ocvu_morphology_ex(src.get(), dst.get(), OCVU_MORPH_DILATE,
                                 OCVU_MORPH_SHAPE_RECT, 1, 3, 1),
              OCVU_STATUS_OK);

    const std::vector<uint8_t> pixels = ReadPixels(dst.get());
    ASSERT_EQ(pixels.size(), 25u);
    for (int r = 0; r < 5; ++r) {
        for (int c = 0; c < 5; ++c) {
            const bool expect_lit = (c == 2) && (r >= 1 && r <= 3);
            EXPECT_EQ(pixels[static_cast<size_t>(r) * 5 + c] == 255, expect_lit)
                << "(" << r << ", " << c << ") が縦 3 画素の帯と合わない";
        }
    }
}

TEST(ImgprocOps, MorphologyUsesTheKernelShape) {
    // **十字と矩形は光る画素数が違う。** 3x3 の矩形なら 9 画素、
    // 十字なら 5 画素である。**shape を無視する実装なら、どちらも 9 になる。**
    ScopedMat src(5, 5);
    FillSingleDot(src);
    ScopedMat dst;

    ASSERT_EQ(ocvu_morphology_ex(src.get(), dst.get(), OCVU_MORPH_DILATE,
                                 OCVU_MORPH_SHAPE_CROSS, 3, 3, 1),
              OCVU_STATUS_OK);
    int lit = 0;
    for (uint8_t v : ReadPixels(dst.get())) { if (v == 255) ++lit; }
    EXPECT_EQ(lit, 5) << "十字の構造要素なのに矩形（9 画素）になっている";
}

TEST(ImgprocOps, MorphologyRepeatsTheOperationAsManyTimesAsAsked) {
    // **iterations が効いていることを見る。** 3x3 の矩形で 1 回膨張させると
    // 9 画素、2 回なら 5x5 全体（25 画素）になる。**iterations を無視する
    // 実装なら 9 のままである。**
    ScopedMat src(5, 5);
    FillSingleDot(src);
    ScopedMat once;
    ScopedMat twice;

    ASSERT_EQ(ocvu_morphology_ex(src.get(), once.get(), OCVU_MORPH_DILATE,
                                 OCVU_MORPH_SHAPE_RECT, 3, 3, 1),
              OCVU_STATUS_OK);
    ASSERT_EQ(ocvu_morphology_ex(src.get(), twice.get(), OCVU_MORPH_DILATE,
                                 OCVU_MORPH_SHAPE_RECT, 3, 3, 2),
              OCVU_STATUS_OK);

    int lit_once = 0;
    for (uint8_t v : ReadPixels(once.get())) { if (v == 255) ++lit_once; }
    int lit_twice = 0;
    for (uint8_t v : ReadPixels(twice.get())) { if (v == 255) ++lit_twice; }

    EXPECT_EQ(lit_once, 9);
    EXPECT_EQ(lit_twice, 25) << "iterations = 2 が 1 回ぶんしか効いていない";
}

TEST(ImgprocOps, MorphologyRejectsBadArguments) {
    ScopedMat src(5, 5);
    FillSingleDot(src);
    ScopedMat dst;

    EXPECT_EQ(ocvu_morphology_ex(src.get(), dst.get(), 99, OCVU_MORPH_SHAPE_RECT, 3, 3, 1),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_morphology_ex(src.get(), dst.get(), -1, OCVU_MORPH_SHAPE_RECT, 3, 3, 1),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_morphology_ex(src.get(), dst.get(), OCVU_MORPH_DILATE, 99, 3, 3, 1),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 構造要素の大きさは 1 以上でなければならない。
    EXPECT_EQ(ocvu_morphology_ex(src.get(), dst.get(), OCVU_MORPH_DILATE,
                                 OCVU_MORPH_SHAPE_RECT, 0, 3, 1),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_morphology_ex(src.get(), dst.get(), OCVU_MORPH_DILATE,
                                 OCVU_MORPH_SHAPE_RECT, 3, 0, 1),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 繰り返しは 1 以上。
    EXPECT_EQ(ocvu_morphology_ex(src.get(), dst.get(), OCVU_MORPH_DILATE,
                                 OCVU_MORPH_SHAPE_RECT, 3, 3, 0),
              OCVU_STATUS_INVALID_ARGUMENT);

    EXPECT_EQ(ocvu_morphology_ex(OCVU_MAT_HANDLE_NONE, dst.get(), OCVU_MORPH_DILATE,
                                 OCVU_MORPH_SHAPE_RECT, 3, 3, 1),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_morphology_ex(src.get(), OCVU_MAT_HANDLE_NONE, OCVU_MORPH_DILATE,
                                 OCVU_MORPH_SHAPE_RECT, 3, 3, 1),
              OCVU_STATUS_INVALID_HANDLE);

    // **失敗しても dst は書き換わっていない。**
    ExpectUntouchedDestination(dst.get());
}

// ----------------------------------------------------------- ocvu_match_template

TEST(ImgprocOps, MatchTemplateProducesTheResponseWeCanComputeByHand) {
    // 5x5 の画像に 3x3 のテンプレートを当てると、応答は 3x3 になる（5 - 3 + 1 = 3）。
    //
    // **値まで手で決まる。** OCVU_TM_CCORR は重なった画素の積の和なので、
    // どちらも 1 画素だけが 255 の場合、テンプレートの中心が画像の点に
    // 重なる位置だけが 255 * 255 = 65025 になり、他は 0 である。
    ScopedMat image(5, 5);
    FillSingleDot(image);

    ScopedMat templ(3, 3);
    std::array<uint8_t, 9> tpixels{};
    tpixels[4] = 255;
    ASSERT_EQ(ocvu_mat_copy_from_buffer(templ.get(), tpixels.data(), 9, 3), OCVU_STATUS_OK);

    ScopedMat dst;
    ASSERT_EQ(ocvu_match_template(image.get(), templ.get(), dst.get(), OCVU_TM_CCORR),
              OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 3);
    EXPECT_EQ(info.cols, 3);
    EXPECT_EQ(info.channels, 1);
    // **応答は 32 bit 浮動小数である。** 呼ぶ側が読めるよう ABI に名前がある。
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_32FC1);

    const std::vector<float> response = ReadFloats(dst.get());
    ASSERT_EQ(response.size(), static_cast<size_t>(9));

    // **厳密な 0 を要求しない。** 実測（2026-09-05）: 重ならない位置の応答は
    // ちょうど 0 ではなく 1e-3 程度の値になる —— OpenCV は照合を浮動小数の
    // 畳み込みで行うので、整数の積の和とは一致しない。
    // **ピークの値と位置だけが手で決まる主張である。**
    constexpr float kPeak = 255.0f * 255.0f;
    for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 3; ++c) {
            const float v = response[static_cast<size_t>(r) * 3 + static_cast<size_t>(c)];
            if (r == 1 && c == 1) {
                EXPECT_NEAR(v, kPeak, kPeak * 1e-4f) << "中心が積の和になっていない";
            } else {
                // ピークに対して 5 桁小さいことだけを見る（誤差の絶対値は縛らない）。
                EXPECT_LT(std::abs(v), kPeak * 1e-4f)
                    << "重ならない位置 (" << r << ", " << c << ") の応答が大きすぎる";
            }
        }
    }
}

TEST(ImgprocOps, MatchTemplateRejectsATemplateBiggerThanTheImage) {
    // **この検査はこの ABI が自分で行う。** 実測（2026-09-05）: cv::matchTemplate は
    // templ が image より両方向とも大きいとき例外を投げず、**image と templ を
    // 入れ替えて計算する** —— 任せると、約束した出力の形（image から templ を
    // 引いて 1 を足したもの）が黙って破られる。
    ScopedMat image(5, 5);
    FillSingleDot(image);
    ScopedMat dst;

    // 両方向とも大きい。OpenCV に落とすと入れ替えて成功してしまう形である。
    ScopedMat big(9, 9);
    EXPECT_EQ(ocvu_match_template(image.get(), big.get(), dst.get(), OCVU_TM_SQDIFF),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 片方向だけ大きい。
    ScopedMat wide(3, 9);
    EXPECT_EQ(ocvu_match_template(image.get(), wide.get(), dst.get(), OCVU_TM_SQDIFF),
              OCVU_STATUS_INVALID_ARGUMENT);
    ScopedMat tall(9, 3);
    EXPECT_EQ(ocvu_match_template(image.get(), tall.get(), dst.get(), OCVU_TM_SQDIFF),
              OCVU_STATUS_INVALID_ARGUMENT);

    // **失敗しても dst は書き換わっていない。**
    ExpectUntouchedDestination(dst.get());

    // **同じ大きさは通る**（応答が 1x1 になる境界）。ここまで書かないと、
    // 「大きすぎる」を断つ検査が厳しすぎても気づけない。
    //
    // **型まで見る。** 応答は 1x1 なので、大きさだけでは「書き換わっていない
    // 1x1 の dst」と区別が付かない —— 32 bit 浮動小数になったことが、
    // 実際に書かれた証拠である。
    ScopedMat same(5, 5);
    FillSingleDot(same);
    EXPECT_EQ(ocvu_match_template(image.get(), same.get(), dst.get(), OCVU_TM_SQDIFF),
              OCVU_STATUS_OK);
    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 1);
    EXPECT_EQ(info.cols, 1);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_32FC1);
}

TEST(ImgprocOps, MatchTemplateRejectsBadArguments) {
    ScopedMat image(5, 5);
    FillSingleDot(image);
    ScopedMat templ(3, 3);
    ScopedMat dst;

    EXPECT_EQ(ocvu_match_template(image.get(), templ.get(), dst.get(), 99),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_match_template(image.get(), templ.get(), dst.get(), -1),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_match_template(OCVU_MAT_HANDLE_NONE, templ.get(), dst.get(), OCVU_TM_SQDIFF),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_match_template(image.get(), OCVU_MAT_HANDLE_NONE, dst.get(), OCVU_TM_SQDIFF),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_match_template(image.get(), templ.get(), OCVU_MAT_HANDLE_NONE,
                                  OCVU_TM_SQDIFF),
              OCVU_STATUS_INVALID_HANDLE);

    // **失敗しても dst は書き換わっていない。**
    ExpectUntouchedDestination(dst.get());
}

// ------------------------- ocvu_get_perspective_transform / ocvu_warp_perspective

TEST(ImgprocOps, PerspectiveTransformRecoversTheScale) {
    // 3 単位の正方形を 7 単位へ引き伸ばす対応。**行列は手で決まる** ——
    // 右下で正規化すると diag(7/3, 7/3, 1) になる。
    ScopedMat transform;
    ASSERT_EQ(ocvu_get_perspective_transform(kFrom.data(), kQuadBytes,
                                             kTo.data(), kQuadBytes, transform.get()),
              OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(transform.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 3);
    EXPECT_EQ(info.cols, 3);
    EXPECT_EQ(info.channels, 1);
    // **変換は 64 bit 浮動小数である。** 名前が無いと、呼ぶ側は 1 画素の
    // バイト数を知る手立てが無い。
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_64FC1);

    const std::vector<double> m = Read3x3(transform.get());
    const double w = At(m, 2, 2);
    ASSERT_NE(w, 0.0);
    EXPECT_NEAR(At(m, 0, 0) / w, 7.0 / 3.0, 1e-9);
    EXPECT_NEAR(At(m, 1, 1) / w, 7.0 / 3.0, 1e-9);
    EXPECT_NEAR(At(m, 0, 1) / w, 0.0, 1e-9);
    EXPECT_NEAR(At(m, 1, 0) / w, 0.0, 1e-9);
    EXPECT_NEAR(At(m, 2, 0) / w, 0.0, 1e-9);
    EXPECT_NEAR(At(m, 2, 1) / w, 0.0, 1e-9);
}

TEST(ImgprocOps, PerspectiveTransformAndWarpRoundTrip) {
    // 4x4 の画像を、恒等ではない変換で 8x8 へ引き伸ばす。
    // **対応は「4 隅 -> 8x8 の 4 隅」なので、期待値は手で決まる。**
    ScopedMat transform;
    ASSERT_EQ(ocvu_get_perspective_transform(kFrom.data(), kQuadBytes,
                                             kTo.data(), kQuadBytes, transform.get()),
              OCVU_STATUS_OK);

    ScopedMat src(4, 4);
    FillSplit(src);
    ScopedMat dst;

    ASSERT_EQ(ocvu_warp_perspective(src.get(), dst.get(), transform.get(), 8, 8,
                                    OCVU_INTER_NEAREST, OCVU_BORDER_CONSTANT),
              OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 8);
    EXPECT_EQ(info.cols, 8);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_8UC1) << "型は src と同じままである";

    // 左半分が暗く、右半分が明るいという性質は、引き伸ばしても保たれる。
    const std::vector<uint8_t> pixels = ReadPixels(dst.get());
    ASSERT_EQ(pixels.size(), static_cast<size_t>(64));
    EXPECT_LT(pixels[4 * 8 + 1], 100) << "左は暗いままのはず";
    EXPECT_GT(pixels[4 * 8 + 6], 100) << "右は明るいままのはず";
}

TEST(ImgprocOps, PerspectiveTransformRejectsBadArguments) {
    ScopedMat transform;

    EXPECT_EQ(ocvu_get_perspective_transform(nullptr, kQuadBytes,
                                             kTo.data(), kQuadBytes, transform.get()),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_get_perspective_transform(kFrom.data(), kQuadBytes,
                                             nullptr, kQuadBytes, transform.get()),
              OCVU_STATUS_NULL_POINTER);

    // **4 点ぶん（float 8 個 = 32 バイト）が要る。** 1 バイト足りなければ何も読まない。
    EXPECT_EQ(ocvu_get_perspective_transform(kFrom.data(), kQuadBytes - 1,
                                             kTo.data(), kQuadBytes, transform.get()),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_get_perspective_transform(kFrom.data(), kQuadBytes,
                                             kTo.data(), kQuadBytes - 1, transform.get()),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 負の長さも断る。
    EXPECT_EQ(ocvu_get_perspective_transform(kFrom.data(), -1,
                                             kTo.data(), kQuadBytes, transform.get()),
              OCVU_STATUS_INVALID_ARGUMENT);

    EXPECT_EQ(ocvu_get_perspective_transform(kFrom.data(), kQuadBytes,
                                             kTo.data(), kQuadBytes, OCVU_MAT_HANDLE_NONE),
              OCVU_STATUS_INVALID_HANDLE);

    // **失敗しても dst は書き換わっていない。**
    ExpectUntouchedDestination(transform.get());

    // **余分にあるのは通る**（先頭の 4 点だけを読む）。ここまで書かないと
    // 「余分」の経路を 1 度も通らない —— ちょうど一致は余分ではない。
    const std::array<float, 12> padded{0.0f, 0.0f, 3.0f, 0.0f, 3.0f, 3.0f,
                                       0.0f, 3.0f, 99.0f, 99.0f, 99.0f, 99.0f};
    EXPECT_EQ(ocvu_get_perspective_transform(padded.data(),
                                             12 * static_cast<int64_t>(sizeof(float)),
                                             kTo.data(), kQuadBytes, transform.get()),
              OCVU_STATUS_OK);
    ExpectShape(transform.get(), 3, 3);
}

TEST(ImgprocOps, WarpPerspectiveRejectsBadArguments) {
    ScopedMat transform;
    ASSERT_EQ(ocvu_get_perspective_transform(kFrom.data(), kQuadBytes,
                                             kFrom.data(), kQuadBytes, transform.get()),
              OCVU_STATUS_OK);

    ScopedMat src(4, 4);
    FillSplit(src);
    ScopedMat dst;

    EXPECT_EQ(ocvu_warp_perspective(src.get(), dst.get(), transform.get(), 0, 8,
                                    OCVU_INTER_NEAREST, OCVU_BORDER_CONSTANT),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_warp_perspective(src.get(), dst.get(), transform.get(), 8, 0,
                                    OCVU_INTER_NEAREST, OCVU_BORDER_CONSTANT),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_warp_perspective(src.get(), dst.get(), transform.get(), 8, 8, 99,
                                    OCVU_BORDER_CONSTANT),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_warp_perspective(src.get(), dst.get(), transform.get(), 8, 8,
                                    OCVU_INTER_NEAREST, 99),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_warp_perspective(src.get(), dst.get(), transform.get(), 8, 8,
                                    OCVU_INTER_NEAREST, -1),
              OCVU_STATUS_INVALID_ARGUMENT);

    EXPECT_EQ(ocvu_warp_perspective(OCVU_MAT_HANDLE_NONE, dst.get(), transform.get(), 8, 8,
                                    OCVU_INTER_NEAREST, OCVU_BORDER_CONSTANT),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_warp_perspective(src.get(), OCVU_MAT_HANDLE_NONE, transform.get(), 8, 8,
                                    OCVU_INTER_NEAREST, OCVU_BORDER_CONSTANT),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_warp_perspective(src.get(), dst.get(), OCVU_MAT_HANDLE_NONE, 8, 8,
                                    OCVU_INTER_NEAREST, OCVU_BORDER_CONSTANT),
              OCVU_STATUS_INVALID_HANDLE);

    // **変換が 3x3 でないのは呼ぶ側の誤りである。** src（4x4）を渡して確かめる。
    EXPECT_EQ(ocvu_warp_perspective(src.get(), dst.get(), src.get(), 8, 8,
                                    OCVU_INTER_NEAREST, OCVU_BORDER_CONSTANT),
              OCVU_STATUS_INVALID_ARGUMENT);

    // **失敗しても dst は書き換わっていない。**
    ExpectUntouchedDestination(dst.get());
}

// ---------------------------------------------------------------------------
// **summary が OPENCV_ERROR を約束している経路を、実際に通す。**
//
// **約束だけして実装が返さない状態は、ビルドも既存テストも緑のまま隠れる**
// （add-abi-function skill）。この 5 本はどれも「OpenCV が例外を投げた場合は
// OCVU_STATUS_OPENCV_ERROR を返す」と書いているのに、**その経路を 1 度も
// 通していなかった** —— PR 前のレビューが指摘した。
//
// **UNKNOWN_ERROR でないことを見るのが要点である。** OCVU_TRY_END は
// cv::Exception を UNKNOWN_ERROR に落とすので、各関数が手前で個別に
// catch していなければ「原因不明」として報告される。
// ---------------------------------------------------------------------------

TEST(ImgprocOps, ThresholdReportsOpenCvFailuresAsOpenCvError) {
    // **Otsu は 1 channel でしか動かない**（summary にそう書いてある）。
    const ScopedTypedMat src(4, 4, OCVU_MAT_TYPE_8UC3);
    ScopedMat dst;
    std::array<uint8_t, 48> pixels{};
    ASSERT_EQ(ocvu_mat_copy_from_buffer(src.get(), pixels.data(), 48, 12), OCVU_STATUS_OK);

    double computed = 12345.0;
    EXPECT_EQ(ocvu_threshold(src.get(), dst.get(), 0.0, 255.0,
                             OCVU_THRESH_BINARY | OCVU_THRESH_OTSU, &computed),
              OCVU_STATUS_OPENCV_ERROR);
    EXPECT_DOUBLE_EQ(computed, 0.0) << "失敗したのに out_computed_threshold を書いている";
}

TEST(ImgprocOps, CannyReportsOpenCvFailuresAsOpenCvError) {
    // **Canny は 8 bit を要求する。** 32 bit 浮動小数は受けない。
    const ScopedTypedMat src(8, 8, OCVU_MAT_TYPE_32FC1);
    ScopedMat dst;
    std::vector<uint8_t> zeros(8 * 8 * 4, 0);
    ASSERT_EQ(ocvu_mat_copy_from_buffer(src.get(), zeros.data(),
                                        static_cast<int64_t>(zeros.size()), 8 * 4),
              OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_canny(src.get(), dst.get(), 50.0, 150.0, 3, 0),
              OCVU_STATUS_OPENCV_ERROR);
}

TEST(ImgprocOps, MatchTemplateReportsOpenCvFailuresAsOpenCvError) {
    // **image と templ は同じ型でなければならない**（OpenCV の assertion）。
    ScopedMat image(8, 8);
    const ScopedTypedMat templ(3, 3, OCVU_MAT_TYPE_8UC3);
    ScopedMat dst;
    std::array<uint8_t, 64> image_pixels{};
    ASSERT_EQ(ocvu_mat_copy_from_buffer(image.get(), image_pixels.data(), 64, 8),
              OCVU_STATUS_OK);
    std::array<uint8_t, 27> templ_pixels{};
    ASSERT_EQ(ocvu_mat_copy_from_buffer(templ.get(), templ_pixels.data(), 27, 9),
              OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_match_template(image.get(), templ.get(), dst.get(), OCVU_TM_CCORR),
              OCVU_STATUS_OPENCV_ERROR);
}

TEST(ImgprocOps, WarpPerspectiveReportsOpenCvFailuresAsOpenCvError) {
    // **変換行列は浮動小数でなければならない。** 3x3 であることは
    // この ABI が自分で見るが、**型は OpenCV に任せている** ——
    // 8 bit の 3x3 を渡すと例外になる。
    ScopedMat src(4, 4);
    FillSplit(src);
    const ScopedTypedMat bad_transform(3, 3, OCVU_MAT_TYPE_8UC1);
    std::array<uint8_t, 9> t{};
    ASSERT_EQ(ocvu_mat_copy_from_buffer(bad_transform.get(), t.data(), 9, 3), OCVU_STATUS_OK);
    ScopedMat dst;

    EXPECT_EQ(ocvu_warp_perspective(src.get(), dst.get(), bad_transform.get(), 8, 8,
                                    OCVU_INTER_NEAREST, OCVU_BORDER_CONSTANT),
              OCVU_STATUS_OPENCV_ERROR);
}

TEST(ImgprocOps, MorphologyReportsOpenCvFailuresAsOpenCvError) {
    // **型では到達できなかった。** 最初は 64 bit 浮動小数を渡す形で書いたが、
    // cv::morphologyEx はそれを受け付けて成功した（2026-09-05 に実測）——
    // **8 bit だけだろうという推測が外れた。**
    //
    // 代わりに summary が名指ししている経路を使う ——
    // 「構造要素が大きすぎて確保できない場合」である。iterations を極端に
    // 大きくすると、OpenCV は実際の窓の大きさを
    // ksize + (iterations - 1) * (ksize - 1) で先に計算し、そこで破綻する。
    // **繰り返しが実行されるわけではないので、このテストは速い。**
    ScopedMat src(4, 4);
    FillSplit(src);
    ScopedMat dst;

    const ocvu_status status = ocvu_morphology_ex(
        src.get(), dst.get(), OCVU_MORPH_DILATE, OCVU_MORPH_SHAPE_RECT, 3, 3, INT32_MAX);

    // **UNKNOWN_ERROR でないことが要点である。** 個別の catch が無ければ
    // OCVU_TRY_END が「原因不明」に落とす。
    EXPECT_NE(status, OCVU_STATUS_UNKNOWN_ERROR)
        << "OpenCV 由来の失敗が「原因不明」として報告されている";
    EXPECT_EQ(status, OCVU_STATUS_OPENCV_ERROR);

    // 失敗したので dst は置き換わっていない（作ったときの 1x1 のままである）。
    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 1);
    EXPECT_EQ(info.cols, 1);
}
