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

    }
}
