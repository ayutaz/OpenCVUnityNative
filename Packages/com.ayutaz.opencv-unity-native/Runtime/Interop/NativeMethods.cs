using System.Runtime.InteropServices;

namespace CvUnity.Interop
{
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
    }
}
