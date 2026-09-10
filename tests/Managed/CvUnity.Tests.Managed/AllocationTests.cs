using System;
using System.Runtime.InteropServices;
using CvUnity;
using Xunit;

/// <summary>
/// 境界を越えるときの割り当てを assert する。
///
/// **時間は測らない**（設計 D1）—— 共有 CI ランナーの上で時間を assert すると
/// 必ずフレークになり、閾値を緩めればその検査は何も見ていない。
/// **割り当ては決定的なので assert できる。**
///
/// **測定器そのものが壊れたときに落ちる形にしてある**（設計 D2）——
/// 「0 バイトだった」は、測れていないときにも出る。だから
/// **byte[] 経路が割り当てることも同時に要求する。**
/// </summary>
public class AllocationTests
{
    private const int Rows = 64;
    private const int Cols = 64;
    private const int Channels = 4;
    private const int ByteCount = Rows * Cols * Channels;

    [Fact]
    public void PointerCopyFromAllocatesNothing()
    {
        var source = new byte[ByteCount];
        var handle = GCHandle.Alloc(source, GCHandleType.Pinned);
        try
        {
            IntPtr ptr = handle.AddrOfPinnedObject();
            using var mat = CvMat.Create(Rows, Cols, CvMatType.Bgra32);

            long allocated = AllocationProbe.Measure(
                () => mat.CopyFrom(ptr, ByteCount, Cols * Channels));

            Assert.Equal(0, allocated);
        }
        finally { handle.Free(); }
    }

    [Fact]
    public void PointerCopyToAllocatesNothing()
    {
        var destination = new byte[ByteCount];
        var handle = GCHandle.Alloc(destination, GCHandleType.Pinned);
        try
        {
            IntPtr ptr = handle.AddrOfPinnedObject();
            using var mat = CvMat.Create(Rows, Cols, CvMatType.Bgra32);

            long allocated = AllocationProbe.Measure(
                () => mat.CopyTo(ptr, ByteCount, Cols * Channels));

            Assert.Equal(0, allocated);
        }
        finally { handle.Free(); }
    }

    /// <summary>
    /// **これは測定器の負の対照である。**
    ///
    /// 上の 2 件が「0 バイト」で通るのは、(1) 本当に割り当てていないか、
    /// (2) 測定器が壊れて常に 0 を返すか、のどちらかである。
    /// **この 1 件が割り当てを検出することで、(2) を排除する。**
    ///
    /// 落ちるのは 2 つの場合で、**どちらも知りたいことである**:
    /// 測定器が死んだか、byte[] 経路が消えたか。
    /// </summary>
    [Fact]
    public void ByteArrayCopyFromAllocatesTheBuffer()
    {
        using var mat = CvMat.Create(Rows, Cols, CvMatType.Bgra32);

        long allocated = AllocationProbe.Measure(
            () =>
            {
                var buffer = new byte[ByteCount];
                mat.CopyFrom(buffer, Cols * Channels);
            });

        // 配列そのもの（ByteCount）に加えてオブジェクトヘッダが乗る。
        // 下限だけを見る —— 上限を書くと実装の詳細に縛られる。
        Assert.True(
            allocated >= ByteCount,
            $"byte[] 経路が {ByteCount} バイト以上を割り当てるはずが {allocated} だった。" +
            "測定器が壊れているか、この経路が消えている");
    }

    /// <summary>
    /// **測定器が「何も測っていない」状態を直接排除する。**
    ///
    /// 上の 3 件は CvMat を通るので、境界の側の変更でも落ちうる。
    /// この 1 件は CvMat に触れず、**AllocationProbe だけを見る。**
    /// </summary>
    [Fact]
    public void TheProbeItselfSeesAnAllocation()
    {
        long allocated = AllocationProbe.Measure(() => { var _ = new byte[4096]; });
        Assert.True(allocated >= 4096, $"probe が 4096 バイトを見落とした（{allocated}）");

        long nothing = AllocationProbe.Measure(() => { });
        Assert.Equal(0, nothing);
    }
}
