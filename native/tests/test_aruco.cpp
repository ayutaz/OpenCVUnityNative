// ArUco の 2 本の契約テスト。
//
// **外部の画像資産に依存しない。** 自分で生成したマーカーを自分で検出する
// 閉じた輪にしてあるので、テストデータの取り違えも、環境による写りの差も無い。
//
// **期待値は手で決められるものだけを使う。** 位置は「生成したマーカーを
// どこに貼ったか」から決まり、ID は「どの ID を生成したか」から決まる。
// OpenCV に期待値を作らせている箇所は 1 つも無い。

#include <gtest/gtest.h>

#include <opencv_unity_native.h>

#include <cstdint>
#include <vector>

namespace {

// テスト用の Mat を 1 つ作って、抜けるときに必ず解放する。
class ScopedMat {
public:
    explicit ScopedMat(int rows = 1, int cols = 1, int32_t type = OCVU_MAT_TYPE_8UC1) {
        EXPECT_EQ(ocvu_mat_create(rows, cols, type, &handle_), OCVU_STATUS_OK);
    }
    ~ScopedMat() { ocvu_mat_release(handle_); }
    ScopedMat(const ScopedMat&) = delete;
    ScopedMat& operator=(const ScopedMat&) = delete;

    ocvu_mat_handle get() const { return handle_; }

private:
    ocvu_mat_handle handle_ = OCVU_MAT_HANDLE_NONE;
};

// マーカーの 1 辺。DICT_4X4_50 は 4x4 の格子で、枠 1 を足すと 6 セルになる。
// **180 は 6 で割り切れる** —— 割り切れないと OpenCV が最近傍で引き伸ばす
// ときにセルの幅が 1 画素ずつずれ、検出できるかどうかが微妙な話になる。
constexpr int32_t kMarkerSide = 180;

// マーカーの周りに置く白い余白。**これが要る** —— ArUco の検出は黒い枠の
// 外側に白があることを前提にしている。
constexpr int32_t kMargin = 60;

constexpr int32_t kSceneSide = kMarkerSide + kMargin * 2;  // 300

// 画像を 1 つの値で塗りつぶす。
//
// **ocvu_mat_create は画素を初期化しない。** 「何も写っていない画像」を
// 作るつもりで作っただけの Mat を渡すと、中身は不定である ——
// 検出結果が実行のたびに変わりうるので、明示的に埋める。
void FillUniform(ocvu_mat_handle handle, int32_t rows, int32_t cols, uint8_t value) {
    std::vector<uint8_t> pixels(static_cast<size_t>(rows) * static_cast<size_t>(cols), value);
    // **stride はバイト数である**（要素数でも画素数でもない）。8 bit 1 channel
    // なので 1 行のバイト数は cols と等しい。
    ASSERT_EQ(ocvu_mat_copy_from_buffer(handle, pixels.data(),
                                        static_cast<int64_t>(pixels.size()), cols),
              OCVU_STATUS_OK);
}

// 白い場面の真ん中に、生成したマーカーを貼った画素列を作る（8 bit 1 channel）。
void BuildScenePixels(int32_t dictionary_id, int32_t marker_id,
                      std::vector<uint8_t>* out_pixels) {
    ScopedMat marker;
    ASSERT_EQ(ocvu_aruco_generate_marker(dictionary_id, marker_id, kMarkerSide, 1, marker.get()),
              OCVU_STATUS_OK);

    std::vector<uint8_t> marker_pixels(static_cast<size_t>(kMarkerSide) *
                                       static_cast<size_t>(kMarkerSide));
    ASSERT_EQ(ocvu_mat_copy_to_buffer(marker.get(), marker_pixels.data(),
                                      static_cast<int64_t>(marker_pixels.size()), kMarkerSide),
              OCVU_STATUS_OK);

    // **余白は 255 で埋めてから貼る。** ゼロ埋めにすると黒い海に黒枠の
    // マーカーが浮かぶ形になり、輪郭が取れない。
    out_pixels->assign(static_cast<size_t>(kSceneSide) * static_cast<size_t>(kSceneSide), 255);
    for (int32_t r = 0; r < kMarkerSide; ++r) {
        for (int32_t c = 0; c < kMarkerSide; ++c) {
            (*out_pixels)[static_cast<size_t>(r + kMargin) * static_cast<size_t>(kSceneSide) +
                          static_cast<size_t>(c + kMargin)] =
                marker_pixels[static_cast<size_t>(r) * static_cast<size_t>(kMarkerSide) +
                              static_cast<size_t>(c)];
        }
    }
}

// 上の画素列を 8 bit 1 channel の Mat へ入れる。
// scene は kSceneSide 四方の 8 bit 1 channel でなければならない。
void PaintMarkerOnWhite(ocvu_mat_handle scene, int32_t dictionary_id, int32_t marker_id) {
    std::vector<uint8_t> scene_pixels;
    BuildScenePixels(dictionary_id, marker_id, &scene_pixels);
    ASSERT_FALSE(::testing::Test::HasFatalFailure());

    // **stride はバイト数である。** 8 bit 1 channel なので 1 行は kSceneSide バイト。
    ASSERT_EQ(ocvu_mat_copy_from_buffer(scene, scene_pixels.data(),
                                        static_cast<int64_t>(scene_pixels.size()), kSceneSide),
              OCVU_STATUS_OK);
}

// 同じ場面を 4 channel（Unity のテクスチャと同じ形）で入れる。
// scene は kSceneSide 四方の 8 bit 4 channel でなければならない。
void PaintMarkerOnWhiteFourChannel(ocvu_mat_handle scene, int32_t dictionary_id,
                                   int32_t marker_id) {
    std::vector<uint8_t> grey;
    BuildScenePixels(dictionary_id, marker_id, &grey);
    ASSERT_FALSE(::testing::Test::HasFatalFailure());

    // 灰色を 3 つの channel に同じ値で入れ、4 つ目（alpha）は 255 にする。
    std::vector<uint8_t> rgba(grey.size() * 4, 255);
    for (size_t i = 0; i < grey.size(); ++i) {
        rgba[i * 4] = grey[i];
        rgba[i * 4 + 1] = grey[i];
        rgba[i * 4 + 2] = grey[i];
    }

    // **1 行のバイト数は 4 倍になる。**
    ASSERT_EQ(ocvu_mat_copy_from_buffer(scene, rgba.data(),
                                        static_cast<int64_t>(rgba.size()), kSceneSide * 4),
              OCVU_STATUS_OK);
}

}  // namespace

TEST(Aruco, GenerateMarkerFillsTheDestination) {
    ScopedMat dst(4, 4);

    // dst の形は結果に応じて置き換わる。作ったときの 4x4 は残らない。
    ASSERT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, 7, 120, 1, dst.get()),
              OCVU_STATUS_OK);

    ocvu_mat_info info{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &info), OCVU_STATUS_OK);
    EXPECT_EQ(info.rows, 120);
    EXPECT_EQ(info.cols, 120);
    EXPECT_EQ(info.channels, 1);
    EXPECT_EQ(info.type, OCVU_MAT_TYPE_8UC1);

    // マーカーは黒と白の両方を含む。真っ白でも真っ黒でもない。
    std::vector<uint8_t> pixels(120 * 120);
    ASSERT_EQ(ocvu_mat_copy_to_buffer(dst.get(), pixels.data(),
                                      static_cast<int64_t>(pixels.size()), 120),
              OCVU_STATUS_OK);
    bool has_black = false;
    bool has_white = false;
    for (const uint8_t p : pixels) {
        if (p == 0) has_black = true;
        if (p == 255) has_white = true;
    }
    EXPECT_TRUE(has_black);
    EXPECT_TRUE(has_white);
}

TEST(Aruco, GenerateMarkerRejectsBadArguments) {
    ScopedMat dst;

    // 知らない辞書は素通しにしない。**OCVU_ARUCO_DICT_ARUCO_ORIGINAL の
    // 後ろには AprilTag 系が続くが、この plugin では検証していないので出して
    // いない** —— 番号としては OpenCV に在るので、素通しにすると「名前の無い
    // 辞書が使えてしまう」形になる。
    EXPECT_EQ(ocvu_aruco_generate_marker(-1, 0, 100, 1, dst.get()), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_ARUCO_ORIGINAL + 1, 0, 100, 1, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);

    // DICT_4X4_50 は 50 個しか持たない。範囲外の ID は拒否する。
    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, 50, 100, 1, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, -1, 100, 1, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);
    // 49 は在る。上の 50 が「範囲の外」であって「辞書が使えない」のではない
    // ことを、同じ辞書で示す。
    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, 49, 100, 1, dst.get()),
              OCVU_STATUS_OK);

    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, 0, 0, 1, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, 0,
                                         OCVU_ARUCO_MAX_MARKER_PIXELS + 1, 1, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, 0, 100, 0, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);

    // 無効な handle。
    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, 0, 100, 1, OCVU_MAT_HANDLE_NONE),
              OCVU_STATUS_INVALID_HANDLE);
}

TEST(Aruco, GenerateMarkerRejectsASizeSmallerThanTheGridPlusItsBorder) {
    // **格子より小さい画像にマーカーは描けない。** DICT_4X4_50 は 4x4 の
    // 格子なので、枠 1 なら 6 画素、枠 2 なら 8 画素が下限になる。
    // **境界の両側を見る** —— 下限そのものが通ることまで見ないと、
    // 「常に断る」実装でもこの検査は緑になる。
    ScopedMat dst;

    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, 0, 5, 1, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, 0, 6, 1, dst.get()),
              OCVU_STATUS_OK);

    // **枠を太くすると下限も動く。** 定数を焼き込んだ実装ではここが落ちる。
    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, 0, 7, 2, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, 0, 8, 2, dst.get()),
              OCVU_STATUS_OK);

    // **辞書が変われば格子の細かさも変わる。** DICT_6X6_250 は 6x6 なので
    // 枠 1 でも 8 画素が要る。
    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_6X6_250, 0, 7, 1, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_6X6_250, 0, 8, 1, dst.get()),
              OCVU_STATUS_OK);
}

TEST(Aruco, GenerateMarkerLeavesTheDestinationUntouchedWhenItFails) {
    ScopedMat dst;

    // 先に成功させて、既知の形にしておく。
    ASSERT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, 3, 60, 1, dst.get()),
              OCVU_STATUS_OK);
    ocvu_mat_info before{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &before), OCVU_STATUS_OK);
    ASSERT_EQ(before.rows, 60);

    // 失敗する呼び出しが dst を書き換えないこと。
    EXPECT_EQ(ocvu_aruco_generate_marker(OCVU_ARUCO_DICT_4X4_50, 999, 120, 1, dst.get()),
              OCVU_STATUS_INVALID_ARGUMENT);

    ocvu_mat_info after{};
    ASSERT_EQ(ocvu_mat_get_info(dst.get(), &after), OCVU_STATUS_OK);
    EXPECT_EQ(before.rows, after.rows);
    EXPECT_EQ(before.cols, after.cols);
}

TEST(Aruco, DetectFindsTheMarkerItGenerated) {
    // **生成したものを検出する閉じた輪である。** 外部の画像に依存しない。
    ScopedMat scene(kSceneSide, kSceneSide);
    PaintMarkerOnWhite(scene.get(), OCVU_ARUCO_DICT_4X4_50, 7);
    ASSERT_FALSE(::testing::Test::HasFatalFailure());

    std::vector<int32_t> ids(8);
    std::vector<float> corners(64);
    int32_t count = -1;

    ASSERT_EQ(ocvu_aruco_detect_markers(scene.get(), OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), 8, corners.data(), 64, &count),
              OCVU_STATUS_OK);
    ASSERT_EQ(count, 1);
    EXPECT_EQ(ids[0], 7);

    // 4 隅はマーカーを貼った領域（余白 kMargin の内側）に収まる。
    // **厳密な位置ではなく範囲を見る** —— 検出器の細かな挙動に縛られないため。
    for (int i = 0; i < 8; ++i) {
        EXPECT_GE(corners[static_cast<size_t>(i)], static_cast<float>(kMargin) - 10.0f)
            << "隅の要素 " << i << " が余白の外に出ている";
        EXPECT_LE(corners[static_cast<size_t>(i)],
                  static_cast<float>(kMargin + kMarkerSide) + 10.0f)
            << "隅の要素 " << i << " が余白の外に出ている";
    }
}

TEST(Aruco, DetectReturnsTheCornersClockwiseFromTheTopLeft) {
    // **上下も左右も分かる形で貼ってあるから、この検査ができる。**
    // マーカーは回転させずに場面の真ん中へ貼ってあるので、OpenCV が
    // 「マーカーの左上」として返す隅は、画像の左上側に在るはずである。
    // ここが崩れると、この 4 隅をそのまま姿勢推定へ渡す使い方
    // （OCVU_SOLVEPNP_IPPE_SQUARE）が黙って間違った姿勢を返す。
    ScopedMat scene(kSceneSide, kSceneSide);
    PaintMarkerOnWhite(scene.get(), OCVU_ARUCO_DICT_4X4_50, 7);
    ASSERT_FALSE(::testing::Test::HasFatalFailure());

    std::vector<int32_t> ids(8);
    std::vector<float> corners(64);
    int32_t count = -1;

    ASSERT_EQ(ocvu_aruco_detect_markers(scene.get(), OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), 8, corners.data(), 64, &count),
              OCVU_STATUS_OK);
    ASSERT_EQ(count, 1);

    constexpr float kCenter = static_cast<float>(kSceneSide) / 2.0f;
    // 隅は x と y が交互に並ぶ。0 番が左上、以降は時計回りである。
    EXPECT_LT(corners[0], kCenter) << "0 番の隅が左半分に無い";
    EXPECT_LT(corners[1], kCenter) << "0 番の隅が上半分に無い";
    EXPECT_GT(corners[2], kCenter) << "1 番の隅が右半分に無い";
    EXPECT_LT(corners[3], kCenter) << "1 番の隅が上半分に無い";
    EXPECT_GT(corners[4], kCenter) << "2 番の隅が右半分に無い";
    EXPECT_GT(corners[5], kCenter) << "2 番の隅が下半分に無い";
    EXPECT_LT(corners[6], kCenter) << "3 番の隅が左半分に無い";
    EXPECT_GT(corners[7], kCenter) << "3 番の隅が下半分に無い";
}

TEST(Aruco, DetectAnswersHowManyMarkersAreThereBeforeTheBuffersExist) {
    // **大きさを先に問い合わせる呼び方**。容量 0 と NULL の組み合わせは
    // 正常な問い合わせで、実際に見つかった個数が out_count に返る。
    ScopedMat scene(kSceneSide, kSceneSide);
    PaintMarkerOnWhite(scene.get(), OCVU_ARUCO_DICT_4X4_50, 7);
    ASSERT_FALSE(::testing::Test::HasFatalFailure());

    int32_t count = -1;
    ASSERT_EQ(ocvu_aruco_detect_markers(scene.get(), OCVU_ARUCO_DICT_4X4_50,
                                        nullptr, 0, nullptr, 0, &count),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    ASSERT_EQ(count, 1);

    // 返ってきた個数ちょうどで確保し直せば通る。
    std::vector<int32_t> ids(static_cast<size_t>(count));
    std::vector<float> corners(static_cast<size_t>(count) * 8);
    int32_t second = -1;
    EXPECT_EQ(ocvu_aruco_detect_markers(scene.get(), OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), count, corners.data(), count * 8, &second),
              OCVU_STATUS_OK);
    EXPECT_EQ(second, 1);
    EXPECT_EQ(ids[0], 7);
}

TEST(Aruco, DetectReturnsZeroWhenNothingIsThere) {
    // **検出できないのは誤りではない。** OK と count 0 で返る。
    ScopedMat blank(120, 120);
    FillUniform(blank.get(), 120, 120, 255);
    ASSERT_FALSE(::testing::Test::HasFatalFailure());

    std::vector<int32_t> ids(8);
    std::vector<float> corners(64);
    int32_t count = -1;

    EXPECT_EQ(ocvu_aruco_detect_markers(blank.get(), OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), 8, corners.data(), 64, &count),
              OCVU_STATUS_OK);
    EXPECT_EQ(count, 0);
}

TEST(Aruco, DetectRejectsTooSmallBuffersWithoutWriting) {
    ScopedMat scene(kSceneSide, kSceneSide);
    PaintMarkerOnWhite(scene.get(), OCVU_ARUCO_DICT_4X4_50, 7);
    ASSERT_FALSE(::testing::Test::HasFatalFailure());

    // **0 ではない値で埋めてから呼ぶ。** 0 埋めだと「書いていない」と
    // 「0 を書いた」が区別できない。
    std::vector<int32_t> ids(8, -7);
    std::vector<float> corners(64, -7.0f);
    int32_t count = -1;

    // ids の容量が足りない。
    EXPECT_EQ(ocvu_aruco_detect_markers(scene.get(), OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), 0, corners.data(), 64, &count),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(count, 1) << "溢れたときは実際に見つかった数を返すこと";

    // corners の容量が足りない（1 マーカーにつき 8 要素が要る）。
    count = -1;
    EXPECT_EQ(ocvu_aruco_detect_markers(scene.get(), OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), 8, corners.data(), 7, &count),
              OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(count, 1);

    for (const int32_t v : ids) EXPECT_EQ(v, -7) << "断ったのに ids を書いている";
    for (const float v : corners) EXPECT_FLOAT_EQ(v, -7.0f) << "断ったのに corners を書いている";
}

TEST(Aruco, DetectRejectsBadArgumentsAndZeroesTheCount) {
    ScopedMat blank(120, 120);
    FillUniform(blank.get(), 120, 120, 255);
    ASSERT_FALSE(::testing::Test::HasFatalFailure());

    std::vector<int32_t> ids(8);
    std::vector<float> corners(64);

    // **out_count が NULL なら、他の何より先に断る。**
    EXPECT_EQ(ocvu_aruco_detect_markers(blank.get(), OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), 8, corners.data(), 64, nullptr),
              OCVU_STATUS_NULL_POINTER);

    // **0 ではない値で汚してから呼ぶ。** どの失敗経路でも 0 が書かれること。
    int32_t count = 12345;
    EXPECT_EQ(ocvu_aruco_detect_markers(blank.get(), 99, ids.data(), 8, corners.data(), 64, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0) << "失敗時は out_count に 0 を書くこと";

    // **容量が正なのにポインタが NULL なら断る**（容量 0 と NULL の組み合わせは
    // 正常な問い合わせなので、そちらは別のテストが通ることを見ている）。
    count = 12345;
    EXPECT_EQ(ocvu_aruco_detect_markers(blank.get(), OCVU_ARUCO_DICT_4X4_50,
                                        nullptr, 8, corners.data(), 64, &count),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_aruco_detect_markers(blank.get(), OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), 8, nullptr, 64, &count),
              OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_aruco_detect_markers(OCVU_MAT_HANDLE_NONE, OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), 8, corners.data(), 64, &count),
              OCVU_STATUS_INVALID_HANDLE);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_aruco_detect_markers(blank.get(), OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), -1, corners.data(), 64, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);

    count = 12345;
    EXPECT_EQ(ocvu_aruco_detect_markers(blank.get(), OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), 8, corners.data(), -1, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);
}

TEST(Aruco, DetectAcceptsTheFourChannelImagesUnityProduces) {
    // **Unity のテクスチャは 4 channel である。**
    // TextureConverter も WebCamTextureConverter も Bgra32 の CvMat を作るので、
    // **ここが通らないと、いちばん普通の使い方が通らない。**
    // 中身は 1 channel 版とまったく同じ場面なので、同じ ID が返るはずである。
    ScopedMat scene(kSceneSide, kSceneSide, OCVU_MAT_TYPE_8UC4);
    PaintMarkerOnWhiteFourChannel(scene.get(), OCVU_ARUCO_DICT_4X4_50, 7);
    ASSERT_FALSE(::testing::Test::HasFatalFailure());

    std::vector<int32_t> ids(8);
    std::vector<float> corners(64);
    int32_t count = -1;

    ASSERT_EQ(ocvu_aruco_detect_markers(scene.get(), OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), 8, corners.data(), 64, &count),
              OCVU_STATUS_OK);
    ASSERT_EQ(count, 1);
    EXPECT_EQ(ids[0], 7);
}

TEST(Aruco, DetectRejectsAPixelTypeItDoesNotAccept) {
    // **8 bit でない Mat は断る。** OpenCV に落とすと例外になるが、呼ぶ側が
    // 直せる誤りなので INVALID_ARGUMENT で返す。
    // （OCVU_MAT_TYPE_32FC1 は ocvu_match_template のような関数の出力の型で、
    // 画像として検出器に渡せるものではない。）
    ScopedMat floats(32, 32, OCVU_MAT_TYPE_32FC1);

    std::vector<int32_t> ids(8);
    std::vector<float> corners(64);
    int32_t count = 12345;

    EXPECT_EQ(ocvu_aruco_detect_markers(floats.get(), OCVU_ARUCO_DICT_4X4_50,
                                        ids.data(), 8, corners.data(), 64, &count),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(count, 0);
}
