using System.Runtime.InteropServices;
using Xunit;

namespace CvUnity.Tests.Managed
{
    /// <summary>
    /// このクラスは「意図的に落ちる」ためのものであり、通常の test 実行には
    /// 含めない（含めると常に赤くなる）。tools/run-managed-probe.ps1 が
    /// フィルタで名指しして起動し、落ちることそのものを確認する。
    /// </summary>
    public class HarnessProbeTests
    {
        [DllImport("opencv_unity_native", CallingConvention = CallingConvention.Cdecl)]
        private static extern void ocvu_debug_crash(int kind);

        [Fact]
        [Trait("Category", "Probe")]
        public void Probe_NativeSegfault()
        {
            ocvu_debug_crash(0);
        }

        [Fact]
        [Trait("Category", "Probe")]
        public void Probe_NativeHang()
        {
            ocvu_debug_crash(1);
        }
    }
}
