using System;
using System.Linq;
using System.Runtime.InteropServices;
using CvUnity;
using CvUnity.Interop;
using Xunit;

public class MatchingTests
{
    // **入力の一辺は 200 以上でなければならない。** ORB は edgeThreshold=31 のため
    // 小さい画像では特徴点が 1 つも出ない（2026-09-05 の実測: 32 -> 0 / 64 -> 0 /
    // 128 -> 8 / 160 -> 104 / 200 -> 212）。**64 で書くと「0 個」で落ちる。**
    private const int Side = 224;

    // **max_features は上限ではない。** ORB も SIFT も指定より多く返すことが
    // あるので、この値を buffer の大きさとして使ってはならない。そこを隠すのが
    // CvFeatures.DetectAndCompute の仕事であり、下のテストが実際に隠せている
    // ことを見る。
    private const int MaxFeatures = 200;

    [Fact]
    public void TheDmatchStructMatchesTheNativeLayout()
    {
        // native 側は static_assert(sizeof(ocvu_dmatch) == 16) で固定している。
        // 食い違うと marshalling だけが壊れるので、両側から挟む。
        Assert.Equal(16, Marshal.SizeOf<OcvuDMatch>());
    }

    [Fact]
    public void EveryDmatchFieldSitsWhereTheNativeStructPutsIt()
    {
        // **合計の大きさだけでは足りない。** QueryIndex / TrainIndex / ImageIndex は
        // 3 つとも int なので、入れ替えても sizeof は 16 のままで、C 側の
        // static_assert も C# の SizeOf も通る。そのとき壊れるのは呼んだ場所では
        // なく、後から索引を読む無関係な場所である（FeaturesTests が
        // ocvu_keypoint について同じ形の検査を持っている）。
        Assert.Equal(0, Marshal.OffsetOf<OcvuDMatch>(nameof(OcvuDMatch.QueryIndex)).ToInt32());
        Assert.Equal(4, Marshal.OffsetOf<OcvuDMatch>(nameof(OcvuDMatch.TrainIndex)).ToInt32());
        Assert.Equal(8, Marshal.OffsetOf<OcvuDMatch>(nameof(OcvuDMatch.ImageIndex)).ToInt32());
        Assert.Equal(12, Marshal.OffsetOf<OcvuDMatch>(nameof(OcvuDMatch.Distance)).ToInt32());
    }

    [Fact]
    public void DetectAndComputeProducesOrbDescriptorsOfThirtyTwoColumns()
    {
        using var img = MakeCheckerboard(Side, 8);
        using var descriptors = CvMat.Create(1, 1, CvMatType.Gray8);

        CvKeyPoint[] keypoints = CvFeatures.DetectAndCompute(
            img, CvFeatureDetector.Orb, MaxFeatures, descriptors);

        Assert.NotEmpty(keypoints);

        // **記述子の行は特徴点 1 つ、列は記述子の次元である。** ORB は 32 バイト。
        Assert.Equal(keypoints.Length, descriptors.Rows);
        Assert.Equal(32, descriptors.Cols);
        Assert.Equal(1, descriptors.Channels);

        Assert.All(keypoints, k =>
        {
            Assert.InRange(k.X, 0f, (float)Side);
            Assert.InRange(k.Y, 0f, (float)Side);
        });
    }

    [Fact]
    public void DetectAndComputeProducesSiftDescriptorsOf128Columns()
    {
        using var img = MakeCheckerboard(Side, 8);
        using var descriptors = CvMat.Create(1, 1, CvMatType.Gray8);

        CvKeyPoint[] keypoints = CvFeatures.DetectAndCompute(
            img, CvFeatureDetector.Sift, MaxFeatures, descriptors);

        Assert.NotEmpty(keypoints);

        // SIFT の記述子は 128 次元の 32 bit 浮動小数である。**ORB とは型も幅も違う。**
        // **CvMat は型を公開していない**ので、型の違いは 1 画素のバイト数として
        // 現れる —— 行の長さ（Step）が列数の 4 倍になる。
        Assert.Equal(keypoints.Length, descriptors.Rows);
        Assert.Equal(128, descriptors.Cols);
        Assert.Equal((long)descriptors.Cols * 4, descriptors.Step);
    }

    [Fact]
    public void DetectAndComputeReturnsEveryKeypointEvenWhenMaxFeaturesIsExceeded()
    {
        // **これがこの API の存在理由である。** cv::ORB::create(n) も
        // cv::SIFT::create(n) も n を上限として守らない（2026-09-05 の実測:
        // SIFT は 160x160 で create(200) が 240 個を返した）。native は切り詰めずに
        // BUFFER_TOO_SMALL と実際の個数を返すので、**呼ぶ側が maxFeatures ぶんを
        // 確保していると溢れる。**
        //
        // **「多く返ること」を期待値に書かない** —— 検出器の版で変わる数に
        // 検査をぶら下げると、上流が変わった日に理由の分からない赤が出る。
        // かわりに native に同じ引数で直接問い、**その out_count（capacity が
        // 足りたかどうかに関わらず、実際に見つかった数である）と C# の戻り値の
        // 長さが一致すること**を見る。**切り詰める実装なら、溢れた瞬間に
        // min(count, maxFeatures) になってここで落ちる。**
        using var img = MakeCheckerboard(Side, 8);
        using var managed = CvMat.Create(1, 1, CvMatType.Gray8);
        using var direct = CvMat.Create(1, 1, CvMatType.Gray8);

        CvKeyPoint[] keypoints = CvFeatures.DetectAndCompute(
            img, CvFeatureDetector.Sift, MaxFeatures, managed);

        var raw = new OcvuKeyPoint[MaxFeatures];
        var status = (CvStatus)NativeMethods.ocvu_detect_and_compute(
            img.Handle, (int)CvFeatureDetector.Sift, MaxFeatures,
            raw, raw.Length, direct.Handle, out int nativeCount);

        // Ok（収まった）でも BufferTooSmall（溢れた）でも、out_count は
        // 実際に見つかった数である。どちらでもないなら native 側の誤りである。
        Assert.True(
            status == CvStatus.Ok || status == CvStatus.BufferTooSmall,
            $"予期しない status: {status}");
        Assert.True(nativeCount > 0, "市松模様なのに特徴点が 1 つも出ない");

        Assert.Equal(nativeCount, keypoints.Length);
        Assert.Equal(nativeCount, managed.Rows);
    }

    [Fact]
    public void DetectAndComputeReturnsEmptyWhenThereIsNothingToFind()
    {
        // **CvMat.Create は画素を初期化しない。** 「真っ黒」を主張するなら
        // 明示的にゼロ埋めする（CalibrationTests が同じ欠陥を踏んだ記録を持つ）。
        using var blank = CvMat.Create(Side, Side, CvMatType.Gray8);
        blank.CopyFrom(new byte[Side * Side], Side);

        using var descriptors = CvMat.Create(1, 1, CvMatType.Gray8);

        // **1 つも見つからないのは誤りではない。** 空配列が返る。
        Assert.Empty(CvFeatures.DetectAndCompute(
            blank, CvFeatureDetector.Orb, MaxFeatures, descriptors));
    }

    [Fact]
    public void CrossCheckKeepsOnlyMutualNearestNeighboursAndTheirIndicesLineUp()
    {
        using var img = MakeCheckerboard(Side, 8);
        using var a = CvMat.Create(1, 1, CvMatType.Gray8);
        using var b = CvMat.Create(1, 1, CvMatType.Gray8);

        CvFeatures.DetectAndCompute(img, CvFeatureDetector.Orb, MaxFeatures, a);
        CvFeatures.DetectAndCompute(img, CvFeatureDetector.Orb, MaxFeatures, b);

        CvMatch[] loose = CvFeatures.MatchDescriptors(a, b, CvDescriptorNorm.Hamming);
        Assert.NotEmpty(loose);

        // **crossCheck が false のときに索引がずれるかは入力しだいである。**
        // 繰り返す模様では記述子が重複し、同点のとき BFMatcher は先に現れた
        // ほうを選ぶ —— 別の市松（200x200・8 画素の格子）では 212 件中 53 件しか
        // 一致しなかったが、**この 224x224 では全件が一致した**（2026-09-05 に
        // 両方とも実測）。**だから「ずれること」を不変条件として主張しない** ——
        // 主張すると、入力を少し変えただけで落ちるテストになる。
        CvMatch[] strict = CvFeatures.MatchDescriptors(
            a, b, CvDescriptorNorm.Hamming, crossCheck: true);

        // **入力によらず成り立つのはこの 3 つである。**
        Assert.NotEmpty(strict);
        Assert.True(strict.Length <= loose.Length,
            "crossCheck は対応を絞るだけなので、増えることはない");
        Assert.All(strict, m =>
        {
            // 同じ記述子集合どうしなので、互いに最近傍なら索引は一致する。
            Assert.Equal(m.QueryIndex, m.TrainIndex);
            Assert.Equal(0f, m.Distance);
        });
    }

    [Fact]
    public void MatchDescriptorsGrowsTheBufferWhenTheFirstGuessIsTooSmall()
    {
        // **maxMatches は上限ではなく最初の見積もりである。** 1 件ぶんしか
        // 確保しない値を渡しても、溢れは C# 側が隠す（1 回目の BufferTooSmall で
        // 実際の数を受け取り、その数で確保して 1 度だけ呼び直す）。
        // **切り詰める実装なら、ここで Length == 1 になって落ちる。**
        using var img = MakeCheckerboard(Side, 8);
        using var a = CvMat.Create(1, 1, CvMatType.Gray8);
        using var b = CvMat.Create(1, 1, CvMatType.Gray8);

        CvFeatures.DetectAndCompute(img, CvFeatureDetector.Orb, MaxFeatures, a);
        CvFeatures.DetectAndCompute(img, CvFeatureDetector.Orb, MaxFeatures, b);

        CvMatch[] roomy = CvFeatures.MatchDescriptors(a, b, CvDescriptorNorm.Hamming);
        CvMatch[] cramped = CvFeatures.MatchDescriptors(
            a, b, CvDescriptorNorm.Hamming, maxMatches: 1);

        // **対応が 1 件以下では、この検査は何も見ていない。** 先にそれを断る。
        Assert.True(roomy.Length > 1, "対応が 1 件以下では、溢れの経路を通らない");

        Assert.Equal(roomy.Length, cramped.Length);
        Assert.Equal(
            roomy.Select(m => m.QueryIndex).ToArray(),
            cramped.Select(m => m.QueryIndex).ToArray());
    }

    [Fact]
    public void MatchingTheWrongNormAgainstTheDescriptorsIsAnOpenCvError()
    {
        // **ハミング距離は 2 値の記述子のためのものである。** SIFT の 32 bit
        // 浮動小数の記述子に当てると OpenCV が例外を投げる（実測）——
        // それが status に変換され、例外として C# に届くことまで見る。
        using var img = MakeCheckerboard(Side, 8);
        using var sift = CvMat.Create(1, 1, CvMatType.Gray8);
        CvFeatures.DetectAndCompute(img, CvFeatureDetector.Sift, MaxFeatures, sift);

        var ex = Assert.Throws<CvNativeException>(
            () => CvFeatures.MatchDescriptors(sift, sift, CvDescriptorNorm.Hamming));
        Assert.Equal(CvStatus.OpenCvError, ex.Status);
    }

    [Fact]
    public void TheManagedDetectorValuesMatchWhatNativeAccepts()
    {
        // CvFeatureDetector の値は C の OCVU_FEATURE_* の写しである。
        // C# から C の #define は読めないので複製しており、**両側を native に問う**。
        using var img = MakeCheckerboard(Side, 8);
        using var descriptors = CvMat.Create(1, 1, CvMatType.Gray8);

        foreach (CvFeatureDetector detector in Enum.GetValues(typeof(CvFeatureDetector)))
        {
            var ex = Record.Exception(
                () => CvFeatures.DetectAndCompute(img, detector, MaxFeatures, descriptors));
            Assert.Null(ex);
        }

        // **定義に無い値は native が断る。** 公開 API は enum を受けるので
        // ここだけ P/Invoke を直接叩く（C# の enum は未定義の数値でも
        // キャストが通ってしまう）。
        var raw = new OcvuKeyPoint[1];
        var status = (CvStatus)NativeMethods.ocvu_detect_and_compute(
            img.Handle, 99, MaxFeatures, raw, raw.Length, descriptors.Handle, out _);
        Assert.Equal(CvStatus.InvalidArgument, status);
    }

    [Fact]
    public void TheManagedNormValuesMatchWhatNativeAccepts()
    {
        // CvDescriptorNorm の値は C の OCVU_NORM_*（= cv::NORM_*）の写しである。
        // **記述子の型に合う組で問う** —— 合っていない組は OpenCV が断るので、
        // それでは「値が受理されたか」を見たことにならない。
        using var img = MakeCheckerboard(Side, 8);
        using var orb = CvMat.Create(1, 1, CvMatType.Gray8);
        using var sift = CvMat.Create(1, 1, CvMatType.Gray8);
        CvFeatures.DetectAndCompute(img, CvFeatureDetector.Orb, MaxFeatures, orb);
        CvFeatures.DetectAndCompute(img, CvFeatureDetector.Sift, MaxFeatures, sift);

        Assert.Null(Record.Exception(
            () => CvFeatures.MatchDescriptors(orb, orb, CvDescriptorNorm.Hamming)));
        Assert.Null(Record.Exception(
            () => CvFeatures.MatchDescriptors(sift, sift, CvDescriptorNorm.L2)));

        // 定義に無い値は native が断る。
        var raw = new OcvuDMatch[1];
        var status = (CvStatus)NativeMethods.ocvu_match_descriptors(
            orb.Handle, orb.Handle, 99, 0, raw, raw.Length, out _);
        Assert.Equal(CvStatus.InvalidArgument, status);
    }

    [Fact]
    public void DetectAndComputeRejectsBadArguments()
    {
        using var img = MakeCheckerboard(Side, 8);
        using var descriptors = CvMat.Create(1, 1, CvMatType.Gray8);

        Assert.Throws<ArgumentNullException>(
            () => CvFeatures.DetectAndCompute(null, CvFeatureDetector.Orb, MaxFeatures, descriptors));
        Assert.Throws<ArgumentNullException>(
            () => CvFeatures.DetectAndCompute(img, CvFeatureDetector.Orb, MaxFeatures, null));
        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvFeatures.DetectAndCompute(img, CvFeatureDetector.Orb, 0, descriptors));

        // 10001 は C の OCVU_ORB_MAX_FEATURES（10000）の 1 つ上である ——
        // 上限そのものの同期は FeaturesTests が両側を native に問うて守っている。
        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvFeatures.DetectAndCompute(img, CvFeatureDetector.Orb, 10001, descriptors));
    }

    [Fact]
    public void MatchDescriptorsRejectsBadArguments()
    {
        using var img = MakeCheckerboard(Side, 8);
        using var orb = CvMat.Create(1, 1, CvMatType.Gray8);
        CvFeatures.DetectAndCompute(img, CvFeatureDetector.Orb, MaxFeatures, orb);

        Assert.Throws<ArgumentNullException>(
            () => CvFeatures.MatchDescriptors(null, orb, CvDescriptorNorm.Hamming));
        Assert.Throws<ArgumentNullException>(
            () => CvFeatures.MatchDescriptors(orb, null, CvDescriptorNorm.Hamming));
        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvFeatures.MatchDescriptors(orb, orb, CvDescriptorNorm.Hamming, maxMatches: 0));
    }

    /// <summary>cell 画素ごとの市松模様。ORB も SIFT も角に乗る。</summary>
    private static CvMat MakeCheckerboard(int size, int cell)
    {
        var mat = CvMat.Create(size, size, CvMatType.Gray8);

        // **CvMat.Create は画素を初期化しない。** 全画素を明示的に書く。
        var pixels = new byte[size * size];
        for (int y = 0; y < size; y++)
        {
            for (int x = 0; x < size; x++)
            {
                pixels[(y * size) + x] = ((x / cell) + (y / cell)) % 2 == 0 ? (byte)220 : (byte)40;
            }
        }

        // **stride はバイト数である**（8 bit 1 channel なので size と同じ値になる）。
        mat.CopyFrom(pixels, size);
        return mat;
    }
}
