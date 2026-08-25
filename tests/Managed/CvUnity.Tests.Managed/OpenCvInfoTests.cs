using CvUnity;
using Xunit;

namespace CvUnity.Tests.Managed
{
    public class OpenCvInfoTests
    {
        [Fact]
        public void OpenCvVersion_MatchesThePinnedVersion()
        {
            Assert.Equal("5.0.0", CvNative.OpenCvVersion);
        }

        [Fact]
        public void BuildInformation_CrossesTheBoundaryIntact()
        {
            var info = CvNative.GetBuildInformation();

            Assert.Contains("OpenCV", info);
            Assert.DoesNotContain('\0', info);
        }

        /// <summary>
        /// 依存 allowlist を実行時のバイナリに対して検査する。
        /// ビルドスクリプトの意図ではなく、実際にリンクされた構成を見る。
        ///
        /// 実際の cv::getBuildInformation() を確認したところ（native/tests/
        /// test_opencv_link.cpp の同名テストの根拠を参照）、videoio モジュール
        /// 自体が "Disabled by dependency" に落ちているため、
        /// "FFMPEG:                      YES" のような列揃えの行はそもそも
        /// 出力に現れない。その形を探す検査は何ともマッチしないまま常に通り、
        /// 検証しているように見えて実は何も見ていないことになる。
        /// 代わりに、videoio が "To be built:" に含まれないこと（根本原因）と、
        /// 出力全体に ffmpeg / gstreamer という文字列が現れないこと
        /// （列揃えに依存しない、その結果の確認）の 2 段で検査する。
        /// </summary>
        [Fact]
        public void LinkedOpenCv_DoesNotEnableForbiddenDependencies()
        {
            var info = CvNative.GetBuildInformation().ToLowerInvariant();

            const string builtMarker = "to be built:";
            var builtIndex = info.IndexOf(builtMarker, System.StringComparison.Ordinal);
            Assert.True(builtIndex >= 0, "could not find the 'To be built:' line in build information");

            var lineEnd = info.IndexOf('\n', builtIndex);
            var builtLine = lineEnd < 0
                ? info.Substring(builtIndex)
                : info.Substring(builtIndex, lineEnd - builtIndex);
            Assert.DoesNotContain("videoio", builtLine);

            Assert.DoesNotContain("ffmpeg", info);
            Assert.DoesNotContain("gstreamer", info);
        }
    }
}
