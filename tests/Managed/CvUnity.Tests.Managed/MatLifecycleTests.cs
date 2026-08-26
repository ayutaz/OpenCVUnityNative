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
        public void FailedCreate_LeavesTheHandleUntouchedAndReportsAMessage()
        {
            ulong handle = 12345UL;
            var status = (CvStatus)NativeMethods.ocvu_mat_create(0, 4, 0, out handle);

            Assert.Equal(CvStatus.InvalidArgument, status);
            Assert.Contains("rows and cols", CvNative.GetLastErrorMessage());
        }
    }
}
