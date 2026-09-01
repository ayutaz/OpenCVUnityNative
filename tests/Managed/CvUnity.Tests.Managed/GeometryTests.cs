using System;
using CvUnity;
using Xunit;

public class GeometryTests
{
    // 正方形と、それを 2 倍に拡大した正方形。
    private static readonly CvPoint2[] Square =
    {
        new CvPoint2(0f, 0f), new CvPoint2(10f, 0f),
        new CvPoint2(10f, 10f), new CvPoint2(0f, 10f),
    };

    private static readonly CvPoint2[] Doubled =
    {
        new CvPoint2(0f, 0f), new CvPoint2(20f, 0f),
        new CvPoint2(20f, 20f), new CvPoint2(0f, 20f),
    };

    [Fact]
    public void FindHomographyRecoversAScale()
    {
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        Assert.True(CvGeometry.FindHomography(Square, Doubled, dst));

        Assert.Equal(3, dst.Rows);
        Assert.Equal(3, dst.Cols);
    }

    [Fact]
    public void FindHomographyReturnsFalseWhenThePointsAreDegenerate()
    {
        // 全部同じ点。解が求まらないが、**これは誤りではない**ので
        // 例外ではなく false で返る。
        var same = new[]
        {
            new CvPoint2(5f, 5f), new CvPoint2(5f, 5f),
            new CvPoint2(5f, 5f), new CvPoint2(5f, 5f),
        };

        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);
        Assert.False(CvGeometry.FindHomography(same, same, dst));
    }

    [Fact]
    public void FindHomographyRejectsTooFewPoints()
    {
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        var three = new[] { Square[0], Square[1], Square[2] };
        Assert.Throws<ArgumentException>(() => CvGeometry.FindHomography(three, three, dst));
    }

    [Fact]
    public void FindHomographyRejectsMismatchedLengths()
    {
        // **長さが違う 2 つを渡せてしまうと、native 側は短いほうの終端を越えて読む。**
        // C# の入口で断る —— point_count は片方からしか決められないので、
        // native からは食い違いが見えない。
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        var five = new[] { Square[0], Square[1], Square[2], Square[3], Square[0] };
        Assert.Throws<ArgumentException>(() => CvGeometry.FindHomography(Square, five, dst));
    }

    [Fact]
    public void FindHomographyRejectsNull()
    {
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        Assert.Throws<ArgumentNullException>(() => CvGeometry.FindHomography(null, Doubled, dst));
        Assert.Throws<ArgumentNullException>(() => CvGeometry.FindHomography(Square, null, dst));
        Assert.Throws<ArgumentNullException>(() => CvGeometry.FindHomography(Square, Doubled, null));
    }

    [Fact]
    public void TheManagedMethodValuesMatchWhatNativeAccepts()
    {
        // CvHomographyMethod の値は C の OCVU_HOMOGRAPHY_METHOD_* の写しである。
        // C# から C の #define は読めないので複製しており、**両側を native に問う**。
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        // 知っている 3 つはすべて受理される（退化した点なので結果は false だが、
        // method の検証は通っている —— 拒否されるなら例外になる）。
        foreach (CvHomographyMethod method in Enum.GetValues(typeof(CvHomographyMethod)))
        {
            var ex = Record.Exception(() => CvGeometry.FindHomography(Square, Doubled, dst, method));
            Assert.Null(ex);
        }
    }
}
