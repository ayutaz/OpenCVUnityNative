// このファイルは生成物である。手で編集しないこと。
// 正本: bindings/spec/dnn.json
// 生成: ./tools/dev.ps1 generate

using System.Runtime.InteropServices;

namespace CvUnity.Interop.Dnn
{
    internal static partial class NativeMethodsDnn
    {
#if (UNITY_IOS || UNITY_WEBGL) && !UNITY_EDITOR
        internal const string LibraryName = "__Internal";
#else
        internal const string LibraryName = "opencv_unity_native";
#endif

        /// <summary>メモリ上の ONNX の byte 列からネットワークを読み、handle を out_handle に書く。ファイルパスは受け取らない（Windows の文字コードと Android の StreamingAssets のため）。読めなければ OCVU_STATUS_OPENCV_ERROR を返し out_handle は変更しない。data が NULL、out_handle が NULL なら OCVU_STATUS_NULL_POINTER。length が 1 未満なら OCVU_STATUS_INVALID_ARGUMENT。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_dnn_net_read_onnx(byte[] data, int length, out ulong out_handle);

        /// <summary>ocvu_dnn_net_read_onnx が返した handle を解放する。native が所有する（docs/abi-ownership-and-versioning.md §1.7）ので、使い終わったら必ずこれで解放する。net が 0、解放済み、未知の handle のいずれでも OCVU_STATUS_INVALID_HANDLE を返し、落とさない（二重解放を検出する）。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_dnn_net_release(ulong net);

        /// <summary>src を推論の入力形式（4 次元の blob。N=1, C, height, width）に変換して dst に書く。scale は画素値に掛ける係数（例: 1/255.0）。width と height は 1 以上 OCVU_DNN_MAX_BLOB_DIM 以下でなければならず（cv::dnn::blobFromImage がその寸法でメモリを確保するため）、外れれば OCVU_STATUS_INVALID_ARGUMENT を返す。mean は NULL を許さず、常に 3 要素（B, G, R の順）を読んで各チャンネルから引く固定契約で、NULL なら OCVU_STATUS_NULL_POINTER。swap_rb は 0 以外で R と B を入れ替え、crop は 0 以外でアスペクト比を保ったまま中央をトリミングする。src または dst の handle が無効なら OCVU_STATUS_INVALID_HANDLE。dst が受け取る Mat は 4 次元のまま保持される（ocvu_mat_get_info のような 2 次元前提の関数へは渡さないこと）—— 2 次元へ潰すのは ocvu_dnn_net_forward の出力側だけである。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、失敗したときは dst を書き換えない。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_dnn_blob_from_image(ulong src, ulong dst, double scale, int width, int height, double[] mean, int swap_rb, int crop);

        /// <summary>net に input（ocvu_dnn_blob_from_image が作った blob）を渡して推論を 1 回走らせ、結果を output に書く。出力は 2 次元の Mat に潰される（rows × cols）。4 次元の blob を返すモデル（検出など）では、N と C の区別が失われる。分類モデルの 1 × N の出力を受け取ることを想定している。net / input / output のいずれかの handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合、または結果が空になった場合は OCVU_STATUS_OPENCV_ERROR を返し、失敗したときは output を書き換えない。engine / backend を選ぶ引数は無い（上流の 5.1 で enum EngineType の値が総入れ替えになったため、5.1 で意味が変わる数字を境界の外へ出さない）。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_dnn_net_forward(ulong net, ulong input, ulong output);

    }
}
