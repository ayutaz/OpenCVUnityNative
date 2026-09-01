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
