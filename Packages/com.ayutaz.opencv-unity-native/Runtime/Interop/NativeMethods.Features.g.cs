// このファイルは生成物である。手で編集しないこと。
// 正本: bindings/spec/features.json
// 生成: ./tools/dev.ps1 generate

using System.Runtime.InteropServices;

namespace CvUnity.Interop
{
    internal static partial class NativeMethods
    {
        /// <summary>src から ORB の特徴点を検出して out_keypoints へ書き、見つかった個数を out_count に返す。呼ぶ側は必要量を事前に知り得るので 2 回呼ぶ必要は無い（上限は max_features で、capacity がそれに満たなければ何も書かずに OCVU_STATUS_BUFFER_TOO_SMALL を返し out_count に max_features を入れる）。max_features は 1 以上 OCVU_ORB_MAX_FEATURES 以下でなければならない。buffer の所有権は最初から最後まで呼ぶ側にある。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_orb_detect(ulong src, int max_features, OcvuKeyPoint[] out_keypoints, int capacity, out int out_count);

    }
}
