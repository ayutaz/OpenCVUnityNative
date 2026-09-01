using System;
using System.Text;
using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>
    /// QR コードの符号化と復号(OpenCV の objdetect)。
    /// </summary>
    /// <remarks>
    /// **CvOps に入れていない。** あちらは imgproc の範囲である。
    /// クラスを分けてあるので、この plugin がどの OpenCV モジュールを
    /// リンクしているかが C# 側から読み取れる。
    /// </remarks>
    public static class CvQrCode
    {
        /// <summary>
        /// text を QR コードの画像に符号化して <paramref name="dst"/> に入れる。
        /// <paramref name="dst"/> は結果に応じて丸ごと置き換わり、8 bit 1 channel の
        /// 正方形になる —— 呼び出し前に <paramref name="dst"/> が持っていた形状・型・
        /// 内容は保持されない。
        /// </summary>
        public static void Encode(string text, CvMat dst)
        {
            if (text == null) throw new ArgumentNullException(nameof(text));
            if (text.Length == 0)
                throw new ArgumentException("text は空にできません。", nameof(text));
            if (dst == null) throw new ArgumentNullException(nameof(dst));

            // **文字列は自分で UTF-8 の NUL 終端 byte 列にする。**
            // string のまま marshaller に任せると、境界の文字コード変換が
            // 既定の CharSet に依存する(Mono と IL2CPP で違い得る)。
            var status = (CvStatus)NativeMethods.ocvu_qr_encode(
                ToNulTerminatedUtf8(text), dst.Handle);
            CvNative.ThrowIfFailed(status);
        }

        /// <summary>
        /// <paramref name="src"/> に写っている QR コードを 1 つ復号する。
        /// 写っていなければ null を返す。
        /// </summary>
        /// <remarks>
        /// 検出の前に白い余白(quiet zone)を必ず足し、短いほうの辺が 200 px 未満の
        /// 画像はさらに最近傍補間で拡大してから検出する。**この前処理は内部で作る
        /// 加工済みのコピーに対して行われ、<paramref name="src"/> 自体は変更しない。**
        /// </remarks>
        public static string Decode(CvMat src)
        {
            if (src == null) throw new ArgumentNullException(nameof(src));

            // 1 回目: 必要な大きさを問い合わせる。
            var probe = (CvStatus)NativeMethods.ocvu_qr_decode(
                src.Handle, null, 0, out int required);

            // **写っていないのは失敗ではない。** 呼ぶ側には null で返す。
            if (probe == CvStatus.NotFound) { return null; }

            // **BufferTooSmall だけを通す。** それ以外はここで投げる ——
            // 無効な handle も空の画像もこの段で判明するので、
            // null を返して呼ぶ側に気づかせない形にしない。
            if (probe != CvStatus.BufferTooSmall)
            {
                CvNative.ThrowIfFailed(probe);
                // 失敗でも BufferTooSmall でもない = 長さ 0 の復号。
                // ありえないが、黙って空文字列を返すと呼ぶ側が気づけない。
                throw new CvNativeException(
                    CvStatus.UnknownError,
                    "ocvu_qr_decode reported success for a size query");
            }

            var buffer = new byte[required];
            var status = (CvStatus)NativeMethods.ocvu_qr_decode(
                src.Handle, buffer, required, out var written);
            CvNative.ThrowIfFailed(status);

            // 2 回目で足りなくなるのは、1 回目との間に src が変わった場合である。
            // native は 1 バイトも書いていないので、ここで見ないと
            // **呼ぶ側は例外も無しに全部 0 の byte 列を受け取る**(CvCodecs と同じ形)。
            if (status != CvStatus.Ok || written != required)
            {
                throw new CvNativeException(status,
                    $"ocvu_qr_decode wrote {written} of {required} bytes " +
                    "(the source Mat likely changed between the size query and the read)");
            }

            // 末尾の NUL を落とす。
            return Encoding.UTF8.GetString(buffer, 0, required - 1);
        }

        private static byte[] ToNulTerminatedUtf8(string value)
        {
            int count = Encoding.UTF8.GetByteCount(value);
            var bytes = new byte[count + 1];
            Encoding.UTF8.GetBytes(value, 0, value.Length, bytes, 0);
            bytes[count] = 0;
            return bytes;
        }
    }
}
