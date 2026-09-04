using System;
using CvUnity;
using CvUnity.Interop;
using Xunit;

public class StereoTests
{
    private const int Width = 128;
    private const int Height = 64;

    // BM が受け付ける最小の組（16 の倍数の視差幅、5 以上の奇数の窓）。
    private const int NumDisparities = 16;
    private const int BlockSize = 21;

    [Fact]
    public void ComputeDisparityProducesA16BitImageOfTheSameShape()
    {
        using var left = MakeStripes(Width, Height, 0);
        using var right = MakeStripes(Width, Height, 4);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        CvStereo.ComputeDisparity(
            left, right, dst, CvStereoAlgorithm.BlockMatching, NumDisparities, BlockSize);

        Assert.Equal(Height, dst.Rows);
        Assert.Equal(Width, dst.Cols);
        Assert.Equal(1, dst.Channels);

        // **形だけを見ると、1 画素を何バイトとして読めばよいかが未検査のまま残る。**
        // CvMat は型を公開していないので、Disparity16 であることは
        // 「行の長さが列数の 2 倍」として現れる。
        Assert.Equal((long)Width * 2, dst.Step);

        // **remarks が約束した読み方をそのまま実行する。** 約束だけ書いて
        // 確かめないままにしない —— stride を Cols にすると長さの検証に
        // 引っかかって例外になる。
        var disparity = new byte[Width * Height * 2];
        dst.CopyTo(disparity, (long)dst.Cols * 2);
    }

    [Fact]
    public void ComputeDisparityWorksForBothAlgorithms()
    {
        // **BM で通る引数は SGBM でも通る。** この ABI は 2 つに同じ制限を
        // かけてあるので、algorithm を差し替えるだけでよい。
        using var left = MakeStripes(Width, Height, 0);
        using var right = MakeStripes(Width, Height, 4);

        foreach (CvStereoAlgorithm algorithm in Enum.GetValues(typeof(CvStereoAlgorithm)))
        {
            using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

            CvStereo.ComputeDisparity(
                left, right, dst, algorithm, NumDisparities, BlockSize);

            Assert.Equal(Height, dst.Rows);
            Assert.Equal(Width, dst.Cols);
            Assert.Equal((long)Width * 2, dst.Step);
        }
    }

    [Fact]
    public void TheManagedAlgorithmValuesMatchWhatNativeAccepts()
    {
        // CvStereoAlgorithm の値は C の OCVU_STEREO_* の写しである。
        // C# から C の #define は読めないので複製しており、**両側を native に問う**
        // （上の ComputeDisparityWorksForBothAlgorithms が「知っている値は
        // 受理される」側を見ているので、ここは「知らない値は断られる」側を見る）。
        using var left = MakeStripes(Width, Height, 0);
        using var right = MakeStripes(Width, Height, 4);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        // 公開 API は enum を受けるので、ここだけ P/Invoke を直接叩く
        // （C# の enum は未定義の数値でもキャストが通ってしまう）。
        var status = (CvStatus)NativeMethods.ocvu_compute_disparity(
            left.Handle, right.Handle, dst.Handle, 99, NumDisparities, BlockSize);
        Assert.Equal(CvStatus.InvalidArgument, status);
    }

    [Fact]
    public void ComputeDisparityRejectsDisparityWidthsAndBlockSizesThisAbiDoesNotAccept()
    {
        // **これは OpenCV の要求ではなく、この ABI が決めた契約である。**
        // 実測では SGBM は block_size も num_disparities も検査せず、BM も
        // num_disparities=0 を落とさずに 64 と読み替える。**だから両方に当てる** ——
        // 片方だけ見ると「BM がたまたま落としていただけ」と区別できない。
        using var left = MakeStripes(Width, Height, 0);
        using var right = MakeStripes(Width, Height, 4);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        foreach (CvStereoAlgorithm algorithm in Enum.GetValues(typeof(CvStereoAlgorithm)))
        {
            // 16 の倍数でない視差幅。
            ExpectInvalidArgument(left, right, dst, algorithm, 17, BlockSize);
            ExpectInvalidArgument(left, right, dst, algorithm, 0, BlockSize);

            // 偶数の窓と、5 未満の窓。
            ExpectInvalidArgument(left, right, dst, algorithm, NumDisparities, 20);
            ExpectInvalidArgument(left, right, dst, algorithm, NumDisparities, 3);
        }
    }

    [Fact]
    public void ComputeDisparityRejectsInputsThatAreNotGray8()
    {
        // **この制限もこの ABI のものである。** BM は 8 bit 1 channel しか
        // 受けないが、SGBM は 8 bit なら 3 channel でも受ける。厳しいほうへ
        // 揃えてあるので、どちらでも同じ status になる。
        using var gray = MakeStripes(Width, Height, 0);
        using var color = CvMat.Create(Height, Width, CvMatType.Bgr24);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        foreach (CvStereoAlgorithm algorithm in Enum.GetValues(typeof(CvStereoAlgorithm)))
        {
            var badLeft = Assert.Throws<CvNativeException>(() => CvStereo.ComputeDisparity(
                color, gray, dst, algorithm, NumDisparities, BlockSize));
            Assert.Equal(CvStatus.InvalidArgument, badLeft.Status);

            var badRight = Assert.Throws<CvNativeException>(() => CvStereo.ComputeDisparity(
                gray, color, dst, algorithm, NumDisparities, BlockSize));
            Assert.Equal(CvStatus.InvalidArgument, badRight.Status);
        }
    }

    [Fact]
    public void ComputeDisparityLeavesDstAloneWhenItRefuses()
    {
        // **断ったときに dst を書き換えていないことまで見る。** 形と型だけでは
        // 足りないので画素も読み直す —— 途中まで書き換わった Mat が残ると、
        // 呼ぶ側は例外を捕まえたあとで「古い視差」を新しい結果として使う。
        using var left = MakeStripes(Width, Height, 0);
        using var right = MakeStripes(Width, Height, 4);
        using var dst = CvMat.Create(4, 4, CvMatType.Gray8);

        // **0 では埋めない** —— 「書いていない」と「0 を書いた」が
        // 区別できなくなる。
        var sentinel = new byte[4 * 4];
        for (int i = 0; i < sentinel.Length; i++) { sentinel[i] = 0xAB; }
        dst.CopyFrom(sentinel, 4);

        Assert.Throws<CvNativeException>(() => CvStereo.ComputeDisparity(
            left, right, dst, CvStereoAlgorithm.BlockMatching, NumDisparities, 20));

        Assert.Equal(4, dst.Rows);
        Assert.Equal(4, dst.Cols);

        var after = new byte[4 * 4];
        dst.CopyTo(after, 4);
        Assert.Equal(sentinel, after);
    }

    [Fact]
    public void ComputeDisparityRejectsNull()
    {
        using var left = MakeStripes(Width, Height, 0);
        using var right = MakeStripes(Width, Height, 4);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        Assert.Throws<ArgumentNullException>(() => CvStereo.ComputeDisparity(
            null, right, dst, CvStereoAlgorithm.BlockMatching, NumDisparities, BlockSize));
        Assert.Throws<ArgumentNullException>(() => CvStereo.ComputeDisparity(
            left, null, dst, CvStereoAlgorithm.BlockMatching, NumDisparities, BlockSize));
        Assert.Throws<ArgumentNullException>(() => CvStereo.ComputeDisparity(
            left, right, null, CvStereoAlgorithm.BlockMatching, NumDisparities, BlockSize));
    }

    private static void ExpectInvalidArgument(
        CvMat left, CvMat right, CvMat dst,
        CvStereoAlgorithm algorithm, int numDisparities, int blockSize)
    {
        var ex = Assert.Throws<CvNativeException>(() => CvStereo.ComputeDisparity(
            left, right, dst, algorithm, numDisparities, blockSize));

        Assert.Equal(CvStatus.InvalidArgument, ex.Status);
    }

    /// <summary>
    /// 縦縞のグレー画像。offsetX だけ横にずらすので、視差のある左右の対を作れる。
    /// </summary>
    private static CvMat MakeStripes(int width, int height, int offsetX)
    {
        var mat = CvMat.Create(height, width, CvMatType.Gray8);

        // **CvMat.Create は画素を初期化しない。** 全画素を明示的に書く。
        var pixels = new byte[width * height];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                int shifted = x + offsetX;
                pixels[(y * width) + x] = (shifted / 5) % 2 == 0 ? (byte)220 : (byte)30;
            }
        }

        // **stride はバイト数である**（8 bit 1 channel なので width と同じ値になる）。
        mat.CopyFrom(pixels, width);
        return mat;
    }
}
