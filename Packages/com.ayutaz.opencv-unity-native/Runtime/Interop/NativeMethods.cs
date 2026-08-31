using System;
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

    internal static partial class NativeMethods
    {
#if UNITY_IOS && !UNITY_EDITOR
        internal const string LibraryName = "__Internal";
#else
        internal const string LibraryName = "opencv_unity_native";
#endif

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_last_error_message(
            byte[] buffer, int bufferSize, out int requiredSize);

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

        /*
         * ポインタを直接渡す版。C ABI 側の signature は byte[] 版と同一で、
         * 呼び出し規約も同じ。marshaller に配列を固定させる代わりに、
         * 呼ぶ側が既に持っているアドレスをそのまま渡す。
         *
         * Unity の NativeArray（Texture2D.GetRawTextureData など）はこの経路で
         * 渡す。byte[] 版を使うと managed 配列への写しが 1 回挟まり、
         * Texture2D -> Mat がコピー 2 回になる。
         *
         * **呼ぶ側の責任**: ポインタが指す領域は、この呼び出しが戻るまで
         * 生きていなければならない。native 側は呼び出しの内側でしか触らず、
         * 戻った後は一切保持しない（docs/abi-ownership-and-versioning.md §1）。
         * NativeArray なら Dispose される前、Texture2D の生データなら
         * テクスチャが更新・破棄される前に呼び終えること。
         *
         * length と stride は native 側が検証する。ここを信用して検証を
         * 省いてはならない — 検証を通らなければ 1 バイトも書かれない。
         */
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_mat_copy_from_buffer(
            ulong dst, IntPtr src, long srcLength, long srcStride);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_mat_copy_to_buffer(
            ulong src, IntPtr dst, long dstLength, long dstStride);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_cvt_color(ulong src, ulong dst, int code);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_resize(
            ulong src, ulong dst, int width, int height, int interpolation);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_gaussian_blur(
            ulong src, ulong dst, int ksizeWidth, int ksizeHeight, double sigmaX, double sigmaY);

        /*
         * ext は **UTF-8 の NUL 終端 byte 列**として渡す。string を
         * marshaller に任せず自分で encode するのは、境界での文字コード変換を
         * 実行環境（Mono / IL2CPP、既定の CharSet）任せにしないためである。
         * CvNative.ReadString が UTF-8 を明示的に扱っているのと同じ理由。
         *
         * buffer に null を渡す 1 回目は必要サイズの問い合わせで、
         * OCVU_STATUS_BUFFER_TOO_SMALL が返るのが正常である。
         */
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_imencode(
            ulong src, byte[] ext, byte[] buffer, int bufferSize, out int requiredSize);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_imdecode(
            byte[] data, long length, int flags, ulong dst);
    }
}
