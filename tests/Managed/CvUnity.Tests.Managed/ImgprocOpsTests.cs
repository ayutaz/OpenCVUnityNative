using System;
using System.Linq;
using CvUnity;
using CvUnity.Interop;
using Xunit;

/// <summary>
/// M5 の API 拡張で <c>CvOps</c> に加わった imgproc の 9 本を、
/// P/Invoke 越しに実物の native library に対して確かめる（L3）。
/// </summary>
/// <remarks>
/// M2 からある 3 本（cvtColor / resize / GaussianBlur）は
/// <c>ImgprocTests</c> が native の宣言を直接叩いて見ている。
/// こちらは<b>公開 API の側</b>を見る —— 2 回呼びを隠していること、
/// 入出力兼用の buffer を外へ出していないこと、managed の enum の値が
/// native に受け付けられることは、そこにしか現れない。
/// </remarks>
public class ImgprocOpsTests
{
    // ---------------------------------------------------------------
    // Threshold
    // ---------------------------------------------------------------

    [Fact]
    public void ThresholdWithOtsuReturnsTheValueItPicked()
    {
        // 10 と 200 の 2 山だけを持つ画像。
        using var src = MakeGray(8, 8, (x, y) => x < 4 ? (byte)10 : (byte)200);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        // **渡す threshold は 0 である。** Otsu が無視して自分で選ぶことを、
        // 「返り値が 0 ではない」形で見られるようにしてある。
        double computed = CvOps.Threshold(
            src, dst, 0.0, 255.0, CvThresholdType.Binary | CvThresholdType.Otsu);

        // **選ばれた値そのものを狭く縛らない。** 2 値のヒストグラムでは
        // 10 以上 199 以下のどこで分割しても分離の良さが同じで、実装は最初に
        // 最大を取る値を返す（実測では ちょうど 10.0）。見たいのは
        // 「Otsu が画像から値を選んで返している」ことである。
        Assert.True(computed >= 10.0 && computed < 200.0,
                    $"Otsu が選んだしきい値が範囲の外にあります: {computed}");

        // どの t が選ばれても、10 は t を超えず 200 は超えるので結果は同じになる。
        byte[] binarized = ReadGray(dst);
        for (int y = 0; y < 8; y++)
        {
            for (int x = 0; x < 8; x++)
            {
                Assert.Equal(x < 4 ? (byte)0 : (byte)255, binarized[(y * 8) + x]);
            }
        }
    }

    [Fact]
    public void ThresholdWithoutOtsuReturnsTheValueItWasGiven()
    {
        // **上の検査の対照である。** これが無いと「返り値は渡した値をそのまま
        // 返しているだけ」でも Otsu の検査が通りうる形になる（0 を渡した場合を
        // 除けば）。ここでは 128 を渡し、128 が返ることを見る。
        using var src = MakeGray(8, 8, (x, y) => x < 4 ? (byte)10 : (byte)200);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        Assert.Equal(128.0, CvOps.Threshold(src, dst, 128.0, 255.0, CvThresholdType.Binary));
    }

    [Fact]
    public void ThresholdRejectsNull()
    {
        using var src = MakeGray(4, 4, (x, y) => (byte)0);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        Assert.Throws<ArgumentNullException>(
            () => CvOps.Threshold(null, dst, 1, 255, CvThresholdType.Binary));
        Assert.Throws<ArgumentNullException>(
            () => CvOps.Threshold(src, null, 1, 255, CvThresholdType.Binary));
    }

    // ---------------------------------------------------------------
    // Canny
    // ---------------------------------------------------------------

    [Fact]
    public void CannyFindsTheEdgeAtTheStep()
    {
        // 左半分が黒、右半分が白。段差は x = 16 の手前にある。
        using var src = MakeGray(32, 32, (x, y) => x < 16 ? (byte)0 : (byte)255);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        CvOps.Canny(src, dst, 50.0, 150.0);

        Assert.Equal(32, dst.Rows);
        Assert.Equal(32, dst.Cols);

        byte[] edges = ReadGray(dst);

        // **「非ゼロが 1 つでもある」で満足しない。** それだと画像全体が
        // 白く塗られても通る。段差の位置に固まっていることまで見る。
        int[] columns = Enumerable.Range(0, 32 * 32)
            .Where(i => edges[i] != 0)
            .Select(i => i % 32)
            .Distinct()
            .ToArray();

        Assert.NotEmpty(columns);
        Assert.All(columns, c => Assert.InRange(c, 13, 18));
    }

    [Fact]
    public void CannyRejectsANegativeThreshold()
    {
        using var src = MakeGray(8, 8, (x, y) => (byte)0);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        var ex = Assert.Throws<CvNativeException>(() => CvOps.Canny(src, dst, -1.0, 10.0));
        Assert.Equal(CvStatus.InvalidArgument, ex.Status);
    }

    [Fact]
    public void CannyAcceptsBothGradientNorms()
    {
        // **bool は C# 側の入口にしか無い。** native へは 0 / 1 の int で渡している
        // ので、両方の分岐が実際に通ることを見ておく。
        using var src = MakeGray(32, 32, (x, y) => x < 16 ? (byte)0 : (byte)255);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        Assert.Null(Record.Exception(() => CvOps.Canny(src, dst, 50, 150, 3, false)));
        Assert.Null(Record.Exception(() => CvOps.Canny(src, dst, 50, 150, 3, true)));
    }

    // ---------------------------------------------------------------
    // MorphologyEx
    // ---------------------------------------------------------------

    [Fact]
    public void DilatingASinglePixelWithAThreeByThreeKernelLightsNinePixels()
    {
        using var src = MakeGray(9, 9, (x, y) => (x == 4 && y == 4) ? (byte)255 : (byte)0);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        CvOps.MorphologyEx(src, dst, CvMorphOp.Dilate, CvMorphShape.Rect, 3, 3);

        byte[] after = ReadGray(dst);

        // **個数だけを数えない。** 9 個という数は、別の場所が 9 画素光っても
        // 満たせる。中心のまわりの 3x3 ちょうどであることを画素ごとに見る。
        for (int y = 0; y < 9; y++)
        {
            for (int x = 0; x < 9; x++)
            {
                bool inside = Math.Abs(x - 4) <= 1 && Math.Abs(y - 4) <= 1;
                Assert.Equal(inside ? (byte)255 : (byte)0, after[(y * 9) + x]);
            }
        }
        Assert.Equal(9, after.Count(b => b != 0));
    }

    [Fact]
    public void ErodingASinglePixelLeavesNothing()
    {
        // 膨張だけを見ると、op を無視して常に膨張する実装でも緑になる。
        using var src = MakeGray(9, 9, (x, y) => (x == 4 && y == 4) ? (byte)255 : (byte)0);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        CvOps.MorphologyEx(src, dst, CvMorphOp.Erode, CvMorphShape.Rect, 3, 3);

        Assert.All(ReadGray(dst), b => Assert.Equal(0, b));
    }

    // ---------------------------------------------------------------
    // MatchTemplate
    // ---------------------------------------------------------------

    [Fact]
    public void MatchTemplateFindsThePatchAndReturnsAFloatResponse()
    {
        const int Size = 16;
        const int Side = 4;
        const int PatchX = 5;
        const int PatchY = 3;

        // **正方形の位置を x と y で変える。** 同じにすると取り違えても
        // 気づけない（CalibrationTests が同じ理由で盤を長方形にしている）。
        using var image = MakeGray(Size, Size, (x, y) =>
            (x >= PatchX && x < PatchX + Side && y >= PatchY && y < PatchY + Side)
                ? (byte)255 : (byte)0);
        using var templ = MakeGray(Side, Side, (x, y) => (byte)255);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        CvOps.MatchTemplate(image, templ, dst, CvTemplateMatchMethod.SquaredDifference);

        Assert.Equal(Size - Side + 1, dst.Rows);
        Assert.Equal(Size - Side + 1, dst.Cols);
        Assert.Equal(1, dst.Channels);

        // **CvMat は Type を公開していない。** 1 画素が 4 バイトであることは
        // step から測る（32 bit 浮動小数 1 channel なら Cols * 4 になる）。
        Assert.Equal((long)dst.Cols * sizeof(float), dst.Step);

        float[] response = ReadFloats(dst);
        int best = 0;
        for (int i = 1; i < response.Length; i++)
        {
            if (response[i] < response[best]) { best = i; }
        }

        // 差の二乗和なので**小さいほど似ている**。完全一致の位置は 0 になる。
        Assert.Equal(PatchX, best % dst.Cols);
        Assert.Equal(PatchY, best / dst.Cols);
        Assert.InRange(response[best], -1f, 1f);
    }

    [Fact]
    public void MatchTemplateRejectsATemplateBiggerThanTheImage()
    {
        // **OpenCV はこれを断らない** —— 両方向とも templ のほうが大きいとき、
        // 例外を投げずに image と templ を入れ替えて計算する（2026-09-05 に実測）。
        // 任せると出力の形（image - templ + 1）が黙って破られるので、
        // C ABI が自分で断っている。ここはそれが公開 API まで届くことを見る。
        using var image = MakeGray(4, 4, (x, y) => (byte)0);
        using var templ = MakeGray(8, 8, (x, y) => (byte)0);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        var ex = Assert.Throws<CvNativeException>(
            () => CvOps.MatchTemplate(image, templ, dst, CvTemplateMatchMethod.SquaredDifference));
        Assert.Equal(CvStatus.InvalidArgument, ex.Status);
    }

    // ---------------------------------------------------------------
    // GetPerspectiveTransform / WarpPerspective
    // ---------------------------------------------------------------

    [Fact]
    public void GetPerspectiveTransformAndWarpPerspectiveMakeTheRoundTrip()
    {
        // 16x16 の四隅を 32x32 の四隅へ写す = ちょうど 2 倍に拡大する変換。
        var before = new[]
        {
            new CvPoint2(0f, 0f), new CvPoint2(16f, 0f),
            new CvPoint2(16f, 16f), new CvPoint2(0f, 16f),
        };
        var after = new[]
        {
            new CvPoint2(0f, 0f), new CvPoint2(32f, 0f),
            new CvPoint2(32f, 32f), new CvPoint2(0f, 32f),
        };

        using var transform = CvMat.Create(1, 1, CvMatType.Gray8);
        CvOps.GetPerspectiveTransform(before, after, transform);

        Assert.Equal(3, transform.Rows);
        Assert.Equal(3, transform.Cols);
        // 64 bit 浮動小数 1 channel なら 1 行は 3 * 8 バイトになる。
        Assert.Equal(3L * sizeof(double), transform.Step);

        // **画素の値を x と y の両方から作る。** 一様な画像だと、変換が
        // 恒等でも上下反転でも同じ結果になり、この検査が何も見なくなる。
        using var src = MakeGray(16, 16, (x, y) => (byte)((x * 16) + y));
        using var warped = CvMat.Create(1, 1, CvMatType.Gray8);

        CvOps.WarpPerspective(src, warped, transform, 32, 32,
                              CvOps.InterNearest, CvBorderMode.Constant);

        Assert.Equal(32, warped.Rows);
        Assert.Equal(32, warped.Cols);

        byte[] source = ReadGray(src);
        byte[] result = ReadGray(warped);

        // 2 倍なので、出力の偶数座標が入力の 1 画素にちょうど対応する
        // （最近傍なので値は写しになる）。奇数座標は境界の丸めが混ざるので見ない。
        for (int y = 0; y < 16; y++)
        {
            for (int x = 0; x < 16; x++)
            {
                Assert.Equal(source[(y * 16) + x], result[(y * 2 * 32) + (x * 2)]);
            }
        }
    }

    [Fact]
    public void GetPerspectiveTransformRejectsAnythingButFourPoints()
    {
        // **native は 4 点より長い配列を通し、先頭の 4 点だけを読む。**
        // 黙って捨てられると呼ぶ側は気づけないので、C# の入口が断る。
        var four = new[]
        {
            new CvPoint2(0f, 0f), new CvPoint2(1f, 0f),
            new CvPoint2(1f, 1f), new CvPoint2(0f, 1f),
        };
        var five = four.Concat(new[] { new CvPoint2(2f, 2f) }).ToArray();
        var three = four.Take(3).ToArray();

        using var transform = CvMat.Create(1, 1, CvMatType.Gray8);

        Assert.Throws<ArgumentException>(() => CvOps.GetPerspectiveTransform(five, four, transform));
        Assert.Throws<ArgumentException>(() => CvOps.GetPerspectiveTransform(four, five, transform));
        Assert.Throws<ArgumentException>(() => CvOps.GetPerspectiveTransform(three, four, transform));
    }

    [Fact]
    public void GetPerspectiveTransformAndWarpPerspectiveRejectNull()
    {
        var four = new[]
        {
            new CvPoint2(0f, 0f), new CvPoint2(1f, 0f),
            new CvPoint2(1f, 1f), new CvPoint2(0f, 1f),
        };
        using var mat = CvMat.Create(1, 1, CvMatType.Gray8);

        Assert.Throws<ArgumentNullException>(() => CvOps.GetPerspectiveTransform(null, four, mat));
        Assert.Throws<ArgumentNullException>(() => CvOps.GetPerspectiveTransform(four, null, mat));
        Assert.Throws<ArgumentNullException>(() => CvOps.GetPerspectiveTransform(four, four, null));

        Assert.Throws<ArgumentNullException>(
            () => CvOps.WarpPerspective(null, mat, mat, 4, 4, CvOps.InterNearest, CvBorderMode.Constant));
        Assert.Throws<ArgumentNullException>(
            () => CvOps.WarpPerspective(mat, null, mat, 4, 4, CvOps.InterNearest, CvBorderMode.Constant));
        Assert.Throws<ArgumentNullException>(
            () => CvOps.WarpPerspective(mat, mat, null, 4, 4, CvOps.InterNearest, CvBorderMode.Constant));
    }

    // ---------------------------------------------------------------
    // HoughLinesP
    // ---------------------------------------------------------------

    [Fact]
    public void HoughLinesPFindsAHorizontalLine()
    {
        using var src = MakeGray(64, 64, (x, y) =>
            (y == 32 && x >= 5 && x <= 58) ? (byte)255 : (byte)0);

        CvLine[] lines = CvOps.HoughLinesP(src, 1.0, Math.PI / 180.0, 30, 30.0, 3.0);

        Assert.NotEmpty(lines);

        // **本数だけを見ない。** 見つかった線分が実際に「y = 32 の横線」で
        // あることまで見る（そうでないと、何でもよいから 1 本返す実装で通る）。
        Assert.Contains(lines, line =>
            Math.Abs(line.Start.Y - line.End.Y) <= 1f &&
            Math.Abs(line.End.X - line.Start.X) >= 30f &&
            line.Start.Y >= 31f && line.Start.Y <= 33f);
    }

    [Fact]
    public void HoughLinesPReturnsAnEmptyArrayWhenThereIsNoLine()
    {
        // **空配列は誤りではない。** 線分が写っていなかっただけである。
        using var blank = MakeGray(64, 64, (x, y) => (byte)0);

        Assert.Empty(CvOps.HoughLinesP(blank, 1.0, Math.PI / 180.0, 30, 30.0, 3.0));
    }

    [Fact]
    public void HoughLinesPGrowsTheBufferWhenTheFirstGuessIsTooSmall()
    {
        // 横線を 8 本引いて、最初の見積もりを 1 本にする。
        // **溢れを隠していなければ、ここは 1 本しか返らないか例外になる。**
        // native は溢れたときに 1 バイトも書かないので、2 回目を呼ばない実装は
        // 「線があるのに空」か「本数だけ大きい」形で必ず落ちる。
        using var src = MakeGray(64, 64, (x, y) =>
            (y % 8 == 4 && x >= 2 && x <= 61) ? (byte)255 : (byte)0);

        CvLine[] lines = CvOps.HoughLinesP(src, 1.0, Math.PI / 180.0, 30, 30.0, 3.0, maxLines: 1);

        Assert.True(lines.Length > 1,
                    $"2 回呼びが働いていれば 1 本を超えるはずです（返ったのは {lines.Length} 本）。");
        Assert.All(lines, line => Assert.True(Math.Abs(line.Start.Y - line.End.Y) <= 1f));
    }

    [Fact]
    public void HoughLinesPRejectsABadMaxLines()
    {
        using var src = MakeGray(8, 8, (x, y) => (byte)0);

        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvOps.HoughLinesP(src, 1.0, Math.PI / 180.0, 30, 10.0, 3.0, maxLines: 0));
        // 4 倍すると int に収まらない値は、掛ける前に断る。
        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvOps.HoughLinesP(src, 1.0, Math.PI / 180.0, 30, 10.0, 3.0, maxLines: int.MaxValue));
    }

    [Fact]
    public void HoughLinesPSurfacesNativeArgumentChecks()
    {
        using var src = MakeGray(8, 8, (x, y) => (byte)0);

        var ex = Assert.Throws<CvNativeException>(
            () => CvOps.HoughLinesP(src, 0.0, Math.PI / 180.0, 30, 10.0, 3.0));
        Assert.Equal(CvStatus.InvalidArgument, ex.Status);
    }

    // ---------------------------------------------------------------
    // CornerSubPix
    // ---------------------------------------------------------------

    [Fact]
    public void CornerSubPixReturnsANewArrayAndLeavesTheGivenOneAlone()
    {
        // **C ABI の points は入出力兼用である。** その形を公開 API へ出していない
        // ことを見る —— 呼ぶ側が持っている「検出したままの位置」が、精緻化の
        // 副作用で黙って消えてはならない。
        using var board = MakeCheckerboard(64, 16);
        var given = new[] { new CvPoint2(15f, 15f) };

        CvPoint2[] refined = CvOps.CornerSubPix(board, given);

        Assert.NotSame(given, refined);
        Assert.Equal(15f, given[0].X);
        Assert.Equal(15f, given[0].Y);

        Assert.Single(refined);
        // 16 画素のセルなので、内側の角は 15.5 のあたりにある。
        Assert.InRange(refined[0].X, 13f, 18f);
        Assert.InRange(refined[0].Y, 13f, 18f);
    }

    [Fact]
    public void CornerSubPixRejectsAnEmptyOrOversizedArray()
    {
        using var board = MakeCheckerboard(64, 16);

        Assert.Throws<ArgumentException>(() => CvOps.CornerSubPix(board, Array.Empty<CvPoint2>()));
        Assert.Throws<ArgumentException>(() => CvOps.CornerSubPix(board, new CvPoint2[10001]));
        Assert.Throws<ArgumentNullException>(() => CvOps.CornerSubPix(board, null));
        Assert.Throws<ArgumentNullException>(
            () => CvOps.CornerSubPix(null, new[] { new CvPoint2(1f, 1f) }));
    }

    [Fact]
    public void TheManagedCornerPointLimitMatchesWhatNativeAccepts()
    {
        // CvOps の 10000 は C の OCVU_CORNER_MAX_POINTS の写しである。
        // **写しなので、放っておくと片方だけ変わる。** 境界の両側を native に問う。
        //
        // 点数の検査と長さの検査はどちらも INVALID_ARGUMENT を返すので、
        // **status では区別できない。** どちらの門で止まったかを last-error の
        // メッセージで見分ける —— 10000 は点数の門を通り抜けて長さの門に落ち、
        // 10001 は点数の門そのもので落ちる。
        //
        // **"point_count" という語では見分けられない。** 長さの門のメッセージも
        // "too small for point_count" と述べているので、両方に現れる。
        // 片方にしか現れない語（"points_length" と "must be between"）で見る。
        using var src = MakeGray(16, 16, (x, y) => (byte)0);
        var one = new float[2];

        var atTheLimit = (CvStatus)NativeMethods.ocvu_corner_sub_pix(
            src.Handle, one, (long)one.Length * sizeof(float), 10000, 1, -1, 1, 0.1);
        Assert.Equal(CvStatus.InvalidArgument, atTheLimit);
        Assert.Contains("points_length", CvNative.GetLastErrorMessage());

        var overTheLimit = (CvStatus)NativeMethods.ocvu_corner_sub_pix(
            src.Handle, one, (long)one.Length * sizeof(float), 10001, 1, -1, 1, 0.1);
        Assert.Equal(CvStatus.InvalidArgument, overTheLimit);
        Assert.Contains("must be between", CvNative.GetLastErrorMessage());
        Assert.DoesNotContain("points_length", CvNative.GetLastErrorMessage());
    }

    // ---------------------------------------------------------------
    // FindContours
    // ---------------------------------------------------------------

    [Fact]
    public void FindContoursFindsAWhiteSquareAsFourPoints()
    {
        using var src = MakeGray(32, 32, (x, y) =>
            (x >= 8 && x <= 23 && y >= 8 && y <= 23) ? (byte)255 : (byte)0);

        CvPoint2[][] contours = CvOps.FindContours(
            src, CvRetrievalMode.External, CvChainApproxMethod.Simple);

        Assert.Single(contours);
        Assert.Equal(4, contours[0].Length);

        // **本数と点数だけでは足りない。** 4 点がどこにあるかまで見る。
        var corners = contours[0]
            .Select(p => ((int)p.X, (int)p.Y))
            .OrderBy(p => p.Item1)
            .ThenBy(p => p.Item2)
            .ToArray();
        Assert.Equal(new[] { (8, 8), (8, 23), (23, 8), (23, 23) }, corners);
    }

    [Fact]
    public void FindContoursKeepsEveryPixelWhenNothingIsApproximated()
    {
        // Simple だけを見ると、method を無視する実装でも緑になる。
        using var src = MakeGray(32, 32, (x, y) =>
            (x >= 8 && x <= 23 && y >= 8 && y <= 23) ? (byte)255 : (byte)0);

        CvPoint2[][] contours = CvOps.FindContours(
            src, CvRetrievalMode.External, CvChainApproxMethod.None);

        Assert.Single(contours);

        // **見たいのは「method が無視されていない」ことである。** 同じ矩形を
        // Simple で取ると 4 点なので、間引かない指定でそれを大きく上回ることを見る。
        // 16x16 の塗りつぶし矩形の縁は 4 * 16 - 4 = 60 画素になるはずだが、
        // 輪郭追跡が縁の画素をどう数えるかはこの検査の主題ではないので広く取る。
        Assert.InRange(contours[0].Length, 56, 64);
    }

    [Fact]
    public void FindContoursReturnsAnEmptyArrayWhenThereIsNothing()
    {
        // **空配列は誤りではない。** 白い塊が無かっただけである。
        using var blank = MakeGray(32, 32, (x, y) => (byte)0);

        Assert.Empty(CvOps.FindContours(
            blank, CvRetrievalMode.External, CvChainApproxMethod.Simple));
    }

    [Fact]
    public void FindContoursGrowsTheBuffersWhenTheDefaultCapacityIsTooSmall()
    {
        // 1 画素の点を 31 x 31 = 961 個置く。**既定で用意する輪郭の本数
        // （256）を超える。** 溢れを隠していなければ、native は 1 本も書かずに
        // BUFFER_TOO_SMALL を返すので、2 回目を呼ばない実装はここで必ず落ちる。
        using var src = MakeGray(64, 64, (x, y) =>
            (x % 2 == 1 && x <= 61 && y % 2 == 1 && y <= 61) ? (byte)255 : (byte)0);

        CvPoint2[][] contours = CvOps.FindContours(
            src, CvRetrievalMode.External, CvChainApproxMethod.Simple);

        Assert.Equal(961, contours.Length);
        Assert.All(contours, contour => Assert.Single(contour));

        // 点が輪郭ごとに正しく切り分けられていることまで見る ——
        // 平らな配列を 2 本受け取って入れ子に戻すのは C# 側の仕事なので、
        // 「本数は合っているが点が全部 1 本目に入っている」形がありうる。
        var distinct = contours.Select(c => ((int)c[0].X, (int)c[0].Y)).Distinct().Count();
        Assert.Equal(961, distinct);
    }

    [Fact]
    public void FindContoursRejectsNull()
    {
        Assert.Throws<ArgumentNullException>(() => CvOps.FindContours(
            null, CvRetrievalMode.External, CvChainApproxMethod.Simple));
    }

    // ---------------------------------------------------------------
    // managed の enum と native の値の対応
    //
    // **どの enum も C の #define の写しである。** C# から C の #define は
    // 読めないので複製しており、放っておくと片方だけ変わる。既存の
    // GeometryTests.TheManagedMethodValuesMatchWhatNativeAccepts と同じく、
    // 「知っている値は全部通る / 一覧に無い値は INVALID_ARGUMENT で断られる」の
    // 両側を native に問う。
    // ---------------------------------------------------------------

    [Fact]
    public void TheManagedThresholdTypeValuesMatchWhatNativeAccepts()
    {
        using var src = MakeGray(8, 8, (x, y) => x < 4 ? (byte)10 : (byte)200);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        foreach (CvThresholdType type in Enum.GetValues(typeof(CvThresholdType)))
        {
            Assert.Null(Record.Exception(
                () => CvOps.Threshold(src, dst, 100.0, 255.0, type)));

            // **Otsu は or して渡す指定である。** その形も通ることを見る。
            Assert.Null(Record.Exception(
                () => CvOps.Threshold(src, dst, 100.0, 255.0, type | CvThresholdType.Otsu)));
        }

        var ex = Assert.Throws<CvNativeException>(
            () => CvOps.Threshold(src, dst, 100.0, 255.0, (CvThresholdType)99));
        Assert.Equal(CvStatus.InvalidArgument, ex.Status);
    }

    [Fact]
    public void TheManagedMorphologyValuesMatchWhatNativeAccepts()
    {
        using var src = MakeGray(9, 9, (x, y) => (x == 4 && y == 4) ? (byte)255 : (byte)0);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        foreach (CvMorphOp op in Enum.GetValues(typeof(CvMorphOp)))
        {
            foreach (CvMorphShape shape in Enum.GetValues(typeof(CvMorphShape)))
            {
                Assert.Null(Record.Exception(
                    () => CvOps.MorphologyEx(src, dst, op, shape, 3, 3)));
            }
        }

        Assert.Equal(CvStatus.InvalidArgument, Assert.Throws<CvNativeException>(
            () => CvOps.MorphologyEx(src, dst, (CvMorphOp)99, CvMorphShape.Rect, 3, 3)).Status);
        Assert.Equal(CvStatus.InvalidArgument, Assert.Throws<CvNativeException>(
            () => CvOps.MorphologyEx(src, dst, CvMorphOp.Dilate, (CvMorphShape)99, 3, 3)).Status);
    }

    [Fact]
    public void TheManagedTemplateMatchMethodValuesMatchWhatNativeAccepts()
    {
        using var image = MakeGray(8, 8, (x, y) => (byte)((x * 8) + y));
        using var templ = MakeGray(4, 4, (x, y) => (byte)((x * 8) + y));
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        foreach (CvTemplateMatchMethod method in Enum.GetValues(typeof(CvTemplateMatchMethod)))
        {
            Assert.Null(Record.Exception(() => CvOps.MatchTemplate(image, templ, dst, method)));
        }

        var ex = Assert.Throws<CvNativeException>(
            () => CvOps.MatchTemplate(image, templ, dst, (CvTemplateMatchMethod)99));
        Assert.Equal(CvStatus.InvalidArgument, ex.Status);
    }

    [Fact]
    public void TheManagedContourValuesMatchWhatNativeAccepts()
    {
        using var src = MakeGray(32, 32, (x, y) =>
            (x >= 8 && x <= 23 && y >= 8 && y <= 23) ? (byte)255 : (byte)0);

        foreach (CvRetrievalMode mode in Enum.GetValues(typeof(CvRetrievalMode)))
        {
            foreach (CvChainApproxMethod method in Enum.GetValues(typeof(CvChainApproxMethod)))
            {
                Assert.Null(Record.Exception(() => CvOps.FindContours(src, mode, method)));
            }
        }

        Assert.Equal(CvStatus.InvalidArgument, Assert.Throws<CvNativeException>(
            () => CvOps.FindContours(src, (CvRetrievalMode)99, CvChainApproxMethod.Simple)).Status);
        Assert.Equal(CvStatus.InvalidArgument, Assert.Throws<CvNativeException>(
            () => CvOps.FindContours(src, CvRetrievalMode.External, (CvChainApproxMethod)99)).Status);
    }

    [Fact]
    public void TheManagedBorderModeAndInterpolationValuesMatchWhatNativeAccepts()
    {
        // **恒等変換を使う。** 出力を入力と同じ大きさにすると、元の画像の外を
        // 参照する画素が 1 つも出ないので、border mode の値が受理されるかどうか
        // だけを見られる。ここで見たいのは「managed の数が C ABI の一覧の内側に
        // あるか」であって、OpenCV がどう外側を埋めるかではない
        // （OpenCV が warpPerspective について文書で挙げているのは 5 つのうち
        // 2 つだけで、残りの挙動はこの検査の対象外である）。
        var square = new[]
        {
            new CvPoint2(0f, 0f), new CvPoint2(8f, 0f),
            new CvPoint2(8f, 8f), new CvPoint2(0f, 8f),
        };

        using var transform = CvMat.Create(1, 1, CvMatType.Gray8);
        CvOps.GetPerspectiveTransform(square, square, transform);

        using var src = MakeGray(8, 8, (x, y) => (byte)((x * 8) + y));
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        foreach (CvBorderMode mode in Enum.GetValues(typeof(CvBorderMode)))
        {
            Assert.Null(Record.Exception(() => CvOps.WarpPerspective(
                src, dst, transform, 8, 8, CvOps.InterNearest, mode)));
        }

        Assert.Equal(CvStatus.InvalidArgument, Assert.Throws<CvNativeException>(
            () => CvOps.WarpPerspective(
                src, dst, transform, 8, 8, CvOps.InterNearest, (CvBorderMode)99)).Status);

        // **補間は enum にしていない**（既存の Resize が生の int を受けるのに
        // 揃えてある）。定数 2 つが通ることと、一覧に無い値が断られることを見る。
        foreach (int interpolation in new[] { CvOps.InterNearest, CvOps.InterLinear })
        {
            Assert.Null(Record.Exception(() => CvOps.WarpPerspective(
                src, dst, transform, 8, 8, interpolation, CvBorderMode.Constant)));
        }

        Assert.Equal(CvStatus.InvalidArgument, Assert.Throws<CvNativeException>(
            () => CvOps.WarpPerspective(
                src, dst, transform, 8, 8, 99, CvBorderMode.Constant)).Status);
    }

    // ---------------------------------------------------------------
    // 道具
    // ---------------------------------------------------------------

    /// <summary>
    /// 8 bit 1 channel の Mat を作り、画素を全部書く。
    /// <b>引数は幅・高さの順である</b>（<c>CvMat.Create</c> は行・列の順なので、
    /// ここで 1 度だけ入れ替える）。
    /// </summary>
    /// <remarks>
    /// <b><c>CvMat.Create</c> は画素を初期化しない。</b> 「真っ黒」を主張するなら
    /// 明示的に書く必要がある（CalibrationTests が同じ欠陥を踏んだ記録を持つ）。
    /// この道具は必ず全画素を書くので、呼ぶ側がそれを忘れる経路が無い。
    /// </remarks>
    [Fact]
    public void CornerSubPixRejectsWindowsBeforeTheyReachNative()
    {
        // **この検査が無いと、1 呼び出しでプロセスが落ちる。**
        // 2026-09-05 の実測（native を直接叩いたもの）: zeroZone に 2 の 30 乗を
        // 渡すとアクセス違反でプロセスが即死し、winSize に int.MaxValue を渡すと
        // 無意味な窓のまま成功が返った。**どちらも status では気づけない。**
        //
        // **C# 側でも断るのは、その 1 呼び出しが Unity の Editor / Player を
        // 落とすからである** —— CLAUDE.md いわく、Unity のレーンでは
        // クラッシュは赤いテストにならず無音で 10 分以上返らない。
        using var src = MakeCheckerboard(32, 16);
        var points = new[] { new CvPoint2(14.0f, 14.0f) };

        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvOps.CornerSubPix(src, points, winSize: 257));
        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvOps.CornerSubPix(src, points, winSize: 0));
        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvOps.CornerSubPix(src, points, zeroZone: 257));
        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvOps.CornerSubPix(src, points, zeroZone: -2));
        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvOps.CornerSubPix(src, points, maxIterations: 0));

        // **渡した配列は 1 要素も変わっていない。**
        Assert.Equal(14.0f, points[0].X);
        Assert.Equal(14.0f, points[0].Y);
    }

    [Fact]
    public void TheManagedCornerWindowLimitMatchesWhatNativeAccepts()
    {
        // **両側を native に問う。** C の #define は C# から読めないので、
        // 「managed が通す最大値を native も通す」ことで同期を測る
        // （CalibrationTests.TheManagedCornerLimitMatchesWhatNativeAccepts と同じ形）。
        using var src = MakeCheckerboard(32, 16);
        var points = new[] { new CvPoint2(14.0f, 14.0f) };

        // managed の上限ちょうど。**native の値域検査は通る** ——
        // 窓が画像より大きいので OpenCV が断るが、それは別の理由である。
        var ex = Record.Exception(() => CvOps.CornerSubPix(src, points, winSize: 256));
        if (ex is CvNativeException native)
        {
            Assert.NotEqual(CvStatus.InvalidArgument, native.Status);
        }
        Assert.IsNotType<ArgumentOutOfRangeException>(ex);

        // 実用の窓では成功し、点が角へ動く。
        CvPoint2[] refined = CvOps.CornerSubPix(src, points, winSize: 5);
        Assert.Single(refined);
    }

    private static CvMat MakeGray(int width, int height, Func<int, int, byte> pixel)
    {
        var mat = CvMat.Create(height, width, CvMatType.Gray8);
        var pixels = new byte[width * height];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                pixels[(y * width) + x] = pixel(x, y);
            }
        }
        mat.CopyFrom(pixels, width);
        return mat;
    }

    private static CvMat MakeCheckerboard(int size, int cell) =>
        MakeGray(size, size, (x, y) => ((x / cell) + (y / cell)) % 2 == 0 ? (byte)255 : (byte)0);

    private static byte[] ReadGray(CvMat mat)
    {
        var bytes = new byte[mat.Rows * mat.Cols];
        mat.CopyTo(bytes, mat.Cols);
        return bytes;
    }

    /// <summary>
    /// 32 bit 浮動小数 1 channel の Mat を読む。
    /// </summary>
    /// <remarks>
    /// <c>CvMat.CopyTo</c> は byte 列しか受けないので、<b>1 画素が 4 バイトである
    /// ことは呼ぶ側が知っていなければならない</b>（<c>CvMatType.Response32</c> の
    /// 説明が同じことを述べている）。
    /// </remarks>
    private static float[] ReadFloats(CvMat mat)
    {
        var bytes = new byte[mat.Rows * mat.Cols * sizeof(float)];
        mat.CopyTo(bytes, (long)mat.Cols * sizeof(float));

        var values = new float[mat.Rows * mat.Cols];
        Buffer.BlockCopy(bytes, 0, values, 0, bytes.Length);
        return values;
    }
}
