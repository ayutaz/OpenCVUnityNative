using System.Collections;
using CvUnity;
using CvUnity.Unity;
using NUnit.Framework;
using Unity.Collections;
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
            // EditMode と同じ形状検査。往復だけを見ていると、変換が形を
            // 取り違えていても往復の対称性で打ち消されて通り得る。
            Assert.AreEqual(4, mat.Cols);
            Assert.AreEqual(2, mat.Rows);
            Assert.AreEqual(4, mat.Channels);

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

            // EditMode と同じ 5 行。寸法だけを見ていると、GaussianBlur が何も
            // せずに返っても Player は緑になる。
            //
            // さらにこの 2 行は、Player で byte[] 版の P/Invoke を通す唯一の
            // 経路でもある。byte[] 版は今も public API であり、利用者は IL2CPP
            // 上でこれを呼ぶ。stripping がその宣言を削らないことを確かめる場所は
            // このレーンしか無い（Mono では再現しない）。
            var before = new byte[8 * 8 * 4];
            var after = new byte[8 * 8 * 4];
            src.CopyTo(before, 8 * 4);
            dst.CopyTo(after, 8 * 4);
            CollectionAssert.AreNotEqual(before, after, "the blur must actually change pixels");
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
    [UnityTest]
    public IEnumerator UserOwnedNativeArray_RoundTripsWithoutGoingThroughAManagedArray()
    {
        var input = new NativeArray<byte>(12, Allocator.Temp);
        var output = new NativeArray<byte>(12, Allocator.Temp);
        try
        {
            for (int i = 0; i < input.Length; i++) { input[i] = (byte)(i * 7 + 1); }

            using (var mat = CvMat.Create(3, 4, CvMatType.Gray8))
            {
                mat.CopyFrom(input, 4);
                mat.CopyTo(output, 4);
            }

            for (int i = 0; i < input.Length; i++)
            {
                Assert.AreEqual(input[i], output[i], $"byte {i} did not survive the round trip");
            }
        }
        finally { input.Dispose(); output.Dispose(); }
        yield return null;
    }

    [UnityTest]
    public IEnumerator NativeArrayLength_IsElementsNotBytes()
    {
        var pixels = new NativeArray<Color32>(12, Allocator.Temp);
        try
        {
            for (int i = 0; i < pixels.Length; i++)
            {
                pixels[i] = new Color32((byte)i, (byte)(i * 2), (byte)(i * 3), 255);
            }

            using (var mat = CvMat.Create(3, 4, CvMatType.Bgra32))
            {
                mat.CopyFrom(pixels, 4 * 4);

                var back = new NativeArray<Color32>(12, Allocator.Temp);
                try
                {
                    mat.CopyTo(back, 4 * 4);
                    for (int i = 0; i < pixels.Length; i++)
                    {
                        Assert.AreEqual(pixels[i].r, back[i].r, $"pixel {i} red channel");
                        Assert.AreEqual(pixels[i].a, back[i].a, $"pixel {i} alpha channel");
                    }
                }
                finally { back.Dispose(); }
            }
        }
        finally { pixels.Dispose(); }
        yield return null;
    }

    [UnityTest]
    public IEnumerator ToTexture_RejectsAMatWhoseChannelCountDoesNotMatchTheTexture()
    {
        var texture = new Texture2D(4, 3, TextureFormat.RGBA32, false);
        using (var gray = CvMat.Create(3, 4, CvMatType.Gray8))
        {
            var ex = Assert.Throws<System.ArgumentException>(
                () => TextureConverter.ToTexture(gray, texture));
            StringAssert.Contains("pixel format mismatch", ex.Message);
        }
        yield return null;
    }

    [UnityTest]
    public IEnumerator ToTexture_RejectsANonRgba32Texture()
    {
        // 形式検査そのものを固定する。バイト数一致検査とは別物である:
        // RGB24 の 4x3 テクスチャ（36 バイト）に 3 チャンネル Mat（36 バイト）を
        // 渡すとバイト数は一致してしまうので、形式検査を消してもバイト数検査は
        // 通る。M2 が RGBA32 しか扱わないことを明示的に見る。
        var texture = new Texture2D(4, 3, TextureFormat.RGB24, false);
        using (var mat = CvMat.Create(3, 4, CvMatType.Bgr24))
        {
            Assert.Throws<System.NotSupportedException>(
                () => TextureConverter.ToTexture(mat, texture));
        }
        yield return null;
    }

    [UnityTest]
    public IEnumerator ToTexture_AcceptsAMatchingFourChannelMat()
    {
        var texture = new Texture2D(4, 3, TextureFormat.RGBA32, false);
        using (var rgba = CvMat.Create(3, 4, CvMatType.Bgra32))
        {
            TextureConverter.ToTexture(rgba, texture);
        }
        yield return null;
    }
}
