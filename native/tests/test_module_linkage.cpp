// objdetect / features が「ビルドされている」ではなく
// 「この plugin にリンクされている」ことを見る。
//
// **この 2 つは別である。** tools/opencv-config.psd1 の Modules に載っていれば
// OpenCV 側は当然ビルドされ、ocvu_get_build_information() も To be built: に
// その名前を出す。それを根拠にすると誤る —— M3.5 で imgcodecs がこれで、
// cmake/FindOpenCvUnityDeps.cmake の COMPONENTS に無いまま
// 「リンク済み」と複数の文書が書いていた。リンカが cv::imencode を
// 未解決にして初めて分かった。
//
// **参照しないと引かれない。** COMPONENTS に足すだけでは binary は
// 1 バイトも増えないので、実際にシンボルを参照するここが唯一の証拠になる。

#include <gtest/gtest.h>

#include <opencv2/core.hpp>
#include <opencv2/features.hpp>
#include <opencv2/geometry.hpp>
#include <opencv2/objdetect.hpp>

TEST(ModuleLinkage, ObjdetectSymbolsResolve) {
    cv::Ptr<cv::QRCodeEncoder> encoder = cv::QRCodeEncoder::create();
    ASSERT_FALSE(encoder.empty());

    cv::QRCodeDetector detector;
    // 空の cv::Mat() は cv::checkQRInputImage の `!img.empty()` assertion で
    // 例外になる（OpenCV 5.0.0 で実測。計画のコメントはここを「例外になら
    // ない」と誤って書いていた）。QR コードを含まない有効な Mat を渡し、
    // 結果ではなく「呼べた」ことを確かめる —— ここで見たいのはリンクである。
    const cv::Mat blank = cv::Mat::zeros(16, 16, CV_8UC1);
    const std::string decoded = detector.detectAndDecode(blank);
    EXPECT_TRUE(decoded.empty());
}

TEST(ModuleLinkage, FeaturesSymbolsResolve) {
    cv::Ptr<cv::ORB> orb = cv::ORB::create(16);
    ASSERT_FALSE(orb.empty());
    EXPECT_EQ(orb->getMaxFeatures(), 16);
}

TEST(ModuleLinkage, GeometrySymbolsResolve) {
    // **geometry は Modules に無いが、ビルドされている。** flann と同じく
    // features / objdetect の依存として引かれるためで、OpenCVModules.cmake も
    // component として公開している。**ただしそれは「リンクできる」ことの
    // 証拠ではない** —— COMPONENTS に足して、実際にシンボルを参照して初めて分かる。
    //
    // 4 点の対応から射影変換を求める。同一平面上の 4 点なので解は一意に決まり、
    // ここでは結果ではなく **cv::findHomography が呼べたこと**を見る。
    const std::vector<cv::Point2f> src{{0, 0}, {10, 0}, {10, 10}, {0, 10}};
    const std::vector<cv::Point2f> dst{{0, 0}, {20, 0}, {20, 20}, {0, 20}};

    const cv::Mat h = cv::findHomography(src, dst);
    ASSERT_FALSE(h.empty());
    EXPECT_EQ(h.rows, 3);
    EXPECT_EQ(h.cols, 3);
}
