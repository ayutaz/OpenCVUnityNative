// imgproc のうち「形を返す」3 本の契約テスト —— ocvu_hough_lines_p /
// ocvu_corner_sub_pix / ocvu_find_contours。
//
// **入力は自分で描いた図形だけを使う。** 外部の画像に依存せず、期待値も
// OpenCV に作らせない（同じ経路で作ると、両方が同じだけ間違っていても緑になる）。
//
// **ocvu_mat_create は画素を初期化しない。** 「何も写っていない画像」が要るなら、
// 下のヘルパのようにゼロを明示的に入れるまで、中身は前の確保の残りである。

#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <array>
#include <cmath>
#include <cstdint>
#include <vector>

namespace {

// Mat を 1 つ持ち、抜けるときに必ず解放する。
class ScopedMat {
public:
    explicit ScopedMat(int32_t rows = 1, int32_t cols = 1,
                       int32_t type = OCVU_MAT_TYPE_8UC1) {
        EXPECT_EQ(ocvu_mat_create(rows, cols, type, &handle_), OCVU_STATUS_OK);
    }
    ~ScopedMat() { ocvu_mat_release(handle_); }
    ScopedMat(const ScopedMat&) = delete;
    ScopedMat& operator=(const ScopedMat&) = delete;

    ocvu_mat_handle get() const { return handle_; }

private:
    ocvu_mat_handle handle_ = OCVU_MAT_HANDLE_NONE;
};

// 1 度をラジアンで。**手で書いた 0.0174... を置かない** —— 桁を 1 つ間違えても
// テストは「線が見つからない」としか言わず、原因が読めなくなる。
double OneDegree() { return std::acos(-1.0) / 180.0; }

// 8 bit 1 channel の Mat を、渡した画素で丸ごと埋める。stride はバイト単位である。
void FillGray(ocvu_mat_handle handle, const std::vector<uint8_t>& pixels, int32_t cols) {
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(),
                                        static_cast<int64_t>(pixels.size()), cols),
              OCVU_STATUS_OK);
}

// 全画素 0 の side x side（8 bit 1 channel）。
void DrawBlank(ocvu_mat_handle handle, int32_t side) {
    const std::vector<uint8_t> pixels(static_cast<size_t>(side) * side, 0);
    FillGray(handle, pixels, side);
}

// 指定した行だけが 255 の side x side。
void DrawHorizontalLine(ocvu_mat_handle handle, int32_t side, int32_t row) {
    std::vector<uint8_t> pixels(static_cast<size_t>(side) * side, 0);
    for (int32_t c = 0; c < side; ++c) {
        pixels[static_cast<size_t>(row) * side + c] = 255;
    }
    FillGray(handle, pixels, side);
}

// 左上と右下が白、右上と左下が黒の 2 値の市松。**角は中央にできる。**
// side = 32 なら、白黒の境目は画素 15 と 16 の間、つまり連続座標で 15.5 である。
void DrawCheckerCorner(ocvu_mat_handle handle, int32_t side) {
    std::vector<uint8_t> pixels(static_cast<size_t>(side) * side, 0);
    const int32_t half = side / 2;
    for (int32_t r = 0; r < side; ++r) {
        for (int32_t c = 0; c < side; ++c) {
            const bool white = (r < half) == (c < half);
            pixels[static_cast<size_t>(r) * side + c] = white ? 255 : 0;
        }
    }
    FillGray(handle, pixels, side);
}

// 黒い side x side の中に、[from, to] の範囲（両端を含む）の白い正方形を 1 つ置く。
void DrawSingleSquare(ocvu_mat_handle handle, int32_t side, int32_t from, int32_t to) {
    std::vector<uint8_t> pixels(static_cast<size_t>(side) * side, 0);
    for (int32_t r = from; r <= to; ++r) {
        for (int32_t c = from; c <= to; ++c) {
            pixels[static_cast<size_t>(r) * side + c] = 255;
        }
    }
    FillGray(handle, pixels, side);
}

// 3 channel の Mat を全画素 0 で埋める。**型が合わない入力を作るためだけに使う。**
void DrawBlankColor(ocvu_mat_handle handle, int32_t side) {
    const std::vector<uint8_t> pixels(static_cast<size_t>(side) * side * 3, 0);
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(),
                                        static_cast<int64_t>(pixels.size()),
                                        static_cast<int64_t>(side) * 3),
              OCVU_STATUS_OK);
}

std::vector<uint8_t> ReadGray(ocvu_mat_handle handle) {
    ocvu_mat_info info{};
    EXPECT_EQ(ocvu_mat_get_info(handle, &info), OCVU_STATUS_OK);
    std::vector<uint8_t> pixels(
        static_cast<size_t>(info.rows) * info.cols * info.channels);
    EXPECT_EQ(ocvu_mat_copy_to_buffer(handle, pixels.data(),
                                      static_cast<int64_t>(pixels.size()),
                                      static_cast<int64_t>(info.cols) * info.channels),
              OCVU_STATUS_OK);
    return pixels;
}

}  // namespace

// ---------------------------------------------------------------------------
// ocvu_hough_lines_p
// ---------------------------------------------------------------------------

TEST(ImgprocShape, HoughFindsTheHorizontalLine) {
    ScopedMat src(64, 64);
    DrawHorizontalLine(src.get(), 64, 32);

    std::array<float, 64> lines{};
    int32_t count = -1;

    ASSERT_EQ(ocvu_hough_lines_p(src.get(), 1.0, OneDegree(), 30, 20.0, 5.0,
                                 lines.data(), 64, &count),
              OCVU_STATUS_OK);
    ASSERT_GE(count, 1) << "1 本の横線があるのに何も見つからない";

    // 1 本目は y がほぼ 32 の横線である（4 要素で x1, y1, x2, y2）。
    // **x は端がどこで切れるか分からないので見ない。** y だけが手で決まる。
    EXPECT_NEAR(lines[1], 32.0f, 2.0f);
    EXPECT_NEAR(lines[3], 32.0f, 2.0f);
}

TEST(ImgprocShape, HoughReturnsZeroOnABlankImage) {
    // **見つからないのは誤りではない。**
    ScopedMat blank(64, 64);
    DrawBlank(blank.get(), 64);

    std::array<float, 64> lines{};
    int32_t count = -1;

    EXPECT_EQ(ocvu_hough_lines_p(blank.get(), 1.0, OneDegree(), 30, 20.0, 5.0,
                                 lines.data(), 64, &count),
              OCVU_STATUS_OK);
    EXPECT_EQ(count, 0);
}

TEST(ImgprocShape, HoughRejectsBadArgumentsAndZeroesTheCount) {
    ScopedMat src(64, 64);
    DrawHorizontalLine(src.get(), 64, 32);
    std::array<float, 64> lines{};

    EXPECT_EQ(ocvu_hough_lines_p(src.get(), 1.0, OneDegree(), 30, 20.0, 5.0,
                                 lines.data(), 64, nullptr),
              OCVU_STATUS_NULL_POINTER);

    // **0 ではない値で汚してから呼ぶ。** 0 で初期化すると「書いていない」と
    // 「0 を書いた」が区別できない。
    int32_t count = 12345;
    EXPECT_EQ(ocvu_hough_lines_p(src.get(), 0.0, OneDegree(), 30, 20.0, 5.0,
                                 lines.data(), 64, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0) << "失敗時は out_count に 0 を書くこと";

    count = 12345;
    EXPECT_EQ(ocvu_hough_lines_p(src.get(), 1.0, 0.0, 30, 20.0, 5.0,
                                 lines.data(), 64, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_hough_lines_p(src.get(), 1.0, OneDegree(), 0, 20.0, 5.0,
                                 lines.data(), 64, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_hough_lines_p(src.get(), 1.0, OneDegree(), 30, 20.0, 5.0,
                                 lines.data(), -1, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    // **容量が 1 以上なのに buffer が無いのは呼ぶ側の誤りである。**
    count = 12345;
    EXPECT_EQ(ocvu_hough_lines_p(src.get(), 1.0, OneDegree(), 30, 20.0, 5.0,
                                 nullptr, 64, &count),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_hough_lines_p(OCVU_MAT_HANDLE_NONE, 1.0, OneDegree(), 30, 20.0, 5.0,
                                 lines.data(), 64, &count),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(count, 0);
}

TEST(ImgprocShape, HoughReportsTheNeededCountWhenTheBufferIsTooSmall) {
    ScopedMat src(64, 64);
    DrawHorizontalLine(src.get(), 64, 32);

    std::array<float, 64> lines{};
    lines.fill(-7.0f);
    int32_t count = -1;

    // 容量 0 では 1 本も入らない。
    EXPECT_EQ(ocvu_hough_lines_p(src.get(), 1.0, OneDegree(), 30, 20.0, 5.0,
                                 lines.data(), 0, &count),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_GE(count, 1) << "溢れたときは実際に見つかった本数を返すこと";
    for (float v : lines) {
        EXPECT_FLOAT_EQ(v, -7.0f) << "断ったのに out_lines へ書いている";
    }
}

TEST(ImgprocShape, HoughAnswersHowManyLinesWithoutABuffer) {
    // **容量 0 なら out_lines は NULL でよい。** これが「何本あるか」だけを
    // 問い合わせる呼び方で、C# 側の 2 回呼びがこの経路に乗る。
    ScopedMat src(64, 64);
    DrawHorizontalLine(src.get(), 64, 32);

    int32_t count = -1;
    EXPECT_EQ(ocvu_hough_lines_p(src.get(), 1.0, OneDegree(), 30, 20.0, 5.0,
                                 nullptr, 0, &count),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    ASSERT_GE(count, 1);

    // 返ってきた本数の 4 倍を確保すれば、2 回目は通る。
    std::vector<float> lines(static_cast<size_t>(count) * 4, 0.0f);
    int32_t again = -1;
    EXPECT_EQ(ocvu_hough_lines_p(src.get(), 1.0, OneDegree(), 30, 20.0, 5.0,
                                 lines.data(), count * 4, &again),
              OCVU_STATUS_OK);
    EXPECT_EQ(again, count);
}

TEST(ImgprocShape, HoughReportsOpenCvFailuresAsOpenCvError) {
    // **summary が OPENCV_ERROR を約束しているので、返ることを実証する。**
    // 約束だけして実装が UNKNOWN_ERROR を返す状態は、ビルドも他のテストも
    // 緑のまま隠れる。3 channel は cv::HoughLinesP が受け付けない。
    ScopedMat color(64, 64, OCVU_MAT_TYPE_8UC3);
    DrawBlankColor(color.get(), 64);

    std::array<float, 64> lines{};
    int32_t count = 12345;
    EXPECT_EQ(ocvu_hough_lines_p(color.get(), 1.0, OneDegree(), 30, 20.0, 5.0,
                                 lines.data(), 64, &count),
              OCVU_STATUS_OPENCV_ERROR);
    EXPECT_EQ(count, 0);
}

TEST(ImgprocShape, HoughLeavesTheSourceImageAlone) {
    // **この 1 件は、いま実装から clone を外しても落ちない**（2026-09-05 実測:
    // cv::HoughLinesP は入力を 1 画素も書き換えなかった）。それでも置いてある
    // のは、OpenCV の doc が「この関数が書き換えることがある」と宣言しており、
    // 上流がその契約を変えた日に**こちらが黙って壊れる**のを防ぐためである。
    // **「壊して落ちることを見た」とは言えない検査**なので、そう書いてある。
    ScopedMat src(64, 64);
    DrawHorizontalLine(src.get(), 64, 32);
    const std::vector<uint8_t> before = ReadGray(src.get());

    std::array<float, 64> lines{};
    int32_t count = -1;
    ASSERT_EQ(ocvu_hough_lines_p(src.get(), 1.0, OneDegree(), 30, 20.0, 5.0,
                                 lines.data(), 64, &count),
              OCVU_STATUS_OK);

    const std::vector<uint8_t> after = ReadGray(src.get());
    ASSERT_EQ(before.size(), after.size());
    int differing = 0;
    for (size_t i = 0; i < before.size(); ++i) {
        if (before[i] != after[i]) { ++differing; }
    }
    EXPECT_EQ(differing, 0) << "呼ぶ側の src を書き換えている";
}

// ---------------------------------------------------------------------------
// ocvu_corner_sub_pix
// ---------------------------------------------------------------------------

TEST(ImgprocShape, CornerSubPixMovesThePointTowardTheCorner) {
    // 32x32 の市松の角は連続座標で (15.5, 15.5) にある。**そこから 1.5 画素
    // ずらして渡し、近づくことを見る。**
    ScopedMat src(32, 32);
    DrawCheckerCorner(src.get(), 32);

    std::array<float, 2> points{14.0f, 14.0f};

    ASSERT_EQ(ocvu_corner_sub_pix(src.get(), points.data(),
                                  static_cast<int64_t>(sizeof(points)),
                                  1, 5, -1, 30, 0.01),
              OCVU_STATUS_OK);

    // **精緻化なので、値を狭く縛らない。** 元の位置より角に寄っていればよい。
    EXPECT_NEAR(points[0], 16.0f, 1.5f);
    EXPECT_NEAR(points[1], 16.0f, 1.5f);
}

TEST(ImgprocShape, CornerSubPixRejectsBadArgumentsWithoutTouchingThePoints) {
    ScopedMat src(32, 32);
    DrawCheckerCorner(src.get(), 32);

    std::array<float, 2> points{14.0f, 14.0f};
    const int64_t bytes = static_cast<int64_t>(sizeof(points));

    EXPECT_EQ(ocvu_corner_sub_pix(src.get(), nullptr, bytes, 1, 5, -1, 30, 0.01),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_corner_sub_pix(src.get(), points.data(), bytes, 0, 5, -1, 30, 0.01),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_corner_sub_pix(src.get(), points.data(), bytes, -1, 5, -1, 30, 0.01),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_corner_sub_pix(src.get(), points.data(), bytes,
                                  OCVU_CORNER_MAX_POINTS + 1, 5, -1, 30, 0.01),
              OCVU_STATUS_INVALID_ARGUMENT);
    // **長さはバイト数である。** 1 バイト足りなければ何も読まない。
    EXPECT_EQ(ocvu_corner_sub_pix(src.get(), points.data(), bytes - 1, 1, 5, -1, 30, 0.01),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_corner_sub_pix(src.get(), points.data(), -1, 1, 5, -1, 30, 0.01),
              OCVU_STATUS_INVALID_ARGUMENT);
    // 窓の半径は 1 以上、繰り返しは 1 以上。
    EXPECT_EQ(ocvu_corner_sub_pix(src.get(), points.data(), bytes, 1, 0, -1, 30, 0.01),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_corner_sub_pix(src.get(), points.data(), bytes, 1, 5, -1, 0, 0.01),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_corner_sub_pix(OCVU_MAT_HANDLE_NONE, points.data(), bytes,
                                  1, 5, -1, 30, 0.01),
              OCVU_STATUS_INVALID_HANDLE);

    // **断ったのだから、渡した点は 1 つも動いていない。**
    EXPECT_FLOAT_EQ(points[0], 14.0f);
    EXPECT_FLOAT_EQ(points[1], 14.0f);
}

TEST(ImgprocShape, CornerSubPixReportsOpenCvFailuresWithoutTouchingThePoints) {
    // cv::cornerSubPix が縛るのは channel の数である。3 channel を渡すと
    // OpenCV が例外を投げるので、OPENCV_ERROR として報告する。
    // **そのときも points は書きかけで残らない** —— 写してから戻す実装が、
    // それを構造で保証している。
    ScopedMat color(32, 32, OCVU_MAT_TYPE_8UC3);
    DrawBlankColor(color.get(), 32);

    std::array<float, 2> points{14.0f, 14.0f};
    EXPECT_EQ(ocvu_corner_sub_pix(color.get(), points.data(),
                                  static_cast<int64_t>(sizeof(points)),
                                  1, 5, -1, 30, 0.01),
              OCVU_STATUS_OPENCV_ERROR);
    EXPECT_FLOAT_EQ(points[0], 14.0f);
    EXPECT_FLOAT_EQ(points[1], 14.0f);
}

// ---------------------------------------------------------------------------
// ocvu_find_contours
// ---------------------------------------------------------------------------

TEST(ImgprocShape, FindContoursFindsTheSquare) {
    ScopedMat src(32, 32);
    DrawSingleSquare(src.get(), 32, 11, 20);

    std::array<float, 256> points{};
    std::array<int32_t, 16> counts{};
    int32_t contour_count = -1;
    int32_t total_points = -1;

    ASSERT_EQ(ocvu_find_contours(src.get(), OCVU_RETR_EXTERNAL, OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), 256, counts.data(), 16,
                                 &contour_count, &total_points),
              OCVU_STATUS_OK);

    // 白い塊が 1 つなので輪郭も 1 本である。
    EXPECT_EQ(contour_count, 1);
    // OCVU_CHAIN_APPROX_SIMPLE は正方形を 4 隅に間引く。
    EXPECT_EQ(counts[0], 4);
    EXPECT_EQ(total_points, 4);

    // **4 隅そのものを見る。** 順序は OpenCV が決めるので、集合として突き合わせる
    // （範囲だけを見ると、中の 1 点がずれていても緑になる）。
    bool seen[4] = {false, false, false, false};
    const float corners[4][2] = {{11.0f, 11.0f}, {20.0f, 11.0f},
                                 {20.0f, 20.0f}, {11.0f, 20.0f}};
    for (int i = 0; i < 4; ++i) {
        const float x = points[static_cast<size_t>(i) * 2];
        const float y = points[static_cast<size_t>(i) * 2 + 1];
        bool matched = false;
        for (int k = 0; k < 4; ++k) {
            if (x == corners[k][0] && y == corners[k][1]) {
                EXPECT_FALSE(seen[k]) << "同じ隅が 2 回出ている";
                seen[k] = true;
                matched = true;
            }
        }
        EXPECT_TRUE(matched) << "隅ではない点が返った: (" << x << ", " << y << ")";
    }
    for (int k = 0; k < 4; ++k) {
        EXPECT_TRUE(seen[k]) << "隅が 1 つ返っていない";
    }
}

TEST(ImgprocShape, FindContoursReturnsZeroOnABlankImage) {
    ScopedMat blank(32, 32);
    DrawBlank(blank.get(), 32);

    std::array<float, 256> points{};
    std::array<int32_t, 16> counts{};
    int32_t contour_count = -1;
    int32_t total_points = -1;

    EXPECT_EQ(ocvu_find_contours(blank.get(), OCVU_RETR_EXTERNAL, OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), 256, counts.data(), 16,
                                 &contour_count, &total_points),
              OCVU_STATUS_OK);
    EXPECT_EQ(contour_count, 0);
    EXPECT_EQ(total_points, 0);
}

TEST(ImgprocShape, FindContoursReportsWhatItNeedsWhenTheBuffersAreTooSmall) {
    ScopedMat src(32, 32);
    DrawSingleSquare(src.get(), 32, 11, 20);

    std::array<float, 256> points{};
    std::array<int32_t, 16> counts{};
    points.fill(-7.0f);
    counts.fill(-7);
    int32_t contour_count = -1;
    int32_t total_points = -1;

    // 点の容量が足りない（4 点 = 8 要素が要る）。
    EXPECT_EQ(ocvu_find_contours(src.get(), OCVU_RETR_EXTERNAL, OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), 7, counts.data(), 16,
                                 &contour_count, &total_points),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(contour_count, 1) << "溢れたときは必要な輪郭の本数を返すこと";
    EXPECT_EQ(total_points, 4) << "溢れたときは必要な点の総数を返すこと";

    // 輪郭数の容量が足りない。**点のほうは足りていても、どちらにも書かない。**
    contour_count = -1;
    total_points = -1;
    EXPECT_EQ(ocvu_find_contours(src.get(), OCVU_RETR_EXTERNAL, OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), 256, counts.data(), 0,
                                 &contour_count, &total_points),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(contour_count, 1);
    EXPECT_EQ(total_points, 4);

    for (float v : points) {
        EXPECT_FLOAT_EQ(v, -7.0f) << "断ったのに out_points へ書いている";
    }
    for (int32_t v : counts) {
        EXPECT_EQ(v, -7) << "断ったのに out_counts へ書いている";
    }
}

TEST(ImgprocShape, FindContoursAnswersHowMuchRoomItNeedsWithoutBuffers) {
    // **容量 0 なら両方 NULL でよい。** summary が「確保し直して呼び直せる」と
    // 約束しているので、その 1 回目が呼べることを実証する。
    ScopedMat src(32, 32);
    DrawSingleSquare(src.get(), 32, 11, 20);

    int32_t contour_count = -1;
    int32_t total_points = -1;
    EXPECT_EQ(ocvu_find_contours(src.get(), OCVU_RETR_EXTERNAL, OCVU_CHAIN_APPROX_SIMPLE,
                                 nullptr, 0, nullptr, 0,
                                 &contour_count, &total_points),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    ASSERT_EQ(contour_count, 1);
    ASSERT_EQ(total_points, 4);

    // 返ってきた大きさで確保すれば、2 回目は通る。
    std::vector<float> points(static_cast<size_t>(total_points) * 2, 0.0f);
    std::vector<int32_t> counts(static_cast<size_t>(contour_count), 0);
    int32_t again_contours = -1;
    int32_t again_points = -1;
    EXPECT_EQ(ocvu_find_contours(src.get(), OCVU_RETR_EXTERNAL, OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), total_points * 2,
                                 counts.data(), contour_count,
                                 &again_contours, &again_points),
              OCVU_STATUS_OK);
    EXPECT_EQ(again_contours, contour_count);
    EXPECT_EQ(again_points, total_points);
}

TEST(ImgprocShape, FindContoursRejectsBadArgumentsAndZeroesBothCounts) {
    ScopedMat src(32, 32);
    DrawSingleSquare(src.get(), 32, 11, 20);

    std::array<float, 256> points{};
    std::array<int32_t, 16> counts{};

    EXPECT_EQ(ocvu_find_contours(src.get(), OCVU_RETR_EXTERNAL, OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), 256, counts.data(), 16, nullptr, nullptr),
              OCVU_STATUS_NULL_POINTER);

    int32_t contour_count = 12345;
    EXPECT_EQ(ocvu_find_contours(src.get(), OCVU_RETR_EXTERNAL, OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), 256, counts.data(), 16,
                                 &contour_count, nullptr),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(contour_count, 0);

    // **0 ではない値で汚してから呼ぶ。**
    int32_t total_points = 12345;
    contour_count = 12345;

    EXPECT_EQ(ocvu_find_contours(src.get(), 99, OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), 256, counts.data(), 16,
                                 &contour_count, &total_points),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(contour_count, 0) << "失敗時は 0 を書くこと";
    EXPECT_EQ(total_points, 0) << "失敗時は 0 を書くこと";

    // **RETR_FLOODFILL(4) は出していない。** 範囲の外として断る。
    contour_count = 12345;
    total_points = 12345;
    EXPECT_EQ(ocvu_find_contours(src.get(), 4, OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), 256, counts.data(), 16,
                                 &contour_count, &total_points),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(contour_count, 0);
    EXPECT_EQ(total_points, 0);

    // **CHAIN_CODE(0) と Teh-Chin 系(3, 4) も出していない。**
    contour_count = 12345;
    total_points = 12345;
    EXPECT_EQ(ocvu_find_contours(src.get(), OCVU_RETR_EXTERNAL, 0,
                                 points.data(), 256, counts.data(), 16,
                                 &contour_count, &total_points),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(contour_count, 0);
    EXPECT_EQ(total_points, 0);

    contour_count = 12345;
    total_points = 12345;
    EXPECT_EQ(ocvu_find_contours(src.get(), OCVU_RETR_EXTERNAL, 3,
                                 points.data(), 256, counts.data(), 16,
                                 &contour_count, &total_points),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(contour_count, 0);
    EXPECT_EQ(total_points, 0);

    // 容量が負なのは呼ぶ側の誤りである。
    contour_count = 12345;
    total_points = 12345;
    EXPECT_EQ(ocvu_find_contours(src.get(), OCVU_RETR_EXTERNAL, OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), -1, counts.data(), 16,
                                 &contour_count, &total_points),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(contour_count, 0);
    EXPECT_EQ(total_points, 0);

    // 容量が 1 以上なのに buffer が無いのも誤りである。
    contour_count = 12345;
    total_points = 12345;
    EXPECT_EQ(ocvu_find_contours(src.get(), OCVU_RETR_EXTERNAL, OCVU_CHAIN_APPROX_SIMPLE,
                                 nullptr, 256, counts.data(), 16,
                                 &contour_count, &total_points),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(contour_count, 0);
    EXPECT_EQ(total_points, 0);

    contour_count = 12345;
    total_points = 12345;
    EXPECT_EQ(ocvu_find_contours(src.get(), OCVU_RETR_EXTERNAL, OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), 256, nullptr, 16,
                                 &contour_count, &total_points),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(contour_count, 0);
    EXPECT_EQ(total_points, 0);

    contour_count = 12345;
    total_points = 12345;
    EXPECT_EQ(ocvu_find_contours(OCVU_MAT_HANDLE_NONE, OCVU_RETR_EXTERNAL,
                                 OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), 256, counts.data(), 16,
                                 &contour_count, &total_points),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(contour_count, 0);
    EXPECT_EQ(total_points, 0);
}

TEST(ImgprocShape, FindContoursReportsOpenCvFailuresAsOpenCvError) {
    // 3 channel は cv::findContours が受け付けない。**summary が約束している
    // OPENCV_ERROR が実際に返ることを見る。**
    ScopedMat color(32, 32, OCVU_MAT_TYPE_8UC3);
    DrawBlankColor(color.get(), 32);

    std::array<float, 256> points{};
    std::array<int32_t, 16> counts{};
    int32_t contour_count = 12345;
    int32_t total_points = 12345;

    EXPECT_EQ(ocvu_find_contours(color.get(), OCVU_RETR_EXTERNAL, OCVU_CHAIN_APPROX_SIMPLE,
                                 points.data(), 256, counts.data(), 16,
                                 &contour_count, &total_points),
              OCVU_STATUS_OPENCV_ERROR);
    EXPECT_EQ(contour_count, 0);
    EXPECT_EQ(total_points, 0);
}
