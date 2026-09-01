// このファイルは生成物である。手で編集しないこと。
// 正本: bindings/spec/*.json
// 生成: ./tools/dev.ps1 generate
//
// **なぜ在るか。** IL2CPP の stripping は、呼ばれない P/Invoke 宣言を
// 消せる。M4 の点検では、手書きの 19 本のうち 7 本が Editor でも
// Player でも一度も呼ばれていなかった。**呼ばれない宣言は、消えても
// 誰も気づかない。** ここは spec が載せる宣言を 1 つ残らず 1 回ずつ
// 呼ぶ。結果は見ない —— 呼べたことだけを見る。
//
// 呼ばないのは spec が reachable: false と書いた関数だけで、
// 理由は spec の reachableNote にある（印だけ付けて理由が
// 無い spec は SpecModel が拒む）。

using CvUnity.Interop;

public static class AbiReachabilityChecks
{
    /// <summary>
    /// 呼んだ宣言の本数を返す。C の entry point 1 本に対して C# の宣言が
    /// 2 つある場合（byte[] 版とポインタ版）は 2 本と数える —— 消えるのは
    /// entry point ではなく宣言のほうだからである。
    /// </summary>
    public static int CallEveryEntryPoint()
    {
        NativeMethods.ocvu_mat_create(0, 0, 0, out _);
        NativeMethods.ocvu_mat_release(0UL);
        NativeMethods.ocvu_mat_clone(0UL, out _);
        NativeMethods.ocvu_mat_get_info(0UL, out _);
        NativeMethods.ocvu_mat_copy_from_buffer(0UL, null, 0L, 0L);
        NativeMethods.ocvu_mat_copy_from_buffer_ptr(0UL, default, 0L, 0L);
        NativeMethods.ocvu_mat_copy_to_buffer(0UL, null, 0L, 0L);
        NativeMethods.ocvu_mat_copy_to_buffer_ptr(0UL, default, 0L, 0L);
        NativeMethods.ocvu_orb_detect(0UL, 0, default, 0, out _);
        NativeMethods.ocvu_find_homography(default, 0L, default, 0L, 0, 0, 0.0, 0UL);
        NativeMethods.ocvu_imencode(0UL, null, null, 0, out _);
        NativeMethods.ocvu_imdecode(null, 0L, 0, 0UL);
        NativeMethods.ocvu_cvt_color(0UL, 0UL, 0);
        NativeMethods.ocvu_resize(0UL, 0UL, 0, 0, 0);
        NativeMethods.ocvu_gaussian_blur(0UL, 0UL, 0, 0, 0.0, 0.0);
        NativeMethods.ocvu_undistort(0UL, default, 0L, default, 0L, 0UL);
        NativeMethods.ocvu_get_abi_version();
        NativeMethods.ocvu_get_last_error_status();
        NativeMethods.ocvu_get_last_error_message(null, 0, out _);
        NativeMethods.ocvu_get_status_count();
        NativeMethods.ocvu_get_status_value(0, out _);
        NativeMethods.ocvu_get_opencv_version(null, 0, out _);
        NativeMethods.ocvu_get_build_information(null, 0, out _);
        NativeMethods.ocvu_debug_throw(0);
        NativeMethods.ocvu_qr_encode(null, 0UL);
        NativeMethods.ocvu_qr_decode(0UL, null, 0, out _);
        NativeMethods.ocvu_find_chessboard_corners(0UL, 0, 0, default, 0, out _);
        return 27;
    }
}
