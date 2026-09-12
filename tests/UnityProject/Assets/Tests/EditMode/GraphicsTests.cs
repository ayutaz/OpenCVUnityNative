using System.Linq;
using System.Reflection;
using CvUnity.Tests.Shared;
using NUnit.Framework;

/// <summary>
/// GPU に依る検査の入口。検証の本体は <see cref="GraphicsChecks"/> にある。
/// **ここに検証を書かないこと。**
///
/// **PlayMode 側に対を作らない。** Player（`test-unity-player` /
/// `ci-unity.yml` の Standalone レーン）は `-nographics` で起動するため、
/// GPU に依る検査は原理的に通らない（下の実測と同じ理由）。
/// `RenderTextureChecks` は GPU に依らない部分（`FillFlipped`）を純粋関数
/// として切り出してあるので Player 側に対（`RenderTexturePlayerTests`）を
/// 持てるが、`GraphicsChecks` にはその切り出しが無く、対を作りようがない。
///
/// **`-nographics` を付けないレーンからだけ走る。** ローカルの
/// `test-unity-graphics` と、**CI の `Graphics` レーン**（`ci-unity.yml`、
/// 2026-09-11 から）の 2 つである。既存の EditMode / PlayMode レーンは
/// `-nographics` で起動するため、ここに置いた検査は常に失敗する
/// （`GL.Clear` が効かず 205,205,205 が返る、実測）。
/// **CI の `Graphics` レーンは必須チェックではない** ——
/// `CiVisibilityTests` がその帰結（ここに置いたテストは merge を止めない）を
/// 台帳として固定している。
///
/// **`[Category("Graphics")]` で振り分ける。** 改訂は
/// `-testFilter 'GraphicsChecks'` と書いていたが、それは検証本体
/// （`GraphicsChecks`、`[Test]` を持たない）の名前であって、Unity が
/// フィルタするテストの FullName（`GraphicsTests.<メソッド名>`）には
/// 現れない —— 文字どおりに渡すと 0 件になる（実測）。加えて
/// `-testFilter` は選ぶ側にしか効かず、**既存の `test-unity-editmode`
/// からこのクラスを除外する手段にならない**。そちらを直さないと、
/// 今回足したこのクラスのせいで既存レーンが `-nographics` の下で
/// 落ちるようになる（`AGraphicsDeviceIsPresent` から）。
/// そこで `tools/dev.ps1` 側は `-testCategory 'Graphics'`（このレーン）と
/// `-testCategory '!Graphics'`（既存の EditMode レーン）で振り分ける。
/// </summary>
[Category("Graphics")]
public class GraphicsTests
{
    [Test] public void AGraphicsDeviceIsPresent() => GraphicsChecks.AGraphicsDeviceIsPresent();
    [Test] public void SyncReadbackProducesTheExpectedPixels() => GraphicsChecks.SyncReadbackProducesTheExpectedPixels();
    [Test] public void VerticalFlipIsApplied() => GraphicsChecks.VerticalFlipIsApplied();
    [Test] public void AsyncMatchesSync() => GraphicsChecks.AsyncMatchesSync();
    [Test] public void TakingTheMatTwiceIsRejected() => GraphicsChecks.TakingTheMatTwiceIsRejected();

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
        var shared = typeof(GraphicsChecks)
            .GetMethods(BindingFlags.Public | BindingFlags.Static)
            .Where(m => m.ReturnType == typeof(void) && m.GetParameters().Length == 0)
            .Select(m => m.Name).ToList();
        Assert.Greater(shared.Count, 1, "共有本体の検査が拾えていない");

        var wired = typeof(GraphicsTests)
            .GetMethods(BindingFlags.Public | BindingFlags.Instance)
            .Select(m => m.Name).ToList();

        var missing = shared.Where(n => !wired.Contains(n)).ToList();
        Assert.IsEmpty(missing,
            "共有本体に在るのに、この入口に配線されていない検査: " + string.Join(", ", missing));
    }
}
