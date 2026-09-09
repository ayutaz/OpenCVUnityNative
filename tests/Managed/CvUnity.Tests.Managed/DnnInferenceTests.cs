using System;
using System.IO;
using CvUnity;
using CvUnity.Dnn;
using Xunit;

/// <summary>
/// **実物の ONNX を通して、境界の往復が成立することを見る。**
///
/// <c>tiny.onnx</c>（TestModels/ 隣の <c>tiny.onnx.py</c> が生成した合成モデル。
/// **外部から取ってきたものではない** —— 詳細はそのスクリプトの docstring を
/// 見ること）は Identity 1 ノードなので、推論の中身は何もしない ——
/// **確かめているのは「読めて、blob になって、forward が返る」ことである。**
/// 推論そのものの正しさは OpenCV の責任であって、この境界の責任ではない。
/// </summary>
public class DnnInferenceTests
{
    private const int ModelSize = 4;

    private static byte[] TinyModel()
    {
        var path = Path.Combine(
            AppContext.BaseDirectory, "TestModels", "tiny.onnx");
        Assert.True(File.Exists(path), $"テスト用のモデルが無い: {path}");
        return File.ReadAllBytes(path);
    }

    [Fact]
    public void AValidOnnxLoads()
    {
        using var net = CvDnn.ReadOnnx(TinyModel());
        Assert.NotNull(net);
    }

    /// <summary>
    /// blob は 4 次元のまま保持される契約（spec の summary、決定 A の前段）
    /// なので、2 次元前提の <see cref="CvMat.Rows"/> はこの handle を
    /// 例外で拒む —— それ自体がこの契約の検証であり、値は読めない。
    /// 実際の要素数は <see cref="Forward"/> を通した 2 次元の出力側で見る
    /// （<see cref="ForwardReturnsTheInputUnchangedForAnIdentityNetwork"/>）。
    /// </summary>
    [Fact]
    public void BlobFromImageKeepsTheBlobFourDimensional()
    {
        using var src = CvMat.Create(8, 8, CvMatType.Bgr24);
        using var blob = CvMat.Create(1, 1, CvMatType.Response32);

        CvDnn.BlobFromImage(
            src, blob, scale: 1.0 / 255.0, width: ModelSize, height: ModelSize,
            mean: new[] { 0.0, 0.0, 0.0 }, swapRb: false, crop: false);

        var ex = Assert.Throws<CvNativeException>(() => { _ = blob.Rows; });
        Assert.Equal(CvStatus.InvalidArgument, ex.Status);
    }

    [Fact]
    public void ForwardReturnsTheInputUnchangedForAnIdentityNetwork()
    {
        using var net = CvDnn.ReadOnnx(TinyModel());
        using var src = CvMat.Create(ModelSize, ModelSize, CvMatType.Bgr24);
        using var blob = CvMat.Create(1, 1, CvMatType.Response32);
        using var output = CvMat.Create(1, 1, CvMatType.Response32);

        CvDnn.BlobFromImage(
            src, blob, scale: 1.0, width: ModelSize, height: ModelSize,
            mean: new[] { 0.0, 0.0, 0.0 }, swapRb: false, crop: false);

        CvDnn.Forward(net, blob, output);

        // 1 (N) x 3 (C) x 4 (H) x 4 (W) = 48 要素。Identity なので個数は変わらない。
        Assert.Equal(1 * 3 * ModelSize * ModelSize, output.Rows * output.Cols);
    }

    /// <summary>
    /// **解放した net で forward を呼んでも落ちないこと。**
    /// <see cref="CvNet.Handle"/> の getter が <see cref="ObjectDisposedException"/>
    /// を投げるので、native へは届かない —— mat_table と同じ「解放後アクセスは
    /// 例外で返る」規約を、C# 側の一番外側で確かめる。
    /// </summary>
    [Fact]
    public void ForwardOnADisposedNetIsRejected()
    {
        var net = CvDnn.ReadOnnx(TinyModel());
        net.Dispose();

        using var input = CvMat.Create(1, 48, CvMatType.Response32);
        using var output = CvMat.Create(1, 1, CvMatType.Response32);

        Assert.Throws<ObjectDisposedException>(() => CvDnn.Forward(net, input, output));
    }

    /// <summary>
    /// **C# レベルでの二重 Dispose。** <see cref="CvNet.Dispose"/> のガードは
    /// <see cref="CvMat.Dispose"/> と同じ形（handle が 0 なら何もしない）だが、
    /// 「同じ形をしている」ことは「動くことが確かめられている」ことと同じでは
    /// ない —— <c>DnnTests.DisposingTwiceIsSafe</c> は有効な net を作れなかった
    /// ので <c>NativeMethodsDnn.ocvu_dnn_net_release</c> を直接叩いていた。
    /// ここでは実物の <see cref="CvNet"/> を実際に二重解放する。
    /// </summary>
    [Fact]
    public void DisposingACvNetTwiceIsSafe()
    {
        var net = CvDnn.ReadOnnx(TinyModel());
        net.Dispose();
        net.Dispose();  // 二重 Dispose は例外にならない（IDisposable の規約）
    }

    /// <summary>
    /// **Task 3 が直した defect の再発防止。** <c>ocvu_dnn_net_forward</c> が
    /// 返す Mat は元々 net 内部バッファへの浅いコピーで、同じ net に対する
    /// 2 回目の forward が 1 回目の出力を黙って書き換えていた。修正は
    /// <c>.clone()</c> を足すことだったが、それを実物のモデルで確かめたのは
    /// ここが最初である。
    /// </summary>
    [Fact]
    public void CallingForwardTwiceDoesNotRewriteTheFirstOutput()
    {
        using var net = CvDnn.ReadOnnx(TinyModel());
        using var src = CvMat.Create(ModelSize, ModelSize, CvMatType.Bgr24);
        using var blob = CvMat.Create(1, 1, CvMatType.Response32);
        using var firstOutput = CvMat.Create(1, 1, CvMatType.Response32);
        using var secondOutput = CvMat.Create(1, 1, CvMatType.Response32);

        CvDnn.BlobFromImage(
            src, blob, scale: 1.0, width: ModelSize, height: ModelSize,
            mean: new[] { 0.0, 0.0, 0.0 }, swapRb: false, crop: false);

        CvDnn.Forward(net, blob, firstOutput);

        var beforeSecondForward = ReadAll(firstOutput);

        // **同じ net で 2 回目の forward を呼ぶ。** 別の handle
        // (secondOutput) に書かせるが、defect が再発していれば
        // net が内部で持つバッファ経由で firstOutput まで書き換わる。
        CvDnn.Forward(net, blob, secondOutput);

        var afterSecondForward = ReadAll(firstOutput);

        Assert.Equal(beforeSecondForward, afterSecondForward);
    }

    /// <summary>32FC1（4 byte/pixel、1 channel）の Mat を丸ごと byte[] に読み出す。</summary>
    private static byte[] ReadAll(CvMat mat)
    {
        const int bytesPerElement = 4;
        long stride = mat.Cols * bytesPerElement;
        var buffer = new byte[stride * mat.Rows];
        mat.CopyTo(buffer, stride);
        return buffer;
    }
}
