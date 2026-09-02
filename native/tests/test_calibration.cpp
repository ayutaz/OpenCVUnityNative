// カメラの歪み補正の契約テスト。
//
// **calib module は使っていない。** undistort は imgproc、
// findChessboardCorners は objdetect に在り、どちらも既にリンク済みである
// （native/tests/test_module_linkage.cpp がその前提を固定している）。

#include <gtest/gtest.h>

#include <opencv_unity_native.h>

// 合成データを作るのに OpenCV を直接使う（投影は cv::projectPoints が持つ）。
// **テスト側で cv:: を呼ぶのは、期待値を独立に作るためである** ——
// 実装と同じ経路で作ると、両方が同じだけ間違っていても緑になる。
#include <opencv2/core.hpp>
#include <opencv2/geometry.hpp>

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
    // 検出できない（レビュー I2 で指摘。実測でも確認済み——この並び検証を
    // 先に 7x7 の正方形で書いたところ、x/y を入れ替えて壊しても検査は
    // 緑のままだった）。
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

// ---------------------------------------------------------------------------
// ocvu_calibrate_camera —— 校正の輪を閉じる段。**ここだけが calib module を要る。**
// ---------------------------------------------------------------------------

namespace {

// 合成する校正の既定値。**歪み係数を 0 にしない** —— 0 にすると
// 「歪みを推定しない実装」でも通ってしまう（同じ形を undistort で実際に踏んだ）。
constexpr double kFx = 500.0;
constexpr double kFy = 520.0;
constexpr double kCx = 320.0;
constexpr double kCy = 240.0;
constexpr int32_t kImageWidth = 640;
constexpr int32_t kImageHeight = 480;

constexpr int32_t kBoardCols = 7;
constexpr int32_t kBoardRows = 6;
constexpr int32_t kPointsPerView = kBoardCols * kBoardRows;
constexpr int32_t kViewCount = 8;

// 1 view につき 6 個（回転 3 個のあと並進 3 個）。**この数はここだけで決める。**
constexpr int32_t kPoseStride = 6;

// 盤の 3D 座標（z = 0 の平面）。全 view で同じ形を使う。
std::vector<float> MakeObjectPoints() {
    std::vector<float> flat;
    flat.reserve(static_cast<size_t>(kViewCount) * kPointsPerView * 3);
    for (int32_t v = 0; v < kViewCount; ++v) {
        for (int32_t r = 0; r < kBoardRows; ++r) {
            for (int32_t c = 0; c < kBoardCols; ++c) {
                flat.push_back(static_cast<float>(c) * 0.03f);
                flat.push_back(static_cast<float>(r) * 0.03f);
                flat.push_back(0.0f);
            }
        }
    }
    return flat;
}

// 既知のカメラで盤を投影して画像点を作る。**view ごとに姿勢を変える** ——
// 全部同じ姿勢だと校正が解けない（平面パターンは複数の向きが要る）。
std::vector<float> MakeImagePoints() {
    const cv::Mat camera = (cv::Mat_<double>(3, 3) << kFx, 0, kCx, 0, kFy, kCy, 0, 0, 1);
    const cv::Mat coeffs = (cv::Mat_<double>(1, 5) << -0.20, 0.08, 0.001, -0.001, 0.0);

    std::vector<cv::Point3f> board;
    for (int32_t r = 0; r < kBoardRows; ++r) {
        for (int32_t c = 0; c < kBoardCols; ++c) {
            board.emplace_back(static_cast<float>(c) * 0.03f, static_cast<float>(r) * 0.03f, 0.0f);
        }
    }

    std::vector<float> flat;
    flat.reserve(static_cast<size_t>(kViewCount) * kPointsPerView * 2);
    for (int32_t v = 0; v < kViewCount; ++v) {
        const double t = static_cast<double>(v);
        const cv::Mat rvec = (cv::Mat_<double>(3, 1) << 0.05 * t - 0.15, 0.04 * t - 0.12, 0.02 * t);
        const cv::Mat tvec = (cv::Mat_<double>(3, 1) << -0.09 + 0.005 * t, -0.07 + 0.004 * t, 0.5 + 0.02 * t);

        std::vector<cv::Point2f> projected;
        cv::projectPoints(board, rvec, tvec, camera, coeffs, projected);
        for (const cv::Point2f& p : projected) {
            flat.push_back(p.x);
            flat.push_back(p.y);
        }
    }
    return flat;
}

// 呼び出しの定型。出力は呼ぶ側が持つ。
struct CalibOutputs {
    std::vector<double> camera_matrix;
    std::vector<double> dist_coeffs;
    std::vector<double> view_poses;
    int32_t dist_count = -1;
    double rms = -1.0;

    CalibOutputs()
        : camera_matrix(9, 0.0), dist_coeffs(14, 0.0),
          view_poses(static_cast<size_t>(kViewCount) * kPoseStride, 0.0) {}
};

ocvu_status CallCalibrate(const std::vector<float>& object_points,
                          const std::vector<float>& image_points,
                          CalibOutputs& out) {
    return ocvu_calibrate_camera(
        object_points.data(),
        static_cast<int64_t>(object_points.size() * sizeof(float)),
        image_points.data(),
        static_cast<int64_t>(image_points.size() * sizeof(float)),
        kViewCount, kPointsPerView, kImageWidth, kImageHeight,
        out.camera_matrix.data(), static_cast<int32_t>(out.camera_matrix.size()),
        out.dist_coeffs.data(), static_cast<int32_t>(out.dist_coeffs.size()),
        &out.dist_count,
        out.view_poses.data(), static_cast<int32_t>(out.view_poses.size()),
        &out.rms);
}

}  // namespace

TEST(Calibration, CalibrateCameraRecoversTheKnownIntrinsics) {
    // **status が OK であることだけを見ない。** それでは「何も計算せず OK を
    // 返す」退化実装が通る。合成に使った焦点距離と主点が戻ることを見る。
    //
    // **object 点の x と y を入れ替えても、このテストは緑のままである**（実測）。
    // **それは検査の穴ではない** —— 盤の座標系が回っただけで、同じカメラを
    // 別の向きから見たことになる。校正はカメラの内部パラメータを解くので、
    // 盤をどちら向きに置いたかには依存しない。**image 点の x と y を入れ替えれば
    // 落ちる**（そちらは投影の結果なので、入れ替えると対応が崩れる）。
    const std::vector<float> object_points = MakeObjectPoints();
    const std::vector<float> image_points = MakeImagePoints();
    CalibOutputs out;

    ASSERT_EQ(CallCalibrate(object_points, image_points, out), OCVU_STATUS_OK);

    // 合成データなので誤差は小さい。**緩すぎる窓にしない** —— 大きく許すと
    // 「初期値をそのまま返す」実装が通りうる。
    EXPECT_NEAR(out.camera_matrix[0], kFx, kFx * 0.02);   // fx
    EXPECT_NEAR(out.camera_matrix[4], kFy, kFy * 0.02);   // fy
    EXPECT_NEAR(out.camera_matrix[2], kCx, 15.0);         // cx
    EXPECT_NEAR(out.camera_matrix[5], kCy, 15.0);         // cy

    // 3x3 の残りは行優先の 0 と 1 でなければならない。
    EXPECT_DOUBLE_EQ(out.camera_matrix[1], 0.0);
    EXPECT_DOUBLE_EQ(out.camera_matrix[3], 0.0);
    EXPECT_DOUBLE_EQ(out.camera_matrix[6], 0.0);
    EXPECT_DOUBLE_EQ(out.camera_matrix[7], 0.0);
    EXPECT_DOUBLE_EQ(out.camera_matrix[8], 1.0);

    // **歪みを推定していることを見る。** 合成に使った k1 は -0.20 である。
    // ここを見ないと「係数を 0 のまま返す」実装が通る。
    ASSERT_GE(out.dist_count, 5);
    EXPECT_NEAR(out.dist_coeffs[0], -0.20, 0.06);

    // 再投影誤差は合成データなので極小になる。
    EXPECT_GE(out.rms, 0.0);
    EXPECT_LT(out.rms, 1.0);
}

TEST(Calibration, CalibrateCameraWritesOneRotationAndOneTranslationPerView) {
    // **姿勢の並びを見る。** summary は「1 view につき 6 個で、回転 3 個の
    // あとに並進 3 個」と書いている。**これを誰も見ていなければ、
    // rvec と tvec を入れ替えても緑のままになる。**
    const std::vector<float> object_points = MakeObjectPoints();
    const std::vector<float> image_points = MakeImagePoints();

    CalibOutputs out;
    // 末尾に番兵を置き、書いてよい範囲の外が触られないことを見る。
    out.view_poses.push_back(12345.0);

    ASSERT_EQ(CallCalibrate(object_points, image_points, out), OCVU_STATUS_OK);

    EXPECT_DOUBLE_EQ(out.view_poses.back(), 12345.0);

    // 合成では view ごとに tz を 0.5 から 0.02 ずつ増やしてある。
    // **並進は添字 3..5 に在る**ので、その 3 番目（tz）が単調に増えるはずである。
    // 回転と入れ替えると、この関係は成り立たない。
    for (int32_t v = 0; v < kViewCount; ++v) {
        const size_t base = static_cast<size_t>(v) * kPoseStride;
        const double tz = out.view_poses[base + 5];
        EXPECT_NEAR(tz, 0.5 + 0.02 * static_cast<double>(v), 0.05)
            << "view " << v << " の並進 z が合成値から外れた";

        // 回転ベクトルの大きさは 1 rad 未満に収まる合成にしてある。
        const double rx = out.view_poses[base + 0];
        const double ry = out.view_poses[base + 1];
        const double rz = out.view_poses[base + 2];
        EXPECT_LT(std::sqrt(rx * rx + ry * ry + rz * rz), 1.0)
            << "view " << v << " の回転が大きすぎる（並進と入れ替わっていないか）";
    }
}

TEST(Calibration, CalibrateCameraRejectsBuffersThatAreTooSmallWithoutWriting) {
    const std::vector<float> object_points = MakeObjectPoints();
    const std::vector<float> image_points = MakeImagePoints();

    // 3 つの容量それぞれについて見る。**足りないと分かった時点で何も書かない。**
    struct Case {
        const char* what;
        int32_t camera_capacity;
        int32_t dist_capacity;
        int32_t pose_capacity;
    };
    const Case cases[] = {
        { "camera matrix", 8, 14, kViewCount * kPoseStride },
        // capacity 0 は使わない —— vector の data() が nullptr を返しうるので、
        // 容量ではなく NULL の検査に当たってしまう。3 は「最小でも 4 は要る」に掛かる。
        { "dist coeffs",   9,  3, kViewCount * kPoseStride },
        { "view poses",    9, 14, kViewCount * kPoseStride - 1 },
    };

    for (const Case& c : cases) {
        // **buffer を宣言した capacity ちょうどの大きさで確保する。**
        // 余分に取ると、実装が capacity を無視して書いても ASan が捕まえられない
        // —— 「何も書いていない」を値で見るだけでなく、**境界の外に書いたら
        // sanitizer が落とす**形にしておく。
        std::vector<double> camera(static_cast<size_t>(c.camera_capacity), 7.0);
        std::vector<double> dist(static_cast<size_t>(c.dist_capacity), 7.0);
        std::vector<double> poses(static_cast<size_t>(c.pose_capacity), 7.0);
        int32_t dist_count = 99;
        double rms = 99.0;

        const ocvu_status status = ocvu_calibrate_camera(
            object_points.data(), static_cast<int64_t>(object_points.size() * sizeof(float)),
            image_points.data(), static_cast<int64_t>(image_points.size() * sizeof(float)),
            kViewCount, kPointsPerView, kImageWidth, kImageHeight,
            camera.data(), c.camera_capacity,
            dist.data(), c.dist_capacity,
            &dist_count,
            poses.data(), c.pose_capacity,
            &rms);

        EXPECT_EQ(status, OCVU_STATUS_BUFFER_TOO_SMALL) << c.what;
        EXPECT_EQ(dist_count, 0) << c.what;

        // **1 バイトも書いていないこと。**
        for (double v : camera) { EXPECT_DOUBLE_EQ(v, 7.0) << c.what; }
        for (double v : dist) { EXPECT_DOUBLE_EQ(v, 7.0) << c.what; }
        for (double v : poses) { EXPECT_DOUBLE_EQ(v, 7.0) << c.what; }
    }
}

TEST(Calibration, CalibrateCameraRejectsInvalidArgumentsAndAlwaysWritesZero) {
    const std::vector<float> object_points = MakeObjectPoints();
    const std::vector<float> image_points = MakeImagePoints();
    const int64_t object_bytes = static_cast<int64_t>(object_points.size() * sizeof(float));
    const int64_t image_bytes = static_cast<int64_t>(image_points.size() * sizeof(float));

    std::vector<double> camera(9, 0.0);
    std::vector<double> dist(14, 0.0);
    std::vector<double> poses(static_cast<size_t>(kViewCount) * kPoseStride, 0.0);
    double rms = 0.0;

    auto call = [&](const float* obj, int64_t obj_len, const float* img, int64_t img_len,
                    int32_t views, int32_t per_view, int32_t w, int32_t h,
                    double* cam, double* dst, int32_t* count, double* pose_out,
                    double* rms_out) {
        return ocvu_calibrate_camera(obj, obj_len, img, img_len, views, per_view, w, h,
                                     cam, 9, dst, 14, count,
                                     pose_out, static_cast<int32_t>(poses.size()), rms_out);
    };

    // out_dist_coeffs_count が NULL —— **書き先が無いので 0 も書けない。**
    EXPECT_EQ(call(object_points.data(), object_bytes, image_points.data(), image_bytes,
                   kViewCount, kPointsPerView, kImageWidth, kImageHeight,
                   camera.data(), dist.data(), nullptr, poses.data(), &rms),
              OCVU_STATUS_NULL_POINTER);

    struct Case {
        const char* what;
        const float* object_points;
        int64_t object_length;
        const float* image_points;
        int64_t image_length;
        int32_t view_count;
        int32_t points_per_view;
        int32_t width;
        int32_t height;
        double* camera;
        double* dist;
        double* poses;
        double* rms;
        ocvu_status expected;
    };

    const Case cases[] = {
        { "object_points is NULL", nullptr, object_bytes, image_points.data(), image_bytes,
          kViewCount, kPointsPerView, kImageWidth, kImageHeight,
          camera.data(), dist.data(), poses.data(), &rms, OCVU_STATUS_NULL_POINTER },
        { "image_points is NULL", object_points.data(), object_bytes, nullptr, image_bytes,
          kViewCount, kPointsPerView, kImageWidth, kImageHeight,
          camera.data(), dist.data(), poses.data(), &rms, OCVU_STATUS_NULL_POINTER },
        { "out_camera_matrix is NULL", object_points.data(), object_bytes, image_points.data(), image_bytes,
          kViewCount, kPointsPerView, kImageWidth, kImageHeight,
          nullptr, dist.data(), poses.data(), &rms, OCVU_STATUS_NULL_POINTER },
        { "out_dist_coeffs is NULL", object_points.data(), object_bytes, image_points.data(), image_bytes,
          kViewCount, kPointsPerView, kImageWidth, kImageHeight,
          camera.data(), nullptr, poses.data(), &rms, OCVU_STATUS_NULL_POINTER },
        { "out_view_poses is NULL", object_points.data(), object_bytes, image_points.data(), image_bytes,
          kViewCount, kPointsPerView, kImageWidth, kImageHeight,
          camera.data(), dist.data(), nullptr, &rms, OCVU_STATUS_NULL_POINTER },
        { "out_rms is NULL", object_points.data(), object_bytes, image_points.data(), image_bytes,
          kViewCount, kPointsPerView, kImageWidth, kImageHeight,
          camera.data(), dist.data(), poses.data(), nullptr, OCVU_STATUS_NULL_POINTER },
        { "view_count is 1", object_points.data(), object_bytes, image_points.data(), image_bytes,
          1, kPointsPerView, kImageWidth, kImageHeight,
          camera.data(), dist.data(), poses.data(), &rms, OCVU_STATUS_INVALID_ARGUMENT },
        { "points_per_view is 3", object_points.data(), object_bytes, image_points.data(), image_bytes,
          kViewCount, 3, kImageWidth, kImageHeight,
          camera.data(), dist.data(), poses.data(), &rms, OCVU_STATUS_INVALID_ARGUMENT },
        { "image_width is 0", object_points.data(), object_bytes, image_points.data(), image_bytes,
          kViewCount, kPointsPerView, 0, kImageHeight,
          camera.data(), dist.data(), poses.data(), &rms, OCVU_STATUS_INVALID_ARGUMENT },
        { "image_height is 0", object_points.data(), object_bytes, image_points.data(), image_bytes,
          kViewCount, kPointsPerView, kImageWidth, 0,
          camera.data(), dist.data(), poses.data(), &rms, OCVU_STATUS_INVALID_ARGUMENT },
        { "object_points is one float short", object_points.data(), object_bytes - static_cast<int64_t>(sizeof(float)),
          image_points.data(), image_bytes, kViewCount, kPointsPerView, kImageWidth, kImageHeight,
          camera.data(), dist.data(), poses.data(), &rms, OCVU_STATUS_INVALID_ARGUMENT },
        { "image_points is one float short", object_points.data(), object_bytes,
          image_points.data(), image_bytes - static_cast<int64_t>(sizeof(float)),
          kViewCount, kPointsPerView, kImageWidth, kImageHeight,
          camera.data(), dist.data(), poses.data(), &rms, OCVU_STATUS_INVALID_ARGUMENT },
    };

    for (const Case& c : cases) {
        int32_t count = 99;
        EXPECT_EQ(call(c.object_points, c.object_length, c.image_points, c.image_length,
                       c.view_count, c.points_per_view, c.width, c.height,
                       c.camera, c.dist, &count, c.poses, c.rms),
                  c.expected)
            << c.what;
        // **どの失敗経路でも 0 を書く。** 前回の残りを読ませない。
        EXPECT_EQ(count, 0) << c.what;
    }
}

TEST(Calibration, CalibrateCameraRejectsAPointCountExceedingTheLimit) {
    // **符号付き整数の乗算オーバーフローは未定義動作である。**
    // view_count * points_per_view を int32_t で計算すると、この入力で
    // 折り返して負になり、容量の門を素通りする。int64_t で計算していれば
    // 上限に当たって INVALID_ARGUMENT で返る。
    std::vector<double> camera(9, 0.0);
    std::vector<double> dist(14, 0.0);
    std::vector<double> poses(64, 0.0);
    int32_t count = 99;
    double rms = 0.0;

    // 46341^2 は int32_t の範囲を超える。
    const int32_t huge = 46341;
    const float dummy = 0.0f;

    EXPECT_EQ(ocvu_calibrate_camera(&dummy, sizeof(float), &dummy, sizeof(float),
                                    huge, huge, kImageWidth, kImageHeight,
                                    camera.data(), 9, dist.data(), 14, &count,
                                    poses.data(), static_cast<int32_t>(poses.size()), &rms),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    // 上限そのものも見る。OCVU_CALIB_MAX_POINTS を超えたら断る。
    EXPECT_EQ(ocvu_calibrate_camera(&dummy, sizeof(float), &dummy, sizeof(float),
                                    2, OCVU_CALIB_MAX_POINTS, kImageWidth, kImageHeight,
                                    camera.data(), 9, dist.data(), 14, &count,
                                    poses.data(), static_cast<int32_t>(poses.size()), &rms),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);
}
