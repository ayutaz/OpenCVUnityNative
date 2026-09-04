using System;
using CvUnity;
using Xunit;

/// <summary>
/// ArUco（生成・検出・姿勢推定）の L3 契約テスト。
/// </summary>
/// <remarks>
/// **外部の画像資産に依存しない。** 自分で生成したマーカーを自分で検出する
/// 閉じた輪にしてあるので、テストデータの取り違えも、環境による写りの差も無い
/// （native/tests/test_aruco.cpp と同じ組み立てである）。
/// </remarks>
public class ArucoTests
{
    /// <summary>
    /// 生成するマーカーの 1 辺（画素）。**180 は 6 で割り切れる** ——
    /// <see cref="CvArucoDictionary.Dict4X4_50"/> は 4x4 の格子で、枠 1 を足すと
    /// 6 セルになる。割り切れないと最近傍で引き伸ばすときにセルの幅が
    /// 1 画素ずつずれ、検出できるかどうかが微妙な話になる。
    /// </summary>
    private const int MarkerSide = 180;

    /// <summary>
    /// マーカーの周りに置く白い余白。**これが要る** —— ArUco の検出は黒い枠の
    /// 外側に白があることを前提にしている。
    /// </summary>
    private const int Margin = 60;

    /// <summary>場面の 1 辺。300 になる。</summary>
    private const int SceneSide = MarkerSide + (Margin * 2);

    /// <summary>貼るマーカーの ID。**辞書が持つ範囲の中から選んである。**</summary>
    private const int MarkerId = 7;

    /// <summary>
    /// 場面の真ん中を主点にした焦点距離 500 のカメラ。**手で決めてある。**
    /// </summary>
    private static readonly double[] Camera =
    {
        500, 0, SceneSide / 2.0,
        0, 500, SceneSide / 2.0,
        0, 0, 1,
    };

    // -----------------------------------------------------------------------
    // GenerateMarker
    // -----------------------------------------------------------------------

    [Fact]
    public void GenerateMarkerFillsTheDestination()
    {
        using var marker = CvAruco.GenerateMarker(CvArucoDictionary.Dict4X4_50, MarkerId, 120);

        Assert.Equal(120, marker.Rows);
        Assert.Equal(120, marker.Cols);
        Assert.Equal(1, marker.Channels);

        // **形だけを見ない。** マーカーは黒と白の両方を含む ——
        // 真っ白でも真っ黒でもない。
        var pixels = new byte[120 * 120];
        marker.CopyTo(pixels, 120);

        bool hasBlack = false;
        bool hasWhite = false;
        for (int i = 0; i < pixels.Length; i++)
        {
            if (pixels[i] == 0) { hasBlack = true; }
            if (pixels[i] == 255) { hasWhite = true; }
        }
        Assert.True(hasBlack, "生成したマーカーに黒が 1 画素も無い");
        Assert.True(hasWhite, "生成したマーカーに白が 1 画素も無い");
    }

    [Fact]
    public void GenerateMarkerRejectsAnIdOutsideTheDictionary()
    {
        // Dict4X4_50 は 50 個しか持たない。
        var ex = Assert.Throws<CvNativeException>(
            () => CvAruco.GenerateMarker(CvArucoDictionary.Dict4X4_50, 50, 120));
        Assert.Equal(CvStatus.InvalidArgument, ex.Status);

        var negative = Assert.Throws<CvNativeException>(
            () => CvAruco.GenerateMarker(CvArucoDictionary.Dict4X4_50, -1, 120));
        Assert.Equal(CvStatus.InvalidArgument, negative.Status);

        // **49 は在る。** 上の 50 が「範囲の外」であって「辞書が使えない」の
        // ではないことを、同じ辞書で示す（これが無いと「常に断る」実装が通る）。
        using var marker = CvAruco.GenerateMarker(CvArucoDictionary.Dict4X4_50, 49, 120);
        Assert.Equal(120, marker.Rows);
    }

    [Fact]
    public void GenerateMarkerRejectsASizeSmallerThanTheGridPlusItsBorder()
    {
        // Dict4X4_50 は 4x4 の格子なので、枠 1 なら 6 画素が下限になる。
        // **境界の両側を見る** —— 下限そのものが通ることまで見ないと、
        // 「常に断る」実装でもこの検査は緑になる。
        var ex = Assert.Throws<CvNativeException>(
            () => CvAruco.GenerateMarker(CvArucoDictionary.Dict4X4_50, 0, 5));
        Assert.Equal(CvStatus.InvalidArgument, ex.Status);

        using var atTheLimit = CvAruco.GenerateMarker(CvArucoDictionary.Dict4X4_50, 0, 6);
        Assert.Equal(6, atTheLimit.Rows);

        // **枠を太くすると下限も動く。**
        var thicker = Assert.Throws<CvNativeException>(
            () => CvAruco.GenerateMarker(CvArucoDictionary.Dict4X4_50, 0, 7, 2));
        Assert.Equal(CvStatus.InvalidArgument, thicker.Status);

        using var thickerAtTheLimit = CvAruco.GenerateMarker(CvArucoDictionary.Dict4X4_50, 0, 8, 2);
        Assert.Equal(8, thickerAtTheLimit.Rows);
    }

    [Fact]
    public void TheManagedDictionaryValuesMatchWhatNativeAccepts()
    {
        // CvArucoDictionary の値は C の OCVU_ARUCO_DICT_* の写しである。
        // C# から C の #define は読めないので複製しており、**両側を native に問う**
        // （GeometryTests の TheManagedMethodValuesMatchWhatNativeAccepts と同じ形）。
        //
        // 128 画素は、いちばん細かい 7x7 の格子（枠 1 で下限 9）でも足りる。
        foreach (CvArucoDictionary dictionary in Enum.GetValues(typeof(CvArucoDictionary)))
        {
            using var marker = CvAruco.GenerateMarker(dictionary, 0, 128);
            Assert.Equal(128, marker.Rows);
        }

        // **上のループが空振りでないことを示す。** 定義に無い値は断られる ——
        // つまりループは「何を渡しても通る」を見ていたのではない。
        // **17 も断る**: OpenCV 側にはその番号（AprilTag 系）が在るが、
        // この plugin は検証していないので出していない。
        foreach (int unknown in new[] { -1, 17, 99 })
        {
            var ex = Assert.Throws<CvNativeException>(
                () => CvAruco.GenerateMarker((CvArucoDictionary)unknown, 0, 128));
            Assert.Equal(CvStatus.InvalidArgument, ex.Status);
        }
    }

    // -----------------------------------------------------------------------
    // DetectMarkers —— 生成したものを検出する閉じた輪。
    // -----------------------------------------------------------------------

    [Fact]
    public void DetectMarkersFindsTheMarkerItGenerated()
    {
        using var scene = MakeSceneWithMarker(CvArucoDictionary.Dict4X4_50, MarkerId);

        CvArucoMarker[] markers = CvAruco.DetectMarkers(scene, CvArucoDictionary.Dict4X4_50);

        Assert.Single(markers);
        Assert.Equal(MarkerId, markers[0].Id);

        // 4 隅はマーカーを貼った領域（余白の内側）に収まる。
        // **厳密な位置ではなく範囲を見る** —— 検出器の細かな挙動に縛られないため。
        foreach (CvPoint2 corner in Corners(markers[0]))
        {
            Assert.InRange(corner.X, Margin - 10f, Margin + MarkerSide + 10f);
            Assert.InRange(corner.Y, Margin - 10f, Margin + MarkerSide + 10f);
        }
    }

    [Fact]
    public void DetectMarkersReturnsTheCornersClockwiseFromTheTopLeft()
    {
        // **上下も左右も分かる形で貼ってあるから、この検査ができる。**
        // マーカーは回転させずに場面の真ん中へ貼ってあるので、「マーカーの
        // 左上」として返る隅は画像の左上側に在るはずである。
        // **ここが崩れると、この 4 隅をそのまま EstimateMarkerPose へ渡す
        // 使い方が、黙って間違った姿勢を返す。**
        using var scene = MakeSceneWithMarker(CvArucoDictionary.Dict4X4_50, MarkerId);

        CvArucoMarker[] markers = CvAruco.DetectMarkers(scene, CvArucoDictionary.Dict4X4_50);
        Assert.Single(markers);
        CvArucoMarker marker = markers[0];

        const float center = SceneSide / 2f;
        Assert.True(marker.TopLeft.X < center, "TopLeft が左半分に無い");
        Assert.True(marker.TopLeft.Y < center, "TopLeft が上半分に無い");
        Assert.True(marker.TopRight.X > center, "TopRight が右半分に無い");
        Assert.True(marker.TopRight.Y < center, "TopRight が上半分に無い");
        Assert.True(marker.BottomRight.X > center, "BottomRight が右半分に無い");
        Assert.True(marker.BottomRight.Y > center, "BottomRight が下半分に無い");
        Assert.True(marker.BottomLeft.X < center, "BottomLeft が左半分に無い");
        Assert.True(marker.BottomLeft.Y > center, "BottomLeft が下半分に無い");
    }

    [Fact]
    public void DetectMarkersGrowsItsBuffersWhenTheEstimateIsTooSmall()
    {
        // **maxMarkers は上限ではなく最初の見積もりである。**
        // 0 を渡すと 1 回目は必ず溢れるので、**2 回呼びが隠れていることを
        // ここが実証する** —— 隠していなければ、この呼び出しは
        // BufferTooSmall のまま空配列か例外で返る。
        using var scene = MakeSceneWithMarker(CvArucoDictionary.Dict4X4_50, MarkerId);

        CvArucoMarker[] markers = CvAruco.DetectMarkers(scene, CvArucoDictionary.Dict4X4_50, 0);

        Assert.Single(markers);
        Assert.Equal(MarkerId, markers[0].Id);

        // 見積もりが足りている場合と同じ結果になる。
        CvArucoMarker[] roomy = CvAruco.DetectMarkers(scene, CvArucoDictionary.Dict4X4_50, 64);
        Assert.Single(roomy);
        Assert.Equal(markers[0].Id, roomy[0].Id);
        Assert.Equal(markers[0].TopLeft.X, roomy[0].TopLeft.X);
        Assert.Equal(markers[0].TopLeft.Y, roomy[0].TopLeft.Y);
    }

    [Fact]
    public void DetectMarkersReturnsEmptyWhenNothingIsThere()
    {
        using var blank = CvMat.Create(120, 120, CvMatType.Gray8);

        // **`CvMat.Create` は画素を初期化しない。**「何も写っていない画像」を
        // 主張するなら明示的に埋める（CalibrationTests / ObjdetectTests と同じ理由）。
        // 白で埋めるのは、そこにマーカーを貼る場面と同じ地色にするためである。
        var white = new byte[120 * 120];
        for (int i = 0; i < white.Length; i++) { white[i] = 255; }
        blank.CopyFrom(white, 120);

        // **空配列は誤りではない。** 写っていなかっただけである。
        Assert.Empty(CvAruco.DetectMarkers(blank, CvArucoDictionary.Dict4X4_50));
    }

    [Fact]
    public void DetectMarkersRejectsBadInput()
    {
        using var scene = MakeSceneWithMarker(CvArucoDictionary.Dict4X4_50, MarkerId);

        Assert.Throws<ArgumentNullException>(
            () => CvAruco.DetectMarkers(null, CvArucoDictionary.Dict4X4_50));
        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvAruco.DetectMarkers(scene, CvArucoDictionary.Dict4X4_50, -1));

        // 辞書は native が見る。定義に無い値は素通しにしない。
        var ex = Assert.Throws<CvNativeException>(
            () => CvAruco.DetectMarkers(scene, (CvArucoDictionary)99));
        Assert.Equal(CvStatus.InvalidArgument, ex.Status);
    }

    // -----------------------------------------------------------------------
    // EstimateMarkerPose —— 新しい C ABI は 1 本も使わない純 C#。
    // -----------------------------------------------------------------------

    [Fact]
    public void EstimateMarkerPosePutsTheMarkerInFrontOfTheCamera()
    {
        using var scene = MakeSceneWithMarker(CvArucoDictionary.Dict4X4_50, MarkerId);
        CvArucoMarker[] markers = CvAruco.DetectMarkers(scene, CvArucoDictionary.Dict4X4_50);
        Assert.Single(markers);

        const float markerLength = 0.1f;
        CvViewPose pose = CvAruco.EstimateMarkerPose(markers[0], markerLength, Camera, null);

        // **z が正であること。** カメラの後ろに在る解を掴んでいない。
        Assert.True(pose.TranslationZ > 0.0, $"マーカーがカメラの後ろに在る（z = {pose.TranslationZ}）");

        // **符号だけを見ない。** マーカーは 180 画素に写っていて焦点距離は 500 な
        // ので、距離は 500 * 0.1 / 180 ≈ 0.28 になる。
        // **中心を原点に置くときに 2 で割り忘れると、ここが倍（≈ 0.56）になって出る。**
        Assert.InRange(pose.TranslationZ, 0.20, 0.40);

        // マーカーは場面の真ん中に貼ってあり、主点も真ん中に置いてあるので、
        // 横と縦の並進はほぼ 0 である。
        Assert.InRange(pose.TranslationX, -0.02, 0.02);
        Assert.InRange(pose.TranslationY, -0.02, 0.02);
    }

    [Fact]
    public void EstimateMarkerPoseReturnsTheHalfTurnThatAFrontalMarkerImplies()
    {
        // **正面から撮った 1 枚の回転は、ほぼ x 軸まわりの半回転になる。**
        // OpenCV のカメラ座標系は y が下向き、マーカーの座標系は y が上向き
        // なので、この 180 度は誤りではない。
        //
        // **軸まで見るのが要点である** —— 4 隅の並びを 90 度ずらして渡しても
        // 回転角は π のままで、変わるのは軸だけだからである。
        using var scene = MakeSceneWithMarker(CvArucoDictionary.Dict4X4_50, MarkerId);
        CvArucoMarker[] markers = CvAruco.DetectMarkers(scene, CvArucoDictionary.Dict4X4_50);
        Assert.Single(markers);

        CvViewPose pose = CvAruco.EstimateMarkerPose(markers[0], 0.1f, Camera, null);

        // 半回転の向きは ±π のどちらでも同じ回転を表すので、大きさで見る。
        Assert.InRange(Math.Abs(pose.RotationX), Math.PI - 0.25, Math.PI + 0.25);
        Assert.InRange(pose.RotationY, -0.25, 0.25);
        Assert.InRange(pose.RotationZ, -0.25, 0.25);
    }

    [Fact]
    public void EstimateMarkerPoseRejectsABadMarkerLength()
    {
        var marker = new CvArucoMarker(
            0,
            new CvPoint2(60f, 60f),
            new CvPoint2(240f, 60f),
            new CvPoint2(240f, 240f),
            new CvPoint2(60f, 240f));

        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvAruco.EstimateMarkerPose(marker, 0f, Camera, null));
        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvAruco.EstimateMarkerPose(marker, -0.1f, Camera, null));

        // **NaN を素通しにしない。** `markerLength <= 0` だけを見る実装では
        // NaN が両方の比較で false になって通ってしまう。
        Assert.Throws<ArgumentOutOfRangeException>(
            () => CvAruco.EstimateMarkerPose(marker, float.NaN, Camera, null));

        // カメラ行列の検証は SolvePnP が持つ。
        Assert.Throws<ArgumentNullException>(
            () => CvAruco.EstimateMarkerPose(marker, 0.1f, null, null));
    }

    // -----------------------------------------------------------------------

    /// <summary>マーカーの 4 隅を並べる。</summary>
    private static CvPoint2[] Corners(CvArucoMarker marker)
    {
        return new[] { marker.TopLeft, marker.TopRight, marker.BottomRight, marker.BottomLeft };
    }

    /// <summary>
    /// 白い場面の真ん中に、生成したマーカーを貼った 8 bit 1 channel の Mat を作る。
    /// </summary>
    private static CvMat MakeSceneWithMarker(CvArucoDictionary dictionary, int markerId)
    {
        // **余白は 255 で埋めてから貼る。** ゼロ埋めにすると黒い海に黒枠の
        // マーカーが浮かぶ形になり、輪郭が取れない。
        var pixels = new byte[SceneSide * SceneSide];
        for (int i = 0; i < pixels.Length; i++) { pixels[i] = 255; }

        using (var marker = CvAruco.GenerateMarker(dictionary, markerId, MarkerSide))
        {
            var markerPixels = new byte[MarkerSide * MarkerSide];
            marker.CopyTo(markerPixels, MarkerSide);

            for (int r = 0; r < MarkerSide; r++)
            {
                for (int c = 0; c < MarkerSide; c++)
                {
                    pixels[((r + Margin) * SceneSide) + c + Margin] =
                        markerPixels[(r * MarkerSide) + c];
                }
            }
        }

        var scene = CvMat.Create(SceneSide, SceneSide, CvMatType.Gray8);
        try
        {
            // **stride はバイト数である**（要素数でも画素数でもない）。
            // 8 bit 1 channel なので 1 行のバイト数は列数と等しい。
            scene.CopyFrom(pixels, SceneSide);
            return scene;
        }
        catch
        {
            scene.Dispose();
            throw;
        }
    }
}
