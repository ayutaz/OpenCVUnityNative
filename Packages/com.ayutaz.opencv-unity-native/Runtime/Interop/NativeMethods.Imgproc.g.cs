// このファイルは生成物である。手で編集しないこと。
// 正本: bindings/spec/imgproc.json
// 生成: ./tools/dev.ps1 generate

using System.Runtime.InteropServices;

namespace CvUnity.Interop
{
    internal static partial class NativeMethods
    {
        /// <summary>色空間を変換する。dst の形状と型は結果に応じて上書きされる。src と dst が同じ handle なら OCVU_STATUS_INVALID_ARGUMENT を返す（OpenCV の in-place 対応は関数ごとに異なり、曖昧さを ABI に持ち込まない）。OpenCV 由来の失敗は OCVU_STATUS_OPENCV_ERROR になる。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_cvt_color(ulong src, ulong dst, int code);

        /// <summary>width x height に拡大縮小する。width / height が 1 未満なら OCVU_STATUS_INVALID_ARGUMENT。src と dst に同じ handle を渡した場合も同様に拒否する。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_resize(ulong src, ulong dst, int width, int height, int interpolation);

        /// <summary>Gaussian ぼかしを掛ける。ksize は正の奇数でなければならず、そうでなければ OCVU_STATUS_INVALID_ARGUMENT。sigma に 0 を渡すと OpenCV が ksize から算出する。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_gaussian_blur(ulong src, ulong dst, int ksize_width, int ksize_height, double sigma_x, double sigma_y);

        /// <summary>src の歪みを camera_matrix と dist_coeffs で補正して dst に入れる。dst は結果に応じて丸ごと置き換わり、src と同じ形状・型になる。camera_matrix は行優先の 3x3（double 9 個）、dist_coeffs は OpenCV が受ける長さ（4 / 5 / 8 / 12 / 14 個）でなければならない。camera_matrix_length と dist_coeffs_length はどちらもバイト数で、この ABI の length は全部そうである。呼ぶ側を信用せず、長さが合わなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。失敗したときは dst を書き換えない。src と dst に同じ handle を渡してもよい（結果を求めてから入れ替えるので、cvtColor と違い in-place 呼び出しを禁じていない）。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_undistort(ulong src, double[] camera_matrix, long camera_matrix_length, double[] dist_coeffs, long dist_coeffs_length, ulong dst);

    }
}
