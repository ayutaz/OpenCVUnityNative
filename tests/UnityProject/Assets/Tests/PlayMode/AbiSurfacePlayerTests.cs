using System.Collections;
using UnityEngine.TestTools;

/// <summary>
/// Player (IL2CPP) 側の入口。検証の本体は <see cref="AbiSurfaceChecks"/> にある。
///
/// **ここが本命である。** IL2CPP の stripping が P/Invoke 宣言を削ると、
/// このレーンだけが <c>EntryPointNotFoundException</c> になる。M4 の点検まで、
/// cvt_color / resize / mat_clone / imencode / imdecode / get_build_information /
/// debug_throw は Player から一度も呼ばれていなかった —— 消えても誰も
/// 気づかない状態だった。
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
}
