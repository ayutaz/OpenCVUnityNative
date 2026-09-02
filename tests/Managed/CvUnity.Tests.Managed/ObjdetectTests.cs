using System;
using CvUnity;
using Xunit;

public class ObjdetectTests
{
    [Fact]
    public void EncodeThenDecodeRoundTripsTheText()
    {
        const string payload = "OpenCVUnityNative";

        using var img = CvMat.Create(1, 1, CvMatType.Gray8);
        CvQrCode.Encode(payload, img);
        Assert.Equal(img.Rows, img.Cols);

        Assert.Equal(payload, CvQrCode.Decode(img));
    }

    [Fact]
    public void DecodeReturnsNullWhenNoCodeIsPresent()
    {
        using var blank = CvMat.Create(64, 64, CvMatType.Gray8);

        // **`CvMat.Create` は画素を初期化しない。** 「QR が写っていない」と
        // 主張するなら明示的にゼロ埋めする（`CalibrationTests` と同じ理由。
        // `fab6cf3` が足した 500 回のループが同じ大きさの市松模様でアロケータを
        // 汚すようになったので、このテストが受け取る画素も以前より変わりやすい）。
        blank.CopyFrom(new byte[64 * 64], 64);

        Assert.Null(CvQrCode.Decode(blank));
    }

    [Fact]
    public void EncodeRejectsNullAndEmptyText()
    {
        using var img = CvMat.Create(1, 1, CvMatType.Gray8);
        Assert.Throws<ArgumentNullException>(() => CvQrCode.Encode(null, img));
        Assert.Throws<ArgumentException>(() => CvQrCode.Encode("", img));
    }
}
