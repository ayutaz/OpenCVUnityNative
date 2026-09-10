using System;
using System.Collections;
using System.Diagnostics;
using CvUnity;
using CvUnity.Unity;
using NUnit.Framework;
using Unity.Collections;
using UnityEngine;
using UnityEngine.TestTools;

/// <summary>
/// 経路ごとの所要時間を測って公開する（M7a Task 4）。
///
/// **assert しない**（設計 D1）—— 共有 CI ランナーの上で時間を assert すると
/// 必ずフレークになり、閾値を緩めればその検査は何も見ていない。
/// **落ちるのは「測れなかったとき」だけである。**
///
/// **出力は <see cref="TestContext.WriteLine"/>。** brief 原案の
/// <c>Debug.Log</c> ではない —— このリポジトリの確立した型は
/// <c>TestContext.WriteLine</c> で（<c>PluginGatingTests.cs</c> に実例がある）、
/// NUnit3 がそれを結果 XML の <c>&lt;output&gt;</c> に入れる。
/// <c>tools/run-benchmarks.ps1</c> はそこから <c>OCVU_BENCH:</c> 行を拾う。
///
/// **GPU に依る経路（RenderTexture）はここに置かない。** このレーン
/// （<c>test-unity-player</c>）は <c>-nographics</c> で走るため
/// <c>RenderTexture</c> の内容が読めず、意味のある数字にならない（実測、
/// Task 2/3 の改訂）。そちらは
/// <c>tests/UnityProject/Assets/Tests/EditMode/GraphicsBenchmarkRunner.cs</c>
/// （<c>test-unity-graphics</c> レーン）が測る。
///
/// **測定は実物の IL2CPP Player で行う** —— Editor の Mono で測った数字は、
/// 利用者が動かすものと違う。
///
/// **数字は tools/run-benchmarks.ps1 が拾って docs/performance.md へ入る**
/// （docs/performance.md は Task 6 が書く）。
/// </summary>
public class BenchmarkRunner
{
    private const int Size = 512;
    private const int Iterations = 30;

    [UnityTest]
    public IEnumerator MeasureBoundaryPaths()
    {
        yield return null;   // 1 フレーム進めて、Player の初期化を測らない

        var tex = new Texture2D(Size, Size, TextureFormat.RGBA32, mipChain: false);
        tex.Apply();

        const long RowBytes = Size * 4L;
        var buffer = new NativeArray<byte>(
            Size * (int)RowBytes, Allocator.Persistent, NativeArrayOptions.UninitializedMemory);

        try
        {
            Report("texture2d_to_mat", () => { using var m = TextureConverter.ToMat(tex); });

            // **`mat_copy_from_pointer` / `mat_copy_to_pointer` は境界そのものを測る。**
            // Texture2D を介さず、NativeArrayExtensions.CopyFrom/CopyTo（内部で
            // CvMat.CopyFrom/CopyTo(IntPtr, long, long) を呼ぶ）を使う —— これは
            // TextureConverter / RenderTextureConverter がどちらも内部で使っている、
            // コピー無しで渡す入口である。**`unsafe` はここでは書かない**: このテスト
            // assembly の asmdef は allowUnsafeCode=false（利用者の asmdef と同じ
            // 既定）で、ポインタの取得は NativeArrayExtensions 側（allowUnsafeCode=true
            // の CvUnity.UnityIntegration）が引き受ける（そのための拡張メソッドである、
            // NativeArrayExtensions.cs の docstring 参照）。
            using var mat = CvMat.Create(Size, Size, CvMatType.Bgra32);
            Report("mat_copy_from_pointer", () => mat.CopyFrom(buffer, RowBytes));
            Report("mat_copy_to_pointer", () => mat.CopyTo(buffer, RowBytes));
        }
        finally
        {
            buffer.Dispose();
            // **完全修飾する。** using System; と using UnityEngine; が両方あると
            // 裸の Object は System.Object と UnityEngine.Object の間で曖昧になる
            // （CS0104、実測）。RenderTextureConverter.cs と同じ書き方に揃える。
            UnityEngine.Object.DestroyImmediate(tex);
        }

        yield return null;
    }

    /// <summary>
    /// **Player が起きてから最初の P/Invoke が返るまで。**
    ///
    /// native ライブラリの読み込みと、その中の静的初期化がここに乗る……はずだが、
    /// **この assembly には他の PlayMode テスト（`PlayerSmokeTests` など）が
    /// 同じ P/Invoke を先に呼ぶものが複数在り、NUnit の実行順序はこの
    /// テストメソッドがそれより先に走ることを保証しない。** したがって
    /// この数字が「native ライブラリの真の初回ロード」を捉えているとは
    /// 主張しない —— 捉えているのは「このメソッドにとっての初回呼び出し」
    /// までである。**測れるものを測っただけであり、測れていないものを
    /// 測れたことにはしない**（docs/performance.md に同じ注記がある）。
    /// </summary>
    [UnityTest]
    public IEnumerator MeasureFirstPInvoke()
    {
        var sw = Stopwatch.StartNew();
        int version = CvNative.AbiVersion;
        sw.Stop();

        Assert.Greater(version, 0, "ABI version が取れていない");

        long micros = sw.ElapsedTicks * 1_000_000L / Stopwatch.Frequency;
        TestContext.WriteLine($"OCVU_BENCH: first_pinvoke={micros}");
        yield return null;
    }

    private static void Report(string name, Action action)
    {
        // 温める。初回は JIT / IL2CPP の初期化と資源確保が乗る。
        for (int i = 0; i < 5; i++) { action(); }

        var sw = Stopwatch.StartNew();
        for (int i = 0; i < Iterations; i++) { action(); }
        sw.Stop();

        long microsPerCall = sw.ElapsedTicks * 1_000_000L / Stopwatch.Frequency / Iterations;

        // **0 を吐かない。** 0 は「速かった」ではなく「測れなかった」と
        // 区別がつかないので、そのときは落とす。
        Assert.Greater(microsPerCall, 0,
            $"{name} の所要時間が 0 マイクロ秒。測定が効いていない");

        TestContext.WriteLine($"OCVU_BENCH: {name}={microsPerCall}");
    }
}
