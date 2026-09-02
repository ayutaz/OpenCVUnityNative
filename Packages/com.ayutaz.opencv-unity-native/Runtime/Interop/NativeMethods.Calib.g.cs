// このファイルは生成物である。手で編集しないこと。
// 正本: bindings/spec/calib.json
// 生成: ./tools/dev.ps1 generate

using System.Runtime.InteropServices;

namespace CvUnity.Interop
{
    internal static partial class NativeMethods
    {
        /// <summary>複数の view から撮った既知の立体パターン（通常はチェスボード）の対応点から、カメラの内部パラメータと歪み係数、および各 view の姿勢を求める。object_points は 1 点 3 float（x, y, z）、image_points は 1 点 2 float（x, y）で、**どちらも view-major に並べる**（1 枚目の全点、続いて 2 枚目の全点、…）。object_points_length と image_points_length はその配列の**バイト数**である（要素数でも点数でもない —— この ABI の length はすべてバイト数で統一してある）。**呼ぶ側を信用せず、長さが必要量に満たなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。** view_count は 2 以上、points_per_view は 4 以上でなければならず、その積が OCVU_CALIB_MAX_POINTS を超える場合も OCVU_STATUS_INVALID_ARGUMENT を返す（int32 の乗算オーバーフローを避けるための歯止めであり、実用上の校正がこれを超えることは無い）。image_width と image_height はどちらも 1 以上でなければならない。出力の capacity は 3 つとも**配列の要素数**である（バイト数ではない）—— out_camera_matrix は 9 以上（3x3 を行優先で書く）、out_view_poses は view_count * 6 以上（**1 view につき 6 個で、回転ベクトル 3 個のあとに並進ベクトル 3 個が続く**）、out_dist_coeffs は OpenCV が返す係数の個数以上が要る。どれか 1 つでも足りなければ**何も書かずに** OCVU_STATUS_BUFFER_TOO_SMALL を返す。**歪み係数の個数だけは呼ぶ側が事前に知り得ない**（OpenCV が入力を見て 4 / 5 / 8 / 12 / 14 のどれかを選ぶ）ので、dist_coeffs_capacity が足りなかった場合に限り out_dist_coeffs_count に**必要な個数**を入れる —— ocvu_find_chessboard_corners や ocvu_imencode と同じ 2 回呼びの作法である。成功したときは書いた歪み係数の個数を out_dist_coeffs_count に、再投影誤差（RMS、画素）を out_rms に入れる。**それ以外のすべての失敗経路では out_dist_coeffs_count に 0 を書く。** OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、その理由は last-error のメッセージに入る（点が退化している、view ごとの対応が取れていない、などが該当する）。 out_camera_matrix / out_dist_coeffs / out_view_poses / out_rms の所有権は最初から最後まで呼ぶ側にある。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_calibrate_camera(float[] object_points, long object_points_length, float[] image_points, long image_points_length, int view_count, int points_per_view, int image_width, int image_height, double[] out_camera_matrix, int camera_matrix_capacity, double[] out_dist_coeffs, int dist_coeffs_capacity, out int out_dist_coeffs_count, double[] out_view_poses, int view_poses_capacity, out double out_rms);

    }
}
