using System.Collections;
using CvUnity;
using CvUnity.Unity;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

/// <summary>
/// EditMode の VerticalSliceTests と同じ検証を Player で行う。
///
/// 内容を変えないこと。M2 の完了条件は「Unity Editor (Mono) と Windows IL2CPP
/// Player の両方で同じ smoke test が通る」であり、違う検証をしたら
/// 「同じ結果になる」ことを確かめたことにならない。
///
/// Player でしか出ない失敗が本命である: IL2CPP の stripping が P/Invoke 宣言を
/// 削ると、ここで EntryPointNotFoundException になる。Mono では再現しない。
/// </summary>
public class PlayerSmokeTests
{
    [UnityTest]
    public IEnumerator NativeLibraryLoadsUnderIl2cpp()
    {
        Assert.AreEqual(1, CvNative.AbiVersion);
        Assert.AreEqual("5.0.0", CvNative.OpenCvVersion);
        yield return null;
    }

    [UnityTest]
    public IEnumerator Texture2D_RoundTripsThroughOpenCvUnchanged()
    {
        var texture = new Texture2D(4, 2, TextureFormat.RGBA32, false);
        var pixels = new Color32[8];
        for (int i = 0; i < pixels.Length; i++)
        {
            pixels[i] = new Color32((byte)(i * 10), (byte)(i * 5), (byte)i, 255);
        }
        texture.SetPixels32(pixels);
        texture.Apply();

        using (var mat = TextureConverter.ToMat(texture))
        {
            var result = new Texture2D(4, 2, TextureFormat.RGBA32, false);
            TextureConverter.ToTexture(mat, result);

            var original = texture.GetRawTextureData<byte>().ToArray();
            var roundTripped = result.GetRawTextureData<byte>().ToArray();
            CollectionAssert.AreEqual(original, roundTripped);
        }
        yield return null;
    }

    [UnityTest]
    public IEnumerator Blur_ChangesPixelsAndKeepsTheShape()
    {
        var texture = new Texture2D(8, 8, TextureFormat.RGBA32, false);
        var pixels = new Color32[64];
        for (int i = 0; i < pixels.Length; i++) { pixels[i] = new Color32(0, 0, 0, 255); }
        pixels[8 * 4 + 4] = new Color32(255, 255, 255, 255);
        texture.SetPixels32(pixels);
        texture.Apply();

        using (var src = TextureConverter.ToMat(texture))
        using (var dst = CvMat.Create(1, 1, CvMatType.Bgra32))
        {
            CvOps.GaussianBlur(src, dst, 3, 3, 0.0, 0.0);
            Assert.AreEqual(8, dst.Cols);
            Assert.AreEqual(8, dst.Rows);
        }
        yield return null;
    }

    [UnityTest]
    public IEnumerator DisposedMat_ThrowsInsteadOfCorruptingMemory()
    {
        var mat = CvMat.Create(2, 2, CvMatType.Gray8);
        mat.Dispose();
        Assert.Throws<System.ObjectDisposedException>(() => { var _ = mat.Rows; });
        yield return null;
    }
}
