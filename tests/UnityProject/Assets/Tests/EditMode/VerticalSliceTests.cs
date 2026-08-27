using System;
using CvUnity;
using CvUnity.Unity;
using NUnit.Framework;
using Unity.Collections;
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
    public void ToTexture_RejectsAMatWhoseChannelCountDoesNotMatchTheTexture()
    {
        // cvtColor でグレースケール化してから書き戻す、というのは この API を
        // 触った人が最初に書くコードの部類に入る。寸法は一致するので寸法検査は
        // 通ってしまう。
        //
        // ポインタ経路にした際、ここは一度素通りしていた。native の検証は
        // stride >= 1 行 かつ stride <= length / rows しか見ないので、
        // テクスチャより 1 画素あたりが小さい Mat は両方を通る。結果、成功が
        // 返るのに先頭へ詰めて一部だけ書かれ、残りは古いまま Apply された
        // （実測: 48 バイト中 12 バイトだけ書き換わり、例外もログも出ない）。
        //
        // byte[] 経路では LoadRawTextureData がバイト数不一致を例外にしていた。
        // 安全網を外した以上、置き直したものが効いていることをここで固定する。
        var texture = new Texture2D(4, 3, TextureFormat.RGBA32, false);
        using var gray = CvMat.Create(3, 4, CvMatType.Gray8);

        var ex = Assert.Throws<ArgumentException>(
            () => TextureConverter.ToTexture(gray, texture));
        StringAssert.Contains("pixel format mismatch", ex.Message);
    }

    [Test]
    public void UserOwnedNativeArray_RoundTripsWithoutGoingThroughAManagedArray()
    {
        // 完了条件 3 は「Texture2D / NativeArray からの入力と結果反映」を求めている。
        // Texture2D 側は上のテストが見ているが、**利用者が自分で持っている
        // NativeArray** を渡す経路はどのレーンにも無かった。TextureConverter の
        // 内部に出てくる NativeArray はテクスチャの生データであって、それは
        // Texture2D 経路である。ここで利用者側の視点を固定する。
        var input = new NativeArray<byte>(12, Allocator.Temp);
        var output = new NativeArray<byte>(12, Allocator.Temp);
        try
        {
            for (int i = 0; i < input.Length; i++) { input[i] = (byte)(i * 7 + 1); }

            using var mat = CvMat.Create(3, 4, CvMatType.Gray8);
            mat.CopyFrom(input, 4);
            mat.CopyTo(output, 4);

            for (int i = 0; i < input.Length; i++)
            {
                Assert.AreEqual(input[i], output[i], $"byte {i} did not survive the round trip");
            }
        }
        finally
        {
            input.Dispose();
            output.Dispose();
        }
    }

    [Test]
    public void NativeArrayLength_IsElementsNotBytes()
    {
        // NativeArray<T>.Length は要素数であってバイト数ではない。呼ぶ側が
        // 取り違えると、Color32 のような 4 バイト要素で 4 倍ずれ、native の
        // 検証をすり抜けかねない値になる。拡張メソッド側が SizeOf<T>() を
        // 掛けていることを、多バイト要素で固定する。
        var pixels = new NativeArray<Color32>(12, Allocator.Temp);
        try
        {
            for (int i = 0; i < pixels.Length; i++)
            {
                pixels[i] = new Color32((byte)i, (byte)(i * 2), (byte)(i * 3), 255);
            }

            // 12 要素 = 48 バイト。4x3 の 4 チャンネル Mat と一致する。
            // 要素数をバイト数と取り違えていたら 12 バイト扱いになり、
            // stride=16 との組み合わせで native の検証に弾かれる。
            using var mat = CvMat.Create(3, 4, CvMatType.Bgra32);
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
        finally { pixels.Dispose(); }
    }

    [Test]
    public void ToMat_RejectsANonRgba32Texture()
    {
        // ToTexture 側と対になる検査。こちらは今まで誰も触れておらず、
        // 消しても全レーンが緑のままだった（実測）。
        //
        // ここが無いと沈黙して壊れる。ToMat は常に stride = width * 4 を渡し
        // Bgra32 の Mat を作るので、1 画素あたり 4 バイト未満の形式
        // （RGB24 など）でも native の検証（stride >= 1 行、stride * rows <= 長さ）
        // を通り得る。通ってしまえば、渡した領域の外や隣の行を読んだ結果が
        // そのまま Mat に入る — 例外もログも出ない。
        var texture = new Texture2D(4, 3, TextureFormat.RGB24, false);
        Assert.Throws<System.NotSupportedException>(
            () => TextureConverter.ToMat(texture));
    }

    [Test]
    public void ToTexture_RejectsANonRgba32Texture()
    {
        // 形式検査そのものを固定する。
        //
        // 当初このコメントは「バイト数が一致するので形式検査だけが弾ける」と
        // 書いていたが、実装を読み違えていた。バイト数検査は
        // texture.width * height * 4 と計算する（形式検査を通過した後に走る
        // 前提なので RGBA32 決め打ちでよい）ので、RGB24 の 4x3 でも 48 と算出し、
        // 3 チャンネル Mat の 36 とは一致しない。つまりバイト数検査も弾く。
        //
        // それでもこのテストは形式検査を固定する。Assert.Throws<T> は型の完全一致
        // なので、形式検査を消すと ArgumentException（バイト数検査）が飛んで
        // NotSupportedException を期待するこの assertion が落ちるからである
        // （実測で確認済み）。効く理由が「唯一の関門だから」ではなく
        // 「例外の型が違うから」である点を、次に読む人のために書いておく。
        var texture = new Texture2D(4, 3, TextureFormat.RGB24, false);
        using (var mat = CvMat.Create(3, 4, CvMatType.Bgr24))
        {
            Assert.Throws<System.NotSupportedException>(
                () => TextureConverter.ToTexture(mat, texture));
        }
    }

    [Test]
    public void ToTexture_AcceptsAMatchingFourChannelMat()
    {
        // 上の検査が「何でも拒否する」形になっていないことの担保。
        var texture = new Texture2D(4, 3, TextureFormat.RGBA32, false);
        using var rgba = CvMat.Create(3, 4, CvMatType.Bgra32);
        TextureConverter.ToTexture(rgba, texture);
    }

    [Test]
    public void DisposedMat_ThrowsInsteadOfCorruptingMemory()
    {
        var mat = CvMat.Create(2, 2, CvMatType.Gray8);
        mat.Dispose();
        Assert.Throws<ObjectDisposedException>(() => { var _ = mat.Rows; });
    }
}
