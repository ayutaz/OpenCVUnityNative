// ocvu_find_homography の契約テスト。
//
// **この関数は「点の対応から、2 枚の画像のずれ方を求める」ものである。**
// ORB で見つけた特徴点の対応を渡すと 3x3 の射影変換が返り、それを
// imgproc の warpPerspective に渡せば位置合わせができる（変換を当てる側は
// 既にリンク済みの module にある）。

#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <cmath>
#include <cstring>
#include <vector>

namespace {

// 変換行列を受け取る Mat を 1 つ作り、抜けるときに必ず解放する。
class ScopedMat {
public:
    ScopedMat() {
        EXPECT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &handle_), OCVU_STATUS_OK);
    }
    ~ScopedMat() { ocvu_mat_release(handle_); }
    ScopedMat(const ScopedMat&) = delete;
    ScopedMat& operator=(const ScopedMat&) = delete;

    ocvu_mat_handle get() const { return handle_; }

private:
    ocvu_mat_handle handle_ = OCVU_MAT_HANDLE_NONE;
};

// 正方形と、それを 2 倍に拡大した正方形。x と y が交互に並ぶ。
const std::vector<float> kSquare{0.0f, 0.0f, 10.0f, 0.0f, 10.0f, 10.0f, 0.0f, 10.0f};
const std::vector<float> kDoubled{0.0f, 0.0f, 20.0f, 0.0f, 20.0f, 20.0f, 0.0f, 20.0f};

// 行優先の 3x3 double を読む。
double At(const std::vector<double>& m, int row, int col) {
    return m[static_cast<size_t>(row) * 3 + static_cast<size_t>(col)];
}

}  // namespace

TEST(Geometry, FindHomographyRecoversAScale) {
    ScopedMat dst;
    ASSERT_EQ(ocvu_find_homography(kSquare.data(), 8, kDoubled.data(), 8, 4,
                                   OCVU_HOMOGRAPHY_METHOD_DEFAULT, 3.0, dst.get()),
              OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 3);
    EXPECT_EQ(info.cols, 3);
    EXPECT_EQ(info.channels, 1);

    // 2 倍の拡大なので、行列は diag(2, 2, 1) を定数倍したものになる。
    // 右下で割って正規化してから確かめる。
    std::vector<double> m(9, 0.0);
    ASSERT_EQ(ocvu_mat_copy_to_buffer(dst.get(), reinterpret_cast<uint8_t*>(m.data()),
                                      static_cast<int64_t>(m.size() * sizeof(double)),
                                      static_cast<int64_t>(3 * sizeof(double))),
              OCVU_STATUS_OK);

    const double w = At(m, 2, 2);
    ASSERT_NE(w, 0.0);
    EXPECT_NEAR(At(m, 0, 0) / w, 2.0, 1e-6);
    EXPECT_NEAR(At(m, 1, 1) / w, 2.0, 1e-6);
    EXPECT_NEAR(At(m, 0, 1) / w, 0.0, 1e-6);
    EXPECT_NEAR(At(m, 1, 0) / w, 0.0, 1e-6);
}

TEST(Geometry, FindHomographyRejectsInvalidArguments) {
    ScopedMat dst;

    EXPECT_EQ(ocvu_find_homography(nullptr, 8, kDoubled.data(), 8, 4,
                                   OCVU_HOMOGRAPHY_METHOD_DEFAULT, 3.0, dst.get()),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_find_homography(kSquare.data(), 8, nullptr, 8, 4,
                                   OCVU_HOMOGRAPHY_METHOD_DEFAULT, 3.0, dst.get()),
              OCVU_STATUS_NULL_POINTER);

    // **4 点未満では射影変換が決まらない。** 3 点で呼べてしまうと、
    // OpenCV の中で落ちるか、意味の無い行列が返る。
    EXPECT_EQ(ocvu_find_homography(kSquare.data(), 8, kDoubled.data(), 8, 3,
                                   OCVU_HOMOGRAPHY_METHOD_DEFAULT, 3.0, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_find_homography(kSquare.data(), 8, kDoubled.data(), 8, 0,
                                   OCVU_HOMOGRAPHY_METHOD_DEFAULT, 3.0, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_find_homography(kSquare.data(), 8, kDoubled.data(), 8, -1,
                                   OCVU_HOMOGRAPHY_METHOD_DEFAULT, 3.0, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 知らない method は素通しにしない —— OpenCV に落として
    // 「原因不明」にするより、境界で断るほうが呼ぶ側に分かる。
    EXPECT_EQ(ocvu_find_homography(kSquare.data(), 8, kDoubled.data(), 8, 4, 12345, 3.0, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);

    EXPECT_EQ(ocvu_find_homography(kSquare.data(), 8, kDoubled.data(), 8, 4,
                                   OCVU_HOMOGRAPHY_METHOD_DEFAULT, 3.0, OCVU_MAT_HANDLE_NONE),
              OCVU_STATUS_INVALID_HANDLE);
}

TEST(Geometry, FindHomographyLeavesTheDestinationUntouchedWhenItFails) {
    ScopedMat dst;

    // 先に成功させて、既知の形にしておく。
    ASSERT_EQ(ocvu_find_homography(kSquare.data(), 8, kDoubled.data(), 8, 4,
                                   OCVU_HOMOGRAPHY_METHOD_DEFAULT, 3.0, dst.get()),
              OCVU_STATUS_OK);
    ocvu_mat_info before{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &before), OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_find_homography(nullptr, 8, kDoubled.data(), 8, 4,
                                   OCVU_HOMOGRAPHY_METHOD_DEFAULT, 3.0, dst.get()),
              OCVU_STATUS_NULL_POINTER);

    ocvu_mat_info after{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &after), OCVU_STATUS_OK);
    EXPECT_EQ(before.rows, after.rows);
    EXPECT_EQ(before.cols, after.cols);
    EXPECT_EQ(before.type, after.type);
}

TEST(Geometry, FindHomographyReportsNotFoundWhenThePointsAreDegenerate) {
    // 全部同じ点。射影変換は決まらないので、OpenCV は空の行列を返す。
    // **これは誤りではない** —— 入力が悪いのではなく、解が無いだけである。
    const std::vector<float> same{5.0f, 5.0f, 5.0f, 5.0f, 5.0f, 5.0f, 5.0f, 5.0f};

    ScopedMat dst;
    EXPECT_EQ(ocvu_find_homography(same.data(), 8, same.data(), 8, 4,
                                   OCVU_HOMOGRAPHY_METHOD_DEFAULT, 3.0, dst.get()),
              OCVU_STATUS_NOT_FOUND);
}

TEST(Geometry, FindHomographyAcceptsRansacWithOutliers) {
    // 4 点は 2 倍の拡大に従い、5 点目だけ大きく外れている。
    // RANSAC は外れ値を捨てるので、正しい変換が返るはずである。
    const std::vector<float> src{0.0f, 0.0f, 10.0f, 0.0f, 10.0f, 10.0f,
                                 0.0f, 10.0f, 5.0f, 5.0f};
    const std::vector<float> dst_pts{0.0f, 0.0f, 20.0f, 0.0f, 20.0f, 20.0f,
                                     0.0f, 20.0f, 900.0f, 900.0f};

    ScopedMat dst;
    ASSERT_EQ(ocvu_find_homography(src.data(), 10, dst_pts.data(), 10, 5,
                                   OCVU_HOMOGRAPHY_METHOD_RANSAC, 3.0, dst.get()),
              OCVU_STATUS_OK);

    std::vector<double> m(9, 0.0);
    ASSERT_EQ(ocvu_mat_copy_to_buffer(dst.get(), reinterpret_cast<uint8_t*>(m.data()),
                                      static_cast<int64_t>(m.size() * sizeof(double)),
                                      static_cast<int64_t>(3 * sizeof(double))),
              OCVU_STATUS_OK);

    const double w = At(m, 2, 2);
    ASSERT_NE(w, 0.0);
    EXPECT_NEAR(At(m, 0, 0) / w, 2.0, 1e-3) << "RANSAC は外れ値を捨てるはず";
    EXPECT_NEAR(At(m, 1, 1) / w, 2.0, 1e-3);
}

TEST(Geometry, FindHomographyRejectsALengthThatCannotHoldThePoints) {
    // **呼ぶ側を信用しない。** point_count だけを受け取ると、
    // 配列の終端を越えて読んでも native からは分からない。
    // 長さを明示的に受け取り、point_count * 2 に足りなければ断る
    // （ocvu_imdecode / ocvu_mat_copy_from_buffer と同じ契約）。
    ScopedMat dst;

    // 4 点には float が 8 個要る。7 個しか無いと言われたら断る。
    EXPECT_EQ(ocvu_find_homography(kSquare.data(), 7, kDoubled.data(), 8, 4,
                                   OCVU_HOMOGRAPHY_METHOD_DEFAULT, 3.0, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_find_homography(kSquare.data(), 8, kDoubled.data(), 7, 4,
                                   OCVU_HOMOGRAPHY_METHOD_DEFAULT, 3.0, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 負の長さも断る。
    EXPECT_EQ(ocvu_find_homography(kSquare.data(), -1, kDoubled.data(), 8, 4,
                                   OCVU_HOMOGRAPHY_METHOD_DEFAULT, 3.0, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);

    // **桁あふれを計算で作らない。** point_count * 2 は int64_t の掛け算だが、
    // point_count が INT32_MAX なら 2 倍しても int64_t には収まる —— それでも
    // 長さがそこに届かないので断る。**上限を別に設けなくても、
    // 長さの検証だけで塞がる。**
    EXPECT_EQ(ocvu_find_homography(kSquare.data(), 8, kDoubled.data(), 8, INT32_MAX,
                                   OCVU_HOMOGRAPHY_METHOD_DEFAULT, 3.0, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 長さが余分にあるのは問題ない（先頭 point_count 分だけ読む）。
    EXPECT_EQ(ocvu_find_homography(kSquare.data(), 8, kDoubled.data(), 8, 4,
                                   OCVU_HOMOGRAPHY_METHOD_DEFAULT, 3.0, dst.get()),
              OCVU_STATUS_OK);
}
