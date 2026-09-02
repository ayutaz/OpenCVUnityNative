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

    // -----------------------------------------------------------------------
    // CalibrateCamera —— 校正の輪を閉じる段。
    // -----------------------------------------------------------------------

    private const int BoardCols = 7;
    private const int BoardRows = 6;
    private const int PointsPerView = BoardCols * BoardRows;
    private const int ViewCount = 8;
    private const int SyntheticWidth = 640;
    private const int SyntheticHeight = 480;

    // 合成に使う既知のカメラ。**歪み係数を 0 にしない** —— 0 にすると
    // 「歪みを推定しない実装」でも通ってしまう。
    private const double SyntheticFx = 500.0;
    private const double SyntheticFy = 520.0;

    /// <summary>盤の 3D 座標（z = 0 の平面）。全 view で同じ形を使う。</summary>
    private static CvPoint3[] MakeBoard()
    {
        var board = new CvPoint3[PointsPerView];
        for (int r = 0; r < BoardRows; r++)
        {
            for (int c = 0; c < BoardCols; c++)
            {
                board[(r * BoardCols) + c] = new CvPoint3(c * 0.03f, r * 0.03f, 0f);
            }
        }
        return board;
    }

    /// <summary>
    /// 既知のカメラで盤を投影した画像点。**view ごとに姿勢を変える** ——
    /// 全部同じ向きだと平面パターンの校正は解けない。
    /// </summary>
    /// <remarks>
    /// 投影は C# 側で素直に計算する（native の実装と同じ経路を使わない ——
    /// 両方が同じだけ間違っていても緑になってしまうため）。歪みは
    /// 半径方向の 2 項だけを当てる。
    /// </remarks>
    private static CvPoint2[] ProjectBoard(CvPoint3[] board, int viewIndex)
    {
        double t = viewIndex;
        double rx = (0.05 * t) - 0.15;
        double ry = (0.04 * t) - 0.12;
        double rz = 0.02 * t;
        double tx = -0.09 + (0.005 * t);
        double ty = -0.07 + (0.004 * t);
        double tz = 0.5 + (0.02 * t);

        // 回転ベクトルから回転行列（Rodrigues）。
        double theta = Math.Sqrt((rx * rx) + (ry * ry) + (rz * rz));
        double kx = theta > 1e-12 ? rx / theta : 0.0;
        double ky = theta > 1e-12 ? ry / theta : 0.0;
        double kz = theta > 1e-12 ? rz / theta : 0.0;
        double ct = Math.Cos(theta);
        double st = Math.Sin(theta);
        double vt = 1.0 - ct;

        double[,] rot =
        {
            { ct + (kx * kx * vt), (kx * ky * vt) - (kz * st), (kx * kz * vt) + (ky * st) },
            { (ky * kx * vt) + (kz * st), ct + (ky * ky * vt), (ky * kz * vt) - (kx * st) },
            { (kz * kx * vt) - (ky * st), (kz * ky * vt) + (kx * st), ct + (kz * kz * vt) },
        };

        var projected = new CvPoint2[board.Length];
        for (int i = 0; i < board.Length; i++)
        {
            double X = board[i].X;
            double Y = board[i].Y;
            double Z = board[i].Z;

            double cx = (rot[0, 0] * X) + (rot[0, 1] * Y) + (rot[0, 2] * Z) + tx;
            double cy = (rot[1, 0] * X) + (rot[1, 1] * Y) + (rot[1, 2] * Z) + ty;
            double cz = (rot[2, 0] * X) + (rot[2, 1] * Y) + (rot[2, 2] * Z) + tz;

            double a = cx / cz;
            double b = cy / cz;
            double r2 = (a * a) + (b * b);
            double radial = 1.0 + (-0.20 * r2) + (0.08 * r2 * r2);

            double u = (SyntheticFx * a * radial) + 320.0;
            double v = (SyntheticFy * b * radial) + 240.0;
            projected[i] = new CvPoint2((float)u, (float)v);
        }
        return projected;
    }

    private static (CvPoint3[][] Object, CvPoint2[][] Image) MakeSyntheticCalibration()
    {
        var board = MakeBoard();
        var objectPoints = new CvPoint3[ViewCount][];
        var imagePoints = new CvPoint2[ViewCount][];
        for (int v = 0; v < ViewCount; v++)
        {
            objectPoints[v] = board;
            imagePoints[v] = ProjectBoard(board, v);
        }
        return (objectPoints, imagePoints);
    }

    [Fact]
    public void CalibrateCameraRecoversTheKnownIntrinsics()
    {
        // **status が返ったことだけを見ない。** 合成に使った焦点距離が戻ることを見る。
        var (objectPoints, imagePoints) = MakeSyntheticCalibration();

        CvCalibrationResult result = CvCalibration.CalibrateCamera(
            objectPoints, imagePoints, SyntheticWidth, SyntheticHeight);

        Assert.Equal(9, result.CameraMatrix.Length);
        Assert.InRange(result.CameraMatrix[0], SyntheticFx * 0.95, SyntheticFx * 1.05);
        Assert.InRange(result.CameraMatrix[4], SyntheticFy * 0.95, SyntheticFy * 1.05);

        // 行優先の 3x3 なので、残りは 0 と 1 でなければならない。
        Assert.Equal(0.0, result.CameraMatrix[1]);
        Assert.Equal(0.0, result.CameraMatrix[3]);
        Assert.Equal(0.0, result.CameraMatrix[6]);
        Assert.Equal(0.0, result.CameraMatrix[7]);
        Assert.Equal(1.0, result.CameraMatrix[8]);

        // **歪みを推定していることを見る。** ここを見ないと「係数を 0 のまま
        // 返す」実装が通る。合成に使った k1 は -0.20 である。
        Assert.True(result.DistortionCoefficients.Length >= 5);
        Assert.InRange(result.DistortionCoefficients[0], -0.30, -0.10);

        Assert.InRange(result.ReprojectionError, 0.0, 1.0);
    }

    [Fact]
    public void CalibrateCameraSplitsEachPoseIntoRotationAndTranslation()
    {
        // **native は 1 view につき 6 個の double を返す**（回転 3 個のあと並進 3 個）。
        // **その並びを取り違えたら、ここが落ちなければならない。**
        var (objectPoints, imagePoints) = MakeSyntheticCalibration();

        CvCalibrationResult result = CvCalibration.CalibrateCamera(
            objectPoints, imagePoints, SyntheticWidth, SyntheticHeight);

        Assert.Equal(ViewCount, result.ViewPoses.Length);

        for (int v = 0; v < ViewCount; v++)
        {
            CvViewPose pose = result.ViewPoses[v];

            // 合成では tz を 0.5 から 0.02 ずつ増やしてある。
            Assert.InRange(pose.TranslationZ, 0.5 + (0.02 * v) - 0.06, 0.5 + (0.02 * v) + 0.06);

            // 回転ベクトルの大きさは 1 rad 未満に収まる合成にしてある。
            // **回転と並進を入れ替えると、tz（0.5 以上）が回転側に来て破れる。**
            double magnitude = Math.Sqrt(
                (pose.RotationX * pose.RotationX) +
                (pose.RotationY * pose.RotationY) +
                (pose.RotationZ * pose.RotationZ));
            Assert.True(magnitude < 1.0, $"view {v} の回転が大きすぎる（並進と入れ替わっていないか）");
        }
    }

    [Fact]
    public void CalibrateCameraRejectsJaggedInput()
    {
        // **native は points_per_view を 1 つしか受け取らない。**
        // したがって「view ごとに点数が違う」ことは native からは見えず、
        // C# の入口でしか断れない。
        var (objectPoints, imagePoints) = MakeSyntheticCalibration();

        // view の数が食い違う。
        var fewerViews = new CvPoint2[ViewCount - 1][];
        Array.Copy(imagePoints, fewerViews, ViewCount - 1);
        Assert.Throws<ArgumentException>(
            () => CvCalibration.CalibrateCamera(objectPoints, fewerViews, SyntheticWidth, SyntheticHeight));

        // view ごとの点数が揃っていない。
        var ragged = (CvPoint2[][])imagePoints.Clone();
        ragged[3] = new CvPoint2[PointsPerView - 1];
        Assert.Throws<ArgumentException>(
            () => CvCalibration.CalibrateCamera(objectPoints, ragged, SyntheticWidth, SyntheticHeight));

        // null の view が混じっている。
        var withNull = (CvPoint3[][])objectPoints.Clone();
        withNull[2] = null;
        Assert.Throws<ArgumentException>(
            () => CvCalibration.CalibrateCamera(withNull, imagePoints, SyntheticWidth, SyntheticHeight));
    }

    [Fact]
    public void CalibrateCameraRejectsInvalidArguments()
    {
        var (objectPoints, imagePoints) = MakeSyntheticCalibration();

        Assert.Throws<ArgumentNullException>(
            () => CvCalibration.CalibrateCamera(null, imagePoints, SyntheticWidth, SyntheticHeight));
        Assert.Throws<ArgumentNullException>(
            () => CvCalibration.CalibrateCamera(objectPoints, null, SyntheticWidth, SyntheticHeight));

        // view が 1 枚では平面パターンの校正は解けない。
        var oneView = new[] { objectPoints[0] };
        var oneImage = new[] { imagePoints[0] };
        Assert.Throws<ArgumentException>(
            () => CvCalibration.CalibrateCamera(oneView, oneImage, SyntheticWidth, SyntheticHeight));

        // 点が 4 未満。
        var tooFew = new[] { new CvPoint3[3], new CvPoint3[3] };
        var tooFewImage = new[] { new CvPoint2[3], new CvPoint2[3] };
        Assert.Throws<ArgumentException>(
            () => CvCalibration.CalibrateCamera(tooFew, tooFewImage, SyntheticWidth, SyntheticHeight));

        // 画像の大きさが 0 以下。
        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvCalibration.CalibrateCamera(objectPoints, imagePoints, 0, SyntheticHeight));
        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvCalibration.CalibrateCamera(objectPoints, imagePoints, SyntheticWidth, 0));
    }

    [Fact]
    public void TheManagedCalibrationPointLimitMatchesWhatNativeAccepts()
    {
        // CvCalibration の MaxCalibrationPoints（100000）は C の
        // OCVU_CALIB_MAX_POINTS の写しである。**写しなので、放っておくと
        // 片方だけ変わる。** 境界の両側を C# の検証を迂回して native に問う。
        //
        // **status だけでは区別できない**（どちらも InvalidArgument になる）ので、
        // last-error のメッセージで分ける。上限**以内**なら長さ検証まで到達して
        // 「長さが足りない」と言われ、上限を**超える**なら、その手前の上限検証で
        // 弾かれる。
        var obj = new float[3];
        var img = new float[2];
        var camera = new double[9];
        var dist = new double[14];
        var poses = new double[64];

        // 2 x 50000 = 100000（上限ちょうど）。上限の検証は通る。
        var atTheLimit = (CvStatus)CvUnity.Interop.NativeMethods.ocvu_calibrate_camera(
            obj, obj.Length * sizeof(float), img, img.Length * sizeof(float),
            2, 50000, 640, 480, camera, camera.Length, dist, dist.Length,
            out _, poses, poses.Length, out _);
        Assert.Equal(CvStatus.InvalidArgument, atTheLimit);
        Assert.DoesNotContain("OCVU_CALIB_MAX_POINTS", CvNative.GetLastErrorMessage());

        // 2 x 50001 = 100002（上限超え）。**上限の検証で弾かれる。**
        var overTheLimit = (CvStatus)CvUnity.Interop.NativeMethods.ocvu_calibrate_camera(
            obj, obj.Length * sizeof(float), img, img.Length * sizeof(float),
            2, 50001, 640, 480, camera, camera.Length, dist, dist.Length,
            out _, poses, poses.Length, out _);
        Assert.Equal(CvStatus.InvalidArgument, overTheLimit);
        Assert.Contains("OCVU_CALIB_MAX_POINTS", CvNative.GetLastErrorMessage());
    }

}
