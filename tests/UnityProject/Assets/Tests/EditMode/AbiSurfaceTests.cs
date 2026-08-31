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
}
