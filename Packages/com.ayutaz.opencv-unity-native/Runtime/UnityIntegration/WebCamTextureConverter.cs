using System;
using System.Runtime.InteropServices;
using UnityEngine;

namespace CvUnity.Unity
{
    /// <summary>
    /// WebCamTexture から CvMat を作る。
    ///
    /// **カメラを開くのは呼ぶ側の仕事である。** このプロジェクトはカメラ入力を
    /// 独自に実装しない（roadmap の M4 非ゴール）—— 権限の要求も、解像度の
    /// 選択も、Play/Stop も Unity の API でやってもらう。ここが引き受けるのは
    /// 「Unity が持っている画素を OpenCV が読める形にする」ところだけである。
    ///
    /// **なぜ Texture2D 経由にしないか。** WebCamTexture は Texture2D ではない
    /// ので GetRawTextureData を持たない。Texture2D に一度写すと GPU から CPU への
    /// 読み戻しが 2 回になる。GetPixels32 は 1 回で済む。
    /// </summary>
    public static class WebCamTextureConverter
    {
        /// <summary>
        /// 現在のフレームを新しい CvMat に写す。
        ///
        /// **毎フレーム呼ぶなら <see cref="ToMat(WebCamTexture, ref Color32[])"/> を
        /// 使うこと。** こちらは呼ぶたびに幅 x 高さ分の Color32[] を確保する
        /// （640x480 で 1 フレームあたり約 1.2 MB）。
        /// </summary>
        public static CvMat ToMat(WebCamTexture texture)
        {
            if (texture == null) { throw new ArgumentNullException(nameof(texture)); }
            Color32[] buffer = null;
            return ToMat(texture, ref buffer);
        }

        /// <summary>
        /// 現在のフレームを新しい CvMat に写し、画素の受け皿を使い回す。
        ///
        /// <paramref name="buffer"/> が null か大きさ違いのときだけ確保し直す。
        /// **毎フレームの経路はこちらを使う**（CLAUDE.md「毎フレームの細かな
        /// 境界呼び出しを避ける」）。
        /// </summary>
        public static CvMat ToMat(WebCamTexture texture, ref Color32[] buffer)
        {
            if (texture == null) { throw new ArgumentNullException(nameof(texture)); }

            // **最初のフレームが来る前を弾く。**
            //
            // Play() の直後、WebCamTexture は width/height に 16 などの既定値を
            // 返し、画素はまだ無い。そのまま進むと「サイズは通るのに中身が
            // 黒い Mat」ができて、原因が分からなくなる。
            if (!texture.isPlaying)
            {
                throw new InvalidOperationException(
                    "WebCamTexture is not playing. Call Play() and wait for the first frame " +
                    "(check didUpdateThisFrame) before converting.");
            }

            var width = texture.width;
            var height = texture.height;
            var needed = width * height;

            if (buffer == null || buffer.Length != needed)
            {
                buffer = new Color32[needed];
            }
            texture.GetPixels32(buffer);

            return ToMat(buffer, width, height);
        }

        /// <summary>
        /// Color32 の並びを CvMat に写す。**行の順序を入れ替える。**
        ///
        /// Unity のテクスチャは**左下が原点**、OpenCV の Mat は**左上が原点**で
        /// ある。そのまま写すと上下が反転した Mat ができ、しかも
        /// **エラーにはならない** —— cvtColor も resize も問題なく動くので、
        /// 画面に出して初めて気づく。ここで入れ替えておく。
        ///
        /// この overload を公開しているのは、テストが実カメラ無しで変換を
        /// 検査できるようにするためでもある。EditMode でカメラを開くと、権限の
        /// 無い環境やカメラの無い CI で必ず落ちる —— 「環境が理由で赤い」は
        /// 「コードが理由で赤い」と区別できないので、レーンとして成立しない。
        /// </summary>
        public static CvMat ToMat(Color32[] pixels, int width, int height)
        {
            if (pixels == null) { throw new ArgumentNullException(nameof(pixels)); }
            if (width <= 0 || height <= 0)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(width),
                    $"width and height must be positive; got {width}x{height}. " +
                    "A WebCamTexture reports its real size only after the first frame.");
            }

            var expected = (long)width * height;
            if (pixels.Length != expected)
            {
                throw new ArgumentException(
                    $"pixel count mismatch: got {pixels.Length}, {width}x{height} needs {expected}",
                    nameof(pixels));
            }

            // Color32 は R,G,B,A の順に 1 バイトずつ並ぶ。CvMatType.Bgra32 は
            // 「4 チャネル 8 ビット」という形だけを指し、チャネルの意味づけは
            // 持たない（OpenCV の Mat 自体がそうである）。並べ替えが要るなら
            // cvtColor を通すのが呼ぶ側の仕事である。
            var stride = width * 4;
            var flipped = new byte[stride * height];

            var handle = GCHandle.Alloc(pixels, GCHandleType.Pinned);
            try
            {
                var src = handle.AddrOfPinnedObject();
                for (var row = 0; row < height; row++)
                {
                    // Unity の最終行が Mat の先頭行になる。
                    var srcRow = height - 1 - row;
                    Marshal.Copy(IntPtr.Add(src, srcRow * stride), flipped, row * stride, stride);
                }
            }
            finally
            {
                handle.Free();
            }

            var mat = CvMat.Create(height, width, CvMatType.Bgra32);
            try
            {
                mat.CopyFrom(flipped, stride);
                return mat;
            }
            catch
            {
                mat.Dispose();
                throw;
            }
        }
    }
}
