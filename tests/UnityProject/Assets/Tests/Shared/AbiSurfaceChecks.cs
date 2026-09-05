using System;
using CvUnity;
using CvUnity.Unity;
using UnityEngine;

/// <summary>
/// **Unity のどちらのレーンからも一度も呼ばれていなかった公開 API を呼ぶ。**
///
/// M4 の点検で実測した。当時 package が宣言する P/Invoke は **19 本**
/// （<c>[DllImport]</c> は 21 個あるが、<c>mat_copy_from_buffer</c> と
/// <c>mat_copy_to_buffer</c> は byte[] 版とポインタ版で 2 重に宣言されている）
/// で、そのうち **7 本が、Editor でも Player でも一度も到達していなかった**:
/// cvt_color / resize / mat_clone / imencode / imdecode /
/// get_build_information / debug_throw。このクラスがその 7 本を通す。
///
/// **M5 で数が変わった。** 宣言は <c>bindings/spec/*.json</c> から生成される
/// ようになり、C ABI が package に 1 本残らず現れる。
/// **本数はここに書かない** —— 数えるのは <c>docs/api-map.md</c> の冒頭だけで、
/// あちらは spec から生成されるので ABI が増えれば勝手に増える。ここに写すと、
/// **増えた瞬間にこの行だけが嘘になる**（M3.5 で <c>docs/api-reference.md</c> が
/// そうなり、M5 でこの行が 3 度開き直した）。
///
/// **M5 Task 6 で穴が閉じた。** この一覧が触るのは公開 API から辿れる
/// 宣言だけで、<c>ocvu_get_status_count</c> / <c>ocvu_get_status_value</c> は
/// 出荷する C# のどこからも呼ばれていなかった。いまは spec から生成された
/// <c>AbiReachabilityChecks</c> が **spec の載せる宣言を 1 つ残らず** 呼び、
/// EditMode と PlayMode の両方がそれを 1 件のテストとして通す。
/// 呼ばないのは <c>ocvu_debug_crash</c> だけで、**呼べば戻ってこないので
/// 到達性テストから外してある**（理由は <c>bindings/spec/infra.json</c> の
/// <c>reachableNote</c>。表の「到達性」の列にも出る）。
///
/// **それでもこの一覧は要る。** あちらは「呼べること」しか見ない ——
/// 引数は型ごとの無害な既定値で、返る status も結果も見ない。
/// **下の検査は「正しく動くこと」を見ている。** 件数はここに書かない ——
/// 数えるのは <c>EveryCheckInTheSharedBodyIsWiredIntoThisEntryPoint</c> で、
/// **リフレクションで両側を突き合わせる**ので、1 件足すたびに勝手に増える。
///
/// **2026-09 の API 拡張で 13 件足した。** それまで 26 本の新しい ABI は
/// Unity のどのレーンからも「呼べること」しか見られていなかった ——
/// <b>marshalling が壊れていても、結果が間違っていても緑になる状態</b>だった。
/// とくに <c>OcvuDMatch</c> の配列は、素の .NET（L3）でしか marshal されて
/// いなかった。
///
/// L1 と L3 は上記をすべて見ているので「テストが無い」わけではない。
/// しかし**このリポジトリが守ると宣言しているのは
/// 「P/Invoke 宣言が stripping で消えないこと」**であって、それを確かめられる
/// のは IL2CPP の Player だけである。呼ばれない宣言は、消えても誰も気づかない。
///
/// **本体はここにしか無い。** EditMode と PlayMode はこのクラスを呼ぶだけの
/// 薄い入口である。写して 2 つ持つと、片方だけが直って「Editor と Player で
/// 同じ結果になる」ことを確かめられなくなる —— このリポジトリが繰り返し
/// 潰してきた「同じ事実を 2 箇所に書く」形そのものである。
/// </summary>
public static class AbiSurfaceChecks
{
    public static void CvtColor_ReducesTheChannelCount()
    {
        using var src = CvMat.Create(2, 3, CvMatType.Bgra32);
        src.CopyFrom(new byte[2 * 3 * 4], 3 * 4);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        CvOps.CvtColor(src, dst, CvOps.Bgra2Bgr);

        Check.AreEqual(3, dst.Cols);
        Check.AreEqual(2, dst.Rows);
        Check.AreEqual(3, dst.Channels, "Bgra2Bgr は 4 ch を 3 ch にする");
    }

    public static void Resize_ProducesTheRequestedSize()
    {
        using var src = CvMat.Create(4, 4, CvMatType.Bgra32);
        src.CopyFrom(new byte[4 * 4 * 4], 4 * 4);
        using var dst = CvMat.Create(1, 1, CvMatType.Bgra32);

        CvOps.Resize(src, dst, 8, 2, CvOps.InterNearest);

        Check.AreEqual(8, dst.Cols);
        Check.AreEqual(2, dst.Rows);
        Check.AreEqual(4, dst.Channels);
    }

    public static void Clone_CopiesThePixelsIntoAnIndependentMat()
    {
        var pixels = new byte[2 * 2 * 1];
        pixels[0] = 7;
        pixels[3] = 9;

        using var src = CvMat.Create(2, 2, CvMatType.Gray8);
        src.CopyFrom(pixels, 2);

        using var clone = src.Clone();
        Check.AreEqual(2, clone.Rows);
        Check.AreEqual(2, clone.Cols);

        var copied = new byte[4];
        clone.CopyTo(copied, 2);
        Check.SequenceEqual(pixels, copied);

        // **独立していること。** clone が同じメモリを指していたら、
        // 片方を書き換えたときにもう片方も変わる。
        src.CopyFrom(new byte[] { 1, 2, 3, 4 }, 2);
        var afterSrcChanged = new byte[4];
        clone.CopyTo(afterSrcChanged, 2);
        Check.SequenceEqual(pixels, afterSrcChanged,
            "clone は src と別のメモリを持つ");
    }

    public static void EncodedImage_DecodesBackToTheSameShape()
    {
        var pixels = new byte[3 * 4 * 1];
        for (int i = 0; i < pixels.Length; i++) { pixels[i] = (byte)(i * 7); }

        using var src = CvMat.Create(3, 4, CvMatType.Gray8);
        src.CopyFrom(pixels, 4);

        // **platform が持つ形式で試す。**
        //
        // **Web には PNG が無い**（Unity の WebGL 支援が自前の libpng を
        // 同梱しており、束ねると Player のリンクでシンボルが衝突し、
        // 束ねないと OpenCV の PNG コードが未解決になる。M6 で実測）。
        // **他の 5 platform は PNG / JPEG の両方を持つ。**
        //
        // **形式を platform で変えても、確かめることは同じ**である ——
        // 「encode した byte 列が decode で同じ形に戻る」。
        // **可逆性の主張だけは、可逆な形式のときにしかできない。**
#if UNITY_WEBGL && !UNITY_EDITOR
        const string extension = ".jpg";
        const bool lossless = false;
        const byte firstByte = 0xFF;   // JPEG は FF D8 で始まる
#else
        const string extension = ".png";
        const bool lossless = true;
        const byte firstByte = 0x89;   // PNG の署名
#endif

        // **ファイルパスは通らない。** byte 列だけを扱う（M3.5 の決定）。
        var encoded = CvCodecs.Encode(src, extension);
        Check.Greater(encoded.Length, 8, $"{extension} の byte 列が返ること");
        Check.AreEqual(firstByte, encoded[0], $"{extension} の署名で始まること");

        using var decoded = CvCodecs.Decode(encoded, CvCodecs.ImreadGrayscale);
        Check.AreEqual(3, decoded.Rows);
        Check.AreEqual(4, decoded.Cols);
        Check.AreEqual(1, decoded.Channels);

        if (lossless)
        {
            // 可逆な形式なので画素まで一致する。
            var roundTripped = new byte[pixels.Length];
            decoded.CopyTo(roundTripped, 4);
            Check.SequenceEqual(pixels, roundTripped);
        }
    }

    public static void Encode_RejectsAnExtensionOpenCvCannotWrite()
    {
        using var src = CvMat.Create(2, 2, CvMatType.Gray8);
        src.CopyFrom(new byte[4], 2);

        // **型だけで満足しない。** CvCodecs.Encode は 2 か所から
        // CvNativeException を投げるので、型を見るだけでは
        // 「拡張子を断られた」経路を通ったことにならない。
        var ex = Check.Throws<CvNativeException>(() => CvCodecs.Encode(src, ".notanimage"));
        Check.AreEqual(CvStatus.OpenCvError, ex.Status,
            "扱えない拡張子は OpenCV 側のエラーとして返る");
    }

    public static void BuildInformation_ComesBackThroughTheTwoCallIdiom()
    {
        var info = CvNative.GetBuildInformation();

        // **IsNotNull は書かない。** CvNative.ReadString は失敗時に
        // string.Empty を返すので、null 判定は構造的に常に真になる。
        // 2 回呼びが壊れると空文字か切り詰めた文字列が返るので、そこを見る。
        Check.AreNotEqual(string.Empty, info, "2 回呼びが失敗すると空文字が返る");
        Check.Greater(info.Length, 64, "build information は長い文字列である");
        // StringAssert.Contains(expected, actual) と引数の順が逆である。
        Check.Contains(info, "OpenCV", "build information に OpenCV の名が入る");
    }

    public static void NativeExceptionsAreTurnedIntoStatusCodes()
    {
        // **例外を ABI の外へ出さない**という不変条件を、Player でも確かめる。
        // 境界を越える unwind は未定義動作なので、Mono で通っても足りない。
        Check.AreEqual(CvStatus.UnknownError, CvNative.DebugThrow(0));
        Check.AreEqual(CvStatus.OutOfMemory, CvNative.DebugThrow(1));
        Check.AreEqual(CvStatus.UnknownError, CvNative.DebugThrow(2));
        Check.AreEqual(CvStatus.Ok, CvNative.DebugThrow(3));
        Check.AreEqual(CvStatus.InvalidArgument, CvNative.DebugThrow(99));
    }

    /// <summary>
    /// M4 で足した WebCamTextureConverter を Player でも通す。
    /// **新しい P/Invoke は増えていない**が、この API が使う経路
    /// （Color32[] -> CvMat.Create -> copy_from_buffer）が IL2CPP 上でも
    /// 同じ並びを作ることは、Editor で通っただけでは言えない。
    /// </summary>
    public static void WebCamPixels_BecomeATopLeftOriginMat()
    {
        var pixels = new[]
        {
            // Unity の 0 行目 = 画像の一番下
            new Color32(10, 0, 0, 255), new Color32(11, 0, 0, 255),
            // Unity の 1 行目 = 画像の一番上
            new Color32(20, 0, 0, 255), new Color32(21, 0, 0, 255),
        };

        using var mat = WebCamTextureConverter.ToMat(pixels, width: 2, height: 2);

        Check.AreEqual(2, mat.Rows);
        Check.AreEqual(2, mat.Cols);
        Check.AreEqual(4, mat.Channels);

        var got = new byte[2 * 2 * 4];
        mat.CopyTo(got, mat.Cols * 4);

        Check.AreEqual(20, got[0], "Mat の先頭行は Unity の最終行（画像の上端）であること");
        Check.AreEqual(10, got[8], "Mat の 2 行目は Unity の 0 行目（画像の下端）であること");
    }

    // =======================================================================
    // 2026-09 の API 拡張で足した 26 本を、**Unity の中で実際に動かす。**
    //
    // **足す前は、この 26 本を Unity のどのレーンも「呼べること」しか見て
    // いなかった。** 生成された AbiReachabilityChecks は全引数を 0 / null で
    // 渡して status を捨てるので、**宣言が解決すること**しか確かめられない ——
    // marshalling が壊れていても、結果が間違っていても緑になる。
    //
    // **ここで初めて次が Unity の中で確かめられる:**
    //   - 配列の marshalling（float[] / double[] / int[] / OcvuKeyPoint[] /
    //     **OcvuDMatch[]** —— 最後のものは L3 でしか通っていなかった）
    //   - 新しい Mat の型 3 つ（16SC1 / 32FC1 / 64FC1）の読み出し
    //   - 2 回呼びの作法（溢れを C# が隠す経路）
    //   - IL2CPP の stripping を抜けた先で、**値が正しいこと**
    // =======================================================================

    /// <summary>
    /// 姿勢が復元でき、投影がその逆になる。**数値は手で解いてある。**
    /// </summary>
    /// <remarks>
    /// fx = fy = 500 / cx = 320 / cy = 240 のカメラで、1 辺 2 の正方形を
    /// (0, 0, 10) に回転なしで置くと、4 隅は x = 500 * (X / 10) + 320、
    /// y = 500 * (Y / 10) + 240 に写る。**OpenCV に期待値を作らせていない。**
    /// </remarks>
    public static void SolvePnP_RecoversAKnownPoseAndProjectPointsIsItsInverse()
    {
        var camera = new[] { 500.0, 0.0, 320.0, 0.0, 500.0, 240.0, 0.0, 0.0, 1.0 };
        var square = new[]
        {
            new CvPoint3(-1.0f, -1.0f, 0.0f),
            new CvPoint3(1.0f, -1.0f, 0.0f),
            new CvPoint3(1.0f, 1.0f, 0.0f),
            new CvPoint3(-1.0f, 1.0f, 0.0f),
        };
        var image = new[]
        {
            new CvPoint2(270.0f, 190.0f),
            new CvPoint2(370.0f, 190.0f),
            new CvPoint2(370.0f, 290.0f),
            new CvPoint2(270.0f, 290.0f),
        };

        var pose = CvGeometry.SolvePnP(square, image, camera, null);

        Check.IsTrue(Math.Abs(pose.TranslationZ - 10.0) < 1e-2,
            "奥行きが 10 に戻ること（得たのは " + pose.TranslationZ + "）");
        Check.IsTrue(Math.Abs(pose.RotationX) < 1e-2 && Math.Abs(pose.RotationY) < 1e-2,
            "回転なしで置いたので回転ベクトルは 0 に近いこと");

        // **投影は姿勢の逆である。** 同じ数値で往復する。
        var projected = CvGeometry.ProjectPoints(square, pose, camera, null);
        Check.AreEqual(4, projected.Length);
        for (int i = 0; i < 4; i++)
        {
            Check.IsTrue(Math.Abs(projected[i].X - image[i].X) < 0.5f,
                "隅 " + i + " の x が戻ること");
            Check.IsTrue(Math.Abs(projected[i].Y - image[i].Y) < 0.5f,
                "隅 " + i + " の y が戻ること");
        }
    }

    /// <summary>
    /// 回転ベクトルと回転行列が往復する。**double[] の marshalling を両方向に通す。**
    /// </summary>
    public static void Rodrigues_RoundTripsThroughTheMatrix()
    {
        var pose = new CvViewPose(0.1, -0.2, 0.3, 0.0, 0.0, 0.0);

        var matrix = CvGeometry.RodriguesToMatrix(pose);
        Check.AreEqual(9, matrix.Length, "3x3 を行優先で 9 個返すこと");

        var back = CvGeometry.RodriguesToVector(matrix);
        Check.AreEqual(3, back.Length);
        Check.IsTrue(Math.Abs(back[0] - 0.1) < 1e-6, "x が戻ること");
        Check.IsTrue(Math.Abs(back[1] + 0.2) < 1e-6, "y が戻ること");
        Check.IsTrue(Math.Abs(back[2] - 0.3) < 1e-6, "z が戻ること");
    }

    /// <summary>
    /// 生成した ArUco マーカーを、そのまま検出できる。**閉じた輪である。**
    /// </summary>
    /// <remarks>
    /// 外部の画像資産に依存しない。**マーカーの周りに白い余白が要る** ——
    /// ArUco の検出は黒い枠の外側に白があることを前提にしている。
    /// </remarks>
    public static void Aruco_DetectsTheMarkerItGenerated()
    {
        const int side = 200;
        const int margin = 60;
        const int markerId = 7;

        byte[] markerPixels;
        using (var marker = CvAruco.GenerateMarker(CvArucoDictionary.Dict4X4_50, markerId, side))
        {
            Check.AreEqual(side, marker.Rows);
            Check.AreEqual(side, marker.Cols);
            markerPixels = new byte[side * side];
            marker.CopyTo(markerPixels, side);
        }

        // **マーカーは黒と白の両方を含む。** 真っ白でも真っ黒でもない。
        bool hasBlack = false;
        bool hasWhite = false;
        foreach (var p in markerPixels)
        {
            if (p == 0) { hasBlack = true; }
            if (p == 255) { hasWhite = true; }
        }
        Check.IsTrue(hasBlack && hasWhite, "生成したマーカーが単色になっていないこと");

        int full = side + margin * 2;
        var scene = new byte[full * full];
        for (int i = 0; i < scene.Length; i++) { scene[i] = 255; }
        for (int r = 0; r < side; r++)
        {
            for (int c = 0; c < side; c++)
            {
                scene[(r + margin) * full + (c + margin)] = markerPixels[r * side + c];
            }
        }

        using var image = CvMat.Create(full, full, CvMatType.Gray8);
        image.CopyFrom(scene, full);

        var found = CvAruco.DetectMarkers(image, CvArucoDictionary.Dict4X4_50);
        Check.AreEqual(1, found.Length, "生成した 1 個が見つかること");
        Check.AreEqual(markerId, found[0].Id);

        // 4 隅がマーカーの領域に収まる。**位置を厳密に縛らない。**
        var corners = new[]
        {
            found[0].TopLeft, found[0].TopRight, found[0].BottomRight, found[0].BottomLeft,
        };
        foreach (var corner in corners)
        {
            Check.IsTrue(corner.X >= margin - 10 && corner.X <= margin + side + 10,
                "隅の x が余白の内側であること");
            Check.IsTrue(corner.Y >= margin - 10 && corner.Y <= margin + side + 10,
                "隅の y が余白の内側であること");
        }

        // **姿勢はカメラの前に在る。** 新しい C ABI を使わない純 C# の経路である。
        var camera = new[] { 500.0, 0.0, full / 2.0, 0.0, 500.0, full / 2.0, 0.0, 0.0, 1.0 };
        var pose = CvAruco.EstimateMarkerPose(found[0], 0.05f, camera, null);
        Check.IsTrue(pose.TranslationZ > 0.0, "マーカーがカメラの前に在ること");
    }

    /// <summary>
    /// 二値化が Otsu の選んだしきい値を返し、画素が期待どおりに分かれる。
    /// </summary>
    public static void Threshold_SplitsThePixelsAndReportsTheValueOtsuChose()
    {
        // 左半分が 10、右半分が 200 の 4x4。
        var pixels = new byte[16];
        for (int r = 0; r < 4; r++)
        {
            for (int c = 0; c < 4; c++) { pixels[r * 4 + c] = (byte)(c < 2 ? 10 : 200); }
        }
        using var src = CvMat.Create(4, 4, CvMatType.Gray8);
        src.CopyFrom(pixels, 4);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        double used = CvOps.Threshold(src, dst, 100.0, 255.0, CvThresholdType.Binary);
        Check.IsTrue(Math.Abs(used - 100.0) < 1e-9, "明示したしきい値がそのまま返ること");

        var got = new byte[16];
        dst.CopyTo(got, 4);
        for (int r = 0; r < 4; r++)
        {
            Check.AreEqual((byte)0, got[r * 4 + 0], "左半分は 0 になること");
            Check.AreEqual((byte)255, got[r * 4 + 3], "右半分は 255 になること");
        }

        // **Otsu は自分で選ぶ。** その値を呼ぶ側が知る唯一の手段が戻り値である。
        double otsu = CvOps.Threshold(src, dst, 0.0, 255.0,
            CvThresholdType.Binary | CvThresholdType.Otsu);
        Check.IsTrue(otsu >= 10.0 && otsu < 200.0, "Otsu が 2 山の間を選ぶこと");
    }

    /// <summary>
    /// 形態素演算で引数がそれぞれ効いている。**幅と高さを取り違えたら落ちる。**
    /// </summary>
    public static void MorphologyEx_UsesEveryArgument()
    {
        var dot = new byte[25];
        dot[2 * 5 + 2] = 255;
        using var src = CvMat.Create(5, 5, CvMatType.Gray8);
        src.CopyFrom(dot, 5);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        // 幅 1 x 高さ 3 で膨張 -> 縦 3 画素。**入れ替えると横 3 画素になる。**
        CvOps.MorphologyEx(src, dst, CvMorphOp.Dilate, CvMorphShape.Rect, 1, 3);
        var got = new byte[25];
        dst.CopyTo(got, 5);
        for (int r = 0; r < 5; r++)
        {
            for (int c = 0; c < 5; c++)
            {
                bool expectLit = c == 2 && r >= 1 && r <= 3;
                Check.AreEqual(expectLit, got[r * 5 + c] == 255,
                    "縦 3 画素の帯と合うこと");
            }
        }

        // 十字は 5 画素、矩形は 9 画素。**shape を無視したら区別できない。**
        CvOps.MorphologyEx(src, dst, CvMorphOp.Dilate, CvMorphShape.Cross, 3, 3);
        dst.CopyTo(got, 5);
        int lit = 0;
        foreach (var v in got) { if (v == 255) { lit++; } }
        Check.AreEqual(5, lit, "十字の構造要素は 5 画素にすること");
    }

    /// <summary>
    /// テンプレート照合の応答が 32 bit 浮動小数で返り、**その型で読み出せる。**
    /// </summary>
    /// <remarks>
    /// **新しい Mat の型を Unity の中で読む検査である。**
    /// CopyTo は byte[] しか受けないので、stride は Cols * 4 になる。
    /// </remarks>
    public static void MatchTemplate_ProducesAFloatResponseWeCanRead()
    {
        var dot = new byte[25];
        dot[2 * 5 + 2] = 255;
        using var image = CvMat.Create(5, 5, CvMatType.Gray8);
        image.CopyFrom(dot, 5);

        var t = new byte[9];
        t[4] = 255;
        using var templ = CvMat.Create(3, 3, CvMatType.Gray8);
        templ.CopyFrom(t, 3);

        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);
        CvOps.MatchTemplate(image, templ, dst, CvTemplateMatchMethod.CrossCorrelation);

        // 5 - 3 + 1 = 3。**形は手で決まる。**
        Check.AreEqual(3, dst.Rows);
        Check.AreEqual(3, dst.Cols);
        Check.AreEqual(1, dst.Channels);
        Check.AreEqual((long)(3 * 4), dst.Step, "1 画素 4 バイトであること");

        var raw = new byte[3 * 3 * 4];
        dst.CopyTo(raw, 3 * 4);
        // 中心が積の和（255 * 255）になる。他は桁違いに小さい。
        float center = BitConverter.ToSingle(raw, (1 * 3 + 1) * 4);
        Check.IsTrue(Math.Abs(center - 255.0f * 255.0f) < 255.0f * 255.0f * 1e-3f,
            "中心の応答が 255*255 になること");
        float corner = BitConverter.ToSingle(raw, 0);
        Check.IsTrue(Math.Abs(corner) < 255.0f * 255.0f * 1e-3f,
            "重ならない位置の応答が小さいこと");
    }

    /// <summary>
    /// 4 点から射影変換を求め、その行列で画像を変形できる。
    /// </summary>
    /// <remarks>
    /// **変換行列は 64 bit 浮動小数の Mat である** —— 呼ぶ側が読めるよう
    /// ABI に名前がある（CvMatType.Transform64）。
    /// </remarks>
    public static void PerspectiveTransform_IsProducedAndThenApplied()
    {
        var from = new[]
        {
            new CvPoint2(0, 0), new CvPoint2(3, 0), new CvPoint2(3, 3), new CvPoint2(0, 3),
        };
        var to = new[]
        {
            new CvPoint2(0, 0), new CvPoint2(7, 0), new CvPoint2(7, 7), new CvPoint2(0, 7),
        };

        using var transform = CvMat.Create(1, 1, CvMatType.Gray8);
        CvOps.GetPerspectiveTransform(from, to, transform);

        Check.AreEqual(3, transform.Rows);
        Check.AreEqual(3, transform.Cols);
        Check.AreEqual(1, transform.Channels);
        Check.AreEqual((long)(3 * 8), transform.Step, "1 画素 8 バイトであること");

        // 左半分が暗く、右半分が明るい 4x4。
        var pixels = new byte[16];
        for (int r = 0; r < 4; r++)
        {
            for (int c = 0; c < 4; c++) { pixels[r * 4 + c] = (byte)(c < 2 ? 10 : 200); }
        }
        using var src = CvMat.Create(4, 4, CvMatType.Gray8);
        src.CopyFrom(pixels, 4);
        using var dst = CvMat.Create(1, 1, CvMatType.Gray8);

        CvOps.WarpPerspective(src, dst, transform, 8, 8,
            CvOps.InterNearest, CvBorderMode.Constant);

        Check.AreEqual(8, dst.Rows);
        Check.AreEqual(8, dst.Cols);
        var got = new byte[64];
        dst.CopyTo(got, 8);
        Check.IsTrue(got[4 * 8 + 1] < 100, "左が暗いままであること");
        Check.IsTrue(got[4 * 8 + 6] > 100, "右が明るいままであること");
    }

    /// <summary>
    /// 線分と輪郭が見つかる。**溢れは C# 側が隠している。**
    /// </summary>
    public static void HoughAndContours_ReturnTheShapesTheyFind()
    {
        const int side = 64;

        // y = 32 に 1 本の横線。
        var line = new byte[side * side];
        for (int c = 0; c < side; c++) { line[32 * side + c] = 255; }
        using var lineImage = CvMat.Create(side, side, CvMatType.Gray8);
        lineImage.CopyFrom(line, side);

        var lines = CvOps.HoughLinesP(lineImage, 1.0, Math.PI / 180.0, 30, 20.0, 5.0);
        Check.Greater(lines.Length, 0, "1 本の横線が見つかること");
        Check.IsTrue(Math.Abs(lines[0].Start.Y - 32.0f) < 3.0f,
            "見つけた線分が y = 32 の近くにあること");

        // 中央に 10x10 の白い正方形。
        var square = new byte[side * side];
        for (int r = 27; r < 37; r++)
        {
            for (int c = 27; c < 37; c++) { square[r * side + c] = 255; }
        }
        using var squareImage = CvMat.Create(side, side, CvMatType.Gray8);
        squareImage.CopyFrom(square, side);

        var contours = CvOps.FindContours(squareImage,
            CvRetrievalMode.External, CvChainApproxMethod.Simple);
        Check.AreEqual(1, contours.Length, "白い塊が 1 つなので輪郭も 1 本であること");
        Check.AreEqual(4, contours[0].Length, "Simple は正方形を 4 隅に間引くこと");
        foreach (var p in contours[0])
        {
            Check.IsTrue(p.X >= 27 && p.X <= 36, "隅の x が正方形の範囲であること");
            Check.IsTrue(p.Y >= 27 && p.Y <= 36, "隅の y が正方形の範囲であること");
        }
    }

    /// <summary>
    /// 角点が副画素精度へ動き、**渡した配列は書き換わらない。**
    /// </summary>
    public static void CornerSubPix_RefinesWithoutTouchingTheInput()
    {
        const int side = 32;
        var checker = new byte[side * side];
        for (int r = 0; r < side; r++)
        {
            for (int c = 0; c < side; c++)
            {
                bool white = (r < side / 2) == (c < side / 2);
                checker[r * side + c] = (byte)(white ? 255 : 0);
            }
        }
        using var src = CvMat.Create(side, side, CvMatType.Gray8);
        src.CopyFrom(checker, side);

        var points = new[] { new CvPoint2(14.0f, 14.0f) };
        var refined = CvOps.CornerSubPix(src, points);

        Check.AreEqual(1, refined.Length);
        Check.IsTrue(Math.Abs(refined[0].X - 16.0f) < 2.0f, "角（16, 16）へ寄ること");

        // **C# 側は in-place を見せない。** 渡した配列は元のままである。
        Check.AreEqual(14.0f, points[0].X, "渡した配列が書き換わっていないこと");
        Check.AreEqual(14.0f, points[0].Y, "渡した配列が書き換わっていないこと");
    }

    /// <summary>
    /// core の基本演算が、Unity の中で期待どおりの画素を作る。
    /// </summary>
    public static void CoreOps_ProduceThePixelsWeComputeByHand()
    {
        // 4 channel の 2x2。画素 i の channel c に i * 10 + c を入れる。
        var quad = new byte[16];
        for (int i = 0; i < 4; i++)
        {
            for (int c = 0; c < 4; c++) { quad[i * 4 + c] = (byte)(i * 10 + c); }
        }
        using var four = CvMat.Create(2, 2, CvMatType.Bgra32);
        four.CopyFrom(quad, 2 * 4);
        using var single = CvMat.Create(1, 1, CvMatType.Gray8);

        CvCoreOps.ExtractChannel(four, single, 2);
        Check.AreEqual(1, single.Channels);
        var got = new byte[4];
        single.CopyTo(got, 2);
        for (int i = 0; i < 4; i++)
        {
            Check.AreEqual((byte)(i * 10 + 2), got[i], "channel 2 が取れること");
        }

        // 最小・最大とその位置。
        var extremes = new byte[9];
        for (int i = 0; i < 9; i++) { extremes[i] = 100; }
        extremes[0] = 5;
        extremes[1 * 3 + 1] = 200;
        using var image = CvMat.Create(3, 3, CvMatType.Gray8);
        image.CopyFrom(extremes, 3);

        var mm = CvCoreOps.MinMaxLoc(image);
        Check.AreEqual(5.0, mm.MinValue);
        Check.AreEqual(200.0, mm.MaxValue);
        Check.AreEqual(0.0f, mm.MinLocation.X, "最小は (0, 0) にあること");
        Check.AreEqual(1.0f, mm.MaxLocation.X, "最大は (1, 1) にあること");
        Check.AreEqual(1.0f, mm.MaxLocation.Y);

        // 論理演算。0xF0 AND 0x3C = 0x30。**手で計算できる。**
        var a = new byte[4];
        var b = new byte[4];
        for (int i = 0; i < 4; i++) { a[i] = 0xF0; b[i] = 0x3C; }
        using var left = CvMat.Create(2, 2, CvMatType.Gray8);
        using var right = CvMat.Create(2, 2, CvMatType.Gray8);
        left.CopyFrom(a, 2);
        right.CopyFrom(b, 2);
        using var result = CvMat.Create(1, 1, CvMatType.Gray8);

        CvCoreOps.Bitwise(left, right, result, CvBitwiseOp.And);
        var bits = new byte[4];
        result.CopyTo(bits, 2);
        foreach (var v in bits) { Check.AreEqual((byte)0x30, v, "0xF0 AND 0x3C = 0x30"); }

        CvCoreOps.BitwiseNot(left, result);
        result.CopyTo(bits, 2);
        foreach (var v in bits) { Check.AreEqual((byte)0x0F, v, "NOT 0xF0 = 0x0F"); }

        // ルックアップ変換。i -> 255 - i なので 0xF0 (240) -> 15。
        var table = new byte[256];
        for (int i = 0; i < 256; i++) { table[i] = (byte)(255 - i); }
        CvCoreOps.Lut(left, result, table);
        result.CopyTo(bits, 2);
        foreach (var v in bits) { Check.AreEqual((byte)15, v, "240 が 15 になること"); }

        // 余白。2x2 に上 1 / 下 2 / 左 3 / 右 4 で 5x9。**手で数えられる。**
        CvCoreOps.CopyMakeBorder(left, result, 1, 2, 3, 4, CvBorderMode.Constant, 7.0);
        Check.AreEqual(5, result.Rows);
        Check.AreEqual(9, result.Cols);
        var bordered = new byte[5 * 9];
        result.CopyTo(bordered, 9);
        Check.AreEqual((byte)7, bordered[0], "隅は埋め値であること");
        Check.AreEqual((byte)0xF0, bordered[1 * 9 + 3], "元の画素がずれた位置にあること");
    }

    /// <summary>
    /// 記述子を計算して対応づけられる。**OcvuDMatch の marshalling を Unity で通す。**
    /// </summary>
    /// <remarks>
    /// **この検査を足すまで、OcvuDMatch の配列は素の .NET（L3）でしか
    /// marshal されていなかった。** IL2CPP と Web では、生成された到達性テストが
    /// null を渡すだけだったので、**配列として渡す経路は 1 度も通っていない。**
    /// </remarks>
    public static void Descriptors_AreComputedAndMatched()
    {
        const int side = 224;
        var pixels = new byte[side * side];
        for (int r = 0; r < side; r++)
        {
            for (int c = 0; c < side; c++)
            {
                bool light = ((r / 8) + (c / 8)) % 2 == 0;
                pixels[r * side + c] = (byte)(light ? 220 : 40);
            }
        }
        using var image = CvMat.Create(side, side, CvMatType.Gray8);
        image.CopyFrom(pixels, side);

        using var descriptorsA = CvMat.Create(1, 1, CvMatType.Gray8);
        using var descriptorsB = CvMat.Create(1, 1, CvMatType.Gray8);

        var keypoints = CvFeatures.DetectAndCompute(image, CvFeatureDetector.Orb, 200, descriptorsA);
        Check.Greater(keypoints.Length, 0, "市松模様から特徴点が出ること");
        Check.AreEqual(keypoints.Length, descriptorsA.Rows, "記述子の行数が特徴点の数と一致すること");
        Check.AreEqual(32, descriptorsA.Cols, "ORB の記述子は 32 バイトであること");

        CvFeatures.DetectAndCompute(image, CvFeatureDetector.Orb, 200, descriptorsB);

        // **crossCheck を立てると、互いに最近傍である対応だけが残る。**
        var matches = CvFeatures.MatchDescriptors(
            descriptorsA, descriptorsB, CvDescriptorNorm.Hamming, true);
        Check.Greater(matches.Length, 0, "同じ記述子集合どうしで対応が見つかること");
        foreach (var m in matches)
        {
            Check.AreEqual(m.QueryIndex, m.TrainIndex,
                "互いに最近傍なら索引が一致すること（OcvuDMatch の marshalling）");
            Check.AreEqual(0.0f, m.Distance, "同じ記述子なので距離は 0 であること");
        }
    }

    /// <summary>
    /// 視差画像が作られ、**16 bit 符号つきとして読み出せる。**
    /// </summary>
    /// <remarks>
    /// **入力は繰り返さない模様でなければならない** —— 周期のある縞では
    /// ステレオ照合が一意に決まらず、StereoBM は有効視差を 1 つも返さない
    /// （実測）。決定的な擬似乱数で作る。
    /// </remarks>
    public static void Disparity_IsComputedAndReadBackAs16Bit()
    {
        const int width = 128;
        const int height = 64;

        using var left = CvMat.Create(height, width, CvMatType.Gray8);
        using var right = CvMat.Create(height, width, CvMatType.Gray8);
        left.CopyFrom(MakeStereoTexture(width, height, 0), width);
        right.CopyFrom(MakeStereoTexture(width, height, 4), width);

        using var disparity = CvMat.Create(1, 1, CvMatType.Gray8);
        CvStereo.ComputeDisparity(left, right, disparity, CvStereoAlgorithm.BlockMatching, 16, 21);

        Check.AreEqual(height, disparity.Rows);
        Check.AreEqual(width, disparity.Cols);
        Check.AreEqual((long)(width * 2), disparity.Step, "1 画素 2 バイトであること");

        var raw = new byte[width * height * 2];
        disparity.CopyTo(raw, width * 2);

        // **「視差が 1 画素も求まっていない」を落とす。** 形と型だけを見ると、
        // 全画素が無効視差の印でも通ってしまう。
        int valid = 0;
        for (int i = 0; i < width * height; i++)
        {
            short d = BitConverter.ToInt16(raw, i * 2);
            if (d == -16) { continue; }
            valid++;
            Check.IsTrue(d >= 0 && d <= 16 * 16, "視差が範囲に収まること");
        }
        Check.Greater(valid, 0, "視差が 1 画素も求まっていない");
    }


    /// <summary>
    /// エッジ検出・channel の差し込み・範囲抽出・正規化を Unity の中で動かす。
    /// </summary>
    /// <remarks>
    /// <b>この 4 本だけが、Unity のどのレーンからも呼ばれていなかった。</b>
    /// 26 本を Unity で動かす検査を足したとき、C# の入口の名前で機械的に
    /// 突き合わせて見つけた —— <c>Canny</c> / <c>InsertChannel</c> /
    /// <c>InRange</c> / <c>Normalize</c> の 4 つである。
    /// <para>
    /// L1 と L3 は覆っていたが、<b>IL2CPP の stripping を抜けた先で動くことは
    /// 確かめられていなかった</b> —— 呼ばれない宣言は、消えても誰も気づかない。
    /// </para>
    /// </remarks>
    public static void RemainingImgprocAndCoreOps_WorkInsideUnity()
    {
        // --- Canny: 段差にエッジが出る ---
        var split = new byte[16];
        for (int r = 0; r < 4; r++)
        {
            for (int c = 0; c < 4; c++) { split[r * 4 + c] = (byte)(c < 2 ? 10 : 200); }
        }
        using (var src = CvMat.Create(4, 4, CvMatType.Gray8))
        using (var edges = CvMat.Create(1, 1, CvMatType.Gray8))
        {
            src.CopyFrom(split, 4);
            CvOps.Canny(src, edges, 50.0, 150.0);

            Check.AreEqual(4, edges.Rows);
            Check.AreEqual(4, edges.Cols);
            Check.AreEqual(1, edges.Channels, "Canny は 1 channel を返すこと");

            var got = new byte[16];
            edges.CopyTo(got, 4);
            bool anyEdge = false;
            foreach (var v in got) { if (v == 255) { anyEdge = true; } }
            Check.IsTrue(anyEdge, "段差があるのにエッジが 1 画素も無い");
        }

        // --- InsertChannel: **dst を置き換えず、その channel だけを書き換える** ---
        var quad = new byte[16];
        for (int i = 0; i < 4; i++)
        {
            for (int c = 0; c < 4; c++) { quad[i * 4 + c] = (byte)(i * 10 + c); }
        }
        using (var target = CvMat.Create(2, 2, CvMatType.Bgra32))
        using (var replacement = CvMat.Create(2, 2, CvMatType.Gray8))
        {
            target.CopyFrom(quad, 2 * 4);
            replacement.CopyFrom(new byte[] { 99, 99, 99, 99 }, 2);

            CvCoreOps.InsertChannel(replacement, target, 1);

            // **形は変わらない。** これは他の 25 本と違う性質である。
            Check.AreEqual(2, target.Rows);
            Check.AreEqual(4, target.Channels, "InsertChannel は dst を置き換えないこと");

            var got = new byte[16];
            target.CopyTo(got, 2 * 4);
            for (int i = 0; i < 4; i++)
            {
                Check.AreEqual((byte)(i * 10 + 0), got[i * 4 + 0], "channel 0 は元のままであること");
                Check.AreEqual((byte)99, got[i * 4 + 1], "channel 1 だけが差し替わること");
                Check.AreEqual((byte)(i * 10 + 2), got[i * 4 + 2], "channel 2 は元のままであること");
            }
        }

        // --- InRange: 範囲に入る画素だけが 255 ---
        var extremes = new byte[9];
        for (int i = 0; i < 9; i++) { extremes[i] = 100; }
        extremes[0] = 5;
        extremes[1 * 3 + 1] = 200;
        using (var src = CvMat.Create(3, 3, CvMatType.Gray8))
        using (var mask = CvMat.Create(1, 1, CvMatType.Gray8))
        {
            src.CopyFrom(extremes, 3);

            // 50..150 の間だけ 255。5 と 200 は外れ、100 が 7 個残る。
            CvCoreOps.InRange(src, mask, new[] { 50.0 }, new[] { 150.0 });

            var got = new byte[9];
            mask.CopyTo(got, 3);
            int lit = 0;
            foreach (var v in got) { if (v == 255) { lit++; } }
            Check.AreEqual(7, lit, "100 の画素が 7 個あること");
            Check.AreEqual((byte)0, got[0], "5 は範囲外であること");
            Check.AreEqual((byte)0, got[1 * 3 + 1], "200 は範囲外であること");
        }

        // --- Normalize: 値域が 0..255 へ引き伸ばされる ---
        using (var src = CvMat.Create(3, 3, CvMatType.Gray8))
        using (var stretched = CvMat.Create(1, 1, CvMatType.Gray8))
        {
            src.CopyFrom(extremes, 3);

            CvCoreOps.Normalize(src, stretched, 0.0, 255.0, CvNormType.MinMax);

            // **MinMaxLoc で確かめる。** 2 本を同時に通すことになる。
            var mm = CvCoreOps.MinMaxLoc(stretched);
            Check.AreEqual(0.0, mm.MinValue, "最小が 0 へ写ること");
            Check.AreEqual(255.0, mm.MaxValue, "最大が 255 へ写ること");
        }
    }

    /// <summary>決定的な擬似乱数で、繰り返さない模様を作る。</summary>
    private static byte[] MakeStereoTexture(int width, int height, int offsetX)
    {
        var pixels = new byte[width * height];
        for (int r = 0; r < height; r++)
        {
            for (int c = 0; c < width; c++)
            {
                uint x = (uint)(c + offsetX);
                uint y = (uint)r;
                uint h = (x * 2654435761u) ^ (y * 2246822519u);
                h ^= h >> 13;
                h *= 3266489917u;
                h ^= h >> 16;
                pixels[r * width + c] = (byte)(h & 0xFFu);
            }
        }
        return pixels;
    }
}
