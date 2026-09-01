using System;
using System.Runtime.InteropServices;
using CvUnity;
using CvUnity.Interop;
using Xunit;

public class FeaturesTests
{
    [Fact]
    public void TheKeypointStructMatchesTheNativeLayout()
    {
        // native 側は static_assert(sizeof(ocvu_keypoint) == 28) で固定している。
        // 食い違うと marshalling だけが壊れるので、両側から挟む。
        Assert.Equal(28, Marshal.SizeOf<OcvuKeyPoint>());
    }

    [Fact]
    public void EveryKeypointFieldSitsWhereTheNativeStructPutsIt()
    {
        // **合計の大きさだけでは足りない。** 同じ型のフィールドを入れ替えても
        // sizeof は 28 のままで、C 側の static_assert も C# の SizeOf も通る
        // （X と Y、Size と Angle、Octave と ClassId はどれも同型）。
        // そのとき壊れるのは呼んだ場所ではなく、後から値を読む無関係な場所である。
        // native の ocvu_keypoint は x, y, size, angle, response（float 5 つ）に
        // octave, class_id（int32_t 2 つ）が続く並びで、offset はそれを写したもの。
        Assert.Equal(0, Marshal.OffsetOf<OcvuKeyPoint>(nameof(OcvuKeyPoint.X)).ToInt32());
        Assert.Equal(4, Marshal.OffsetOf<OcvuKeyPoint>(nameof(OcvuKeyPoint.Y)).ToInt32());
        Assert.Equal(8, Marshal.OffsetOf<OcvuKeyPoint>(nameof(OcvuKeyPoint.Size)).ToInt32());
        Assert.Equal(12, Marshal.OffsetOf<OcvuKeyPoint>(nameof(OcvuKeyPoint.Angle)).ToInt32());
        Assert.Equal(16, Marshal.OffsetOf<OcvuKeyPoint>(nameof(OcvuKeyPoint.Response)).ToInt32());
        Assert.Equal(20, Marshal.OffsetOf<OcvuKeyPoint>(nameof(OcvuKeyPoint.Octave)).ToInt32());
        Assert.Equal(24, Marshal.OffsetOf<OcvuKeyPoint>(nameof(OcvuKeyPoint.ClassId)).ToInt32());
    }

    [Fact]
    public void DetectOrbFindsKeypointsOnACheckerboard()
    {
        using var img = MakeCheckerboard(128, 16);

        CvKeyPoint[] keypoints = CvFeatures.DetectOrb(img, 64);

        Assert.NotEmpty(keypoints);
        Assert.True(keypoints.Length <= 64);
        Assert.All(keypoints, k =>
        {
            Assert.InRange(k.X, 0f, 128f);
            Assert.InRange(k.Y, 0f, 128f);
        });
    }

    [Fact]
    public void DetectOrbRejectsAnOutOfRangeMaxFeatures()
    {
        using var img = MakeCheckerboard(64, 8);
        Assert.Throws<ArgumentOutOfRangeException>(() => CvFeatures.DetectOrb(img, 0));
    }

    [Fact]
    public void TheManagedUpperBoundMatchesWhatNativeAccepts()
    {
        // CvFeatures の 10000 は C の OCVU_ORB_MAX_FEATURES の写しである。
        // **写しなので、放っておくと片方だけ変わる。** 境界の両側を native に問う。
        using var img = CvMat.Create(8, 8, CvMatType.Gray8);

        var raw = new OcvuKeyPoint[1];

        // 10000 は受理される（capacity 不足で BufferTooSmall になるが、
        // max_features の検証は通っている）。
        var atTheLimit = (CvStatus)NativeMethods.ocvu_orb_detect(img.Handle, 10000, raw, 1, out _);
        Assert.Equal(CvStatus.BufferTooSmall, atTheLimit);

        // 10001 は max_features の検証で弾かれる。
        var overTheLimit = (CvStatus)NativeMethods.ocvu_orb_detect(img.Handle, 10001, raw, 1, out _);
        Assert.Equal(CvStatus.InvalidArgument, overTheLimit);
    }

    private static CvMat MakeCheckerboard(int size, int cell)
    {
        var mat = CvMat.Create(size, size, CvMatType.Gray8);
        var pixels = new byte[size * size];
        for (int y = 0; y < size; y++)
        {
            for (int x = 0; x < size; x++)
            {
                pixels[y * size + x] = ((x / cell) + (y / cell)) % 2 == 0 ? (byte)255 : (byte)0;
            }
        }
        mat.CopyFrom(pixels, size);
        return mat;
    }
}
