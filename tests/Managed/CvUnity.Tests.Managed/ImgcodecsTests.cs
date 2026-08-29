using System;
using System.Text;
using CvUnity;
using CvUnity.Interop;
using Xunit;

namespace CvUnity.Tests.Managed
{
    /// <summary>
    /// L3。P/Invoke 越しに encode / decode の契約を確かめる。
    ///
    /// **ここが見るのは C ABI の呼び方であって、OpenCV の正しさではない。**
    /// 画素の一致は L1 が見ている。ここで確かめたいのは、2 回呼びの作法が
    /// managed 側から正しく使えること、buffer の marshalling が壊れていないこと、
    /// そして <see cref="CvCodecs"/> がそれを隠しても契約が崩れないことである。
    /// </summary>
    public class ImgcodecsTests
    {
        private const int Bgr24 = 16;
        private const int Gray8 = 0;
        private const int StatusOk = 0;
        private const int StatusInvalidArgument = 1;
        private const int StatusNullPointer = 2;
        private const int StatusOpenCvError = 4;
        private const int StatusBufferTooSmall = 6;
        private const int StatusInvalidHandle = 7;

        private static byte[] Ext(string value)
        {
            var count = Encoding.UTF8.GetByteCount(value);
            var bytes = new byte[count + 1];
            Encoding.UTF8.GetBytes(value, 0, value.Length, bytes, 0);
            bytes[count] = 0;
            return bytes;
        }

        private static ulong MakeKnownBgr()
        {
            Assert.Equal(StatusOk, NativeMethods.ocvu_mat_create(4, 4, Bgr24, out var src));
            var pixels = new byte[4 * 4 * 3];
            pixels[0] = 10;
            pixels[1] = 20;
            pixels[2] = 30;
            Assert.Equal(StatusOk, NativeMethods.ocvu_mat_copy_from_buffer(
                src, pixels, pixels.Length, 4 * 3));
            return src;
        }

        [Fact]
        public void Imencode_SizeQuery_ReportsBufferTooSmallWhichIsNotAFailure()
        {
            var src = MakeKnownBgr();
            try
            {
                var status = NativeMethods.ocvu_imencode(src, Ext(".png"), null, 0, out var required);
                // **この status は失敗ではない。** 1 回目の問い合わせの正常な結果である。
                Assert.Equal(StatusBufferTooSmall, status);
                Assert.True(required > 0, "必要サイズが返ること");
            }
            finally
            {
                NativeMethods.ocvu_mat_release(src);
            }
        }

        [Fact]
        public void Imencode_ThenImdecode_RoundTripsThroughPInvoke()
        {
            var src = MakeKnownBgr();
            Assert.Equal(StatusOk, NativeMethods.ocvu_mat_create(1, 1, Gray8, out var dst));
            try
            {
                Assert.Equal(StatusBufferTooSmall,
                    NativeMethods.ocvu_imencode(src, Ext(".png"), null, 0, out var required));

                var blob = new byte[required];
                Assert.Equal(StatusOk,
                    NativeMethods.ocvu_imencode(src, Ext(".png"), blob, blob.Length, out var written));
                Assert.Equal(required, written);

                Assert.Equal(StatusOk,
                    NativeMethods.ocvu_imdecode(blob, blob.LongLength, 1 /* COLOR */, dst));

                Assert.Equal(StatusOk, NativeMethods.ocvu_mat_get_info(dst, out var info));
                Assert.Equal(4, info.Rows);
                Assert.Equal(4, info.Cols);
                Assert.Equal(3, info.Channels);
            }
            finally
            {
                NativeMethods.ocvu_mat_release(src);
                NativeMethods.ocvu_mat_release(dst);
            }
        }

        [Fact]
        public void Imencode_TooSmallBuffer_LeavesItUntouched()
        {
            var src = MakeKnownBgr();
            try
            {
                Assert.Equal(StatusBufferTooSmall,
                    NativeMethods.ocvu_imencode(src, Ext(".png"), null, 0, out var required));
                Assert.True(required > 1);

                var tooSmall = new byte[required - 1];
                for (int i = 0; i < tooSmall.Length; i++) { tooSmall[i] = 0xAB; }

                Assert.Equal(StatusBufferTooSmall, NativeMethods.ocvu_imencode(
                    src, Ext(".png"), tooSmall, tooSmall.Length, out var reported));
                Assert.Equal(required, reported);
                Assert.All(tooSmall, b => Assert.Equal(0xAB, b));
            }
            finally
            {
                NativeMethods.ocvu_mat_release(src);
            }
        }

        [Fact]
        public void Imencode_RejectsBadArguments()
        {
            var src = MakeKnownBgr();
            try
            {
                Assert.Equal(StatusNullPointer,
                    NativeMethods.ocvu_imencode(src, null, null, 0, out _));
                Assert.Equal(StatusInvalidArgument,
                    NativeMethods.ocvu_imencode(src, Ext(string.Empty), null, 0, out _));
                Assert.Equal(StatusInvalidArgument,
                    NativeMethods.ocvu_imencode(src, Ext(".png"), null, -1, out _));
                Assert.Equal(StatusOpenCvError,
                    NativeMethods.ocvu_imencode(src, Ext(".notanimage"), null, 0, out _));
                Assert.Equal(StatusInvalidHandle,
                    NativeMethods.ocvu_imencode(0, Ext(".png"), null, 0, out _));
            }
            finally
            {
                NativeMethods.ocvu_mat_release(src);
            }
        }

        [Fact]
        public void Imdecode_RejectsBadArguments()
        {
            Assert.Equal(StatusOk, NativeMethods.ocvu_mat_create(1, 1, Gray8, out var dst));
            try
            {
                var bytes = new byte[] { 1, 2, 3, 4, 5, 6, 7, 8 };
                Assert.Equal(StatusNullPointer, NativeMethods.ocvu_imdecode(null, 8, 1, dst));
                Assert.Equal(StatusInvalidArgument, NativeMethods.ocvu_imdecode(bytes, 0, 1, dst));
                Assert.Equal(StatusInvalidArgument, NativeMethods.ocvu_imdecode(bytes, -1, 1, dst));
                Assert.Equal(StatusInvalidHandle, NativeMethods.ocvu_imdecode(bytes, 8, 1, 0));
                // 画像ではない byte 列。**落とさずに status で断ること。**
                Assert.Equal(StatusOpenCvError, NativeMethods.ocvu_imdecode(bytes, 8, 1, dst));
            }
            finally
            {
                NativeMethods.ocvu_mat_release(dst);
            }
        }

        [Fact]
        public void CvCodecs_HidesTheTwoCallIdiom()
        {
            using var src = CvMat.Create(4, 4, CvMatType.Bgr24);
            var pixels = new byte[4 * 4 * 3];
            pixels[0] = 10;
            pixels[1] = 20;
            pixels[2] = 30;
            src.CopyFrom(pixels, 4 * 3);

            var blob = CvCodecs.Encode(src, ".png");
            Assert.True(blob.Length > 0);

            using var decoded = CvCodecs.Decode(blob, CvCodecs.ImreadColor);
            Assert.Equal(4, decoded.Rows);
            Assert.Equal(4, decoded.Cols);
            Assert.Equal(3, decoded.Channels);
        }

        [Fact]
        public void CvCodecs_Encode_ThrowsOnAnExtensionOpenCvCannotWrite()
        {
            using var src = CvMat.Create(2, 2, CvMatType.Bgr24);
            // **失敗を握り潰さない。** サイズ問い合わせの段で分かる。
            Assert.Throws<CvNativeException>(() => CvCodecs.Encode(src, ".notanimage"));
        }

        [Fact]
        public void CvCodecs_Decode_ThrowsOnGarbage()
        {
            Assert.Throws<CvNativeException>(
                () => CvCodecs.Decode(new byte[] { 1, 2, 3, 4 }, CvCodecs.ImreadColor));
        }
    }
}
