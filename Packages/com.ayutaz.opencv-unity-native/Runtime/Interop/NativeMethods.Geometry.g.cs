// このファイルは生成物である。手で編集しないこと。
// 正本: bindings/spec/geometry.json
// 生成: ./tools/dev.ps1 generate

using System.Runtime.InteropServices;

namespace CvUnity.Interop
{
    internal static partial class NativeMethods
    {
        /// <summary>2 組の点の対応から射影変換（3x3）を求めて dst に入れる。dst は結果に応じて丸ごと置き換わり、64 bit 1 channel の 3x3 になる。src_points と dst_points はどちらも x と y が交互に並ぶ float の配列で、src_length と dst_length はその配列の**バイト数**である（要素数でも点数でもない —— この ABI の length はすべてバイト数で統一してある）。**呼ぶ側を信用せず、長さが point_count * 2 * sizeof(float) に満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。** point_count は 4 以上でなければならない（4 点未満では射影変換が決まらない）。method は OCVU_HOMOGRAPHY_METHOD_* のいずれかで、それ以外は拒否する。ransac_threshold は RANSAC のときだけ使う画素単位のしきい値である。点が退化していて解が求まらないときは OCVU_STATUS_NOT_FOUND を返し、これは誤りではない（どの入力がそうなるかは OpenCV が決める。実測では全部同じ点と軸に平行な直線が NOT_FOUND で、斜めの直線は rank 不足の行列がそのまま返り OCVU_STATUS_OK になる —— 共線判定はしていない）。失敗したときは dst を書き換えない。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_find_homography(float[] src_points, long src_length, float[] dst_points, long dst_length, int point_count, int method, double ransac_threshold, ulong dst);

    }
}
