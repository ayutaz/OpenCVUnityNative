using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>imgproc の薄い wrapper。status を例外に変換する。</summary>
    public static class CvOps
    {
        public const int Bgra2Bgr = 1;
        public const int Rgba2Bgra = 5;
        public const int Bgr2Gray = 6;
        public const int InterNearest = 0;
        public const int InterLinear = 1;

        public static void CvtColor(CvMat src, CvMat dst, int code) =>
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_cvt_color(
                src.Handle, dst.Handle, code));

        public static void Resize(CvMat src, CvMat dst, int width, int height, int interpolation) =>
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_resize(
                src.Handle, dst.Handle, width, height, interpolation));

        public static void GaussianBlur(CvMat src, CvMat dst,
                                        int ksizeWidth, int ksizeHeight,
                                        double sigmaX, double sigmaY) =>
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_gaussian_blur(
                src.Handle, dst.Handle, ksizeWidth, ksizeHeight, sigmaX, sigmaY));
    }
}
