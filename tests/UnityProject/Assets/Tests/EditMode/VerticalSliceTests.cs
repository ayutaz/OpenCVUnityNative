using System;
using CvUnity;
using CvUnity.Unity;
using NUnit.Framework;
using UnityEngine;

public class VerticalSliceTests
{
    [Test]
    public void NativeLibraryLoadsAndReportsItsVersions()
    {
        Assert.AreEqual(1, CvNative.AbiVersion);
        Assert.AreEqual("5.0.0", CvNative.OpenCvVersion);
    }

    [Test]
    public void Texture2D_RoundTripsThroughOpenCvUnchanged()
    {
        var texture = new Texture2D(4, 2, TextureFormat.RGBA32, false);
        var pixels = new Color32[8];
        for (int i = 0; i < pixels.Length; i++)
        {
            pixels[i] = new Color32((byte)(i * 10), (byte)(i * 5), (byte)i, 255);
        }
        texture.SetPixels32(pixels);
        texture.Apply();

        using var mat = TextureConverter.ToMat(texture);
        Assert.AreEqual(4, mat.Cols);
        Assert.AreEqual(2, mat.Rows);
        Assert.AreEqual(4, mat.Channels);

        var result = new Texture2D(4, 2, TextureFormat.RGBA32, false);
        TextureConverter.ToTexture(mat, result);

        var original = texture.GetRawTextureData<byte>().ToArray();
        var roundTripped = result.GetRawTextureData<byte>().ToArray();
        CollectionAssert.AreEqual(original, roundTripped);
    }

    [Test]
    public void Blur_ChangesPixelsAndKeepsTheShape()
    {
        var texture = new Texture2D(8, 8, TextureFormat.RGBA32, false);
        var pixels = new Color32[64];
        for (int i = 0; i < pixels.Length; i++) { pixels[i] = new Color32(0, 0, 0, 255); }
        pixels[8 * 4 + 4] = new Color32(255, 255, 255, 255);
        texture.SetPixels32(pixels);
        texture.Apply();

        using var src = TextureConverter.ToMat(texture);
        using var dst = CvMat.Create(1, 1, CvMatType.Bgra32);

        CvOps.GaussianBlur(src, dst, 3, 3, 0.0, 0.0);

        Assert.AreEqual(8, dst.Cols);
        Assert.AreEqual(8, dst.Rows);

        var before = new byte[8 * 8 * 4];
        var after = new byte[8 * 8 * 4];
        src.CopyTo(before, 8 * 4);
        dst.CopyTo(after, 8 * 4);
        CollectionAssert.AreNotEqual(before, after, "the blur must actually change pixels");
    }

    [Test]
    public void DisposedMat_ThrowsInsteadOfCorruptingMemory()
    {
        var mat = CvMat.Create(2, 2, CvMatType.Gray8);
        mat.Dispose();
        Assert.Throws<ObjectDisposedException>(() => { var _ = mat.Rows; });
    }
}
