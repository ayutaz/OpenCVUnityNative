using System;
using System.Runtime.InteropServices;
using CvUnity;
using Xunit;

namespace CvUnity.Tests.Managed
{
    /// <summary>
    /// ポインタを直接渡す経路の検証。
    ///
    /// この経路は Unity の NativeArray をコピー無しで渡すために存在するが、
    /// 検証そのものは Unity を必要としない — ポインタであることが本質で、
    /// それが NativeArray 由来かどうかは native 側から見て区別が無いからである。
    /// したがって秒単位で回る L3 に置く。Unity 側（L4/L5）は
    /// 「TextureConverter がこの経路を使っている」ことだけを見ればよい。
    /// </summary>
    public class MatPointerBufferTests
    {
        [Fact]
        public void PointerRoundTrip_MatchesTheManagedArrayPath()
        {
            // 同じ内容を byte[] 版とポインタ版で往復させ、結果が一致することを見る。
            // 片方だけが正しい実装になっていないことの担保。
            var input = new byte[12];
            for (int i = 0; i < input.Length; i++) { input[i] = (byte)(i * 7 + 1); }

            using var viaArray = CvMat.Create(3, 4, CvMatType.Gray8);
            viaArray.CopyFrom(input, 4);
            var arrayResult = new byte[12];
            viaArray.CopyTo(arrayResult, 4);

            var unmanaged = Marshal.AllocHGlobal(input.Length);
            try
            {
                Marshal.Copy(input, 0, unmanaged, input.Length);

                using var viaPointer = CvMat.Create(3, 4, CvMatType.Gray8);
                viaPointer.CopyFrom(unmanaged, input.Length, 4);

                var pointerResult = new byte[12];
                var outBuf = Marshal.AllocHGlobal(pointerResult.Length);
                try
                {
                    viaPointer.CopyTo(outBuf, pointerResult.Length, 4);
                    Marshal.Copy(outBuf, pointerResult, 0, pointerResult.Length);
                }
                finally { Marshal.FreeHGlobal(outBuf); }

                Assert.Equal(input, pointerResult);
                Assert.Equal(arrayResult, pointerResult);
            }
            finally { Marshal.FreeHGlobal(unmanaged); }
        }

        [Fact]
        public void PointerPath_HonoursAStrideLargerThanTheRow()
        {
            // Unity のテクスチャは行が整列されていることがある。stride > 行のバイト数
            // でも正しく読めること。一括コピーの実装ならここで壊れる。
            const int rows = 3, cols = 4, stride = 8;
            var padded = new byte[stride * rows];
            for (int r = 0; r < rows; r++)
            {
                for (int c = 0; c < cols; c++) { padded[r * stride + c] = (byte)(r * 10 + c); }
            }

            var src = Marshal.AllocHGlobal(padded.Length);
            try
            {
                Marshal.Copy(padded, 0, src, padded.Length);

                using var mat = CvMat.Create(rows, cols, CvMatType.Gray8);
                mat.CopyFrom(src, padded.Length, stride);

                var tight = new byte[rows * cols];
                mat.CopyTo(tight, cols);
                for (int r = 0; r < rows; r++)
                {
                    for (int c = 0; c < cols; c++)
                    {
                        Assert.Equal((byte)(r * 10 + c), tight[r * cols + c]);
                    }
                }
            }
            finally { Marshal.FreeHGlobal(src); }
        }

        [Fact]
        public void PointerPath_IsValidatedJustLikeTheArrayPath()
        {
            // ポインタ版は marshaller の長さ検査が無いぶん、native 側の検証だけが
            // 頼りになる。byte[] 版と同じ拒否が効いていることを確かめる。
            // ここが素通りすると、呼ぶ側の計算違いがそのまま任意アドレスへの
            // 書き込みになる。
            using var mat = CvMat.Create(3, 4, CvMatType.Gray8);
            var buf = Marshal.AllocHGlobal(12);
            try
            {
                // 長さ不足
                var tooShort = Assert.Throws<CvNativeException>(
                    () => mat.CopyTo(buf, 11, 4));
                Assert.Equal(CvStatus.InvalidArgument, tooShort.Status);

                // stride が 1 行より小さい
                var narrow = Assert.Throws<CvNativeException>(
                    () => mat.CopyTo(buf, 12, 3));
                Assert.Equal(CvStatus.InvalidArgument, narrow.Status);

                // 桁あふれを狙う値（M2 のレビューで実際に踏んだ経路）
                var overflow = Assert.Throws<CvNativeException>(
                    () => mat.CopyTo(buf, 12, 1L << 62));
                Assert.Equal(CvStatus.InvalidArgument, overflow.Status);

                Assert.Throws<ArgumentNullException>(
                    () => mat.CopyTo(IntPtr.Zero, 12, 4));
            }
            finally { Marshal.FreeHGlobal(buf); }
        }
    }
}
