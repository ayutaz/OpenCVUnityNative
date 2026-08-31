using System.Runtime.InteropServices;

namespace CvUnity.Interop
{
    /// <summary>
    /// ocvu_mat_get_info の native 側 struct と同じ layout。
    /// 固定サイズ型のみで構成する（native/include/opencv_unity_native.h の
    /// ocvu_mat_info を参照）。
    /// </summary>
    /// <remarks>
    /// **この型は生成しない。** spec が持つのは関数の signature だけで、
    /// struct の layout は正本を native のヘッダ側に置いてある。
    /// </remarks>
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

    /// <summary>
    /// P/Invoke 宣言の置き場。
    /// </summary>
    /// <remarks>
    /// **宣言そのものをここに書かないこと。** 正本は bindings/spec/*.json で、
    /// ./tools/dev.ps1 generate が NativeMethods.（module 名）.g.cs へ
    /// 書き出す（partial class なので同じ型に入る）。手で足しても
    /// 次の generate で spec と食い違い、dev.ps1 verify-generated が赤くする。
    ///
    /// このファイルに残すのは、生成物が参照する LibraryName と、
    /// spec が表現しない型（OcvuMatInfo）だけである。
    /// </remarks>
    internal static partial class NativeMethods
    {
#if UNITY_IOS && !UNITY_EDITOR
        internal const string LibraryName = "__Internal";
#else
        internal const string LibraryName = "opencv_unity_native";
#endif
    }
}
