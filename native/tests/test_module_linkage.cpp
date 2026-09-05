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
#include <opencv2/calib.hpp>
#include <opencv2/objdetect.hpp>
#include <opencv2/stereo.hpp>

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

TEST(ModuleLinkage, CalibIsLinked) {
    // **cv::calibrateCamera は calib module にしか無い。**
    // 実物で確かめた: 宣言は third_party/.../include/opencv2/calib.hpp:701 に在り、
    // imgproc / objdetect / geometry のどれにも無い。
    //
    // **したがってこのテストは COMPONENTS の編集で落ちる** —— 上の
    // UndistortAndChessboardComeFromLinkedModules と違い、calib はどの
    // module からも推移的に引かれない（実測: COMPONENTS に足す前は
    // 未解決の外部シンボルでリンクに失敗した）。
    std::vector<std::vector<cv::Point3f>> object_points(1);
    std::vector<std::vector<cv::Point2f>> image_points(1);
    for (int i = 0; i < 4; ++i) {
        object_points[0].emplace_back(static_cast<float>(i), 0.0f, 0.0f);
        image_points[0].emplace_back(static_cast<float>(i), 0.0f);
    }

    cv::Mat camera_matrix;
    cv::Mat dist_coeffs;
    std::vector<cv::Mat> rvecs;
    std::vector<cv::Mat> tvecs;

    // view が 1 枚で点も一直線なので OpenCV は解けずに例外を投げる。
    // **それでよい** —— ここが見ているのは「シンボルが解決するか」だけである。
    EXPECT_THROW(
        cv::calibrateCamera(object_points, image_points, cv::Size(64, 64),
                            camera_matrix, dist_coeffs, rvecs, tvecs),
        cv::Exception);
}

TEST(ModuleLinkage, StereoIsLinked) {
    // **stereo は tools/opencv-config.psd1 の Modules に無いが、
    // ビルドされている。** calib が推移的に引くためで、復元済みのツリーに
    // opencv_stereo が実在する（2026-09-05 に実測）。
    //
    // **desktop では COMPONENTS への追加は no-op である。** 実測の根拠:
    // OpenCVModules.cmake:135-139 が opencv_calib の INTERFACE_LINK_LIBRARIES に
    // opencv_stereo を含めており、COMPONENTS には既に calib が在る。
    // **geometry とまったく同じ形で、CalibIsLinked とは違う** ——
    // calib はどの module からも引かれないので COMPONENTS に足す前は
    // LNK2019 で落ちたが、stereo は足す前から通る。
    //
    // **それでも COMPONENTS には足してある。iOS では話が違うからである** ——
    // native/CMakeLists.txt:88-90 の iOS の束ね分岐は ${OpenCV_LIBS} を
    // foreach で回して実ファイルへ解決するので、**COMPONENTS に無い module は
    // 束ねられない。**
    //
    // **Web は違う。** 同 :158-164 の Emscripten の分岐は OpenCV_LIBS を使わず、
    // install 木の lib/libopencv_*.a を file(GLOB) で全部束ねる ——
    // **COMPONENTS に足しても束ねる中身は 1 バイトも変わらない。**
    // （そうした理由がその場に書いてある: COMPONENTS だけだと推移的に引かれる
    // module が漏れ、実測で cv::flann の未定義が 29 件残った。）
    //
    // **つまりこの 1 語は、desktop と Web には意図の宣言、iOS には実際の指示である。**
    //
    // したがって**このテストは Windows / macOS / Linux では COMPONENTS の
    // 編集で落ちない**（UndistortionSymbolsResolveWithoutCalib と同じ性質）。
    // それでも守っているものがある —— 上流が cv::StereoBM を別 module へ
    // 移したり、calib が stereo を引かなくなったりしたら、ここが最初に赤くなる。
    const cv::Ptr<cv::StereoBM> matcher = cv::StereoBM::create(16, 21);
    ASSERT_FALSE(matcher.empty());
    EXPECT_EQ(matcher->getNumDisparities(), 16);
    EXPECT_EQ(matcher->getBlockSize(), 21);
}
