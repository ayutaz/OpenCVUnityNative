using System;

/// <summary>
/// ある処理が現在のスレッドで割り当てたバイト数を測る。
///
/// **GC.GetAllocatedBytesForCurrentThread() は正確である**（2026-09-05 に
/// .NET 8 で実測: new byte[4096] で delta=4120、無割り当てで delta=0）。
/// GC.GetTotalMemory と違い、回収の影響を受けず、他スレッドの割り当ても混ざらない。
///
/// **先に 1 度空回しするのは、JIT とその場限りの初期化を測らないためである。**
/// 初回だけ型の初期化子や delegate の割り当てが乗るので、それを本番の数字に
/// 含めると「0 バイト」が達成できず、閾値を緩めるしかなくなる。
/// </summary>
internal static class AllocationProbe
{
    internal static long Measure(Action action)
    {
        if (action == null) { throw new ArgumentNullException(nameof(action)); }

        // 空回し。JIT と初期化をここで済ませる。
        action();

        long before = GC.GetAllocatedBytesForCurrentThread();
        action();
        long after = GC.GetAllocatedBytesForCurrentThread();
        return after - before;
    }
}
