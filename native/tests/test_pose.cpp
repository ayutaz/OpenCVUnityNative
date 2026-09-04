// geometry module の姿勢 4 本の契約テスト。
//
// **数値は手で解いてある。** カメラ行列 fx=fy=500, cx=320, cy=240 で、
// 回転なし・並進 (0, 0, 10) に置いた 1 辺 2 の正方形は、
//   x = 500 * (X / 10) + 320,  y = 500 * (Y / 10) + 240
// で写る。OpenCV に投影させて期待値を作ると、投影の実装が壊れたときに
// 期待値も一緒に壊れて検査が空振りする。
//
// **このファイルは OpenCV を直接呼ばない。** 期待値が手で解けているので、
// 合成データを作るために cv:: を持ち込む必要が無い
// （native/tests/test_calibration.cpp は逆に、期待値を独立に作るために
//  cv::projectPoints を使っている —— どちらも「実装と同じ経路で期待値を
//  作らない」という同じ理由から来ている）。

#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <array>
#include <cmath>
#include <cstdint>

namespace {

// fx = fy = 500, cx = 320, cy = 240 を行優先で並べたもの。
constexpr std::array<double, 9> kCamera{500.0, 0.0, 320.0,
                                        0.0, 500.0, 240.0,
                                        0.0, 0.0, 1.0};

// 1 辺 2 の正方形（z = 0 の平面上）。x, y, z の順に並べる。
constexpr std::array<float, 12> kSquareObject{
    -1.0f, -1.0f, 0.0f,
     1.0f, -1.0f, 0.0f,
     1.0f,  1.0f, 0.0f,
    -1.0f,  1.0f, 0.0f};

// 上の正方形を (0, 0, 10) に置いて写した像。x, y の順に並べる。
constexpr std::array<float, 8> kSquareImage{
    270.0f, 190.0f,
    370.0f, 190.0f,
    370.0f, 290.0f,
    270.0f, 290.0f};

// 上の正方形に中心 (0, 0, 0) を足した 5 点。**P3P はちょうど 4 点しか
// 受け付けない**ので、これを渡すと OpenCV 側が投げる
// （geometry/3d.hpp の solvePnP の doc: it is required to use exactly 4 points）。
constexpr std::array<float, 15> kFiveObject{
    -1.0f, -1.0f, 0.0f,
     1.0f, -1.0f, 0.0f,
     1.0f,  1.0f, 0.0f,
    -1.0f,  1.0f, 0.0f,
     0.0f,  0.0f, 0.0f};

constexpr std::array<float, 10> kFiveImage{
    270.0f, 190.0f,
    370.0f, 190.0f,
    370.0f, 290.0f,
    270.0f, 290.0f,
    320.0f, 240.0f};

constexpr int64_t kObjectBytes = static_cast<int64_t>(sizeof(kSquareObject));
constexpr int64_t kImageBytes = static_cast<int64_t>(sizeof(kSquareImage));
constexpr int64_t kCameraBytes = static_cast<int64_t>(sizeof(kCamera));
constexpr int64_t kFiveObjectBytes = static_cast<int64_t>(sizeof(kFiveObject));
constexpr int64_t kFiveImageBytes = static_cast<int64_t>(sizeof(kFiveImage));

constexpr int64_t kVec3Bytes = 3 * static_cast<int64_t>(sizeof(double));
constexpr int64_t kMatrix3x3Bytes = 9 * static_cast<int64_t>(sizeof(double));

}  // namespace

TEST(Pose, SolvePnpRecoversAKnownPose) {
    std::array<double, 3> rvec{};
    std::array<double, 3> tvec{};

    ASSERT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes,
                             kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes,
                             nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE,
                             rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_OK);

    // 回転なしで (0, 0, 10) に置いたので、そこへ戻ってくる。
    EXPECT_NEAR(rvec[0], 0.0, 1e-3);
    EXPECT_NEAR(rvec[1], 0.0, 1e-3);
    EXPECT_NEAR(rvec[2], 0.0, 1e-3);
    EXPECT_NEAR(tvec[0], 0.0, 1e-3);
    EXPECT_NEAR(tvec[1], 0.0, 1e-3);
    EXPECT_NEAR(tvec[2], 10.0, 1e-3);
}

TEST(Pose, SolvePnpRejectsNullPointers) {
    std::array<double, 3> rvec{};
    std::array<double, 3> tvec{};

    EXPECT_EQ(ocvu_solve_pnp(nullptr, kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, nullptr, kImageBytes, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             nullptr, kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, nullptr, 3, tvec.data(), 3),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, nullptr, 3),
              OCVU_STATUS_NULL_POINTER);

    // **dist_coeffs だけは NULL を許す。** 長さ 0 は「歪み無し」の正規の指定である。
    // その組み合わせが上の SolvePnpRecoversAKnownPose で通っていることが証拠になる。
    // 長さが 0 でないのに NULL なら拒否する。
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes,
                             nullptr, 5 * static_cast<int64_t>(sizeof(double)),
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_NULL_POINTER);
}

TEST(Pose, SolvePnpRejectsInvalidArguments) {
    std::array<double, 3> rvec{};
    std::array<double, 3> tvec{};

    // 点が 4 個未満では姿勢が決まらない。
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 3,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 上限を超える点数。
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes,
                             OCVU_PNP_MAX_POINTS + 1,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 知らない method を素通しにしない。
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             99, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             -1, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);

    // **長さはバイト数である。** 4 点ぶんに 1 バイト足りなければ何も読まずに断る。
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes - 1, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes - 1, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes - 1, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 歪み係数の個数は OpenCV が受ける 4 / 5 / 8 / 12 / 14 のいずれかでなければならない。
    const std::array<double, 3> bad_coeffs{0.0, 0.0, 0.0};
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes,
                             bad_coeffs.data(), static_cast<int64_t>(sizeof(bad_coeffs)),
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 長さが負でも同じである（割り算に落とす前に断る）。
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes, bad_coeffs.data(), -8,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);
}

TEST(Pose, SolvePnpRejectsTooSmallOutputsWithoutWriting) {
    // **0 ではない値で汚してから呼ぶ。** 0 で初期化していると
    // 「書いていない」と「0 を書いた」が区別できない（M3.5 で実測）。
    std::array<double, 3> rvec{-7.0, -7.0, -7.0};
    std::array<double, 3> tvec{-7.0, -7.0, -7.0};

    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 2, tvec.data(), 3),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes, kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 2),
              OCVU_STATUS_BUFFER_TOO_SMALL);

    for (int i = 0; i < 3; ++i) {
        EXPECT_DOUBLE_EQ(rvec[i], -7.0) << "断ったのに rvec を書いている";
        EXPECT_DOUBLE_EQ(tvec[i], -7.0) << "断ったのに tvec を書いている";
    }
}

TEST(Pose, SolvePnpReportsOpenCvFailuresAsOpenCvError) {
    // **P3P はちょうど 4 点しか受け付けない。** 5 点を渡すと OpenCV 側が投げる。
    // これを OCVU_TRY_END に任せると std::exception として UNKNOWN_ERROR に落ち、
    // 「OpenCV 由来の失敗」という情報が消える。**cv::Exception を手前で
    // 受けていることを固定するのがこのテストである。**
    std::array<double, 3> rvec{-7.0, -7.0, -7.0};
    std::array<double, 3> tvec{-7.0, -7.0, -7.0};

    const ocvu_status status =
        ocvu_solve_pnp(kFiveObject.data(), kFiveObjectBytes,
                       kFiveImage.data(), kFiveImageBytes, 5,
                       kCamera.data(), kCameraBytes, nullptr, 0,
                       OCVU_SOLVEPNP_P3P, rvec.data(), 3, tvec.data(), 3);
    EXPECT_EQ(status, OCVU_STATUS_OPENCV_ERROR)
        << "OpenCV 由来の失敗が OPENCV_ERROR として報告されていない";

    // 理由が last-error に入っていること（summary がそう約束している）。
    // **NUL だけの空メッセージなら required は 1 になる**ので、そこを見る。
    int32_t required = 0;
    EXPECT_EQ(ocvu_get_last_error_message(nullptr, 0, &required), OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_GT(required, 1) << "OPENCV_ERROR なのに理由が入っていない";

    for (int i = 0; i < 3; ++i) {
        EXPECT_DOUBLE_EQ(rvec[i], -7.0) << "失敗したのに rvec を書いている";
        EXPECT_DOUBLE_EQ(tvec[i], -7.0) << "失敗したのに tvec を書いている";
    }
}

TEST(Pose, SolvePnpRejectsACameraWithNoFocalLength) {
    // **OpenCV はこれを検出しない。** 実測（2026-09-05）: 全要素 0 の
    // カメラ行列を cv::solvePnP に渡すと、例外も投げず false も返さず、
    // **有限の 0 を答えとして返す** —— つまり「もっともらしいが無意味な姿勢」が
    // OCVU_STATUS_OK で戻り、呼ぶ側は status では気づけない。
    //
    // **だからこの ABI が自分で断る。** fx / fy が 0 なら投影が成立しないので、
    // 呼ぶ側が直せる誤りとして INVALID_ARGUMENT を返す。
    //
    // **一般的な特異性の検査ではない** —— 見ているのは [0] と [4] だけである。
    constexpr std::array<double, 9> no_focal{0.0, 0.0, 320.0,
                                             0.0, 0.0, 240.0,
                                             0.0, 0.0, 1.0};
    std::array<double, 3> rvec{-7.0, -7.0, -7.0};
    std::array<double, 3> tvec{-7.0, -7.0, -7.0};

    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes,
                             kSquareImage.data(), kImageBytes, 4,
                             no_focal.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);

    // fy だけが 0 でも同じ。
    constexpr std::array<double, 9> no_fy{500.0, 0.0, 320.0,
                                          0.0, 0.0, 240.0,
                                          0.0, 0.0, 1.0};
    EXPECT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes,
                             kSquareImage.data(), kImageBytes, 4,
                             no_fy.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE, rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);

    // ocvu_project_points も同じ検査を持つ。
    const std::array<double, 3> zero_rvec{0.0, 0.0, 0.0};
    const std::array<double, 3> ten_tvec{0.0, 0.0, 10.0};
    std::array<float, 8> projected{};
    EXPECT_EQ(ocvu_project_points(kSquareObject.data(), kObjectBytes, 4,
                                  zero_rvec.data(), kVec3Bytes,
                                  ten_tvec.data(), kVec3Bytes,
                                  no_focal.data(), kCameraBytes, nullptr, 0,
                                  projected.data(), 8),
              OCVU_STATUS_INVALID_ARGUMENT);

    for (int i = 0; i < 3; ++i) {
        EXPECT_DOUBLE_EQ(rvec[i], -7.0) << "断ったのに rvec を書いている";
        EXPECT_DOUBLE_EQ(tvec[i], -7.0) << "断ったのに tvec を書いている";
    }
}

TEST(Pose, RodriguesToMatrixTurnsAQuarterTurnAboutZ) {
    // z 軸まわりに 90 度。回転行列は手で書ける。
    const double half_pi = std::acos(-1.0) / 2.0;
    const std::array<double, 3> rvec{0.0, 0.0, half_pi};
    std::array<double, 9> matrix{};

    ASSERT_EQ(ocvu_rodrigues_to_matrix(rvec.data(), kVec3Bytes, matrix.data(), 9),
              OCVU_STATUS_OK);

    const std::array<double, 9> expected{0.0, -1.0, 0.0,
                                         1.0, 0.0, 0.0,
                                         0.0, 0.0, 1.0};
    for (int i = 0; i < 9; ++i) {
        EXPECT_NEAR(matrix[i], expected[i], 1e-9) << "要素 " << i;
    }
}

TEST(Pose, RodriguesRoundTrips) {
    const std::array<double, 3> rvec{0.1, -0.2, 0.3};
    std::array<double, 9> matrix{};
    std::array<double, 3> back{};

    ASSERT_EQ(ocvu_rodrigues_to_matrix(rvec.data(), kVec3Bytes, matrix.data(), 9),
              OCVU_STATUS_OK);
    ASSERT_EQ(ocvu_rodrigues_to_vector(matrix.data(), kMatrix3x3Bytes, back.data(), 3),
              OCVU_STATUS_OK);

    for (int i = 0; i < 3; ++i) {
        EXPECT_NEAR(back[i], rvec[i], 1e-9) << "要素 " << i;
    }
}

TEST(Pose, RodriguesRejectsBadArguments) {
    const std::array<double, 3> rvec{0.0, 0.0, 0.0};
    const std::array<double, 9> matrix{1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0};
    std::array<double, 9> out9{-7.0, -7.0, -7.0, -7.0, -7.0, -7.0, -7.0, -7.0, -7.0};
    std::array<double, 3> out3{-7.0, -7.0, -7.0};

    EXPECT_EQ(ocvu_rodrigues_to_matrix(nullptr, kVec3Bytes, out9.data(), 9),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_rodrigues_to_matrix(rvec.data(), kVec3Bytes, nullptr, 9),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_rodrigues_to_vector(nullptr, kMatrix3x3Bytes, out3.data(), 3),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_rodrigues_to_vector(matrix.data(), kMatrix3x3Bytes, nullptr, 3),
              OCVU_STATUS_NULL_POINTER);

    // **長さはバイト数である。** 1 バイト足りなければ何も読まない。
    EXPECT_EQ(ocvu_rodrigues_to_matrix(rvec.data(), kVec3Bytes - 1, out9.data(), 9),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_rodrigues_to_vector(matrix.data(), kMatrix3x3Bytes - 1, out3.data(), 3),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 容量が足りなければ何も書かない。
    EXPECT_EQ(ocvu_rodrigues_to_matrix(rvec.data(), kVec3Bytes, out9.data(), 8),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(ocvu_rodrigues_to_vector(matrix.data(), kMatrix3x3Bytes, out3.data(), 2),
              OCVU_STATUS_BUFFER_TOO_SMALL);

    for (int i = 0; i < 9; ++i) {
        EXPECT_DOUBLE_EQ(out9[i], -7.0) << "断ったのに書いている";
    }
    for (int i = 0; i < 3; ++i) {
        EXPECT_DOUBLE_EQ(out3[i], -7.0) << "断ったのに書いている";
    }
}

TEST(Pose, ProjectPointsMatchesTheHandComputedProjection) {
    // kSquareObject を (0, 0, 10) に回転なしで置くと kSquareImage に写る。
    // **その期待値は手で解いてある**（このファイルの冒頭のコメント）。
    const std::array<double, 3> rvec{0.0, 0.0, 0.0};
    const std::array<double, 3> tvec{0.0, 0.0, 10.0};
    std::array<float, 8> projected{};

    ASSERT_EQ(ocvu_project_points(kSquareObject.data(), kObjectBytes, 4,
                                  rvec.data(), kVec3Bytes,
                                  tvec.data(), kVec3Bytes,
                                  kCamera.data(), kCameraBytes,
                                  nullptr, 0,
                                  projected.data(), 8),
              OCVU_STATUS_OK);

    for (int i = 0; i < 8; ++i) {
        EXPECT_NEAR(projected[i], kSquareImage[i], 1e-3) << "要素 " << i;
    }
}

TEST(Pose, ProjectPointsIsTheInverseOfSolvePnp) {
    // **2 本が互いの逆になっていることを見る。** 片方が壊れても、
    // もう片方の「手で解いた期待値」を使うテストが残る。
    std::array<double, 3> rvec{};
    std::array<double, 3> tvec{};
    ASSERT_EQ(ocvu_solve_pnp(kSquareObject.data(), kObjectBytes,
                             kSquareImage.data(), kImageBytes, 4,
                             kCamera.data(), kCameraBytes, nullptr, 0,
                             OCVU_SOLVEPNP_ITERATIVE,
                             rvec.data(), 3, tvec.data(), 3),
              OCVU_STATUS_OK);

    std::array<float, 8> projected{};
    ASSERT_EQ(ocvu_project_points(kSquareObject.data(), kObjectBytes, 4,
                                  rvec.data(), kVec3Bytes,
                                  tvec.data(), kVec3Bytes,
                                  kCamera.data(), kCameraBytes,
                                  nullptr, 0,
                                  projected.data(), 8),
              OCVU_STATUS_OK);

    for (int i = 0; i < 8; ++i) {
        EXPECT_NEAR(projected[i], kSquareImage[i], 1e-2) << "要素 " << i;
    }
}

TEST(Pose, ProjectPointsRejectsBadArguments) {
    const std::array<double, 3> rvec{0.0, 0.0, 0.0};
    const std::array<double, 3> tvec{0.0, 0.0, 10.0};
    std::array<float, 8> projected{-7.0f, -7.0f, -7.0f, -7.0f, -7.0f, -7.0f, -7.0f, -7.0f};

    EXPECT_EQ(ocvu_project_points(nullptr, kObjectBytes, 4,
                                  rvec.data(), kVec3Bytes, tvec.data(), kVec3Bytes,
                                  kCamera.data(), kCameraBytes, nullptr, 0, projected.data(), 8),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_project_points(kSquareObject.data(), kObjectBytes, 4,
                                  nullptr, kVec3Bytes, tvec.data(), kVec3Bytes,
                                  kCamera.data(), kCameraBytes, nullptr, 0, projected.data(), 8),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_project_points(kSquareObject.data(), kObjectBytes, 4,
                                  rvec.data(), kVec3Bytes, nullptr, kVec3Bytes,
                                  kCamera.data(), kCameraBytes, nullptr, 0, projected.data(), 8),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_project_points(kSquareObject.data(), kObjectBytes, 4,
                                  rvec.data(), kVec3Bytes, tvec.data(), kVec3Bytes,
                                  nullptr, kCameraBytes, nullptr, 0, projected.data(), 8),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_project_points(kSquareObject.data(), kObjectBytes, 4,
                                  rvec.data(), kVec3Bytes, tvec.data(), kVec3Bytes,
                                  kCamera.data(), kCameraBytes, nullptr, 0, nullptr, 8),
              OCVU_STATUS_NULL_POINTER);

    // point_count は 1 以上でよい（姿勢は与えられているので 4 点は要らない）。
    EXPECT_EQ(ocvu_project_points(kSquareObject.data(), kObjectBytes, 0,
                                  rvec.data(), kVec3Bytes, tvec.data(), kVec3Bytes,
                                  kCamera.data(), kCameraBytes, nullptr, 0, projected.data(), 8),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_project_points(kSquareObject.data(), kObjectBytes, OCVU_PNP_MAX_POINTS + 1,
                                  rvec.data(), kVec3Bytes, tvec.data(), kVec3Bytes,
                                  kCamera.data(), kCameraBytes, nullptr, 0, projected.data(), 8),
              OCVU_STATUS_INVALID_ARGUMENT);

    // **長さはバイト数である。**
    EXPECT_EQ(ocvu_project_points(kSquareObject.data(), kObjectBytes - 1, 4,
                                  rvec.data(), kVec3Bytes, tvec.data(), kVec3Bytes,
                                  kCamera.data(), kCameraBytes, nullptr, 0, projected.data(), 8),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_project_points(kSquareObject.data(), kObjectBytes, 4,
                                  rvec.data(), kVec3Bytes - 1, tvec.data(), kVec3Bytes,
                                  kCamera.data(), kCameraBytes, nullptr, 0, projected.data(), 8),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_project_points(kSquareObject.data(), kObjectBytes, 4,
                                  rvec.data(), kVec3Bytes, tvec.data(), kVec3Bytes - 1,
                                  kCamera.data(), kCameraBytes, nullptr, 0, projected.data(), 8),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_project_points(kSquareObject.data(), kObjectBytes, 4,
                                  rvec.data(), kVec3Bytes, tvec.data(), kVec3Bytes,
                                  kCamera.data(), kCameraBytes - 1, nullptr, 0, projected.data(), 8),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 容量が足りなければ何も書かない。4 点なら 8 要素が要る。
    EXPECT_EQ(ocvu_project_points(kSquareObject.data(), kObjectBytes, 4,
                                  rvec.data(), kVec3Bytes, tvec.data(), kVec3Bytes,
                                  kCamera.data(), kCameraBytes, nullptr, 0, projected.data(), 7),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    for (int i = 0; i < 8; ++i) {
        EXPECT_FLOAT_EQ(projected[i], -7.0f) << "断ったのに書いている";
    }
}
