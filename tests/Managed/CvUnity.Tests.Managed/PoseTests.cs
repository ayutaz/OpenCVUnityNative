using System;
using CvUnity;
using CvUnity.Interop;
using Xunit;

/// <summary>
/// 姿勢 4 本（SolvePnP / Rodrigues 往復 / ProjectPoints）の L3 契約テスト。
/// </summary>
/// <remarks>
/// **数値は手で解いてある。** カメラ行列 fx=fy=500, cx=320, cy=240 で、
/// 回転なし・並進 (0, 0, 10) に置いた 1 辺 2 の正方形は
/// <code>x = 500 * (X / 10) + 320,  y = 500 * (Y / 10) + 240</code>
/// で写る。**期待値を OpenCV に作らせない** —— 投影が壊れたときに期待値も
/// 一緒に壊れて、検査が空振りする（native/tests/test_pose.cpp と同じ理由）。
/// </remarks>
public class PoseTests
{
    /// <summary>fx = fy = 500, cx = 320, cy = 240 を行優先で並べたもの。</summary>
    private static readonly double[] Camera = { 500, 0, 320, 0, 500, 240, 0, 0, 1 };

    /// <summary>1 辺 2 の正方形（z = 0 の平面上）。</summary>
    private static readonly CvPoint3[] Square =
    {
        new CvPoint3(-1f, -1f, 0f),
        new CvPoint3(1f, -1f, 0f),
        new CvPoint3(1f, 1f, 0f),
        new CvPoint3(-1f, 1f, 0f),
    };

    /// <summary>上の正方形を (0, 0, 10) に置いて写した像。**手で解いてある。**</summary>
    private static readonly CvPoint2[] SquareImage =
    {
        new CvPoint2(270f, 190f),
        new CvPoint2(370f, 190f),
        new CvPoint2(370f, 290f),
        new CvPoint2(270f, 290f),
    };

    // -----------------------------------------------------------------------
    // SolvePnP
    // -----------------------------------------------------------------------

    [Fact]
    public void SolvePnpRecoversAKnownPose()
    {
        // **status が返ったことだけを見ない。** 合成に使った姿勢が戻ることを見る。
        CvViewPose pose = CvGeometry.SolvePnP(Square, SquareImage, Camera, null);

        Assert.InRange(pose.RotationX, -1e-3, 1e-3);
        Assert.InRange(pose.RotationY, -1e-3, 1e-3);
        Assert.InRange(pose.RotationZ, -1e-3, 1e-3);
        Assert.InRange(pose.TranslationX, -1e-3, 1e-3);
        Assert.InRange(pose.TranslationY, -1e-3, 1e-3);
        Assert.InRange(pose.TranslationZ, 10.0 - 1e-3, 10.0 + 1e-3);
    }

    [Fact]
    public void SolvePnpAcceptsNullAndEmptyDistortionCoefficients()
    {
        // **どちらも「歪み無し」の正規の指定である**（native の contract は
        // 長さ 0 を歪み無しと定めている）。同じ姿勢が返る。
        CvViewPose withNull = CvGeometry.SolvePnP(Square, SquareImage, Camera, null);
        CvViewPose withEmpty = CvGeometry.SolvePnP(Square, SquareImage, Camera, Array.Empty<double>());

        Assert.Equal(withNull.TranslationZ, withEmpty.TranslationZ, 9);
        Assert.Equal(withNull.RotationX, withEmpty.RotationX, 9);
    }

    [Fact]
    public void SolvePnpRejectsAnUnsupportedCoefficientCount()
    {
        // 4 / 5 / 8 / 12 / 14 のいずれか、または空。3 は入らない。
        Assert.Throws<ArgumentException>(
            () => CvGeometry.SolvePnP(Square, SquareImage, Camera, new double[3]));

        // 5 は入る。**「常に断る」実装でも上の 1 行は緑になる**ので、
        // 受理される側も同じテストで見る。
        var ex = Record.Exception(
            () => CvGeometry.SolvePnP(Square, SquareImage, Camera, new double[5]));
        Assert.Null(ex);
    }

    [Fact]
    public void SolvePnpRejectsMismatchedOrTooFewPoints()
    {
        // **長さが違う 2 つを渡せてしまうと、native 側は短いほうの終端を越えて読む。**
        // point_count は片方からしか決められないので、食い違いは C# でしか見えない。
        var fiveObject = new[]
        {
            Square[0], Square[1], Square[2], Square[3], new CvPoint3(0f, 0f, 0f),
        };
        Assert.Throws<ArgumentException>(
            () => CvGeometry.SolvePnP(fiveObject, SquareImage, Camera, null));

        // 4 点未満では姿勢が決まらない。
        var three = new[] { Square[0], Square[1], Square[2] };
        var threeImage = new[] { SquareImage[0], SquareImage[1], SquareImage[2] };
        Assert.Throws<ArgumentException>(
            () => CvGeometry.SolvePnP(three, threeImage, Camera, null));
    }

    [Fact]
    public void SolvePnpRejectsAWrongSizedCameraMatrix()
    {
        var eight = new double[] { 1, 0, 0, 0, 1, 0, 0, 0 };
        Assert.Throws<ArgumentException>(
            () => CvGeometry.SolvePnP(Square, SquareImage, eight, null));
    }

    [Fact]
    public void SolvePnpRejectsNull()
    {
        Assert.Throws<ArgumentNullException>(
            () => CvGeometry.SolvePnP(null, SquareImage, Camera, null));
        Assert.Throws<ArgumentNullException>(
            () => CvGeometry.SolvePnP(Square, null, Camera, null));
        Assert.Throws<ArgumentNullException>(
            () => CvGeometry.SolvePnP(Square, SquareImage, null, null));
    }

    [Fact]
    public void SolvePnpRejectsACameraWithNoFocalLength()
    {
        // **OpenCV はこれを検出しない** —— 例外も投げず false も返さず、
        // 有限だが無意味な姿勢を成功として返す（native 側の実測）。
        // 境界がそこだけを見て断っていることを、C# からも確かめる。
        var noFocal = new double[] { 0, 0, 320, 0, 0, 240, 0, 0, 1 };

        var ex = Assert.Throws<CvNativeException>(
            () => CvGeometry.SolvePnP(Square, SquareImage, noFocal, null));
        Assert.Equal(CvStatus.InvalidArgument, ex.Status);
    }

    [Fact]
    public void SolvePnpRejectsAMethodThatIsNotDefined()
    {
        // C# の enum は未定義の数値でもキャストが通る。**素通しにしない。**
        var ex = Assert.Throws<CvNativeException>(
            () => CvGeometry.SolvePnP(Square, SquareImage, Camera, null, (CvSolvePnPMethod)99));
        Assert.Equal(CvStatus.InvalidArgument, ex.Status);
    }

    [Fact]
    public void TheManagedMethodValuesMatchWhatNativeAccepts()
    {
        // CvSolvePnPMethod の値は C の OCVU_SOLVEPNP_* の写しである。
        // C# から C の #define は読めないので複製しており、**両側を native に問う**。
        //
        // **見るのは「その番号を method として受け付けるか」だけである。**
        // 公開 API 越しに「例外が出ないこと」を見る形にすると、判定が
        // 「この 4 点をその解法が解けるか」に化ける —— P3P と AP3P は
        // ちょうど 4 点しか受け付けず、IPPE_SQUARE は点の並び順まで縛るので、
        // 解法ごとの都合が「managed と native の値が合っているか」という問いに
        // 混ざる。だから C# の入口を迂回して native の method 検証だけを叩く
        // （CalibrationTests の TheManagedCoefficientCountsMatchWhatNativeAccepts と
        // 同じ形である）。
        var flatObject = new float[] { -1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0 };
        var flatImage = new float[] { 270, 190, 370, 190, 370, 290, 270, 290 };
        var rotation = new double[3];
        var translation = new double[3];

        foreach (CvSolvePnPMethod method in Enum.GetValues(typeof(CvSolvePnPMethod)))
        {
            var status = (CvStatus)NativeMethods.ocvu_solve_pnp(
                flatObject, (long)flatObject.Length * sizeof(float),
                flatImage, (long)flatImage.Length * sizeof(float), 4,
                Camera, (long)Camera.Length * sizeof(double), null, 0,
                (int)method, rotation, 3, translation, 3);

            Assert.NotEqual(CvStatus.InvalidArgument, status);
        }

        // **上の NotEqual が空振りでないことを、同じ経路で示す。**
        // 定義に無い値なら InvalidArgument が返る —— つまり上のループは
        // 「何を渡しても InvalidArgument にならない」を見ていたのではない。
        foreach (int unknown in new[] { -1, 7, 99 })
        {
            var status = (CvStatus)NativeMethods.ocvu_solve_pnp(
                flatObject, (long)flatObject.Length * sizeof(float),
                flatImage, (long)flatImage.Length * sizeof(float), 4,
                Camera, (long)Camera.Length * sizeof(double), null, 0,
                unknown, rotation, 3, translation, 3);

            Assert.Equal(CvStatus.InvalidArgument, status);
        }
    }

    [Fact]
    public void TheManagedPointLimitMatchesWhatNativeAccepts()
    {
        // CvGeometry の MaxPnpPoints（10000）は C の OCVU_PNP_MAX_POINTS の
        // 写しである。**写しなので、放っておくと片方だけ変わる。**
        // 境界の両側を、C# の検証を迂回して native に問う。
        //
        // **配列は点数ぶん本当に用意する。** 短い配列で問うと、上限より下でも
        // 長さの検証で InvalidArgument になり、2 つの経路が区別できなくなる
        // （native は point_count → 長さ → 出力容量 の順に見る）。
        const int limit = 10000;

        var atObject = new float[limit * 3];
        var atImage = new float[limit * 2];
        var rotation = new double[3];
        var translation = new double[3];

        // 上限ちょうどは受理される。出力の容量をわざと 2 にしてあるので
        // BufferTooSmall で返るが、**点数の検証はその手前で通っている。**
        var atTheLimit = (CvStatus)NativeMethods.ocvu_solve_pnp(
            atObject, (long)atObject.Length * sizeof(float),
            atImage, (long)atImage.Length * sizeof(float), limit,
            Camera, (long)Camera.Length * sizeof(double), null, 0,
            (int)CvSolvePnPMethod.Iterative, rotation, 2, translation, 3);
        Assert.Equal(CvStatus.BufferTooSmall, atTheLimit);

        // 1 つ超えると点数の検証で断られる。
        var overObject = new float[(limit + 1) * 3];
        var overImage = new float[(limit + 1) * 2];
        var overTheLimit = (CvStatus)NativeMethods.ocvu_solve_pnp(
            overObject, (long)overObject.Length * sizeof(float),
            overImage, (long)overImage.Length * sizeof(float), limit + 1,
            Camera, (long)Camera.Length * sizeof(double), null, 0,
            (int)CvSolvePnPMethod.Iterative, rotation, 2, translation, 3);
        Assert.Equal(CvStatus.InvalidArgument, overTheLimit);

        // C# 側も同じ上限で断る —— native の門に届く前に、確保もせずに返す。
        Assert.Throws<ArgumentException>(
            () => CvGeometry.SolvePnP(
                new CvPoint3[limit + 1], new CvPoint2[limit + 1], Camera, null));
    }

    // -----------------------------------------------------------------------
    // Rodrigues
    // -----------------------------------------------------------------------

    [Fact]
    public void RodriguesToMatrixTurnsAQuarterTurnAboutZ()
    {
        // z 軸まわりに 90 度。**回転行列は手で書ける。**
        var pose = new CvViewPose(0.0, 0.0, Math.PI / 2.0, 0.0, 0.0, 0.0);

        double[] matrix = CvGeometry.RodriguesToMatrix(pose);

        Assert.Equal(9, matrix.Length);
        double[] expected = { 0, -1, 0, 1, 0, 0, 0, 0, 1 };
        for (int i = 0; i < 9; i++)
        {
            Assert.InRange(matrix[i], expected[i] - 1e-9, expected[i] + 1e-9);
        }
    }

    [Fact]
    public void RodriguesRoundTrips()
    {
        var pose = new CvViewPose(0.1, -0.2, 0.3, 0.0, 0.0, 0.0);

        double[] matrix = CvGeometry.RodriguesToMatrix(pose);
        double[] back = CvGeometry.RodriguesToVector(matrix);

        Assert.Equal(3, back.Length);
        Assert.InRange(back[0], 0.1 - 1e-9, 0.1 + 1e-9);
        Assert.InRange(back[1], -0.2 - 1e-9, -0.2 + 1e-9);
        Assert.InRange(back[2], 0.3 - 1e-9, 0.3 + 1e-9);
    }

    [Fact]
    public void RodriguesToMatrixLooksOnlyAtTheRotation()
    {
        // **並進を混ぜたら落ちなければならない。** 回転が同じで並進だけ違う
        // 2 つの姿勢は、同じ行列にならなければならない。
        var withoutTranslation = new CvViewPose(0.1, -0.2, 0.3, 0.0, 0.0, 0.0);
        var withTranslation = new CvViewPose(0.1, -0.2, 0.3, 7.0, -8.0, 9.0);

        Assert.Equal(
            CvGeometry.RodriguesToMatrix(withoutTranslation),
            CvGeometry.RodriguesToMatrix(withTranslation));
    }

    [Fact]
    public void RodriguesToVectorRejectsAWrongSizedMatrix()
    {
        Assert.Throws<ArgumentNullException>(() => CvGeometry.RodriguesToVector(null));
        Assert.Throws<ArgumentException>(() => CvGeometry.RodriguesToVector(new double[8]));
        Assert.Throws<ArgumentException>(() => CvGeometry.RodriguesToVector(new double[10]));
    }

    // -----------------------------------------------------------------------
    // ProjectPoints
    // -----------------------------------------------------------------------

    [Fact]
    public void ProjectPointsMatchesTheHandComputedProjection()
    {
        // Square を (0, 0, 10) に回転なしで置くと SquareImage に写る。
        // **その期待値はこのファイルの冒頭で手で解いてある。**
        var pose = new CvViewPose(0.0, 0.0, 0.0, 0.0, 0.0, 10.0);

        CvPoint2[] projected = CvGeometry.ProjectPoints(Square, pose, Camera, null);

        Assert.Equal(4, projected.Length);
        for (int i = 0; i < 4; i++)
        {
            Assert.InRange(projected[i].X, SquareImage[i].X - 1e-3f, SquareImage[i].X + 1e-3f);
            Assert.InRange(projected[i].Y, SquareImage[i].Y - 1e-3f, SquareImage[i].Y + 1e-3f);
        }
    }

    [Fact]
    public void ProjectPointsIsTheInverseOfSolvePnp()
    {
        // **2 本が互いの逆になっていることを見る。** 片方が壊れても、
        // もう片方の「手で解いた期待値」を使うテストが残る。
        CvViewPose pose = CvGeometry.SolvePnP(Square, SquareImage, Camera, null);

        CvPoint2[] projected = CvGeometry.ProjectPoints(Square, pose, Camera, null);

        Assert.Equal(4, projected.Length);
        for (int i = 0; i < 4; i++)
        {
            Assert.InRange(projected[i].X, SquareImage[i].X - 1e-2f, SquareImage[i].X + 1e-2f);
            Assert.InRange(projected[i].Y, SquareImage[i].Y - 1e-2f, SquareImage[i].Y + 1e-2f);
        }
    }

    [Fact]
    public void ProjectPointsNeedsOnlyOnePoint()
    {
        // **姿勢は与えられているので 4 点は要らない。** SolvePnP と契約が違う。
        var pose = new CvViewPose(0.0, 0.0, 0.0, 0.0, 0.0, 10.0);
        var one = new[] { new CvPoint3(0f, 0f, 0f) };

        CvPoint2[] projected = CvGeometry.ProjectPoints(one, pose, Camera, null);

        Assert.Single(projected);
        // 原点は主点に写る。
        Assert.InRange(projected[0].X, 320f - 1e-3f, 320f + 1e-3f);
        Assert.InRange(projected[0].Y, 240f - 1e-3f, 240f + 1e-3f);
    }

    [Fact]
    public void ProjectPointsRejectsBadInput()
    {
        var pose = new CvViewPose(0.0, 0.0, 0.0, 0.0, 0.0, 10.0);

        Assert.Throws<ArgumentNullException>(
            () => CvGeometry.ProjectPoints(null, pose, Camera, null));
        Assert.Throws<ArgumentNullException>(
            () => CvGeometry.ProjectPoints(Square, pose, null, null));
        Assert.Throws<ArgumentException>(
            () => CvGeometry.ProjectPoints(Array.Empty<CvPoint3>(), pose, Camera, null));
        Assert.Throws<ArgumentException>(
            () => CvGeometry.ProjectPoints(Square, pose, new double[8], null));
        Assert.Throws<ArgumentException>(
            () => CvGeometry.ProjectPoints(Square, pose, Camera, new double[3]));
    }
}
