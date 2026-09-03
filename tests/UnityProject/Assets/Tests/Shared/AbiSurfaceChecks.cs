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
/// 下の 8 件は**正しく動くこと**を見ており、2 つは別のものを守っている。
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
}
