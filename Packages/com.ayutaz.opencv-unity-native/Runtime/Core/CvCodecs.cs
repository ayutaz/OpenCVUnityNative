using System;
using System.Text;
using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>
    /// 符号化された画像 byte 列と <see cref="CvMat"/> の相互変換。
    ///
    /// **ファイルは扱わない。** ファイルを開くのは呼ぶ側の仕事で、ここが受けるのは
    /// メモリ上の byte 列だけである。Unity なら
    /// <c>System.IO.File.ReadAllBytes</c> や <c>UnityWebRequest</c>、Android の
    /// StreamingAssets（APK の中にあるのでパスで開けない）から得た byte 列を渡す。
    ///
    /// <see cref="CvOps"/> とは別のクラスにしてある —— あちらは imgproc に
    /// 範囲を限っている。
    /// </summary>
    public static class CvCodecs
    {
        /// <summary>そのまま読む（アルファも保つ）。</summary>
        public const int ImreadUnchanged = -1;

        /// <summary>1 チャンネルの灰色として読む。</summary>
        public const int ImreadGrayscale = 0;

        /// <summary>3 チャンネルの BGR として読む。</summary>
        public const int ImreadColor = 1;

        /// <summary>
        /// <paramref name="src"/> を <paramref name="ext"/> の形式に符号化する。
        /// </summary>
        /// <param name="src">符号化する画像。</param>
        /// <param name="ext">".png" のように先頭のドットを含む拡張子。</param>
        /// <returns>符号化された byte 列。長さは必要量ちょうど。</returns>
        public static byte[] Encode(CvMat src, string ext)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (ext == null) { throw new ArgumentNullException(nameof(ext)); }

            var extBytes = ToNulTerminatedUtf8(ext);

            // 1 回目はサイズの問い合わせ。**BufferTooSmall は失敗ではない。**
            // それ以外の status（無効な handle、扱えない拡張子）はここで投げる。
            int required;
            var probe = (CvStatus)NativeMethods.ocvu_imencode(
                src.Handle, extBytes, null, 0, out required);
            if (probe != CvStatus.BufferTooSmall)
            {
                CvNative.ThrowIfFailed(probe);
                // BufferTooSmall でも失敗でもない = 0 バイトの符号化。ありえないが、
                // 黙って空配列を返すと呼ぶ側が気づけないので明示的に断る。
                throw new CvNativeException(
                    CvStatus.UnknownError,
                    "ocvu_imencode reported success for a size query");
            }

            var blob = new byte[required];
            var status = (CvStatus)NativeMethods.ocvu_imencode(
                src.Handle, extBytes, blob, blob.Length, out var written);
            CvNative.ThrowIfFailed(status);

            // **BufferTooSmall は「失敗」ではないので ThrowIfFailed は素通しする。**
            // 2 回目でそれが返るのは、1 回目との間に src が変わって必要量が
            // 増えたときで、native は 1 バイトも書いていない（ocvu_imgcodecs.cpp
            // の「足りないときは何も書かない」）。ここで見ないと、**呼ぶ側は
            // 例外も無しに全部 0 の byte 列を受け取る** —— それをファイルに
            // 書けば「0 バイトではない壊れた画像」が残る。
            if (status != CvStatus.Ok || written != blob.Length)
            {
                throw new CvNativeException(status,
                    $"ocvu_imencode wrote {written} of {blob.Length} bytes " +
                    "(the source Mat likely changed between the size query and the write)");
            }
            return blob;
        }

        /// <summary>
        /// 符号化された byte 列を復号して <paramref name="dst"/> に入れる。
        /// dst の大きさと型は結果に応じて置き換わる。
        /// </summary>
        public static void Decode(byte[] data, int flags, CvMat dst)
        {
            if (data == null) { throw new ArgumentNullException(nameof(data)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }

            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_imdecode(
                data, data.LongLength, flags, dst.Handle));
        }

        /// <summary>
        /// 符号化された byte 列を復号して新しい <see cref="CvMat"/> を返す。
        /// </summary>
        public static CvMat Decode(byte[] data, int flags)
        {
            // 中身は decode が置き換えるので、最小の Mat を用意すれば足りる。
            var mat = CvMat.Create(1, 1, CvMatType.Gray8);
            try
            {
                Decode(data, flags, mat);
                return mat;
            }
            catch
            {
                mat.Dispose();
                throw;
            }
        }

        /// <summary>
        /// UTF-8 の NUL 終端 byte 列にする。marshaller の CharSet 既定に頼らない。
        /// </summary>
        private static byte[] ToNulTerminatedUtf8(string value)
        {
            var count = Encoding.UTF8.GetByteCount(value);
            var bytes = new byte[count + 1];
            Encoding.UTF8.GetBytes(value, 0, value.Length, bytes, 0);
            bytes[count] = 0;
            return bytes;
        }
    }
}
