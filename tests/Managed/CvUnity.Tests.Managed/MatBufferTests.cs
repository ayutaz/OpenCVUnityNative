using CvUnity;
using CvUnity.Interop;
using Xunit;

namespace CvUnity.Tests.Managed
{
    public class MatBufferTests
    {
        [Fact]
        public void RoundTrip_PreservesEveryByteAcrossThePInvokeBoundary()
        {
            ulong handle;
            Assert.Equal(0, NativeMethods.ocvu_mat_create(3, 4, 0, out handle));

            var input = new byte[12];
            for (int i = 0; i < input.Length; i++) { input[i] = (byte)(i + 1); }

            Assert.Equal(0, NativeMethods.ocvu_mat_copy_from_buffer(
                handle, input, input.Length, 4));

            var output = new byte[12];
            Assert.Equal(0, NativeMethods.ocvu_mat_copy_to_buffer(
                handle, output, output.Length, 4));

            Assert.Equal(input, output);
            Assert.Equal(0, NativeMethods.ocvu_mat_release(handle));
        }

        [Fact]
        public void OversizedStride_IsRejectedRatherThanWritingPastTheArray()
        {
            // managed の配列を踏み越えると CLR のヒープが壊れる。native 側の検証が
            // P/Invoke 越しにも効いていることを確認する。落ちたらこのテストは
            // 失敗ではなくプロセスごと死ぬので、緑であること自体が結果である。
            ulong handle;
            Assert.Equal(0, NativeMethods.ocvu_mat_create(3, 4, 0, out handle));

            var small = new byte[12];
            var status = (CvStatus)NativeMethods.ocvu_mat_copy_to_buffer(
                handle, small, small.Length, 64);

            Assert.Equal(CvStatus.InvalidArgument, status);
            Assert.Equal(0, NativeMethods.ocvu_mat_release(handle));
        }

        [Fact]
        public void ShortBuffer_IsRejectedAndLeavesTheArrayUnchanged()
        {
            ulong handle;
            Assert.Equal(0, NativeMethods.ocvu_mat_create(3, 4, 0, out handle));

            var tooSmall = new byte[11];
            for (int i = 0; i < tooSmall.Length; i++) { tooSmall[i] = 0x5A; }

            var status = (CvStatus)NativeMethods.ocvu_mat_copy_to_buffer(
                handle, tooSmall, tooSmall.Length, 4);

            Assert.Equal(CvStatus.InvalidArgument, status);
            Assert.All(tooSmall, b => Assert.Equal(0x5A, b));
            Assert.Equal(0, NativeMethods.ocvu_mat_release(handle));
        }
    }
}
