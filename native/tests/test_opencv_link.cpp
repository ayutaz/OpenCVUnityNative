#include <gtest/gtest.h>

#include <cctype>
#include <string>
#include <vector>

#include "opencv_unity_native.h"

namespace {

std::string ReadStringApi(ocvu_status (*api)(char*, int32_t, int32_t*)) {
    int32_t required = 0;
    EXPECT_EQ(api(nullptr, 0, &required), OCVU_STATUS_BUFFER_TOO_SMALL);
    if (required <= 1) {
        return std::string();
    }
    std::vector<char> buffer(static_cast<size_t>(required));
    EXPECT_EQ(api(buffer.data(), required, &required), OCVU_STATUS_OK);
    return std::string(buffer.data());
}

}  // namespace

TEST(OpenCvLink, ReportsThePinnedVersion) {
    EXPECT_EQ(ReadStringApi(&ocvu_get_opencv_version), "5.0.0");
}

TEST(OpenCvLink, VersionApiFollowsTheSameBufferContract) {
    int32_t required = 0;
    EXPECT_EQ(ocvu_get_opencv_version(nullptr, 0, nullptr), OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_get_opencv_version(nullptr, 0, &required), OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(required, 6);  // "5.0.0" + NUL

    char small[3] = {0};
    EXPECT_EQ(ocvu_get_opencv_version(small, 3, &required), OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(required, 6);
}

TEST(OpenCvLink, BuildInformationIsAvailable) {
    const std::string info = ReadStringApi(&ocvu_get_build_information);
    EXPECT_NE(info.find("OpenCV"), std::string::npos);
}

/*
 * 依存 allowlist を「ビルドスクリプトの grep」ではなく「リンク済みバイナリへの
 * テスト」にする。cv::getBuildInformation() は実際にリンクされた構成を返すので、
 * ここが緑であることは configure 時の意図ではなく成果物の性質を示す。
 *
 * 実際に ocvu_get_build_information() を呼んで出力を確認したところ（詳細は
 * task-7-report.md）、"FFMPEG:                      YES" のような列揃えの行は
 * 一切現れない。videoio モジュール自体が "Disabled by dependency" に落ちて
 * おり、videoio がビルドされない結果として「Video I/O:」節に FFmpeg /
 * GStreamer の行そのものが存在しないためである。よって「YES と組になっている
 * 行が無い」という検査は、この成果物に対しては何もマッチしないまま常に緑になる
 * ——検証しているように見えて実は何も見ていない assertion になってしまう。
 *
 * 代わりに実際の出力の性質に基づいた 2 段の検査にする。
 *   1. "To be built:" 行に videoio が含まれないこと（根本原因の直接の裏取り）。
 *   2. 出力全体のどこにも "ffmpeg" / "gstreamer" という文字列が現れないこと
 *      （videoio が外れていることの結果を、列揃えに依存せず確認する）。
 */
TEST(OpenCvLink, ForbiddenDependenciesAreAbsentFromTheLinkedBinary) {
    std::string info = ReadStringApi(&ocvu_get_build_information);
    for (char& c : info) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }

    const std::string::size_type built_pos = info.find("to be built:");
    ASSERT_NE(built_pos, std::string::npos)
        << "could not find the 'To be built:' line in build information";
    const std::string::size_type line_end = info.find('\n', built_pos);
    const std::string built_line = info.substr(
        built_pos,
        line_end == std::string::npos ? std::string::npos : line_end - built_pos);
    EXPECT_EQ(built_line.find("videoio"), std::string::npos)
        << "linked OpenCV lists videoio as built: " << built_line;

    for (const char* forbidden : {"ffmpeg", "gstreamer"}) {
        EXPECT_EQ(info.find(forbidden), std::string::npos)
            << "linked OpenCV build information mentions '" << forbidden << "'";
    }
}
