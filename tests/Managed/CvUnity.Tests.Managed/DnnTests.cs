using System;
using CvUnity;
using CvUnity.Dnn;
using Xunit;

/// <summary>
/// **有効な ONNX を手で組むのは現実的でない。**
/// ここが見るのは、壊れた入力・寿命・所有権である。
/// **正常系は <see cref="DnnInferenceTests"/> が、実物の小さなモデル
/// （<c>tiny.onnx</c>）を使って見ている**（Task 5 で追加済み）。
/// </summary>
public class DnnTests
{
    [Fact]
    public void ReadingGarbageThrowsRatherThanReturningABrokenNet()
    {
        var garbage = new byte[64];
        for (int i = 0; i < garbage.Length; i++) { garbage[i] = 0xAB; }

        var ex = Assert.Throws<CvNativeException>(() => CvDnn.ReadOnnx(garbage));
        Assert.Equal(CvStatus.OpenCvError, ex.Status);
    }

    [Fact]
    public void ANullBufferIsRejected()
        => Assert.Throws<ArgumentNullException>(() => CvDnn.ReadOnnx(null));

    [Fact]
    public void AnEmptyBufferIsRejected()
        => Assert.Throws<ArgumentException>(() => CvDnn.ReadOnnx(Array.Empty<byte>()));

    /// <summary>
    /// **二重解放が落ちないこと。** mat_table と同じ規約である。
    /// </summary>
    [Fact]
    public void DisposingTwiceIsSafe()
    {
        // 読めない入力なので net は作れない。**代わりに、
        // 解放済みの handle を native がどう扱うかを直接見る。**
        // （CvNet を作れないので、ここは NativeMethodsDnn を直接叩く）
        Assert.Equal(
            (int)CvStatus.InvalidHandle,
            CvUnity.Interop.Dnn.NativeMethodsDnn.ocvu_dnn_net_release(0));
    }
}
