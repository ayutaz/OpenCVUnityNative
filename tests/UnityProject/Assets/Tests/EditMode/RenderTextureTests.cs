using System.Linq;
using System.Reflection;
using CvUnity.Tests.Shared;
using NUnit.Framework;

/// <summary>
/// Editor (Mono) 側の入口。検証の本体は <see cref="RenderTextureChecks"/> にある。
/// **ここに検証を書かないこと** —— Player 側と同じものを見ていることが、
/// この 2 ファイルの唯一の役目である。
///
/// **GPU に依らない検査だけをここで走らせる。** このレーンは
/// `-batchmode -nographics` で走るため、`RenderTexture.Create()` は
/// true を返すのに実際には何も描画されない（実測、2026-09-05）。
/// GPU に依る検査は `GraphicsTests`（`test-unity-graphics` レーン）にある。
/// </summary>
public class RenderTextureTests
{
    [Test] public void FillFlippedPutsTheTopRowFirst() => RenderTextureChecks.FillFlippedPutsTheTopRowFirst();
    [Test] public void FillFlippedPreservesEveryByte() => RenderTextureChecks.FillFlippedPreservesEveryByte();
    [Test] public void ToMatRejectsNull() => RenderTextureChecks.ToMatRejectsNull();

    /// <summary>
    /// 共有本体に在るのに、この入口に配線されていない検査を名指しで落とす。
    ///
    /// 手書きの配線は書き忘れる。書き忘れても assembly はレーンに在るので、
    /// 「どのレーンからも走らないテスト」を探す grep には掛からない
    /// （prove-a-check-works skill の §5）。
    /// </summary>
    [Test]
    public void EveryCheckInTheSharedBodyIsWiredIntoThisEntryPoint()
    {
        var shared = typeof(RenderTextureChecks)
            .GetMethods(BindingFlags.Public | BindingFlags.Static)
            .Where(m => m.ReturnType == typeof(void) && m.GetParameters().Length == 0)
            .Select(m => m.Name).ToList();
        Assert.Greater(shared.Count, 1, "共有本体の検査が拾えていない");

        var wired = typeof(RenderTextureTests)
            .GetMethods(BindingFlags.Public | BindingFlags.Instance)
            .Select(m => m.Name).ToList();

        var missing = shared.Where(n => !wired.Contains(n)).ToList();
        Assert.IsEmpty(missing,
            "共有本体に在るのに、この入口に配線されていない検査: " + string.Join(", ", missing));
    }
}
