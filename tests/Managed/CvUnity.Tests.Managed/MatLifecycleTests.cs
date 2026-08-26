using CvUnity;
using CvUnity.Interop;
using Xunit;

namespace CvUnity.Tests.Managed
{
    public class MatLifecycleTests
    {
        [Fact]
        public void ReleasedHandle_IsRejectedAcrossThePInvokeBoundary()
        {
            // C ABI が落ちないことは L1 が見ている。ここで見たいのは、その status が
            // P/Invoke 越しにそのまま観測でき、managed 側が例外に変換できることである。
            ulong handle;
            Assert.Equal(0, NativeMethods.ocvu_mat_create(2, 2, 0, out handle));
            Assert.NotEqual(0UL, handle);

            Assert.Equal(0, NativeMethods.ocvu_mat_release(handle));

            var second = (CvStatus)NativeMethods.ocvu_mat_release(handle);
            Assert.Equal(CvStatus.InvalidHandle, second);
            Assert.True(CvNative.IsFailure(second));
        }

        [Fact]
        public void MatInfo_MarshalsWithTheSameLayoutAsNative()
        {
            // struct の layout がずれると値が黙って壊れる。native 側で計算できる
            // 関係（total_bytes == step * rows）を managed 側で照合して検出する。
            ulong handle;
            Assert.Equal(0, NativeMethods.ocvu_mat_create(4, 6, 16, out handle));

            OcvuMatInfo info;
            Assert.Equal(0, NativeMethods.ocvu_mat_get_info(handle, out info));

            Assert.Equal(4, info.Rows);
            Assert.Equal(6, info.Cols);
            Assert.Equal(3, info.Channels);
            Assert.Equal(18, info.Step);
            Assert.Equal(info.Step * info.Rows, info.TotalBytes);

            Assert.Equal(0, NativeMethods.ocvu_mat_release(handle));
        }

        [Fact]
        public void ZeroHandle_IsInvalidRatherThanCrashingTheRuntime()
        {
            // ゼロ初期化した変数をそのまま渡す誤りは managed 側で起きやすい。
            OcvuMatInfo info;
            Assert.Equal((int)CvStatus.InvalidHandle,
                NativeMethods.ocvu_mat_get_info(0UL, out info));
        }

        [Fact]
        public void FailedCreate_ReportsAMessageAndYieldsNoUsableHandle()
        {
            // 「out 引数が触られていないこと」はここでは検証できない。C# の out は
            // 呼び出し前の値を必ず破棄するので、native が書かなかったことと
            // marshaller が既定値を入れたことを managed 側から区別する手段が無い。
            // その検証は L1 の InvalidDimensionsAreRejected が持っている
            // （native の視点でしか意味を成さない）。
            //
            // ここで確かめられるのは、失敗が失敗として観測でき、理由が読め、
            // 返ってきた値が handle として通用しないことである。
            ulong handle;
            var status = (CvStatus)NativeMethods.ocvu_mat_create(0, 4, 0, out handle);

            Assert.Equal(CvStatus.InvalidArgument, status);
            Assert.Contains("rows and cols", CvNative.GetLastErrorMessage());

            // 失敗した create の戻り値を使い回そうとしても、生きた Mat には
            // 決して当たらない。ここが通ってしまうと、失敗を無視した呼び出し側が
            // 他人の Mat を掴むことになる。
            OcvuMatInfo info;
            Assert.Equal((int)CvStatus.InvalidHandle,
                NativeMethods.ocvu_mat_get_info(handle, out info));
        }
    }
}
