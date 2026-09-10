using System;
using CvUnity.Interop.Dnn;

namespace CvUnity.Dnn
{
    /// <summary>
    /// native が所有する dnn ネットワークへの handle を包む。
    ///
    /// 寿命の契約は <see cref="CvMat"/> と同じである
    /// （docs/abi-ownership-and-versioning.md §1.7）——
    /// handle は常に native 側が持ち、二重の <see cref="Dispose"/> は
    /// 落ちない（<c>ocvu_dnn_net_release</c> が <c>OCVU_STATUS_INVALID_HANDLE</c>
    /// を返すだけで、C# 側はそれを見ない）。
    /// </summary>
    public sealed class CvNet : IDisposable
    {
        private ulong _handle;

        private CvNet(ulong handle) { _handle = handle; }

        internal static CvNet FromHandle(ulong handle) => new CvNet(handle);

        internal ulong Handle
        {
            get
            {
                ThrowIfDisposed();
                return _handle;
            }
        }

        public void Dispose()
        {
            if (_handle == 0) { return; }
            NativeMethodsDnn.ocvu_dnn_net_release(_handle);
            _handle = 0;
        }

        private void ThrowIfDisposed()
        {
            if (_handle == 0) { throw new ObjectDisposedException(nameof(CvNet)); }
        }
    }

    /// <summary>
    /// OpenCV の dnn モジュールへの入口（ONNX の読み込み、推論の入力の前処理、
    /// 推論の実行）。
    /// </summary>
    /// <remarks>
    /// **opt-in profile である。** <c>OCVU_PROFILE_DNN</c> を立てたプロジェクトだけが
    /// この assembly（<c>CvUnity.Dnn</c>）をコンパイルする。この define が無いと
    /// <c>CvUnity.Interop.Dnn</c> も存在しないので、参照を持つこの assembly も
    /// 一緒に消える必要がある —— そのため同じ <c>defineConstraints</c> を
    /// <c>CvUnity.Dnn.asmdef</c> にも置いてある（docs/abi-ownership-and-versioning.md §4）。
    /// <para>
    /// **有効な ONNX を読み込んで実際に推論する経路は、この commit ではまだ
    /// 実証していない。** ここで確かめているのは壊れた入力・寿命・所有権で、
    /// 実物の小さなモデルを使った正常系は別のタスクが L3 に足す。
    /// </para>
    /// </remarks>
    public static class CvDnn
    {
        /// <summary>mean の要素数。B, G, R の 3 個で固定である。</summary>
        private const int MeanLength = 3;

        /// <summary>
        /// メモリ上の ONNX の byte 列からネットワークを読む。
        /// </summary>
        /// <remarks>
        /// **ファイルパスは受け取らない**（Windows の文字コードと Android の
        /// StreamingAssets のため。<see cref="CvCodecs"/> と同じ理由）。
        /// </remarks>
        /// <param name="data">ONNX モデルの byte 列。</param>
        /// <exception cref="ArgumentNullException"><paramref name="data"/> が null。</exception>
        /// <exception cref="ArgumentException"><paramref name="data"/> が空。</exception>
        /// <exception cref="CvNativeException">読めない byte 列だった。</exception>
        public static CvNet ReadOnnx(byte[] data)
        {
            if (data == null) { throw new ArgumentNullException(nameof(data)); }
            if (data.Length == 0)
            {
                throw new ArgumentException("ONNX の byte 列は空であってはなりません。", nameof(data));
            }

            var status = (CvStatus)NativeMethodsDnn.ocvu_dnn_net_read_onnx(
                data, data.Length, out ulong handle);
            CvNative.ThrowIfFailed(status);
            return CvNet.FromHandle(handle);
        }

        /// <summary>
        /// <paramref name="src"/> を推論の入力形式（4 次元の blob。N=1, C, height, width）に
        /// 変換して <paramref name="dst"/> に書く。
        /// </summary>
        /// <remarks>
        /// <paramref name="dst"/> が受け取る Mat は 4 次元のまま保持される ——
        /// <see cref="CvMat.Rows"/> のような 2 次元前提のメンバはこの handle を
        /// 例外で拒む。2 次元へ潰すのは <see cref="Forward"/> の出力側だけである。
        /// </remarks>
        /// <param name="src">変換する画像。</param>
        /// <param name="dst">blob を受け取る Mat。呼び出し前の内容は保持されない。</param>
        /// <param name="scale">画素値に掛ける係数（例: 1/255.0）。</param>
        /// <param name="width">出力の幅（画素）。1 以上、native の上限以下。</param>
        /// <param name="height">出力の高さ（画素）。1 以上、native の上限以下。</param>
        /// <param name="mean">
        /// 各チャンネルから引く値。**B, G, R の順で 3 要素**でなければならない。
        /// native は 3 個の scalar として受け取る固定契約であり、配列ではないので
        /// 長さを取り違えて境界の外を読む余地が無い —— この <paramref name="mean"/>
        /// はその契約を C# 側で表すための配列で、渡す前に長さを検証する。
        /// </param>
        /// <param name="swapRb">true なら R と B を入れ替える。</param>
        /// <param name="crop">true ならアスペクト比を保ったまま中央をトリミングする。</param>
        public static void BlobFromImage(
            CvMat src, CvMat dst, double scale, int width, int height,
            double[] mean, bool swapRb, bool crop)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }
            if (mean == null) { throw new ArgumentNullException(nameof(mean)); }
            if (mean.Length != MeanLength)
            {
                throw new ArgumentException(
                    $"mean は B, G, R の {MeanLength} 要素でなければなりません" +
                    $"（渡されたのは {mean.Length} 要素）。",
                    nameof(mean));
            }

            var status = (CvStatus)NativeMethodsDnn.ocvu_dnn_blob_from_image(
                src.Handle, dst.Handle, scale, width, height,
                mean[0], mean[1], mean[2],
                swapRb ? 1 : 0, crop ? 1 : 0);
            CvNative.ThrowIfFailed(status);
        }

        /// <summary>
        /// <paramref name="net"/> に <paramref name="input"/>（<see cref="BlobFromImage"/> が
        /// 作った blob）を渡して推論を 1 回走らせ、結果を <paramref name="output"/> に書く。
        /// </summary>
        /// <remarks>
        /// 出力は 2 次元の Mat に潰される（rows × cols）。<paramref name="output"/> は
        /// net の内部バッファから独立した新しいメモリのコピーであり、同じ
        /// <paramref name="net"/> で続けて呼んでも書き換わらない。
        /// </remarks>
        /// <param name="net"><see cref="ReadOnnx"/> が返したネットワーク。</param>
        /// <param name="input"><see cref="BlobFromImage"/> が作った 4 次元の blob。</param>
        /// <param name="output">結果（2 次元）を受け取る Mat。</param>
        public static void Forward(CvNet net, CvMat input, CvMat output)
        {
            if (net == null) { throw new ArgumentNullException(nameof(net)); }
            if (input == null) { throw new ArgumentNullException(nameof(input)); }
            if (output == null) { throw new ArgumentNullException(nameof(output)); }

            var status = (CvStatus)NativeMethodsDnn.ocvu_dnn_net_forward(
                net.Handle, input.Handle, output.Handle);
            CvNative.ThrowIfFailed(status);
        }
    }
}
