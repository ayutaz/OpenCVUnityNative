// カメラの歪み補正の契約テスト。
//
// **calib module は使っていない。** undistort は imgproc、
// findChessboardCorners は objdetect に在り、どちらも既にリンク済みである
// （native/tests/test_module_linkage.cpp がその前提を固定している）。

#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <set>
#include <utility>
#include <vector>

namespace {

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

// 焦点距離 100、中心 (16, 16) の 3x3 カメラ行列（行優先）。
const std::vector<double> kCamera{100, 0, 16, 0, 100, 16, 0, 0, 1};

// 樽型の歪みを持つ 5 要素の係数。
const std::vector<double> kCoeffs{0.1, -0.05, 0, 0, 0};

constexpr int64_t kCameraBytes = 9 * static_cast<int64_t>(sizeof(double));
constexpr int64_t kCoeffsBytes = 5 * static_cast<int64_t>(sizeof(double));

}  // namespace

TEST(Calibration, UndistortProducesAnImageOfTheSameShape) {
    ScopedMat src(32, 32);
    ScopedMat dst;

    ASSERT_EQ(ocvu_undistort(src.get(), kCamera.data(), kCameraBytes,
                             kCoeffs.data(), kCoeffsBytes, dst.get()),
              OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 32);
    EXPECT_EQ(info.cols, 32);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_8UC1);
}

TEST(Calibration, UndistortRejectsInvalidArguments) {
    ScopedMat src(32, 32);
    ScopedMat dst;

    EXPECT_EQ(ocvu_undistort(src.get(), nullptr, kCameraBytes,
                             kCoeffs.data(), kCoeffsBytes, dst.get()),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_undistort(src.get(), kCamera.data(), kCameraBytes,
                             nullptr, kCoeffsBytes, dst.get()),
              OCVU_STATUS_NULL_POINTER);

    // **カメラ行列はちょうど 9 要素（72 バイト）でなければならない。**
    // 足りなければ終端を越えて読み、多ければ呼ぶ側の意図と食い違う。
    EXPECT_EQ(ocvu_undistort(src.get(), kCamera.data(), kCameraBytes - 1,
                             kCoeffs.data(), kCoeffsBytes, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_undistort(src.get(), kCamera.data(), kCameraBytes + 8,
                             kCoeffs.data(), kCoeffsBytes, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);

    // **歪み係数は OpenCV が受ける長さだけを通す**（4 / 5 / 8 / 12 / 14）。
    // 3 要素は受け付けない。
    EXPECT_EQ(ocvu_undistort(src.get(), kCamera.data(), kCameraBytes,
                             kCoeffs.data(), 3 * static_cast<int64_t>(sizeof(double)), dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);

    EXPECT_EQ(ocvu_undistort(OCVU_MAT_HANDLE_NONE, kCamera.data(), kCameraBytes,
                             kCoeffs.data(), kCoeffsBytes, dst.get()),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(ocvu_undistort(src.get(), kCamera.data(), kCameraBytes,
                             kCoeffs.data(), kCoeffsBytes, OCVU_MAT_HANDLE_NONE),
              OCVU_STATUS_INVALID_HANDLE);
}

TEST(Calibration, UndistortAcceptsEveryCoefficientCountOpenCvTakes) {
    // **OpenCV が受ける長さを、こちらも全部受ける。** 4 / 5 / 8 / 12 / 14 で、
    // どれか 1 つでも落とすと、その係数を持つ利用者だけが使えなくなる。
    ScopedMat src(32, 32);
    ScopedMat dst;

    for (const int n : {4, 5, 8, 12, 14}) {
        const std::vector<double> coeffs(static_cast<size_t>(n), 0.01);
        EXPECT_EQ(ocvu_undistort(src.get(), kCamera.data(), kCameraBytes, coeffs.data(),
                                 n * static_cast<int64_t>(sizeof(double)), dst.get()),
                  OCVU_STATUS_OK)
            << "係数 " << n << " 個が拒否された";
    }
}

TEST(Calibration, UndistortLeavesTheDestinationUntouchedWhenItFails) {
    ScopedMat src(32, 32);
    ScopedMat dst;

    ASSERT_EQ(ocvu_undistort(src.get(), kCamera.data(), kCameraBytes,
                             kCoeffs.data(), kCoeffsBytes, dst.get()),
              OCVU_STATUS_OK);
    ocvu_mat_info before{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &before), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_undistort(src.get(), nullptr, kCameraBytes,
                             kCoeffs.data(), kCoeffsBytes, dst.get()),
              OCVU_STATUS_NULL_POINTER);

    ocvu_mat_info after{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &after), OCVU_STATUS_OK);
    EXPECT_EQ(before.rows, after.rows);
    EXPECT_EQ(before.cols, after.cols);
    EXPECT_EQ(before.type, after.type);
}

TEST(Calibration, UndistortAcceptsTheSameHandleForSourceAndDestination) {
    // **`UndistortLeavesTheDestinationUntouchedWhenItFails` はこの実装バグを
    // 捕まえられない** —— あちらが使う失敗（NULL_POINTER）は cv::undistort を
    // 呼ぶ前の引数検証で返るので、実装がどちらの形でも dst には触れない。
    //
    // 「求めてから入れる」実装が本当に守っているのは、src と dst が**同じ
    // handle**で渡されたときの正しさである。cv::undistort(*src_mat, *dst_mat, ...)
    // のように直接書く形だと、cv::Mat::create() が既存のサイズ・型と一致する
    // ため no-op になり、dst.data と src.data が同じポインタのまま
    // OpenCV 内部の CV_Assert(dst.data != src.data) に落ちて
    // OCVU_STATUS_OPENCV_ERROR になる（実測で確認済み）。一時 Mat を経由する
    // 実装は dst_mat 自身を cv::undistort へ渡さないので、この assert に
    // 触れずに成功する。
    //
    // **形（rows/cols/type）だけでなく画素の中身も見る。** 形だけでは
    // 「同じ handle なら何もせず OK を返す」退化実装でも通ってしまう。
    //
    // **歪み係数はゼロにしない。** ゼロにすると恒等写像になり、正解＝入力に
    // なるので、「何もしない」退化実装や「ただの複製」もそのまま通ってしまう
    // （レビュー I1）。代わりに、**別 handle で同じ入力を非ゼロ係数で処理した
    // 結果**を基準にし、同一 handle で in-place 実行した結果がそれと
    // バイト単位で一致することを見る。これなら「何もしない」も「複製する」も
    // 「計算を間違える」もすべて落ちる。
    ScopedMat m(32, 32);
    std::vector<uint8_t> pixels(32 * 32, 0);
    for (size_t i = 0; i < pixels.size(); ++i) {
        pixels[i] = static_cast<uint8_t>(i % 256);
    }
    ASSERT_EQ(ocvu_mat_copy_from_buffer(m.get(), pixels.data(),
                                        static_cast<int64_t>(pixels.size()), 32),
              OCVU_STATUS_OK);

    // 基準: 別 handle・別 dst に非ゼロ係数（kCoeffs）で処理した結果。
    ScopedMat ref_src(32, 32);
    ScopedMat ref_dst(32, 32);
    ASSERT_EQ(ocvu_mat_copy_from_buffer(ref_src.get(), pixels.data(),
                                        static_cast<int64_t>(pixels.size()), 32),
              OCVU_STATUS_OK);
    ASSERT_EQ(ocvu_undistort(ref_src.get(), kCamera.data(), kCameraBytes,
                             kCoeffs.data(), kCoeffsBytes, ref_dst.get()),
              OCVU_STATUS_OK);
    std::vector<uint8_t> expected(32 * 32, 0);
    ASSERT_EQ(ocvu_mat_copy_to_buffer(ref_dst.get(), expected.data(),
                                      static_cast<int64_t>(expected.size()), 32),
              OCVU_STATUS_OK);

    // 同一 handle・同じ非ゼロ係数で in-place 実行する。
    EXPECT_EQ(ocvu_undistort(m.get(), kCamera.data(), kCameraBytes,
                             kCoeffs.data(), kCoeffsBytes, m.get()),
              OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(m.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 32);
    EXPECT_EQ(info.cols, 32);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_8UC1);

    std::vector<uint8_t> out(32 * 32, 0);
    ASSERT_EQ(ocvu_mat_copy_to_buffer(m.get(), out.data(),
                                      static_cast<int64_t>(out.size()), 32),
              OCVU_STATUS_OK);

    // **同一 handle の結果は、別 handle で計算した基準と 1 バイトも違わないこと。**
    EXPECT_EQ(out, expected)
        << "同一 handle の結果が別 handle で計算した基準と食い違っている";
}

TEST(Calibration, UndistortWithZeroCoefficientsIsNearlyIdentity) {
    // 歪みが無いなら、補正しても中身はほぼ変わらない。
    // **「呼べた」だけでなく「正しく計算した」ことを見る唯一のテストである。**
    ScopedMat src(16, 16);

    std::vector<uint8_t> pixels(16 * 16, 0);
    for (size_t i = 0; i < pixels.size(); ++i) {
        pixels[i] = static_cast<uint8_t>(i % 256);
    }
    ASSERT_EQ(ocvu_mat_copy_from_buffer(src.get(), pixels.data(),
                                        static_cast<int64_t>(pixels.size()), 16),
              OCVU_STATUS_OK);

    const std::vector<double> zero{0, 0, 0, 0, 0};
    ScopedMat dst;
    ASSERT_EQ(ocvu_undistort(src.get(), kCamera.data(), kCameraBytes, zero.data(),
                             5 * static_cast<int64_t>(sizeof(double)), dst.get()),
              OCVU_STATUS_OK);

    std::vector<uint8_t> out(16 * 16, 0);
    ASSERT_EQ(ocvu_mat_copy_to_buffer(dst.get(), out.data(),
                                      static_cast<int64_t>(out.size()), 16),
              OCVU_STATUS_OK);

    // 補間で端が僅かに動くので、中央付近だけを比べる。
    for (int y = 4; y < 12; ++y) {
        for (int x = 4; x < 12; ++x) {
            const size_t i = static_cast<size_t>(y) * 16 + static_cast<size_t>(x);
            EXPECT_NEAR(static_cast<int>(out[i]), static_cast<int>(pixels[i]), 2)
                << "(" << x << ", " << y << ")";
        }
    }
}

TEST(Calibration, FindChessboardCornersReportsNotFoundOnABlankImage) {
    // 真っ黒な画像に格子は写っていない。**これは誤りではない** ——
    // 入力の形は正しく、見つからなかっただけである
    // （ocvu_qr_decode / ocvu_find_homography と同じ扱い）。
    //
    // **`ocvu_mat_create` は画素を初期化しない。** 「真っ黒」を主張するなら
    // 明示的にゼロ埋めする（レビュー I4。`test_module_linkage.cpp` の
    // `cv::Mat::zeros` と同じ考え方）。
    ScopedMat blank(64, 64);
    std::vector<uint8_t> zeros(64 * 64, 0);
    ASSERT_EQ(ocvu_mat_copy_from_buffer(blank.get(), zeros.data(),
                                        static_cast<int64_t>(zeros.size()), 64),
              OCVU_STATUS_OK);

    // **capacity は float の個数である**（点の個数ではない。レビュー C1）。
    std::vector<float> corners(7 * 7 * 2, 0.0f);
    int32_t count = 4321;  // 0 以外で汚す
    EXPECT_EQ(ocvu_find_chessboard_corners(blank.get(), 7, 7, corners.data(),
                                           7 * 7 * 2, &count),
              OCVU_STATUS_NOT_FOUND);
    EXPECT_EQ(count, 0) << "見つからなかったときは 0 を書くこと";
}

TEST(Calibration, FindChessboardCornersRejectsInvalidArgumentsAndAlwaysWritesZero) {
    ScopedMat src(64, 64);
    // **capacity は float の個数（7*7*2 = 98）である。**
    std::vector<float> corners(7 * 7 * 2, 0.0f);

    EXPECT_EQ(ocvu_find_chessboard_corners(src.get(), 7, 7, corners.data(), 98, nullptr),
              OCVU_STATUS_NULL_POINTER);

    // **格子は 2x2 以上でなければならない。** 1 列や 0 列では格子にならない。
    int32_t count = 4321;
    EXPECT_EQ(ocvu_find_chessboard_corners(src.get(), 1, 7, corners.data(), 98, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    count = 4321;
    EXPECT_EQ(ocvu_find_chessboard_corners(src.get(), 7, 0, corners.data(), 98, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    count = 4321;
    EXPECT_EQ(ocvu_find_chessboard_corners(src.get(), 7, 7, nullptr, 98, &count),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(count, 0);

    count = 4321;
    EXPECT_EQ(ocvu_find_chessboard_corners(OCVU_MAT_HANDLE_NONE, 7, 7,
                                           corners.data(), 98, &count),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(count, 0);

    // **capacity が負の経路にもテストを付ける（レビュー M1）。** これが無いと
    // capacity < 0 の分岐を消しても全部緑になる。
    count = 4321;
    EXPECT_EQ(ocvu_find_chessboard_corners(src.get(), 7, 7, corners.data(), -1, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);
}

TEST(Calibration, FindChessboardCornersRejectsPatternExceedingTheCornerLimit) {
    // **int32 の乗算オーバーフローを防ぐ上限（レビュー I3）。**
    // pattern_cols * pattern_rows が OCVU_CHESSBOARD_MAX_CORNERS を超えると、
    // 素通りせず INVALID_ARGUMENT で断る。素通りすると int32_t の乗算が
    // 折り返し、負になった needed が容量の門をすり抜けてしまう。
    ScopedMat src(64, 64);
    std::vector<float> corners(1, 0.0f);
    int32_t count = 4321;

    // pattern_cols * pattern_rows = 2,500,000,000 は INT32_MAX は言うに及ばず
    // OCVU_CHESSBOARD_MAX_CORNERS も大きく超える。
    EXPECT_EQ(ocvu_find_chessboard_corners(src.get(), 50000, 50000, corners.data(),
                                           0, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);
}

TEST(Calibration, FindChessboardCornersRejectsATooSmallBufferWithoutWriting) {
    ScopedMat src(64, 64);

    // 7x7 の格子には 49 点、**float 98 個**分要る（capacity は float の個数。
    // レビュー C1）。97 個分しか無いと言われたら断る。
    std::vector<float> corners(7 * 7 * 2, 0.0f);
    std::memset(corners.data(), 0xAB, corners.size() * sizeof(float));

    int32_t count = 999;
    EXPECT_EQ(ocvu_find_chessboard_corners(src.get(), 7, 7, corners.data(), 97, &count),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(count, 98) << "必要な float 数を返すこと";

    const auto* bytes = reinterpret_cast<const uint8_t*>(corners.data());
    for (size_t i = 0; i < corners.size() * sizeof(float); ++i) {
        ASSERT_EQ(bytes[i], 0xAB) << "足りない buffer には何も書かないこと";
    }
}

TEST(Calibration, FindChessboardCornersFindsASyntheticBoard) {
    // **「呼べた」だけでなく「見つけられた」ことを見る。**
    //
    // **盤をあえて非正方形にする。** 8x8 の正方形市松模様（内側格子点 7x7）だと
    // x と y を入れ替えても格子座標の集合が変わらず、並びの取り違えを
    // 検出できない（レビュー I2 で指摘。実測でも確認済み——下の
    // FindChessboardCornersFindsASyntheticBoard の並び検証を先に 7x7 の正方形で
    // 書いたところ、x/y を入れ替えて壊しても検査は緑のままだった）。
    // 横 8 マス・縦 7 マスにして、内側の格子点を 7x6（横 7・縦 6）にする。
    constexpr int kCell = 16;
    constexpr int kCols = 8;   // 横方向のマス数。内側格子点は 7 列。
    constexpr int kRows = 7;   // 縦方向のマス数。内側格子点は 6 行。
    constexpr int kWidth = kCell * kCols;
    constexpr int kHeight = kCell * kRows;
    constexpr int kPatternCols = kCols - 1;  // 7
    constexpr int kPatternRows = kRows - 1;  // 6
    constexpr int32_t kPointCount = kPatternCols * kPatternRows;  // 42
    constexpr int32_t kFloatCount = kPointCount * 2;              // 84

    // **ScopedMat を使う（レビュー M3）。** 生の handle を手で release すると
    // 途中の ASSERT_EQ で抜けたときに漏れる。mat table から到達可能なので
    // LeakSanitizer も鳴らない ―― RAII で塞ぐ。
    ScopedMat board(kHeight, kWidth);

    std::vector<uint8_t> pixels(static_cast<size_t>(kWidth) * kHeight, 0);
    for (int y = 0; y < kHeight; ++y) {
        for (int x = 0; x < kWidth; ++x) {
            const bool white = ((x / kCell) + (y / kCell)) % 2 == 0;
            pixels[static_cast<size_t>(y) * kWidth + static_cast<size_t>(x)] =
                white ? 255 : 0;
        }
    }
    ASSERT_EQ(ocvu_mat_copy_from_buffer(board.get(), pixels.data(),
                                        static_cast<int64_t>(pixels.size()), kWidth),
              OCVU_STATUS_OK);

    // **capacity は float の個数（7*6*2 = 84）である（レビュー C1）。**
    std::vector<float> corners(static_cast<size_t>(kFloatCount), 0.0f);
    int32_t count = 0;
    const ocvu_status status = ocvu_find_chessboard_corners(
        board.get(), kPatternCols, kPatternRows, corners.data(), kFloatCount, &count);

    // **見つかることを要求する。** 合成した完璧な市松模様で見つからないなら、
    // 実物の写真で見つかるはずがない。
    EXPECT_EQ(status, OCVU_STATUS_OK);
    ASSERT_EQ(count, kFloatCount);  // float の個数（42 点 x 2）

    const int32_t point_count = count / 2;
    const float max_extent = static_cast<float>(std::max(kWidth, kHeight));

    // 見つかった点が画像の中に収まっていること。
    for (int32_t i = 0; i < count; ++i) {
        EXPECT_GE(corners[static_cast<size_t>(i)], 0.0f);
        EXPECT_LE(corners[static_cast<size_t>(i)], max_extent);
    }

    // **並び（x と y が交互）を検証する（レビュー I2）。** 範囲チェックだけでは
    // 平面配置（x を先に 42 個、y を後で 42 個）でも xy 入れ替えでも同一点の
    // 重複でも緑になってしまう。盤を非正方形にしてあるので、x 方向は 1..7、
    // y 方向は 1..6 という別々の範囲になり、入れ替えれば y が範囲外
    // （またはその逆）になって落ちる。内側の格子点が 16 px 刻みで並ぶことは
    // 合成時点で分かっているので、各点を最寄りの格子座標に丸めて、
    // 42 通りすべてが相異なることまで見る。
    std::set<std::pair<int, int>> grid_positions;
    for (int32_t i = 0; i < point_count; ++i) {
        const float x = corners[static_cast<size_t>(i) * 2];
        const float y = corners[static_cast<size_t>(i) * 2 + 1];

        const int gx = static_cast<int>(std::lround(x / kCell));
        const int gy = static_cast<int>(std::lround(y / kCell));
        EXPECT_GE(gx, 1) << "point " << i;
        EXPECT_LE(gx, kPatternCols) << "point " << i;
        EXPECT_GE(gy, 1) << "point " << i;
        EXPECT_LE(gy, kPatternRows) << "point " << i;
        // 丸めただけでは粗すぎるので、実際の座標が格子点に十分近いことも見る。
        EXPECT_NEAR(x, static_cast<float>(gx * kCell), 2.0f) << "point " << i;
        EXPECT_NEAR(y, static_cast<float>(gy * kCell), 2.0f) << "point " << i;

        grid_positions.emplace(gx, gy);
    }
    EXPECT_EQ(grid_positions.size(), static_cast<size_t>(point_count))
        << "42 点が 7x6 の格子上ですべて相異なる位置であること"
           "（重複や取り違えがあれば集合が小さくなる）";
}
