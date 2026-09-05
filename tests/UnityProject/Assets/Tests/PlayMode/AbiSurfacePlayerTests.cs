using System.Collections;
using System.Linq;
using NUnit.Framework;
using UnityEngine.TestTools;

/// <summary>
/// Player (IL2CPP) 側の入口。検証の本体は <see cref="AbiSurfaceChecks"/> にある。
///
/// **ここが本命である。** IL2CPP の stripping が P/Invoke 宣言を削ると、
/// このレーンだけが <c>EntryPointNotFoundException</c> になる。M4 の点検まで、
/// cvt_color / resize / mat_clone / imencode / imdecode / get_build_information /
/// debug_throw の **7 本**は Player から一度も呼ばれていなかった —— 消えても
/// 誰も気づかない状態だった。M5 Task 6 の <c>EveryEntryPointIsReachable</c> が
/// spec の全宣言を 1 件で守るようになったので、いま Player から呼ばれて
/// いない宣言は <c>ocvu_debug_crash</c> だけである（数え方と理由は
/// <see cref="AbiSurfaceChecks"/> の説明を見ること）。
/// </summary>
public class AbiSurfacePlayerTests
{
    [UnityTest] public IEnumerator CvtColor_ReducesTheChannelCount() { AbiSurfaceChecks.CvtColor_ReducesTheChannelCount(); yield return null; }
    [UnityTest] public IEnumerator Resize_ProducesTheRequestedSize() { AbiSurfaceChecks.Resize_ProducesTheRequestedSize(); yield return null; }
    [UnityTest] public IEnumerator Clone_CopiesThePixelsIntoAnIndependentMat() { AbiSurfaceChecks.Clone_CopiesThePixelsIntoAnIndependentMat(); yield return null; }
    [UnityTest] public IEnumerator EncodedImage_DecodesBackToTheSameShape() { AbiSurfaceChecks.EncodedImage_DecodesBackToTheSameShape(); yield return null; }
    [UnityTest] public IEnumerator Encode_RejectsAnExtensionOpenCvCannotWrite() { AbiSurfaceChecks.Encode_RejectsAnExtensionOpenCvCannotWrite(); yield return null; }
    [UnityTest] public IEnumerator BuildInformation_ComesBackThroughTheTwoCallIdiom() { AbiSurfaceChecks.BuildInformation_ComesBackThroughTheTwoCallIdiom(); yield return null; }
    [UnityTest] public IEnumerator NativeExceptionsAreTurnedIntoStatusCodes() { AbiSurfaceChecks.NativeExceptionsAreTurnedIntoStatusCodes(); yield return null; }
    [UnityTest] public IEnumerator WebCamPixels_BecomeATopLeftOriginMat() { AbiSurfaceChecks.WebCamPixels_BecomeATopLeftOriginMat(); yield return null; }

    // --- 2026-09 の API 拡張で足した 26 本を、IL2CPP の Player で実際に動かす 12 件 ---
    [UnityTest] public IEnumerator SolvePnP_RecoversAKnownPoseAndProjectPointsIsItsInverse() { AbiSurfaceChecks.SolvePnP_RecoversAKnownPoseAndProjectPointsIsItsInverse(); yield return null; }
    [UnityTest] public IEnumerator Rodrigues_RoundTripsThroughTheMatrix() { AbiSurfaceChecks.Rodrigues_RoundTripsThroughTheMatrix(); yield return null; }
    [UnityTest] public IEnumerator Aruco_DetectsTheMarkerItGenerated() { AbiSurfaceChecks.Aruco_DetectsTheMarkerItGenerated(); yield return null; }
    [UnityTest] public IEnumerator Threshold_SplitsThePixelsAndReportsTheValueOtsuChose() { AbiSurfaceChecks.Threshold_SplitsThePixelsAndReportsTheValueOtsuChose(); yield return null; }
    [UnityTest] public IEnumerator MorphologyEx_UsesEveryArgument() { AbiSurfaceChecks.MorphologyEx_UsesEveryArgument(); yield return null; }
    [UnityTest] public IEnumerator MatchTemplate_ProducesAFloatResponseWeCanRead() { AbiSurfaceChecks.MatchTemplate_ProducesAFloatResponseWeCanRead(); yield return null; }
    [UnityTest] public IEnumerator PerspectiveTransform_IsProducedAndThenApplied() { AbiSurfaceChecks.PerspectiveTransform_IsProducedAndThenApplied(); yield return null; }
    [UnityTest] public IEnumerator HoughAndContours_ReturnTheShapesTheyFind() { AbiSurfaceChecks.HoughAndContours_ReturnTheShapesTheyFind(); yield return null; }
    [UnityTest] public IEnumerator CornerSubPix_RefinesWithoutTouchingTheInput() { AbiSurfaceChecks.CornerSubPix_RefinesWithoutTouchingTheInput(); yield return null; }
    [UnityTest] public IEnumerator CoreOps_ProduceThePixelsWeComputeByHand() { AbiSurfaceChecks.CoreOps_ProduceThePixelsWeComputeByHand(); yield return null; }
    [UnityTest] public IEnumerator Descriptors_AreComputedAndMatched() { AbiSurfaceChecks.Descriptors_AreComputedAndMatched(); yield return null; }
    [UnityTest] public IEnumerator Disparity_IsComputedAndReadBackAs16Bit() { AbiSurfaceChecks.Disparity_IsComputedAndReadBackAs16Bit(); yield return null; }

    /// <summary>
    /// spec が載せる P/Invoke 宣言を 1 つ残らず 1 回ずつ呼ぶ。
    /// **stripping が宣言を消していたら、ここで EntryPointNotFoundException に
    /// なる。** Mono では再現しない。上の 8 件は公開 API を通るので宣言の
    /// 一部しか触らないが、この 1 件は spec の全宣言を守る。
    /// </summary>
    [UnityTest]
    public IEnumerator EveryEntryPointIsReachable()
    {
        var called = AbiReachabilityChecks.CallEveryEntryPoint();
        // **0 件で緑にしない。** spec が空でも「呼び終えた」と言えてしまう。
        Assert.Greater(called, 10, "spec が空だと 0 本になる");
        yield return null;
    }

    /// <summary>
    /// **共有本体の検査が、1 つ残らずこの入口に配線されているか。**
    /// </summary>
    /// <remarks>
    /// EditMode 側と同じ検査である。<b>ここが本命で、Player に配線し忘れると
    /// stripping が消したかどうかを確かめる機会そのものが失われる。</b>
    /// </remarks>
    [Test]
    public void EveryCheckInTheSharedBodyIsWiredIntoThisEntryPoint()
    {
        var shared = typeof(AbiSurfaceChecks)
            .GetMethods(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static)
            .Where(m => m.ReturnType == typeof(void) && m.GetParameters().Length == 0)
            .Select(m => m.Name)
            .ToList();

        Assert.Greater(shared.Count, 10, "共有本体の検査が拾えていない");

        var wired = typeof(AbiSurfacePlayerTests)
            .GetMethods(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance)
            .Select(m => m.Name)
            .ToList();

        var missing = shared.Where(n => !wired.Contains(n)).ToList();
        Assert.IsEmpty(missing,
            "共有本体に在るのに、この入口に配線されていない検査: " + string.Join(", ", missing));
    }
}
