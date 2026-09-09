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
    /// <c>ocvu_dnn_net_forward</c> は net の内部バッファではなく独立したコピーを
    /// 返す契約（docs/api-reference.md、spec の summary）を、実物のモデルで
    /// 確かめる。2 回の forward には別々の入力を使う —— 同じ blob を 2 回渡すと
    /// （defect があってもなくても）1 回目と 2 回目の値が一致してしまい、
    /// 何も検証できない（最初の実装がまさにこれだった）。
    /// <para>
    /// <b>この negative control は取れなかった（prove-a-check-works）。</b>
    /// Task 3 の <c>.clone()</c>（native/src/ocvu_dnn.cpp）を一時的に外し、
    /// このネットワーク（Identity 1 ノード）でも 2 層の Relu（learned weight
    /// を持たない別モデルで検証）でもこのテストを走らせたが、**どちらも
    /// このテストは緑のままだった** —— 外した状態と戻した状態とで結果が
    /// 変わらない。
    /// </para>
    /// <para>
    /// <b>「mat_table 側の参照カウントが守っている」という説は、ほぼ確実に
    /// 誤りである。</b> <c>cv::Mat::create()</c> には、要求された shape と type
    /// が現在のヘッダと一致するときに早期リターンする経路があり、**そこは
    /// 参照カウントを一切見ない。** つまり net が持続的なバッファを使い回して
    /// いたとしても、外側（mat_table の Slot）が result への参照を生かして
    /// いることは、2 回目の forward による in-place の上書きを止める理由には
    /// ならない —— 参照カウントは「守ってくれる仕組み」ではなかった。
    /// </para>
    /// <para>
    /// **有力なのは、OpenCV 5 の新しい dnn engine が forward() のたびに
    /// 新しく確保したバッファを返している、という説である。** これも
    /// 未確認（復元済みツリーには header しか無く、OpenCV 本体のソースを
    /// 読める状態ではない）だが、上の refcount 説のように機構として
    /// 否定されているわけではないので、こちらを主説として置く。
    /// </para>
    /// <para>
    /// **この結果、`.clone()` の位置づけは「念のため」ではない。** 元々の
    /// コメントは「参照カウントが本来なら守ってくれるところを、念のため
    /// 独立コピーにしておく」という書き方に読めたが、それは違う ——
    /// refcount 説が否定された以上、**forward() が返す Mat が net 側の
    /// バッファを指していないという保証はどこにも無く、`.clone()` こそが
    /// 「返された handle が独立したメモリを持つ」という契約を成立させている
    /// 唯一のものである。** 消してよい安全装置ではない。
    /// </para>
    /// <para>
    /// **したがってこのテストは、想定した defect を実際に再現させて
    /// 潰したことの証明にはなっていない** —— 契約どおりの結果を実物の
    /// モデルで確認した positive な回帰検査ではあるが、`.clone()` を
    /// 消しても今のところこのテストは検知できない。同じ形の負の対照が
    /// 取れないことがある、という M6 の教訓（CLAUDE.md
    /// 「prove-a-check-works」の節）をここでも踏んだ。
    /// </para>
    /// </summary>
    [Fact]
    public void CallingForwardTwiceWithDifferentInputsDoesNotRewriteTheFirstOutput()
    {
        using var net = CvDnn.ReadOnnx(TinyModel());
        using var srcA = CvMat.Create(ModelSize, ModelSize, CvMatType.Bgr24);
        using var srcB = CvMat.Create(ModelSize, ModelSize, CvMatType.Bgr24);
        FillWithConstant(srcA, 10);
        FillWithConstant(srcB, 200);

        using var blobA = CvMat.Create(1, 1, CvMatType.Response32);
        using var blobB = CvMat.Create(1, 1, CvMatType.Response32);
        using var firstOutput = CvMat.Create(1, 1, CvMatType.Response32);
        using var secondOutput = CvMat.Create(1, 1, CvMatType.Response32);

        var mean = new[] { 0.0, 0.0, 0.0 };
        CvDnn.BlobFromImage(srcA, blobA, scale: 1.0, width: ModelSize, height: ModelSize,
            mean: mean, swapRb: false, crop: false);
        CvDnn.BlobFromImage(srcB, blobB, scale: 1.0, width: ModelSize, height: ModelSize,
            mean: mean, swapRb: false, crop: false);

        CvDnn.Forward(net, blobA, firstOutput);
        var afterFirstForward = ReadAll(firstOutput);

        // **同じ net で 2 回目の forward を呼ぶ。** 別の handle
        // (secondOutput) に書かせるが、defect が再発していれば
        // net が内部で持つバッファ経由で firstOutput まで書き換わる。
        CvDnn.Forward(net, blobB, secondOutput);
        var afterSecondForward = ReadAll(firstOutput);

        Assert.Equal(afterFirstForward, afterSecondForward);

        // **前提の健全性チェック。** srcA と srcB が実際に異なる結果を
        // 生んでいなければ、上の Assert.Equal は defect の有無に関わらず
        // 常に真になり、何も検証したことにならない。
        var secondOutputBytes = ReadAll(secondOutput);
        Assert.NotEqual(afterFirstForward, secondOutputBytes);
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

    /// <summary>8UC3（Bgr24）の Mat を、全画素・全チャンネルが同じ値になるよう埋める。</summary>
    private static void FillWithConstant(CvMat mat, byte value)
    {
        const int channels = 3;
        long stride = mat.Cols * channels;
        var buffer = new byte[stride * mat.Rows];
        for (int i = 0; i < buffer.Length; i++) { buffer[i] = value; }
        mat.CopyFrom(buffer, stride);
    }
}
