// このファイルは生成物である。手で編集しないこと。
// 正本: bindings/spec/infra.json
// 生成: ./tools/dev.ps1 generate

using System.Runtime.InteropServices;

namespace CvUnity.Interop
{
    internal static partial class NativeMethods
    {
        /// <summary>現在の C ABI バージョンを返す。失敗しない。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_abi_version();

        /// <summary>直近のエラー status を返す。呼び出しスレッドごとに独立している。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_last_error_status();

        /// <summary>status 表の件数を返す。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_status_count();

    }
}
