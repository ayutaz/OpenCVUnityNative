using System.Collections;
using System.Diagnostics;
using CvUnity.Unity;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

/// <summary>
/// GPU に依る経路（RenderTexture）の所要時間を測る（M7a Task 4）。
///
/// **`test-unity-graphics` レーンからだけ走る。** <see cref="GraphicsTests"/>
/// と同じ仕組みで <c>[Category("Graphics")]</c> を付け、既存の
/// <c>test-unity-editmode</c>（<c>-testCategory '!Graphics'</c>）からは
/// 除外される。**controller の改訂は <c>-testFilter</c> を指定していたが、
/// それは Task 2 が実測で崩している** —— <c>-testFilter</c> は Unity が
/// フィルタするテストの FullName（<c>クラス名.メソッド名</c>）にしか効かず、
/// 検証本体クラス（<c>[Test]</c> を持たない）の名前では 0 件になる。
/// <see cref="GraphicsTests"/> が確立した <c>[Category("Graphics")]</c> +
/// <c>-testCategory</c> にそのまま合わせた。
///
/// **assert しない**（設計 D1）。落ちるのは測れなかったときだけ。
/// 出力の型・収集経路は <see cref="BenchmarkRunner"/>（PlayMode 側）と同じ。
/// </summary>
[Category("Graphics")]
public class GraphicsBenchmarkRunner
{
    private const int Size = 512;
    private const int Iterations = 30;

    [UnityTest]
    public IEnumerator MeasureRenderTexturePaths()
    {
        yield return null;

        var tex = new Texture2D(Size, Size, TextureFormat.RGBA32, mipChain: false);
        tex.Apply();

        var rt = new RenderTexture(Size, Size, 0, RenderTextureFormat.ARGB32);
        rt.Create();
        Graphics.Blit(tex, rt);

        try
        {
            Report("rendertexture_sync", () => { using var m = RenderTextureConverter.ToMat(rt); });

            // 依頼してから WaitAllRequests で待ち、Mat を取り出すところまでを
            // 1 回として測る。「依頼するだけ」を単独で測ると、後始末（Dispose
            // すべき CvMat が残る、outstanding な readback が rt の破棄と
            // 競合しうる）が安全に取れない。GPU を待たせない価値そのものは
            // ここでは数字にしない —— 測るのは「非同期経路の総コスト」であり、
            // 同期経路との差は docs/performance.md（Task 6）の解釈に委ねる。
            Report("rendertexture_async_request", () =>
            {
                var r = RenderTextureConverter.RequestMat(rt);
                UnityEngine.Rendering.AsyncGPUReadback.WaitAllRequests();
                using var m = r.TakeMat();
            });
        }
        finally
        {
            rt.Release();
            Object.DestroyImmediate(rt);
            Object.DestroyImmediate(tex);
        }

        yield return null;
    }

    private static void Report(string name, System.Action action)
    {
        for (int i = 0; i < 5; i++) { action(); }

        var sw = Stopwatch.StartNew();
        for (int i = 0; i < Iterations; i++) { action(); }
        sw.Stop();

        long microsPerCall = sw.ElapsedTicks * 1_000_000L / Stopwatch.Frequency / Iterations;

        Assert.Greater(microsPerCall, 0,
            $"{name} の所要時間が 0 マイクロ秒。測定が効いていない");

        TestContext.WriteLine($"OCVU_BENCH: {name}={microsPerCall}");
    }
}
