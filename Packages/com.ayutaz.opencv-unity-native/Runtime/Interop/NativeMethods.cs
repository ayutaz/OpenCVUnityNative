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
    /// 特徴点 1 つ。native の ocvu_keypoint と layout を合わせる。
    /// </summary>
    /// <remarks>
    /// struct の layout は正本を native のヘッダ側に置いてある。
    /// 大きさが食い違うと marshalling だけが壊れるので、
    /// L3 の FeaturesTests が Marshal.SizeOf で突き合わせる。
    /// </remarks>
    [StructLayout(LayoutKind.Sequential)]
    internal struct OcvuKeyPoint
    {
        internal float X;
        internal float Y;
        internal float Size;
        internal float Angle;
        internal float Response;
        internal int Octave;
        internal int ClassId;
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
    /// spec が表現しない型（OcvuMatInfo、OcvuKeyPoint）だけである。
    /// </remarks>
    internal static partial class NativeMethods
    {
        // **静的リンクする platform は "__Internal" である。**
        //
        // 共有ライブラリを読み込めない（iOS）か、そもそも共有ライブラリという
        // 仕組みが無い（Web / Wasm）platform では、plugin は Player の binary へ
        // 静的にリンクされる。**その場合 DllImport の名前は "__Internal" になる。**
        //
        // **UNITY_WEBGL が抜けていた**（2026-09-03 に実測）—— Web Player の中で
        // 最初の P/Invoke が
        //
        //     Uncaught exception from main loop: undefined / Halting program.
        //
        // になった。**ビルドもリンクも通り、Player も起動する** ——
        // 壊れるのは実際に呼んだ瞬間だけで、**ブラウザで動かすまで
        // 誰も気づかない。**
#if (UNITY_IOS || UNITY_WEBGL) && !UNITY_EDITOR
        internal const string LibraryName = "__Internal";
#else
        internal const string LibraryName = "opencv_unity_native";
#endif
    }
}
