using System.Linq;
using NUnit.Framework;

/// <summary>
/// Editor (Mono) 側の入口。検証の本体は <see cref="AbiSurfaceChecks"/> にある。
/// **ここに検証を書かないこと** —— Player 側と同じものを見ていることが、
/// この 2 ファイルの唯一の役目である。
/// </summary>
public class AbiSurfaceTests
{
    [Test] public void CvtColor_ReducesTheChannelCount() => AbiSurfaceChecks.CvtColor_ReducesTheChannelCount();
    [Test] public void Resize_ProducesTheRequestedSize() => AbiSurfaceChecks.Resize_ProducesTheRequestedSize();
    [Test] public void Clone_CopiesThePixelsIntoAnIndependentMat() => AbiSurfaceChecks.Clone_CopiesThePixelsIntoAnIndependentMat();
    [Test] public void EncodedImage_DecodesBackToTheSameShape() => AbiSurfaceChecks.EncodedImage_DecodesBackToTheSameShape();
    [Test] public void Encode_RejectsAnExtensionOpenCvCannotWrite() => AbiSurfaceChecks.Encode_RejectsAnExtensionOpenCvCannotWrite();
    [Test] public void BuildInformation_ComesBackThroughTheTwoCallIdiom() => AbiSurfaceChecks.BuildInformation_ComesBackThroughTheTwoCallIdiom();
    [Test] public void NativeExceptionsAreTurnedIntoStatusCodes() => AbiSurfaceChecks.NativeExceptionsAreTurnedIntoStatusCodes();
    [Test] public void WebCamPixels_BecomeATopLeftOriginMat() => AbiSurfaceChecks.WebCamPixels_BecomeATopLeftOriginMat();

    // --- 2026-09 の API 拡張で足した 26 本を、Unity の中で実際に動かす 12 件 ---
    [Test] public void SolvePnP_RecoversAKnownPoseAndProjectPointsIsItsInverse() => AbiSurfaceChecks.SolvePnP_RecoversAKnownPoseAndProjectPointsIsItsInverse();
    [Test] public void Rodrigues_RoundTripsThroughTheMatrix() => AbiSurfaceChecks.Rodrigues_RoundTripsThroughTheMatrix();
    [Test] public void Aruco_DetectsTheMarkerItGenerated() => AbiSurfaceChecks.Aruco_DetectsTheMarkerItGenerated();
    [Test] public void Threshold_SplitsThePixelsAndReportsTheValueOtsuChose() => AbiSurfaceChecks.Threshold_SplitsThePixelsAndReportsTheValueOtsuChose();
    [Test] public void MorphologyEx_UsesEveryArgument() => AbiSurfaceChecks.MorphologyEx_UsesEveryArgument();
    [Test] public void MatchTemplate_ProducesAFloatResponseWeCanRead() => AbiSurfaceChecks.MatchTemplate_ProducesAFloatResponseWeCanRead();
    [Test] public void PerspectiveTransform_IsProducedAndThenApplied() => AbiSurfaceChecks.PerspectiveTransform_IsProducedAndThenApplied();
    [Test] public void HoughAndContours_ReturnTheShapesTheyFind() => AbiSurfaceChecks.HoughAndContours_ReturnTheShapesTheyFind();
    [Test] public void CornerSubPix_RefinesWithoutTouchingTheInput() => AbiSurfaceChecks.CornerSubPix_RefinesWithoutTouchingTheInput();
    [Test] public void CoreOps_ProduceThePixelsWeComputeByHand() => AbiSurfaceChecks.CoreOps_ProduceThePixelsWeComputeByHand();
    [Test] public void Descriptors_AreComputedAndMatched() => AbiSurfaceChecks.Descriptors_AreComputedAndMatched();
    [Test] public void Disparity_IsComputedAndReadBackAs16Bit() => AbiSurfaceChecks.Disparity_IsComputedAndReadBackAs16Bit();

    /// <summary>
    /// spec が載せる P/Invoke 宣言を 1 つ残らず 1 回ずつ呼ぶ（本体は
    /// bindings/spec/*.json から生成された AbiReachabilityChecks にある）。
    /// **Mono では stripping が無いので、ここが赤くなるのは宣言そのものが
    /// 消えたときだけである** —— 本命は同名の Player 側である。
    /// </summary>
    [Test]
    public void EveryEntryPointIsReachable()
    {
        var called = AbiReachabilityChecks.CallEveryEntryPoint();
        // **0 件で緑にしない。** spec が空でも「呼び終えた」と言えてしまう。
        Assert.Greater(called, 10, "spec が空だと 0 本になる");
    }

    /// <summary>
    /// **共有本体の検査が、1 つ残らずこの入口に配線されているか。**
    /// </summary>
    /// <remarks>
    /// <b>この検査が無いと、共有本体に足したのに入口へ配線し忘れたものが
    /// 1 度も走らない。</b> Web の runner はリフレクションで自動に拾うので
    /// 気づけるが、EditMode と PlayMode は <c>[Test]</c> を手で 1 行ずつ書く ——
    /// <b>漏れても緑のまま通る。</b>
    /// <para>
    /// 2026-09 の API 拡張で 12 件を一度に足したときに置いた。
    /// <b>数を写していない</b> —— リフレクションで両側を数えて突き合わせるので、
    /// 検査を 1 件足すたびに勝手に増える。
    /// </para>
    /// </remarks>
    [Test]
    public void EveryCheckInTheSharedBodyIsWiredIntoThisEntryPoint()
    {
        var shared = typeof(AbiSurfaceChecks)
            .GetMethods(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static)
            .Where(m => m.ReturnType == typeof(void) && m.GetParameters().Length == 0)
            .Select(m => m.Name)
            .ToList();

        // **0 件で緑にしない。** 本体が空でも「全部配線した」と言えてしまう。
        Assert.Greater(shared.Count, 10, "共有本体の検査が拾えていない");

        var wired = typeof(AbiSurfaceTests)
            .GetMethods(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance)
            .Select(m => m.Name)
            .ToList();

        var missing = shared.Where(n => !wired.Contains(n)).ToList();
        Assert.IsEmpty(missing,
            "共有本体に在るのに、この入口に配線されていない検査: " + string.Join(", ", missing));
    }
}
