using System;
using CvUnity;
using CvUnity.Unity;
using NUnit.Framework;
using UnityEngine;

/// <summary>
/// WebCamTexture から CvMat を作る経路のテスト（M4、穴 #5）。
///
/// **実カメラは使わない。** EditMode でカメラを開くと、権限の無い環境や
/// カメラの無い CI で必ず落ちる —— 「環境が理由で赤い」は「コードが理由で
/// 赤い」と区別できないので、レーンとして成立しない。
///
/// 代わりに Color32[] を直接受ける overload を検査する。**WebCamTexture から
/// 取れるのはまさにその配列であり、変換の中身はそこから先に全部ある。**
/// テストの外に残るのは、カメラを開いて GetPixels32 を呼ぶ 2 行だけである。
/// </summary>
public class WebCamTextureConverterTests
{
    [Test]
    public void NullWebCamTextureIsRejected()
    {
        Assert.Throws<ArgumentNullException>(() => WebCamTextureConverter.ToMat((WebCamTexture)null));
    }

    [Test]
    public void NullPixelArrayIsRejected()
    {
        Assert.Throws<ArgumentNullException>(() => WebCamTextureConverter.ToMat(null, 2, 2));
    }

    /// <summary>
    /// **Unity と OpenCV で原点が違う。**
    ///
    /// Unity のテクスチャは左下が原点、OpenCV の Mat は左上が原点である。
    /// そのまま写すと上下が反転した Mat ができ、**エラーにはならない** ——
    /// cvtColor も resize も問題なく動くので、画面に出して初めて気づく。
    /// 行ごとに違う値を置いて、順序を実際に見る。
    /// </summary>
    [Test]
    public void RowOrderIsFlippedSoTheMatOriginIsTopLeft()
    {
        var pixels = new Color32[]
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
        Assert.AreEqual(21, got[4]);
        Assert.AreEqual(10, got[8], "Mat の 2 行目は Unity の 0 行目（画像の下端）であること");
        Assert.AreEqual(11, got[12]);
    }

    /// <summary>
    /// チャネルの並びが崩れていないこと。行の入れ替えは 1 行ずつの
    /// バイト列コピーなので、幅の計算を間違えると横方向にずれる。
    /// </summary>
    [Test]
    public void ChannelOrderIsPreservedWithinARow()
    {
        var pixels = new Color32[] { new Color32(1, 2, 3, 4) };

        using var mat = WebCamTextureConverter.ToMat(pixels, width: 1, height: 1);

        var got = new byte[4];
        mat.CopyTo(got, 4);
        CollectionAssert.AreEqual(new byte[] { 1, 2, 3, 4 }, got,
            "Color32 の R,G,B,A がその順で並ぶこと");
    }

    [Test]
    public void PixelCountMustMatchTheGivenSize()
    {
        var pixels = new Color32[3];
        var ex = Assert.Throws<ArgumentException>(
            () => WebCamTextureConverter.ToMat(pixels, width: 2, height: 2));
        StringAssert.Contains("4", ex.Message, "期待した画素数をメッセージに出すこと");
    }

    /// <summary>
    /// WebCamTexture は Play() の直後、まだ最初のフレームが来ていない間は
    /// width/height に既定値を返し、実際の画素はまだ無い。**0 を通すと
    /// native 側で 0 行 0 列の Mat ができて、後段が黙って何もしない。**
    /// </summary>
    [Test]
    public void ZeroSizeIsRejected()
    {
        Assert.Throws<ArgumentOutOfRangeException>(
            () => WebCamTextureConverter.ToMat(new Color32[0], width: 0, height: 0));
    }

    [Test]
    public void NegativeSizeIsRejected()
    {
        Assert.Throws<ArgumentOutOfRangeException>(
            () => WebCamTextureConverter.ToMat(new Color32[4], width: -2, height: 2));
    }

    /// <summary>
    /// 非正方形でも行と列を取り違えないこと。**正方形だけで試すと、
    /// rows と cols を逆に渡していても通ってしまう。**
    /// </summary>
    [Test]
    public void NonSquareImagesKeepTheirRowsAndColumns()
    {
        // 幅 3、高さ 2
        var pixels = new Color32[6];
        for (var i = 0; i < pixels.Length; i++) { pixels[i] = new Color32((byte)i, 0, 0, 255); }

        using var mat = WebCamTextureConverter.ToMat(pixels, width: 3, height: 2);

        Assert.AreEqual(2, mat.Rows, "Rows は高さ");
        Assert.AreEqual(3, mat.Cols, "Cols は幅");
    }
}
