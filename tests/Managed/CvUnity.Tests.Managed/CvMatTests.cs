using System;
using CvUnity;
using Xunit;

namespace CvUnity.Tests.Managed
{
    public class CvMatTests
    {
        [Fact]
        public void Dispose_ReleasesTheHandleAndASecondDisposeIsHarmless()
        {
            var mat = CvMat.Create(2, 3, CvMatType.Gray8);
            Assert.Equal(2, mat.Rows);
            Assert.Equal(3, mat.Cols);

            mat.Dispose();
            mat.Dispose();  // 二重 Dispose は例外にならない（IDisposable の規約）
        }

        [Fact]
        public void UsingAfterDispose_ThrowsObjectDisposedRatherThanReachingNative()
        {
            var mat = CvMat.Create(2, 2, CvMatType.Gray8);
            mat.Dispose();

            Assert.Throws<ObjectDisposedException>(() => { var _ = mat.Rows; });
            Assert.Throws<ObjectDisposedException>(() => mat.CopyTo(new byte[4], 2));
        }

        [Fact]
        public void CopyFromAndCopyTo_RoundTrip()
        {
            using var mat = CvMat.Create(2, 2, CvMatType.Gray8);
            var input = new byte[] { 1, 2, 3, 4 };
            mat.CopyFrom(input, 2);

            var output = new byte[4];
            mat.CopyTo(output, 2);
            Assert.Equal(input, output);
        }

        [Fact]
        public void CreateWithInvalidSize_ThrowsWithTheNativeMessage()
        {
            var ex = Assert.Throws<CvNativeException>(
                () => CvMat.Create(0, 2, CvMatType.Gray8));
            Assert.Equal(CvStatus.InvalidArgument, ex.Status);
        }
    }
}
