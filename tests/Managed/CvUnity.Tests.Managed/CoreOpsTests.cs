using System;
using CvUnity;
using Xunit;

public class CoreOpsTests
{
    // ---------------------------------------------------------------
    // 材料。
    //
    // **`CvMat.Create` は画素を初期化しない。** どのテストも必ず
    // `CopyFrom` で中身を決めてから使う（CalibrationTests が
    // 「ゼロ埋めを忘れて、直前に捨てた画像の画素が残る」形の欠陥を
    // 実際に踏んだ記録を残している）。
    // ---------------------------------------------------------------

    private static CvMat MakeGray(int rows, int cols, byte[] pixels)
    {
        var mat = CvMat.Create(rows, cols, CvMatType.Gray8);
        mat.CopyFrom(pixels, cols);
        return mat;
    }

    private static CvMat MakeBgr(int rows, int cols, byte[] pixels)
    {
        var mat = CvMat.Create(rows, cols, CvMatType.Bgr24);
        mat.CopyFrom(pixels, cols * 3);
        return mat;
    }

    /// <summary>
    /// Mat の中身を読み出す。**8 bit の Mat だけを想定している** ——
    /// 1 要素 1 バイトとして stride を組み立てているので、16 / 32 / 64 bit の
    /// Mat には使えない（このファイルが扱うのは Gray8 と Bgr24 だけである）。
    /// </summary>
    private static byte[] Read(CvMat mat)
    {
        var buffer = new byte[mat.Rows * mat.Cols * mat.Channels];
        mat.CopyTo(buffer, mat.Cols * mat.Channels);
        return buffer;
    }

    // ---------------------------------------------------------------
    // channel の取り出しと差し込み。
    // ---------------------------------------------------------------

    [Fact]
    public void ExtractChannelTakesTheRequestedChannel()
    {
        // 2x2 の BGR。**channel ごとに値域を分けてある** —— 10 番台が青、
        // 20 番台が緑、30 番台が赤なので、**別の channel を取ってきたら
        // 値そのものが違う**。「1 channel になった」だけを見る検査は
        // どの channel を取っても緑になる。
        using var src = MakeBgr(2, 2, new byte[]
        {
            10, 20, 30,  11, 21, 31,
            12, 22, 32,  13, 23, 33,
        });
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        CvCoreOps.ExtractChannel(src, dst, 1);

        Assert.Equal(2, dst.Rows);
        Assert.Equal(2, dst.Cols);
        Assert.Equal(1, dst.Channels);
        Assert.Equal(new byte[] { 20, 21, 22, 23 }, Read(dst));

        // 索引が効いていることを、**同じ dst に別の channel を入れて**見る。
        CvCoreOps.ExtractChannel(src, dst, 2);
        Assert.Equal(new byte[] { 30, 31, 32, 33 }, Read(dst));
    }

    [Fact]
    public void ExtractChannelRejectsAnOutOfRangeIndex()
    {
        using var src = MakeBgr(1, 1, new byte[] { 1, 2, 3 });
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        // BGR の channel は 0 / 1 / 2 の 3 つしか無い。
        var ex = Assert.Throws<CvNativeException>(
            () => CvCoreOps.ExtractChannel(src, dst, 3));
        Assert.Equal(CvStatus.InvalidArgument, ex.Status);

        var negative = Assert.Throws<CvNativeException>(
            () => CvCoreOps.ExtractChannel(src, dst, -1));
        Assert.Equal(CvStatus.InvalidArgument, negative.Status);
    }

    [Fact]
    public void InsertChannelReplacesOnlyThatChannel()
    {
        // **これは dst を丸ごと置き換えない唯一のメソッドである。**
        // 「差し込んだ channel が変わった」だけを見ると、dst 全体を
        // 作り直す実装でも緑になる —— **他の 2 つの channel が
        // 1 バイトも変わっていないこと**まで見る。
        using var dst = MakeBgr(2, 2, new byte[]
        {
            10, 20, 30,  11, 21, 31,
            12, 22, 32,  13, 23, 33,
        });
        using var src = MakeGray(2, 2, new byte[] { 99, 98, 97, 96 });

        CvCoreOps.InsertChannel(src, dst, 0);

        Assert.Equal(3, dst.Channels);
        Assert.Equal(
            new byte[]
            {
                99, 20, 30,  98, 21, 31,
                97, 22, 32,  96, 23, 33,
            },
            Read(dst));
    }

    [Fact]
    public void InsertChannelRejectsTheSameHandleForBothSides()
    {
        // 自分自身へ差し込む意味は無い。native が断ることを C# 越しに見る。
        using var mat = MakeGray(1, 1, new byte[] { 1 });

        var ex = Assert.Throws<CvNativeException>(
            () => CvCoreOps.InsertChannel(mat, mat, 0));
        Assert.Equal(CvStatus.InvalidArgument, ex.Status);
    }

    // ---------------------------------------------------------------
    // 最小・最大とその位置。
    // ---------------------------------------------------------------

    [Fact]
    public void MinMaxLocFindsBothExtremesAndTheirPositions()
    {
        // **正方形にしない。** 3 行 4 列にしてあるので、x と y を取り違えた
        // 実装は範囲の外を指すか、別の値を返す。
        // 最小 5 は (行 2, 列 1) = (x=1, y=2)、最大 250 は (行 0, 列 3) = (x=3, y=0)。
        var pixels = new byte[12];
        for (int i = 0; i < pixels.Length; i++) { pixels[i] = 100; }
        pixels[(2 * 4) + 1] = 5;
        pixels[(0 * 4) + 3] = 250;

        using var src = MakeGray(3, 4, pixels);

        CvMinMax result = CvCoreOps.MinMaxLoc(src);

        Assert.Equal(5.0, result.MinValue);
        Assert.Equal(250.0, result.MaxValue);
        Assert.Equal(1f, result.MinLocation.X);
        Assert.Equal(2f, result.MinLocation.Y);
        Assert.Equal(3f, result.MaxLocation.X);
        Assert.Equal(0f, result.MaxLocation.Y);
    }

    [Fact]
    public void MinMaxLocRejectsAMultiChannelImage()
    {
        // **C# の入口は位置も必ず受け取る。** 位置は複数 channel では
        // 一意に決まらないので OpenCV が拒む —— この経路が在ることを
        // 明示しておく（C の ABI には値だけを取る経路が在るが、
        // C# には出していない）。
        using var src = MakeBgr(1, 2, new byte[] { 1, 2, 3, 4, 5, 6 });

        var ex = Assert.Throws<CvNativeException>(() => CvCoreOps.MinMaxLoc(src));
        Assert.Equal(CvStatus.OpenCvError, ex.Status);
    }

    // ---------------------------------------------------------------
    // 範囲による 2 値化。
    // ---------------------------------------------------------------

    [Fact]
    public void InRangeMarksThePixelsInsideTheBounds()
    {
        // 両端を含む。40 と 150 をちょうど跨ぐ値を置いてある。
        using var src = MakeGray(1, 4, new byte[] { 10, 40, 150, 200 });
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        CvCoreOps.InRange(src, dst, new double[] { 40 }, new double[] { 150 });

        Assert.Equal(1, dst.Rows);
        Assert.Equal(4, dst.Cols);
        Assert.Equal(1, dst.Channels);
        Assert.Equal(new byte[] { 0, 255, 255, 0 }, Read(dst));
    }

    [Fact]
    public void InRangeRequiresEveryChannelToBeInside()
    {
        // 1 つ目の画素は 3 channel とも範囲内、2 つ目は赤だけ外れている。
        // **or ではなく and である**ことを見る。
        using var src = MakeBgr(1, 2, new byte[] { 10, 10, 10, 10, 10, 200 });
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        CvCoreOps.InRange(src, dst,
            new double[] { 0, 0, 0 },
            new double[] { 100, 100, 100 });

        Assert.Equal(new byte[] { 255, 0 }, Read(dst));
    }

    [Fact]
    public void InRangeRejectsBoundsShorterThanTheChannelCount()
    {
        // **C# 側では数えない。** channel 数は native が handle を引いてから
        // でないと分からないので、境界が断る —— その門が P/Invoke 越しにも
        // 効いていることを見る。
        using var src = MakeBgr(1, 1, new byte[] { 1, 2, 3 });
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        var ex = Assert.Throws<CvNativeException>(
            () => CvCoreOps.InRange(src, dst, new double[] { 0 }, new double[] { 255 }));
        Assert.Equal(CvStatus.InvalidArgument, ex.Status);
    }

    // ---------------------------------------------------------------
    // 正規化。
    // ---------------------------------------------------------------

    [Fact]
    public void NormalizeMinMaxStretchesToTheGivenRange()
    {
        // 10 / 20 / 30 / 40 を 0..255 へ写すと、係数が 255/30 = 8.5、
        // ずらしが -85 になり、**丸めを挟まずちょうど** 0 / 85 / 170 / 255 になる。
        // 端数の出る値を選ぶと、この検査は OpenCV の丸め規則を固定してしまう。
        using var src = MakeGray(1, 4, new byte[] { 10, 20, 30, 40 });
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        CvCoreOps.Normalize(src, dst, 0.0, 255.0, CvNormType.MinMax);

        Assert.Equal(new byte[] { 0, 85, 170, 255 }, Read(dst));
    }

    // ---------------------------------------------------------------
    // ビット演算。
    // ---------------------------------------------------------------

    [Fact]
    public void BitwiseAndOrXorProduceTheExpectedValues()
    {
        // **3 つの演算で全部違う答えになる入力を選んである。** 同じ答えに
        // なる入力（たとえば 0xFF と 0xFF）だと、op を取り違えても緑になる。
        using var a = MakeGray(1, 4, new byte[] { 0xF0, 0x0F, 0xFF, 0x00 });
        using var b = MakeGray(1, 4, new byte[] { 0xFF, 0xFF, 0x0F, 0xF0 });
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        CvCoreOps.Bitwise(a, b, dst, CvBitwiseOp.And);
        Assert.Equal(new byte[] { 0xF0, 0x0F, 0x0F, 0x00 }, Read(dst));

        CvCoreOps.Bitwise(a, b, dst, CvBitwiseOp.Or);
        Assert.Equal(new byte[] { 0xFF, 0xFF, 0xFF, 0xF0 }, Read(dst));

        CvCoreOps.Bitwise(a, b, dst, CvBitwiseOp.Xor);
        Assert.Equal(new byte[] { 0x0F, 0xF0, 0xF0, 0xF0 }, Read(dst));
    }

    [Fact]
    public void BitwiseNotInvertsEveryBit()
    {
        // **NOT は別のメソッドである** —— C の ABI では 4 つ目の op だが、
        // 2 つ目の入力を見ないので `Bitwise(a, null, dst, Not)` と
        // 書かせないためにこの形にしてある。
        using var src = MakeGray(1, 4, new byte[] { 0xF0, 0x0F, 0xFF, 0x00 });
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        CvCoreOps.BitwiseNot(src, dst);

        Assert.Equal(new byte[] { 0x0F, 0xF0, 0x00, 0xFF }, Read(dst));
    }

    // ---------------------------------------------------------------
    // 表引き。
    // ---------------------------------------------------------------

    [Fact]
    public void LutReplacesEveryValueThroughTheTable()
    {
        // 反転表。**恒等表を使うと、表を引かずに素通ししても緑になる。**
        var table = new byte[256];
        for (int i = 0; i < table.Length; i++) { table[i] = (byte)(255 - i); }

        using var src = MakeGray(1, 4, new byte[] { 0, 1, 254, 255 });
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        CvCoreOps.Lut(src, dst, table);

        Assert.Equal(new byte[] { 255, 254, 1, 0 }, Read(dst));
    }

    [Fact]
    public void LutRejectsAShortTable()
    {
        // **255 バイト** —— 1 バイトだけ足りない。ここを通してしまうと
        // cv::LUT が表の外を読む（managed のヒープを踏み越える）。
        // ちょうど境界の値で断られることを見る。
        using var src = MakeGray(1, 1, new byte[] { 0 });
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        var ex = Assert.Throws<CvNativeException>(
            () => CvCoreOps.Lut(src, dst, new byte[255]));
        Assert.Equal(CvStatus.InvalidArgument, ex.Status);

        // ちょうど 256 なら通る（**上の検査が「短すぎる」を見ていて、
        // 「常に断る」を見ているのではない**ことの対照）。
        var ok = Record.Exception(() => CvCoreOps.Lut(src, dst, new byte[256]));
        Assert.Null(ok);
    }

    // ---------------------------------------------------------------
    // 余白。
    // ---------------------------------------------------------------

    [Fact]
    public void CopyMakeBorderGrowsTheImageByTheGivenAmounts()
    {
        // **4 つの余白を全部違う値にしてある。** 揃えると、上下左右を
        // 取り違えても出来上がりの大きさが変わらない。
        // 2x2 に上 1 / 下 2 / 左 3 / 右 4 で、5 行 9 列になる。
        using var src = MakeGray(2, 2, new byte[] { 100, 101, 102, 103 });
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        CvCoreOps.CopyMakeBorder(src, dst, 1, 2, 3, 4, CvBorderMode.Constant, 7.0);

        Assert.Equal(5, dst.Rows);
        Assert.Equal(9, dst.Cols);

        var pixels = Read(dst);

        // 元の 2x2 は行 1..2、列 3..4 に来る。**位置まで見る** ——
        // 大きさだけを見る検査は、余白の入れ方が上下逆でも緑になる。
        Assert.Equal(100, pixels[(1 * 9) + 3]);
        Assert.Equal(101, pixels[(1 * 9) + 4]);
        Assert.Equal(102, pixels[(2 * 9) + 3]);
        Assert.Equal(103, pixels[(2 * 9) + 4]);

        // 埋め値は 4 隅すべてに入る。
        Assert.Equal(7, pixels[0]);
        Assert.Equal(7, pixels[8]);
        Assert.Equal(7, pixels[(4 * 9) + 0]);
        Assert.Equal(7, pixels[(4 * 9) + 8]);
    }

    [Fact]
    public void CopyMakeBorderReplicatesTheEdgeWhenAsked()
    {
        // **border_type が実際に渡っていることの対照。** 埋め方を替えると
        // 同じ引数で違う答えになる —— Constant なら 0、Replicate なら 100。
        using var src = MakeGray(1, 1, new byte[] { 100 });
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        CvCoreOps.CopyMakeBorder(src, dst, 1, 1, 1, 1, CvBorderMode.Replicate);
        Assert.Equal(new byte[] { 100, 100, 100, 100, 100, 100, 100, 100, 100 }, Read(dst));

        CvCoreOps.CopyMakeBorder(src, dst, 1, 1, 1, 1, CvBorderMode.Constant, 0.0);
        Assert.Equal(new byte[] { 0, 0, 0, 0, 100, 0, 0, 0, 0 }, Read(dst));
    }

    [Fact]
    public void CopyMakeBorderRejectsANegativeAmount()
    {
        using var src = MakeGray(2, 2, new byte[] { 1, 2, 3, 4 });
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        var ex = Assert.Throws<CvNativeException>(
            () => CvCoreOps.CopyMakeBorder(src, dst, -1, 0, 0, 0, CvBorderMode.Constant));
        Assert.Equal(CvStatus.InvalidArgument, ex.Status);
    }

    // ---------------------------------------------------------------
    // managed の enum と native の対応。
    // ---------------------------------------------------------------

    [Fact]
    public void TheManagedEnumValuesMatchWhatNativeAccepts()
    {
        // CvNormType / CvBitwiseOp の値は C の OCVU_NORM_* / OCVU_BITWISE_* の
        // 写しである。C# から C の #define は読めないので複製しており、
        // **両側を native に問う** ——「定義してある値は全部受理される」ことと
        // 「定義に無い値は拒否される」ことの両方を見る。片方だけだと、
        // 素通しの実装（何でも受理）と、常に断る実装のどちらかを見逃す。
        using var a = MakeGray(1, 4, new byte[] { 10, 20, 30, 40 });
        using var b = MakeGray(1, 4, new byte[] { 1, 2, 3, 4 });
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        foreach (CvNormType normType in Enum.GetValues(typeof(CvNormType)))
        {
            var ex = Record.Exception(
                () => CvCoreOps.Normalize(a, dst, 1.0, 255.0, normType));
            Assert.Null(ex);
        }

        var badNorm = Assert.Throws<CvNativeException>(
            () => CvCoreOps.Normalize(a, dst, 1.0, 255.0, (CvNormType)99));
        Assert.Equal(CvStatus.InvalidArgument, badNorm.Status);

        foreach (CvBitwiseOp op in Enum.GetValues(typeof(CvBitwiseOp)))
        {
            var ex = Record.Exception(() => CvCoreOps.Bitwise(a, b, dst, op));
            Assert.Null(ex);
        }

        var badOp = Assert.Throws<CvNativeException>(
            () => CvCoreOps.Bitwise(a, b, dst, (CvBitwiseOp)99));
        Assert.Equal(CvStatus.InvalidArgument, badOp.Status);
    }

    [Fact]
    public void HammingIsNotOfferedAsANormType()
    {
        // **OCVU_NORM_HAMMING（6）は記述子どうしの距離であって正規化ではない。**
        // CvNormType に入れなかったことを、値そのもので固定する ——
        // 誰かが「OpenCV に在るから」と足すと、native が断るのでここが赤くなる。
        Assert.False(Enum.IsDefined(typeof(CvNormType), 6));

        using var src = MakeGray(1, 4, new byte[] { 10, 20, 30, 40 });
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        var ex = Assert.Throws<CvNativeException>(
            () => CvCoreOps.Normalize(src, dst, 1.0, 255.0, (CvNormType)6));
        Assert.Equal(CvStatus.InvalidArgument, ex.Status);
    }

    // ---------------------------------------------------------------
    // null。
    // ---------------------------------------------------------------

    [Fact]
    public void EveryEntryPointRejectsNull()
    {
        using var mat = MakeGray(1, 1, new byte[] { 1 });
        var table = new byte[256];

        Assert.Throws<ArgumentNullException>(() => CvCoreOps.ExtractChannel(null, mat, 0));
        Assert.Throws<ArgumentNullException>(() => CvCoreOps.ExtractChannel(mat, null, 0));
        Assert.Throws<ArgumentNullException>(() => CvCoreOps.InsertChannel(null, mat, 0));
        Assert.Throws<ArgumentNullException>(() => CvCoreOps.InsertChannel(mat, null, 0));
        Assert.Throws<ArgumentNullException>(() => CvCoreOps.MinMaxLoc(null));
        Assert.Throws<ArgumentNullException>(
            () => CvCoreOps.InRange(null, mat, new double[] { 0 }, new double[] { 1 }));
        Assert.Throws<ArgumentNullException>(
            () => CvCoreOps.InRange(mat, null, new double[] { 0 }, new double[] { 1 }));
        Assert.Throws<ArgumentNullException>(
            () => CvCoreOps.InRange(mat, mat, null, new double[] { 1 }));
        Assert.Throws<ArgumentNullException>(
            () => CvCoreOps.InRange(mat, mat, new double[] { 0 }, null));
        Assert.Throws<ArgumentNullException>(
            () => CvCoreOps.Normalize(null, mat, 0, 255, CvNormType.MinMax));
        Assert.Throws<ArgumentNullException>(
            () => CvCoreOps.Normalize(mat, null, 0, 255, CvNormType.MinMax));
        Assert.Throws<ArgumentNullException>(
            () => CvCoreOps.Bitwise(null, mat, mat, CvBitwiseOp.And));
        Assert.Throws<ArgumentNullException>(
            () => CvCoreOps.Bitwise(mat, null, mat, CvBitwiseOp.And));
        Assert.Throws<ArgumentNullException>(
            () => CvCoreOps.Bitwise(mat, mat, null, CvBitwiseOp.And));
        Assert.Throws<ArgumentNullException>(() => CvCoreOps.BitwiseNot(null, mat));
        Assert.Throws<ArgumentNullException>(() => CvCoreOps.BitwiseNot(mat, null));
        Assert.Throws<ArgumentNullException>(() => CvCoreOps.Lut(null, mat, table));
        Assert.Throws<ArgumentNullException>(() => CvCoreOps.Lut(mat, null, table));
        Assert.Throws<ArgumentNullException>(() => CvCoreOps.Lut(mat, mat, null));
        Assert.Throws<ArgumentNullException>(
            () => CvCoreOps.CopyMakeBorder(null, mat, 0, 0, 0, 0, CvBorderMode.Constant));
        Assert.Throws<ArgumentNullException>(
            () => CvCoreOps.CopyMakeBorder(mat, null, 0, 0, 0, 0, CvBorderMode.Constant));
    }

    [Fact]
    public void BitwiseReportsInvalidArgumentWhenTheShapesDiffer()
    {
        // **doc が約束した status を、C# 側から実際に確かめる。**
        //
        // この検査が無かったせいで、native の status を
        // OPENCV_ERROR から INVALID_ARGUMENT に変えたとき
        // **CvCoreOps.Bitwise の XML doc だけが古い status を約束したまま残った**
        // （生成物は自動で直り、手書きの C# だけが取り残された）——
        // 再レビューが指摘するまで、どの検査も落ちなかった。
        using var small = MakeGray(2, 2, new byte[] { 1, 1, 1, 1 });
        using var big = MakeGray(3, 3, new byte[9]);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        var ex = Assert.Throws<CvNativeException>(
            () => CvCoreOps.Bitwise(small, big, dst, CvBitwiseOp.And));
        Assert.Equal(CvStatus.InvalidArgument, ex.Status);
    }

    [Fact]
    public void BitwiseRejectsASingleElementSecondOperandInsteadOfBroadcasting()
    {
        // **これが、OpenCV に任せず自分で検査する理由である。**
        // 実測（検査を足す前）: 8x8 に 1x1 を AND すると OK が返り、
        // 1 要素の値が 64 画素すべてに当たった —— **誤りが status ではなく
        // 「もっともらしい画像」として現れる。**
        var pixels = new byte[64];
        for (int i = 0; i < pixels.Length; i++) { pixels[i] = 0xF0; }
        using var big = MakeGray(8, 8, pixels);
        using var one = MakeGray(1, 1, new byte[] { 0x3C });
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        var ex = Assert.Throws<CvNativeException>(
            () => CvCoreOps.Bitwise(big, one, dst, CvBitwiseOp.And));
        Assert.Equal(CvStatus.InvalidArgument, ex.Status);
    }
}
