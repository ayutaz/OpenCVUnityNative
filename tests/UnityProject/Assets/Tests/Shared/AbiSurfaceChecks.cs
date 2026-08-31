using System;
using CvUnity;
using CvUnity.Unity;
using NUnit.Framework;
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
/// ようになり、C ABI の 20 本すべてが package に現れる（<c>[DllImport]</c> は
/// 22 個。上の 2 重宣言は <c>_ptr</c> 付きの別名になった）。増えた 1 本は
/// <c>ocvu_debug_crash</c> で、**呼べばプロセスが死ぬので通す対象ではない。**
///
/// 通していない残りは 3 本（<c>ocvu_get_status_count</c> /
/// <c>ocvu_get_status_value</c> / <c>ocvu_debug_crash</c>）である。
/// 前の 2 本は **出荷する C# のどこからも呼ばれていない** —— 呼ぶ側が無く、
/// <c>NativeMethods</c> は internal なので Unity のテストからも到達できない。
/// stripping がこの 2 本を消しても壊れるものは無いが、「通した」と
/// 書かないために明記しておく
/// （status 表の同期は L3 の <c>StatusCodeSyncTests</c> が見ている）。
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

        Assert.AreEqual(3, dst.Cols);
        Assert.AreEqual(2, dst.Rows);
        Assert.AreEqual(3, dst.Channels, "Bgra2Bgr は 4 ch を 3 ch にする");
    }

    public static void Resize_ProducesTheRequestedSize()
    {
        using var src = CvMat.Create(4, 4, CvMatType.Bgra32);
        src.CopyFrom(new byte[4 * 4 * 4], 4 * 4);
        using var dst = CvMat.Create(1, 1, CvMatType.Bgra32);

        CvOps.Resize(src, dst, 8, 2, CvOps.InterNearest);

        Assert.AreEqual(8, dst.Cols);
        Assert.AreEqual(2, dst.Rows);
        Assert.AreEqual(4, dst.Channels);
    }

    public static void Clone_CopiesThePixelsIntoAnIndependentMat()
    {
        var pixels = new byte[2 * 2 * 1];
        pixels[0] = 7;
        pixels[3] = 9;

        using var src = CvMat.Create(2, 2, CvMatType.Gray8);
        src.CopyFrom(pixels, 2);

        using var clone = src.Clone();
        Assert.AreEqual(2, clone.Rows);
        Assert.AreEqual(2, clone.Cols);

        var copied = new byte[4];
        clone.CopyTo(copied, 2);
        CollectionAssert.AreEqual(pixels, copied);

        // **独立していること。** clone が同じメモリを指していたら、
        // 片方を書き換えたときにもう片方も変わる。
        src.CopyFrom(new byte[] { 1, 2, 3, 4 }, 2);
        var afterSrcChanged = new byte[4];
        clone.CopyTo(afterSrcChanged, 2);
        CollectionAssert.AreEqual(pixels, afterSrcChanged,
            "clone は src と別のメモリを持つ");
    }

    public static void EncodedImage_DecodesBackToTheSameShape()
    {
        var pixels = new byte[3 * 4 * 1];
        for (int i = 0; i < pixels.Length; i++) { pixels[i] = (byte)(i * 7); }

        using var src = CvMat.Create(3, 4, CvMatType.Gray8);
        src.CopyFrom(pixels, 4);

        // **ファイルパスは通らない。** byte 列だけを扱う（M3.5 の決定）。
        var png = CvCodecs.Encode(src, ".png");
        Assert.Greater(png.Length, 8, "PNG の byte 列が返ること");
        Assert.AreEqual(0x89, png[0], "PNG の署名で始まること");

        using var decoded = CvCodecs.Decode(png, CvCodecs.ImreadGrayscale);
        Assert.AreEqual(3, decoded.Rows);
        Assert.AreEqual(4, decoded.Cols);
        Assert.AreEqual(1, decoded.Channels);

        // PNG は可逆なので画素まで一致する。
        var roundTripped = new byte[pixels.Length];
        decoded.CopyTo(roundTripped, 4);
        CollectionAssert.AreEqual(pixels, roundTripped);
    }

    public static void Encode_RejectsAnExtensionOpenCvCannotWrite()
    {
        using var src = CvMat.Create(2, 2, CvMatType.Gray8);
        src.CopyFrom(new byte[4], 2);

        // **型だけで満足しない。** CvCodecs.Encode は 2 か所から
        // CvNativeException を投げるので、型を見るだけでは
        // 「拡張子を断られた」経路を通ったことにならない。
        var ex = Assert.Throws<CvNativeException>(() => CvCodecs.Encode(src, ".notanimage"));
        Assert.AreEqual(CvStatus.OpenCvError, ex.Status,
            "扱えない拡張子は OpenCV 側のエラーとして返る");
    }

    public static void BuildInformation_ComesBackThroughTheTwoCallIdiom()
    {
        var info = CvNative.GetBuildInformation();

        // **IsNotNull は書かない。** CvNative.ReadString は失敗時に
        // string.Empty を返すので、null 判定は構造的に常に真になる。
        // 2 回呼びが壊れると空文字か切り詰めた文字列が返るので、そこを見る。
        Assert.AreNotEqual(string.Empty, info, "2 回呼びが失敗すると空文字が返る");
        Assert.Greater(info.Length, 64, "build information は長い文字列である");
        StringAssert.Contains("OpenCV", info);
    }

    public static void NativeExceptionsAreTurnedIntoStatusCodes()
    {
        // **例外を ABI の外へ出さない**という不変条件を、Player でも確かめる。
        // 境界を越える unwind は未定義動作なので、Mono で通っても足りない。
        Assert.AreEqual(CvStatus.UnknownError, CvNative.DebugThrow(0));
        Assert.AreEqual(CvStatus.OutOfMemory, CvNative.DebugThrow(1));
        Assert.AreEqual(CvStatus.UnknownError, CvNative.DebugThrow(2));
        Assert.AreEqual(CvStatus.Ok, CvNative.DebugThrow(3));
        Assert.AreEqual(CvStatus.InvalidArgument, CvNative.DebugThrow(99));
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

        Assert.AreEqual(2, mat.Rows);
        Assert.AreEqual(2, mat.Cols);
        Assert.AreEqual(4, mat.Channels);

        var got = new byte[2 * 2 * 4];
        mat.CopyTo(got, mat.Cols * 4);

        Assert.AreEqual(20, got[0], "Mat の先頭行は Unity の最終行（画像の上端）であること");
        Assert.AreEqual(10, got[8], "Mat の 2 行目は Unity の 0 行目（画像の下端）であること");
    }
}
