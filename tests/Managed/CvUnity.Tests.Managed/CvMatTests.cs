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
            // using と明示の Dispose を併用している。using は「Assert が落ちたとき
            // にも handle を返す」ためだけのもので、確かめたいのは下の 2 回の
            // Dispose である（using だけにすると、このテストは何も検証しなくなる）。
            // Dispose は冪等なので 3 回目にあたる using 側の解放も無害である。
            using var mat = CvMat.Create(2, 3, CvMatType.Gray8);
            Assert.Equal(2, mat.Rows);
            Assert.Equal(3, mat.Cols);

            mat.Dispose();
            mat.Dispose();  // 二重 Dispose は例外にならない（IDisposable の規約）
        }

        [Fact]
        public void UsingAfterDispose_ThrowsObjectDisposedRatherThanReachingNative()
        {
            // ここは using を足さない。Create の直後に Dispose しており、その間に
            // 落ちる余地が無いので、解放され損ねる経路が存在しない。
            var mat = CvMat.Create(2, 2, CvMatType.Gray8);
            mat.Dispose();

            // 破棄済みの Mat に触れること自体が検証対象なので、値は捨てる。
            // `var _ =` と書くと本物のローカル変数になり「使われない代入」に
            // 見えてしまうため、破棄子（discard）で受ける。
            Assert.Throws<ObjectDisposedException>(() => { _ = mat.Rows; });
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
