// features module のうち「記述子」に関わる 2 本の契約テスト
// （ocvu_detect_and_compute / ocvu_match_descriptors）。
//
// **入力は自分で描いた模様にする。** 外部の画像に依存しないので、
// 同じ入力なら同じ特徴点が出る。
//
// **期待値は手で決められるものだけを見る。** 特徴点の個数そのものは
// OpenCV の版と実装に左右されるので固定しない —— 見るのは
// 「1 つ以上出ること」「記述子の行数が特徴点の数と一致すること」
// 「同じ記述子どうしを突き合わせると距離 0 の対応が並ぶこと」である。

#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace {

// 画像の一辺。**200 以上でなければならない。**
//
// ORB は edgeThreshold=31 のため、小さい画像では特徴点が 1 つも出ない
// （2026-09-05 の実測: 32 -> 0 / 64 -> 0 / 96 -> 0 / 128 -> 8 / 160 -> 104 /
// 200 -> 212 / 256 -> 280）。**64 で書くと「特徴点が 0 個」で落ちる。**
constexpr int32_t kSide = 224;

// **max_features は OpenCV への希望であって上限ではない。**
//
// 実測（2026-09-05）: cv::ORB::create(5) は 200x200 で 24 個、create(10) は
// 36 個を返す。cv::SIFT::create(200) は 160x160 で 240 個を返す。
// **だから capacity を max_features と同じにしてはいけない** ——
// そうすると「溢れないはず」を仮定したテストが検出器の都合で赤くなる。
constexpr int32_t kMaxFeatures = 200;
constexpr int32_t kCapacity = 1000;

// 抜けるときに必ず解放する。
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

// 8 画素ごとの市松模様を描いたグレー画像を作る。
ocvu_mat_handle MakeTexturedImage() {
    ocvu_mat_handle handle = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(kSide, kSide, OCVU_MAT_TYPE_8UC1, &handle), OCVU_STATUS_OK);

    // **ocvu_mat_create は画素を初期化しない。** 全画素を明示的に書く。
    std::vector<uint8_t> pixels(static_cast<size_t>(kSide) * static_cast<size_t>(kSide), 0);
    for (int32_t r = 0; r < kSide; ++r) {
        for (int32_t c = 0; c < kSide; ++c) {
            const bool light = ((r / 8) + (c / 8)) % 2 == 0;
            pixels[static_cast<size_t>(r) * static_cast<size_t>(kSide) +
                   static_cast<size_t>(c)] = light ? 220 : 40;
        }
    }

    // **stride はバイト数である**（8UC1 なので 1 行が kSide バイト）。
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(),
                                        static_cast<int64_t>(pixels.size()),
                                        static_cast<int64_t>(kSide)),
              OCVU_STATUS_OK);
    return handle;
}

// 1 枚から記述子の Mat を作る。個数は out_count に返る。
ocvu_mat_handle ComputeDescriptors(ocvu_mat_handle src, int32_t detector, int32_t* out_count) {
    ocvu_mat_handle descriptors = OCVU_MAT_HANDLE_NONE;
    EXPECT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &descriptors), OCVU_STATUS_OK);

    std::vector<ocvu_keypoint> keypoints(static_cast<size_t>(kCapacity));
    EXPECT_EQ(ocvu_detect_and_compute(src, detector, kMaxFeatures, keypoints.data(),
                                      kCapacity, descriptors, out_count),
              OCVU_STATUS_OK);
    return descriptors;
}

// 1x1 の 8UC1 に決まった 1 バイトを入れる。**溢れたときに書き換わっていない
// ことを見るための目印である** —— 0 で埋めると「書いていない」と
// 「0 を書いた」が区別できない。
constexpr uint8_t kDescriptorSentinel = 0x5A;

void MarkDescriptorMat(ocvu_mat_handle handle) {
    const uint8_t byte = kDescriptorSentinel;
    EXPECT_EQ(ocvu_mat_copy_from_buffer(handle, &byte, 1, 1), OCVU_STATUS_OK);
}

void ExpectDescriptorMatUntouched(ocvu_mat_handle handle) {
    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(handle, &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 1) << "断ったのに out_descriptors を置き換えている";
    EXPECT_EQ(info.cols, 1) << "断ったのに out_descriptors を置き換えている";
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_8UC1);

    uint8_t byte = 0;
    ASSERT_EQ(ocvu_mat_copy_to_buffer(handle, &byte, 1, 1), OCVU_STATUS_OK);
    EXPECT_EQ(byte, kDescriptorSentinel) << "断ったのに out_descriptors の中身を書いている";
}

}  // namespace

// ---------------------------------------------------------------------------
// ocvu_detect_and_compute
// ---------------------------------------------------------------------------

TEST(Matching, DetectAndComputeProducesOrbKeypointsAndDescriptors) {
    const ScopedMat src(MakeTexturedImage());
    const ScopedMat descriptors;

    std::vector<ocvu_keypoint> keypoints(static_cast<size_t>(kCapacity));
    int32_t count = -1;

    ASSERT_EQ(ocvu_detect_and_compute(src.get(), OCVU_FEATURE_ORB, kMaxFeatures,
                                      keypoints.data(), kCapacity, descriptors.get(), &count),
              OCVU_STATUS_OK);
    ASSERT_GT(count, 0) << "市松模様なのに特徴点が 1 つも出ない";

    // **記述子の行数は特徴点の数と一致する。** ORB の記述子は 32 バイトである。
    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(descriptors.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, count);
    EXPECT_EQ(info.cols, 32);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_8UC1);

    // 市松の角に乗るので、座標は画像の中に収まっている。
    for (int32_t i = 0; i < count; ++i) {
        const ocvu_keypoint& kp = keypoints[static_cast<size_t>(i)];
        EXPECT_GE(kp.x, 0.0f);
        EXPECT_GE(kp.y, 0.0f);
        EXPECT_LE(kp.x, static_cast<float>(kSide));
        EXPECT_LE(kp.y, static_cast<float>(kSide));
    }
}

TEST(Matching, DetectAndComputeProducesSiftKeypointsAndDescriptors) {
    const ScopedMat src(MakeTexturedImage());
    const ScopedMat descriptors;

    std::vector<ocvu_keypoint> keypoints(static_cast<size_t>(kCapacity));
    int32_t count = -1;

    ASSERT_EQ(ocvu_detect_and_compute(src.get(), OCVU_FEATURE_SIFT, kMaxFeatures,
                                      keypoints.data(), kCapacity, descriptors.get(), &count),
              OCVU_STATUS_OK);
    ASSERT_GT(count, 0);

    // SIFT の記述子は 128 次元の 32 bit 浮動小数である。**ORB とは型も幅も違う。**
    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(descriptors.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, count);
    EXPECT_EQ(info.cols, 128);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_32FC1);
}

TEST(Matching, DetectAndComputeReportsTheCountWhenTheBufferIsTooSmall) {
    const ScopedMat src(MakeTexturedImage());
    const ScopedMat descriptors;
    MarkDescriptorMat(descriptors.get());

    // **buffer 全体を 0 でない値で埋め、1 バイトも変わっていないことを見る。**
    std::vector<ocvu_keypoint> keypoints(static_cast<size_t>(kCapacity));
    const size_t bytes = keypoints.size() * sizeof(ocvu_keypoint);
    std::memset(keypoints.data(), 0xAB, bytes);
    std::vector<uint8_t> before(bytes);
    std::memcpy(before.data(), keypoints.data(), bytes);

    int32_t count = -1;
    EXPECT_EQ(ocvu_detect_and_compute(src.get(), OCVU_FEATURE_ORB, kMaxFeatures,
                                      keypoints.data(), 0, descriptors.get(), &count),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_GT(count, 0) << "溢れたときは実際に見つかった数を返すこと";
    EXPECT_EQ(std::memcmp(keypoints.data(), before.data(), bytes), 0)
        << "断ったのに out_keypoints を書いている";

    // **溢れた経路では out_descriptors も置き換えない**（この 2 つが
    // 食い違うと、呼ぶ側は「個数は 240 なのに記述子は 1 行」という
    // もっともらしい嘘を掴む）。
    ExpectDescriptorMatUntouched(descriptors.get());
}

TEST(Matching, DetectAndComputeAnswersACountQuery) {
    const ScopedMat src(MakeTexturedImage());
    const ScopedMat descriptors;
    MarkDescriptorMat(descriptors.get());

    // **max_features は上限ではない**ので、呼ぶ側は必要量を事前に知り得ない。
    // buffer を渡さずに個数だけを問い合わせられること。
    int32_t count = -1;
    EXPECT_EQ(ocvu_detect_and_compute(src.get(), OCVU_FEATURE_ORB, kMaxFeatures,
                                      nullptr, 0, descriptors.get(), &count),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_GT(count, 0);
    ExpectDescriptorMatUntouched(descriptors.get());
}

TEST(Matching, DetectAndComputeRejectsBadArgumentsAndZeroesTheCount) {
    const ScopedMat src(MakeTexturedImage());
    const ScopedMat descriptors;
    std::vector<ocvu_keypoint> keypoints(static_cast<size_t>(kCapacity));

    // **out_count が NULL なら他の何より先に断る。**
    EXPECT_EQ(ocvu_detect_and_compute(src.get(), OCVU_FEATURE_ORB, kMaxFeatures,
                                      keypoints.data(), kCapacity, descriptors.get(), nullptr),
              OCVU_STATUS_NULL_POINTER);

    // **0 ではない値で汚してから呼ぶ。** 0 で初期化すると
    // 「書いていない」と「0 を書いた」が区別できない。
    int32_t count = 12345;
    EXPECT_EQ(ocvu_detect_and_compute(src.get(), 99, kMaxFeatures, keypoints.data(),
                                      kCapacity, descriptors.get(), &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0) << "失敗時は out_count に 0 を書くこと";

    count = 12345;
    EXPECT_EQ(ocvu_detect_and_compute(src.get(), OCVU_FEATURE_ORB, 0, keypoints.data(),
                                      kCapacity, descriptors.get(), &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_detect_and_compute(src.get(), OCVU_FEATURE_ORB,
                                      OCVU_ORB_MAX_FEATURES + 1, keypoints.data(),
                                      kCapacity, descriptors.get(), &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_detect_and_compute(src.get(), OCVU_FEATURE_ORB, kMaxFeatures,
                                      keypoints.data(), -1, descriptors.get(), &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    // capacity が正なのに buffer が無いのは誤りである（capacity が 0 の
    // ときだけ NULL を通す —— そちらは個数の問い合わせである）。
    count = 12345;
    EXPECT_EQ(ocvu_detect_and_compute(src.get(), OCVU_FEATURE_ORB, kMaxFeatures,
                                      nullptr, kCapacity, descriptors.get(), &count),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_detect_and_compute(OCVU_MAT_HANDLE_NONE, OCVU_FEATURE_ORB, kMaxFeatures,
                                      keypoints.data(), kCapacity, descriptors.get(), &count),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_detect_and_compute(src.get(), OCVU_FEATURE_ORB, kMaxFeatures,
                                      keypoints.data(), kCapacity, OCVU_MAT_HANDLE_NONE, &count),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(count, 0);

    // **src と out_descriptors が同じ handle なのは誤りである** ——
    // 入力を読みながら同じ Mat を置き換えることになる。
    count = 12345;
    EXPECT_EQ(ocvu_detect_and_compute(src.get(), OCVU_FEATURE_ORB, kMaxFeatures,
                                      keypoints.data(), kCapacity, src.get(), &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);
}

// ---------------------------------------------------------------------------
// ocvu_dmatch / ocvu_match_descriptors
// ---------------------------------------------------------------------------

TEST(Matching, TheDmatchStructHasTheExpectedLayout) {
    // **native 側の正本を固定する。** C# 側は L3 が Marshal.SizeOf と
    // Marshal.OffsetOf の**両方**で突き合わせる —— 合計だけを見る検査は、
    // 同じ型のフィールドの入れ替えを通す（M5 で ocvu_keypoint について実測）。
    EXPECT_EQ(sizeof(ocvu_dmatch), 16u);
    EXPECT_EQ(offsetof(ocvu_dmatch, query_index), 0u);
    EXPECT_EQ(offsetof(ocvu_dmatch, train_index), 4u);
    EXPECT_EQ(offsetof(ocvu_dmatch, image_index), 8u);
    EXPECT_EQ(offsetof(ocvu_dmatch, distance), 12u);
}

TEST(Matching, MatchDescriptorsFindsSelfCorrespondencesWithCrossCheck) {
    const ScopedMat image(MakeTexturedImage());
    int32_t count = 0;
    const ScopedMat a(ComputeDescriptors(image.get(), OCVU_FEATURE_ORB, &count));
    int32_t count_b = 0;
    const ScopedMat b(ComputeDescriptors(image.get(), OCVU_FEATURE_ORB, &count_b));
    ASSERT_GT(count, 0);
    ASSERT_EQ(count, count_b);

    std::vector<ocvu_dmatch> matches(static_cast<size_t>(kCapacity));
    int32_t match_count = -1;

    // **cross_check を使う。** 同じ記述子集合どうしでも、cross_check が
    // 0 だと query_index と train_index は一致しない —— 市松のように
    // 繰り返す模様では記述子が重複し、同点のとき BFMatcher は先に現れた
    // ほうを選ぶためである（2026-09-05 の実測: 200x200 で 212 件中 53 件しか
    // 一致しなかった）。cross_check を 1 にすると互いに最近傍である対応だけが
    // 残り、実測では 44 件すべてが自分自身になった。
    //
    // **この 1 つのテストが 2 つのことを同時に示す** ——
    // 索引が正しく運ばれていることと、cross_check が実際に効いていること。
    ASSERT_EQ(ocvu_match_descriptors(a.get(), b.get(), OCVU_NORM_HAMMING, 1,
                                     matches.data(), kCapacity, &match_count),
              OCVU_STATUS_OK);
    ASSERT_GT(match_count, 0);
    ASSERT_LE(match_count, count);

    for (int32_t i = 0; i < match_count; ++i) {
        const ocvu_dmatch& m = matches[static_cast<size_t>(i)];
        EXPECT_FLOAT_EQ(m.distance, 0.0f) << "同じ記述子どうしなのに距離が 0 でない";
        EXPECT_EQ(m.query_index, m.train_index) << "cross_check を通ったのに自分自身ではない";
        EXPECT_EQ(m.image_index, 0) << "1 対 1 の照合なので image_index は 0 である";
        EXPECT_GE(m.query_index, 0);
        EXPECT_LT(m.query_index, count);
    }
}

TEST(Matching, MatchDescriptorsReportsTheCountWhenTheBufferIsTooSmall) {
    const ScopedMat image(MakeTexturedImage());
    int32_t count = 0;
    const ScopedMat a(ComputeDescriptors(image.get(), OCVU_FEATURE_ORB, &count));
    int32_t count_b = 0;
    const ScopedMat b(ComputeDescriptors(image.get(), OCVU_FEATURE_ORB, &count_b));
    ASSERT_GT(count, 0);

    std::vector<ocvu_dmatch> matches(static_cast<size_t>(kCapacity));
    const size_t bytes = matches.size() * sizeof(ocvu_dmatch);
    std::memset(matches.data(), 0xAB, bytes);
    std::vector<uint8_t> before(bytes);
    std::memcpy(before.data(), matches.data(), bytes);

    int32_t match_count = -1;
    EXPECT_EQ(ocvu_match_descriptors(a.get(), b.get(), OCVU_NORM_HAMMING, 0,
                                     matches.data(), 0, &match_count),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_GT(match_count, 0) << "溢れたときは実際の対応数を返すこと";
    EXPECT_EQ(std::memcmp(matches.data(), before.data(), bytes), 0)
        << "断ったのに out_matches を書いている";

    // buffer を渡さずに個数だけを問い合わせられること。
    int32_t queried = -1;
    EXPECT_EQ(ocvu_match_descriptors(a.get(), b.get(), OCVU_NORM_HAMMING, 0,
                                     nullptr, 0, &queried),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(queried, match_count);
}

TEST(Matching, MatchDescriptorsRejectsBadArgumentsAndZeroesTheCount) {
    const ScopedMat image(MakeTexturedImage());
    int32_t count = 0;
    const ScopedMat a(ComputeDescriptors(image.get(), OCVU_FEATURE_ORB, &count));
    int32_t count_b = 0;
    const ScopedMat b(ComputeDescriptors(image.get(), OCVU_FEATURE_ORB, &count_b));
    std::vector<ocvu_dmatch> matches(static_cast<size_t>(kCapacity));

    EXPECT_EQ(ocvu_match_descriptors(a.get(), b.get(), OCVU_NORM_HAMMING, 0,
                                     matches.data(), kCapacity, nullptr),
              OCVU_STATUS_NULL_POINTER);

    int32_t match_count = 12345;
    EXPECT_EQ(ocvu_match_descriptors(a.get(), b.get(), 99, 0,
                                     matches.data(), kCapacity, &match_count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(match_count, 0) << "失敗時は out_count に 0 を書くこと";

    match_count = 12345;
    EXPECT_EQ(ocvu_match_descriptors(a.get(), b.get(), OCVU_NORM_HAMMING, 0,
                                     nullptr, kCapacity, &match_count),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(match_count, 0);

    match_count = 12345;
    EXPECT_EQ(ocvu_match_descriptors(a.get(), b.get(), OCVU_NORM_HAMMING, 0,
                                     matches.data(), -1, &match_count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(match_count, 0);

    match_count = 12345;
    EXPECT_EQ(ocvu_match_descriptors(OCVU_MAT_HANDLE_NONE, b.get(), OCVU_NORM_HAMMING, 0,
                                     matches.data(), kCapacity, &match_count),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(match_count, 0);

    match_count = 12345;
    EXPECT_EQ(ocvu_match_descriptors(a.get(), OCVU_MAT_HANDLE_NONE, OCVU_NORM_HAMMING, 0,
                                     matches.data(), kCapacity, &match_count),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(match_count, 0);
}

TEST(Matching, MatchDescriptorsReportsOpenCvErrors) {
    // **summary が OPENCV_ERROR を約束しているので、それを実証する。**
    // 約束だけして実装が返さない状態は、ビルドも既存テストも緑のまま隠れる。
    const ScopedMat image(MakeTexturedImage());
    int32_t orb_count = 0;
    const ScopedMat orb(ComputeDescriptors(image.get(), OCVU_FEATURE_ORB, &orb_count));
    int32_t sift_count = 0;
    const ScopedMat sift(ComputeDescriptors(image.get(), OCVU_FEATURE_SIFT, &sift_count));
    ASSERT_GT(orb_count, 0);
    ASSERT_GT(sift_count, 0);

    std::vector<ocvu_dmatch> matches(static_cast<size_t>(kCapacity));

    // **ハミング距離は 2 値の記述子のためのものである。** SIFT の
    // 32 bit 浮動小数の記述子に当てると OpenCV が例外を投げる（実測）。
    int32_t match_count = 12345;
    EXPECT_EQ(ocvu_match_descriptors(sift.get(), sift.get(), OCVU_NORM_HAMMING, 0,
                                     matches.data(), kCapacity, &match_count),
              OCVU_STATUS_OPENCV_ERROR);
    EXPECT_EQ(match_count, 0);
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_OPENCV_ERROR)
        << "cv::Exception を UNKNOWN_ERROR に落としている";

    // **query と train の記述子の型が違う場合も例外になる**（実測）。
    match_count = 12345;
    EXPECT_EQ(ocvu_match_descriptors(orb.get(), sift.get(), OCVU_NORM_L2, 0,
                                     matches.data(), kCapacity, &match_count),
              OCVU_STATUS_OPENCV_ERROR);
    EXPECT_EQ(match_count, 0);
}
