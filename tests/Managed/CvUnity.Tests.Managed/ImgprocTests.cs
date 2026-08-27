using CvUnity;
using CvUnity.Interop;
using Xunit;

namespace CvUnity.Tests.Managed
{
    public class ImgprocTests
    {
        [Fact]
        public void CvtColor_BgrToGray_ProducesTheExpectedBytes()
        {
            ulong src, dst;
            Assert.Equal(0, NativeMethods.ocvu_mat_create(2, 2, 16, out src));
            Assert.Equal(0, NativeMethods.ocvu_mat_create(1, 1, 0, out dst));

            var white = new byte[2 * 2 * 3];
            for (int i = 0; i < white.Length; i++) { white[i] = 255; }
            Assert.Equal(0, NativeMethods.ocvu_mat_copy_from_buffer(
                src, white, white.Length, 6));

            Assert.Equal(0, NativeMethods.ocvu_cvt_color(src, dst, 6));

            var gray = new byte[4];
            Assert.Equal(0, NativeMethods.ocvu_mat_copy_to_buffer(dst, gray, 4, 2));
            Assert.All(gray, b => Assert.Equal(255, b));

            NativeMethods.ocvu_mat_release(src);
            NativeMethods.ocvu_mat_release(dst);
        }

        [Fact]
        public void OpenCvFailure_SurfacesAsOpenCvErrorWithAMessage()
        {
            // 例外が P/Invoke フレームへ unwind すると CLR ごと落ちる。緑であること
            // 自体が「例外が境界を越えていない」ことの結果である。
            ulong src, dst;
            Assert.Equal(0, NativeMethods.ocvu_mat_create(2, 2, 0, out src));
            Assert.Equal(0, NativeMethods.ocvu_mat_create(1, 1, 0, out dst));

            var status = (CvStatus)NativeMethods.ocvu_cvt_color(src, dst, 6);

            Assert.Equal(CvStatus.OpenCvError, status);
            Assert.NotEmpty(CvNative.GetLastErrorMessage());

            NativeMethods.ocvu_mat_release(src);
            NativeMethods.ocvu_mat_release(dst);
        }

        [Fact]
        public void Resize_MapsWidthToColsAndHeightToRows()
        {
            // 幅と高さの取り違えは、正方形の画像でテストすると永久に気づけない。
            // 非正方形で固定する。
            ulong src, dst;
            Assert.Equal(0, NativeMethods.ocvu_mat_create(4, 4, 0, out src));
            Assert.Equal(0, NativeMethods.ocvu_mat_create(1, 1, 0, out dst));

            Assert.Equal(0, NativeMethods.ocvu_resize(src, dst, 2, 8, 1));

            OcvuMatInfo info;
            Assert.Equal(0, NativeMethods.ocvu_mat_get_info(dst, out info));
            Assert.Equal(2, info.Cols);
            Assert.Equal(8, info.Rows);

            NativeMethods.ocvu_mat_release(src);
            NativeMethods.ocvu_mat_release(dst);
        }
    }
}
