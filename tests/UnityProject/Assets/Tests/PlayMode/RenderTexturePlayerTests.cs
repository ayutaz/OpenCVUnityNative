using System.Linq;
using System.Reflection;
using CvUnity.Tests.Shared;
using NUnit.Framework;

/// <summary>
/// Player (IL2CPP) 側の入口。検証の本体は <see cref="RenderTextureChecks"/> にある。
/// **ここに検証を書かないこと** —— EditMode（<c>RenderTextureTests</c>）と
/// 同じものを見ていることが、この入口の唯一の役目である。
///
/// **`FillFlipped` はこのブランチが足した唯一の実質的な新規 CPU 経路である**
/// （`unsafe` + `GetUnsafeReadOnlyPtr` + `Buffer.MemoryCopy` + `Allocator.Temp`
/// という、IL2CPP で確かめる価値が最も高い形をしている）。GPU に依らない
/// 部分として純粋関数に切り出した目的が、まさに「既存レーンで検証できる
/// ようにする」ことだった。EditMode 側にだけ配線して Player 側を欠いたままでは、
/// その目的が達成されないまま達成されたように見える文書だけが残る。
///
/// **`GraphicsChecks` の対はここに作らない。** Player は `-nographics` で
/// 起動するため、GPU に依る検査は原理的に通らない（`GraphicsTests` の
/// docstring 参照）。`RenderTextureChecks` は `FillFlipped` を GPU に依らない
/// 形へ切り出してあるので、こちらだけが Player 側の対を持てる。
///
/// **`allowUnsafeCode: false` のまま呼べる。** `FillFlipped` の signature に
/// ポインタ型は無く、unsafe な取得は <c>CvUnity.Unity.RenderTextureConverter</c>
/// （`allowUnsafeCode: true`）側に閉じている。
/// </summary>
public class RenderTexturePlayerTests
{
    [Test] public void FillFlippedPutsTheTopRowFirst() => RenderTextureChecks.FillFlippedPutsTheTopRowFirst();
    [Test] public void FillFlippedPreservesEveryByte() => RenderTextureChecks.FillFlippedPreservesEveryByte();
    [Test] public void ToMatRejectsNull() => RenderTextureChecks.ToMatRejectsNull();

    /// <summary>
    /// 共有本体に在るのに、この入口に配線されていない検査を名指しで落とす。
    /// EditMode 側（<c>RenderTextureTests</c>）と同じ検査である。
    /// </summary>
    [Test]
    public void EveryCheckInTheSharedBodyIsWiredIntoThisEntryPoint()
    {
        var shared = typeof(RenderTextureChecks)
            .GetMethods(BindingFlags.Public | BindingFlags.Static)
            .Where(m => m.ReturnType == typeof(void) && m.GetParameters().Length == 0)
            .Select(m => m.Name).ToList();
        Assert.Greater(shared.Count, 1, "共有本体の検査が拾えていない");

        var wired = typeof(RenderTexturePlayerTests)
            .GetMethods(BindingFlags.Public | BindingFlags.Instance)
            .Select(m => m.Name).ToList();

        var missing = shared.Where(n => !wired.Contains(n)).ToList();
        Assert.IsEmpty(missing,
            "共有本体に在るのに、この入口に配線されていない検査: " + string.Join(", ", missing));
    }
}
