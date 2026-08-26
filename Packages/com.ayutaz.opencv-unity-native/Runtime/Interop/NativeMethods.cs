using System.Runtime.InteropServices;

namespace CvUnity.Interop
{
    /// <summary>
    /// ocvu_mat_get_info の native 側 struct と同じ layout。
    /// 固定サイズ型のみで構成する（native/include/opencv_unity_native.h の
    /// ocvu_mat_info を参照）。
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct OcvuMatInfo
    {
        internal int Rows;
        internal int Cols;
        internal int Type;
        internal int Channels;
        internal long Step;
        internal long TotalBytes;
    }

    internal static class NativeMethods
    {
#if UNITY_IOS && !UNITY_EDITOR
        internal const string LibraryName = "__Internal";
#else
        internal const string LibraryName = "opencv_unity_native";
#endif

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_abi_version();

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_last_error_status();

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_last_error_message(
            byte[] buffer, int bufferSize, out int requiredSize);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_status_count();

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_status_value(int index, out int value);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_debug_throw(int kind);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_opencv_version(
            byte[] buffer, int bufferSize, out int requiredSize);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_build_information(
            byte[] buffer, int bufferSize, out int requiredSize);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_mat_create(int rows, int cols, int type, out ulong handle);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_mat_release(ulong handle);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_mat_clone(ulong src, out ulong handle);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_mat_get_info(ulong handle, out OcvuMatInfo info);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_mat_copy_from_buffer(
            ulong dst, byte[] src, long srcLength, long srcStride);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_mat_copy_to_buffer(
            ulong src, byte[] dst, long dstLength, long dstStride);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_cvt_color(ulong src, ulong dst, int code);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_resize(
            ulong src, ulong dst, int width, int height, int interpolation);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_gaussian_blur(
            ulong src, ulong dst, int ksizeWidth, int ksizeHeight, double sigmaX, double sigmaY);
    }
}
