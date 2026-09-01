// このファイルは生成物である。手で編集しないこと。
// 正本: bindings/spec/geometry.json
// 生成: ./tools/dev.ps1 generate

using System.Runtime.InteropServices;

namespace CvUnity.Interop
{
    internal static partial class NativeMethods
    {
        /// <summary>2 組の点の対応から射影変換（3x3）を求めて dst に入れる。dst は結果に応じて丸ごと置き換わり、64 bit 1 channel の 3x3 になる。src_points と dst_points はどちらも x と y が交互に並ぶ float の配列で、長さは point_count の 2 倍でなければならない。point_count は 4 以上（4 点未満では射影変換が決まらない）。method は OCVU_HOMOGRAPHY_METHOD_* のいずれかで、それ以外は拒否する。ransac_threshold は RANSAC のときだけ使う画素単位のしきい値である。点が退化していて解が求まらないときは OCVU_STATUS_NOT_FOUND を返し、これは誤りではない。失敗したときは dst を書き換えない。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_find_homography(float[] src_points, float[] dst_points, int point_count, int method, double ransac_threshold, ulong dst);

    }
}
