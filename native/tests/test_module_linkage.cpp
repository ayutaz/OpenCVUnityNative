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
#include <opencv2/imgproc.hpp>
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

TEST(ModuleLinkage, UndistortionSymbolsResolveWithoutCalib) {
    // **この計画の前提を固定する。** カメラの歪み補正に要る関数は
    // calib module ではなく imgproc と objdetect に在り、どちらも
    // 既にリンク済みである（2026-09-01 実測）。
    //
    // **上流が module を再編したら、この前提は黙って崩れる** ——
    // OpenCV 5 は 4.x の calib3d を geometry / calib / stereo / ptcloud へ
    // 実際に割った。次に同じことが起きたとき、ここが最初に赤くなる。
    //
    // **注**: このテストは `COMPONENTS` の編集では落ちない。imgproc は
    // imgcodecs / objdetect / features / geometry から推移的に引かれるため、
    // cmake/FindOpenCvUnityDeps.cmake から外しても、最終的なリンク行には
    // 残る（実測で確認済み）。**それでも守っているものがある** ——
    // 上流が cv::undistort を imgproc から別 module へ移したら、リンク
    // エラーで初めて気づく。だから「壊して落ちることを見た」検査では無い。
    const cv::Mat src = cv::Mat::zeros(32, 32, CV_8UC1);
    const cv::Mat camera = (cv::Mat_<double>(3, 3) << 100, 0, 16, 0, 100, 16, 0, 0, 1);
    const cv::Mat coeffs = (cv::Mat_<double>(1, 5) << 0.1, -0.05, 0, 0, 0);

    cv::Mat dst;
    cv::undistort(src, dst, camera, coeffs);
    EXPECT_EQ(dst.rows, 32);
    EXPECT_EQ(dst.cols, 32);

    // 真っ黒な画像に格子は写っていないので false が返る。
    // ここで見たいのはリンクなので、結果ではなく「呼べた」ことを確かめる。
    std::vector<cv::Point2f> corners;
    const bool found = cv::findChessboardCorners(src, cv::Size(7, 7), corners);
    EXPECT_FALSE(found);
}
