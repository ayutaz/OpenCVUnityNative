// このファイルは生成物である。手で編集しないこと。
// 正本: bindings/spec/core.json
// 生成: ./tools/dev.ps1 generate

using System.Runtime.InteropServices;

namespace CvUnity.Interop
{
    internal static partial class NativeMethods
    {
        /// <summary>rows x cols、指定 type の Mat を確保し、handle を out_handle に書く。rows / cols が 1 未満、または type が未知なら OCVU_STATUS_INVALID_ARGUMENT を返し out_handle は変更しない。out_handle が NULL なら OCVU_STATUS_NULL_POINTER。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_mat_create(int rows, int cols, int type, out ulong out_handle);

        /// <summary>handle を解放する。解放済み、または未知の handle なら OCVU_STATUS_INVALID_HANDLE を返す（落とさない）。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_mat_release(ulong handle);

        /// <summary>src の内容を複製した独立の handle を作る。src と複製は別の記憶域を持つ。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_mat_clone(ulong src, out ulong out_handle);

        /// <summary>handle の形状を out_info に書く。out_info が NULL なら OCVU_STATUS_NULL_POINTER。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_mat_get_info(ulong handle, out OcvuMatInfo out_info);

        /// <summary>外部 buffer から Mat へコピーする。src は呼び出しの内側でだけ読む借用で、戻った後 native は一切保持しない。長さと stride は書く前にすべて検証し、1 つでも合わなければ何も書かずに返す。src_stride は Mat の step と異なってよく、行ごとにコピーする。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_mat_copy_from_buffer(ulong dst, byte[] src, long src_length, long src_stride);

        /// <summary>ocvu_mat_copy_from_buffer にアドレスを直接渡す C# 側の入口。NativeArray や Texture2D の生データを managed 配列へ写さずに渡すためにある。領域はこの呼び出しが戻るまで生きていなければならない。</summary>
        [DllImport(LibraryName, EntryPoint = "ocvu_mat_copy_from_buffer", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_mat_copy_from_buffer_ptr(ulong dst, System.IntPtr src, long src_length, long src_stride);

        /// <summary>Mat から外部 buffer へコピーする。借用と検証の規則は ocvu_mat_copy_from_buffer と同じである。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_mat_copy_to_buffer(ulong src, byte[] dst, long dst_length, long dst_stride);

        /// <summary>ocvu_mat_copy_to_buffer にアドレスを直接渡す C# 側の入口。借用の契約は ocvu_mat_copy_from_buffer_ptr と同じである。</summary>
        [DllImport(LibraryName, EntryPoint = "ocvu_mat_copy_to_buffer", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_mat_copy_to_buffer_ptr(ulong src, System.IntPtr dst, long dst_length, long dst_stride);

    }
}
