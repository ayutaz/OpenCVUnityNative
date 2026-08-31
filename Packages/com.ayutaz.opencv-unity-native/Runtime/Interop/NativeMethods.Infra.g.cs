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

        /// <summary>直近のエラーメッセージを UTF-8・NUL 終端で buffer に書く。buffer に NULL を渡して必要サイズだけを聞くのが正規の 1 回目で、そのとき返る OCVU_STATUS_BUFFER_TOO_SMALL は失敗ではない。out_required_size が NULL なら OCVU_STATUS_NULL_POINTER。この関数自身は last-error を変更しない。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_last_error_message(byte[] buffer, int buffer_size, out int out_required_size);

        /// <summary>ネイティブ側が定義している status code の個数を返す。失敗しない。C# の CvStatus との同期を L3 で検証するために公開している。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_status_count();

        /// <summary>index 番目の status code の数値を out_value に書く。並び順は OCVU_STATUS_LIST の記述順。範囲外の index は OCVU_STATUS_INVALID_ARGUMENT、out_value が NULL なら OCVU_STATUS_NULL_POINTER。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_status_value(int index, out int out_value);

        /// <summary>リンクされている OpenCV のバージョン文字列（例 5.0.0）を UTF-8 で書く。バッファ規約は ocvu_get_last_error_message と同一である。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_opencv_version(byte[] buffer, int buffer_size, out int out_required_size);

        /// <summary>cv::getBuildInformation() の内容を UTF-8 で書く。どの依存が有効なリンクになっているかを実行時に確認するために使う。バッファ規約は ocvu_get_opencv_version と同一である。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_build_information(byte[] buffer, int buffer_size, out int out_required_size);

        /// <summary>conformance test 用に、内部で意図的に例外を投げる。kind は 0 が std::runtime_error、1 が std::bad_alloc、2 が非標準例外、3 が投げない。例外が ABI 境界を越えないことの検証に使う。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_debug_throw(int kind);

        /// <summary>conformance test 用に、意図的にプロセスを壊す。kind は 0 が不正アクセスで即死、1 が戻ってこない（無限ループ）。managed 側からネイティブが死んだときに L3 が有限時間で赤くなるかを確かめるためだけに存在し、通常の経路からは決して呼ばれない。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern void ocvu_debug_crash(int kind);

    }
}
