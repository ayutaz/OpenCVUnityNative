using System;
using System.Linq;
using CvUnity;
using Xunit;

public class CalibrationTests
{
    private static readonly double[] Camera = { 100, 0, 16, 0, 100, 16, 0, 0, 1 };
    private static readonly double[] Coeffs = { 0.1, -0.05, 0, 0, 0 };

    [Fact]
    public void UndistortKeepsTheShape()
    {
        using var src = CvMat.Create(32, 32, CvMatType.Gray8);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        CvCalibration.Undistort(src, Camera, Coeffs, dst);

        Assert.Equal(32, dst.Rows);
        Assert.Equal(32, dst.Cols);
    }

    [Fact]
    public void UndistortRejectsAWrongSizedCameraMatrix()
    {
        using var src = CvMat.Create(32, 32, CvMatType.Gray8);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        var eight = new double[] { 1, 0, 0, 0, 1, 0, 0, 0 };
        Assert.Throws<ArgumentException>(
            () => CvCalibration.Undistort(src, eight, Coeffs, dst));
    }

    [Fact]
    public void UndistortRejectsAnUnsupportedCoefficientCount()
    {
        using var src = CvMat.Create(32, 32, CvMatType.Gray8);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        var three = new double[] { 0.1, 0, 0 };
        Assert.Throws<ArgumentException>(
            () => CvCalibration.Undistort(src, Camera, three, dst));
    }

    [Fact]
    public void UndistortRejectsNull()
    {
        using var src = CvMat.Create(32, 32, CvMatType.Gray8);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        Assert.Throws<ArgumentNullException>(() => CvCalibration.Undistort(null, Camera, Coeffs, dst));
        Assert.Throws<ArgumentNullException>(() => CvCalibration.Undistort(src, null, Coeffs, dst));
        Assert.Throws<ArgumentNullException>(() => CvCalibration.Undistort(src, Camera, null, dst));
        Assert.Throws<ArgumentNullException>(() => CvCalibration.Undistort(src, Camera, Coeffs, null));
    }

    [Fact]
    public void FindChessboardCornersReturnsEmptyWhenThereIsNoBoard()
    {
        // **ゼロ埋めが要ることを、外すと実際に赤くなる形で確かめる（レビュー I5 の強化）。**
        // 同じ大きさの Mat を書いて捨てると、アロケータは直前の画素をそのまま
        // 次の確保へ引き継ぐことがある（実測: 4096 バイト中 2048 バイトが非ゼロ）。
        // **xUnit は既定でテストクラスを並列実行するので、他のテストクラスの
        // 確保・解放が間に挟まると 1 回や数回の書いて捨てるだけでは再現が
        // 安定しない**（実測: 8 回では毎回 0 バイトだった）。500 回に増やすと
        // 5 回連続で安定して再現した（実測）ので、この回数にしてある。
        //
        // **盤の側の幾何も、探すパターンに合わせる必要がある。** 64x64 の画像に
        // 7x7（cell=8）の盤を書いても、`patternCols`/`patternRows` を 3x3 で
        // 探すと見つからない（実測: cell=8 の盤を捨てても corners=0）——
        // 4x4 マス（cell=16）で書いた盤なら、内側格子点がちょうど 3x3 になり、
        // 汚れた画素の中から実際に 9 点見つかる。
        //
        // 7x7 の格子は 64x64 に検出可能な形で収まらないため、旧版の検査
        // （7x7 で探す）はゼロ埋めを外しても緑のままだった
        // ——**「たまたま緑」そのものの形**だったので、盤と探索パターンを
        // 3x3 に揃える。
        for (int i = 0; i < 500; i++)
        {
            using var board = MakeCheckerboard(64, 64, 16);
        }

        using var blank = CvMat.Create(64, 64, CvMatType.Gray8);

        // **`CvMat.Create` は画素を初期化しない。** 「真っ黒」を主張するなら
        // 明示的にゼロ埋めする（L1 の同じ欠陥はレビュー I4 で直っている
        // ——native/tests/test_calibration.cpp の
        // FindChessboardCornersReportsNotFoundOnABlankImage を参照）。
        // **この行を外すと、直前に捨てた市松模様の画素が残り、3x3 の格子が
        // 実際に 9 点見つかってしまう**（実測。ゼロ埋めすると 0 点。
        // dev.ps1 test-managed で、この行を外すと本当に落ちることを確認済み）。
        blank.CopyFrom(new byte[64 * 64], 64);

        // **空配列は誤りではない。** 格子が写っていなかっただけである。
        Assert.Empty(CvCalibration.FindChessboardCorners(blank, 3, 3));
    }

    [Fact]
    public void FindChessboardCornersFindsASyntheticBoard()
    {
        // **盤は正方形にしない。** 正方形だと x と y の値域が同じになるので、
        // 取り違えても格子の形が変わらず、この検査が入れ替えを見抜けない
        // （L1 で実測した —— 7x7 では xy を入れ替えても緑のままだった）。
        // 128 x 112、16 画素のセルで 8x7 のセル = 7x6 の内側格子点になる。
        using var board = MakeCheckerboard(128, 112, 16);

        CvPoint2[] corners = CvCalibration.FindChessboardCorners(board, 7, 6);

        Assert.Equal(42, corners.Length);

        // **範囲だけを見ない。** 範囲しか見ない検査は、平面配置でも
        // xy 入れ替えでも同一点 42 個でも緑になる（これも L1 で実測した）。
        // 格子の構造そのものを見る —— x は 7 通り、y は 6 通りに落ちるはずである。
        var xs = corners.Select(p => (int)Math.Round(p.X / 16.0)).Distinct().OrderBy(v => v).ToArray();
        var ys = corners.Select(p => (int)Math.Round(p.Y / 16.0)).Distinct().OrderBy(v => v).ToArray();

        Assert.Equal(new[] { 1, 2, 3, 4, 5, 6, 7 }, xs);
        Assert.Equal(new[] { 1, 2, 3, 4, 5, 6 }, ys);
    }

    [Fact]
    public void FindChessboardCornersRejectsATooSmallPattern()
    {
        using var src = CvMat.Create(64, 64, CvMatType.Gray8);

        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvCalibration.FindChessboardCorners(src, 1, 7));
        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvCalibration.FindChessboardCorners(src, 7, 0));
    }

    [Fact]
    public void FindChessboardCornersRejectsAPatternExceedingTheCornerLimit()
    {
        // レビュー I4: 修正前は int のまま計算していたため、(32768, 32768) は
        // int.MinValue へ折り返して new float[負] が OverflowException になり、
        // (50000, 50000) は 2 回折り返して 705,032,704 個（約 2.8 GB）を
        // 確保してから native が断っていた。**native の門に届く前に、
        // ArgumentOutOfRangeException で断ること**を見る。
        using var src = CvMat.Create(64, 64, CvMatType.Gray8);

        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvCalibration.FindChessboardCorners(src, 32768, 32768));
        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvCalibration.FindChessboardCorners(src, 50000, 50000));

        // 上限ちょうど（100 x 100 = 10000）は拒否されないことも見る
        // —— capacity は足りるので、実際に呼び出しまで進む。
        var ex = Record.Exception(() => CvCalibration.FindChessboardCorners(src, 100, 100));
        Assert.Null(ex);
    }

    [Fact]
    public void TheManagedCoefficientCountsMatchWhatNativeAccepts()
    {
        // IsAcceptedCoefficientCount は C と C# に二重に書かれている。
        // **片方だけ変わったときに落ちる検査を置く。**
        using var src = CvMat.Create(32, 32, CvMatType.Gray8);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        foreach (int n in new[] { 4, 5, 8, 12, 14 })
        {
            var coeffs = new double[n];
            var ex = Record.Exception(() => CvCalibration.Undistort(src, Camera, coeffs, dst));
            Assert.Null(ex);
        }

        // native も同じ集合を持っていることを、C# の検証を迂回して確かめる。
        foreach (int n in new[] { 3, 6, 15 })
        {
            var coeffs = new double[n];
            var status = (CvStatus)CvUnity.Interop.NativeMethods.ocvu_undistort(
                src.Handle, Camera, (long)Camera.Length * sizeof(double),
                coeffs, (long)n * sizeof(double), dst.Handle);
            Assert.Equal(CvStatus.InvalidArgument, status);
        }
    }

    [Fact]
    public void TheManagedCornerLimitMatchesWhatNativeAccepts()
    {
        // CvCalibration の MaxCorners（10000）は C の OCVU_CHESSBOARD_MAX_CORNERS の
        // 写しである。**写しなので、放っておくと片方だけ変わる。** 境界の両側を
        // C# の検証を迂回して native に問う（FeaturesTests と同じ形）。
        using var img = CvMat.Create(8, 8, CvMatType.Gray8);
        var raw = new float[1];

        // 100 x 100 = 10000 は受理される（capacity 不足で BufferTooSmall になるが、
        // 上限の検証は通っている）。
        var atTheLimit = (CvStatus)CvUnity.Interop.NativeMethods.ocvu_find_chessboard_corners(
            img.Handle, 100, 100, raw, 1, out _);
        Assert.Equal(CvStatus.BufferTooSmall, atTheLimit);

        // 100 x 101 = 10100 は上限の検証で弾かれる。
        var overTheLimit = (CvStatus)CvUnity.Interop.NativeMethods.ocvu_find_chessboard_corners(
            img.Handle, 100, 101, raw, 1, out _);
        Assert.Equal(CvStatus.InvalidArgument, overTheLimit);
    }

    /// <summary>市松模様を作る。**幅と高さを別々に取る** —— 正方形の盤では
    /// x と y の取り違えを検出できないため。</summary>
    private static CvMat MakeCheckerboard(int width, int height, int cell)
    {
        var mat = CvMat.Create(height, width, CvMatType.Gray8);
        var pixels = new byte[width * height];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                pixels[(y * width) + x] = ((x / cell) + (y / cell)) % 2 == 0 ? (byte)255 : (byte)0;
            }
        }
        mat.CopyFrom(pixels, width);
        return mat;
    }
}
