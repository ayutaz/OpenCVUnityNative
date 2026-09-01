// カメラの歪み補正の契約テスト。
//
// **calib module は使っていない。** undistort は imgproc、
// findChessboardCorners は objdetect に在り、どちらも既にリンク済みである
// （native/tests/test_module_linkage.cpp がその前提を固定している）。

#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <cstring>
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
    ScopedMat m(32, 32);
    std::vector<uint8_t> pixels(32 * 32, 7);
    ASSERT_EQ(ocvu_mat_copy_from_buffer(m.get(), pixels.data(),
                                        static_cast<int64_t>(pixels.size()), 32),
              OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_undistort(m.get(), kCamera.data(), kCameraBytes,
                             kCoeffs.data(), kCoeffsBytes, m.get()),
              OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(m.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 32);
    EXPECT_EQ(info.cols, 32);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_8UC1);
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
