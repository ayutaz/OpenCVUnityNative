using System;
using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>
    /// 画像上の点。x と y だけを持つ読み取り専用の値。
    /// </summary>
    /// <remarks>
    /// UnityEngine の Vector2 を使わないのは、<c>Runtime/Core</c> が
    /// UnityEngine を参照してはならないためである（参照した瞬間に
    /// netstandard2.1 shim のビルドが落ち、Unity を起動しない L3 レーンが失われる）。
    /// Unity 側で Vector2 から詰め替えるのは呼ぶ側の仕事にする。
    /// </remarks>
    public readonly struct CvPoint2
    {
        /// <summary>横方向の位置（画素）。</summary>
        public float X { get; }

        /// <summary>縦方向の位置（画素）。</summary>
        public float Y { get; }

        /// <summary>x と y から点を作る。</summary>
        public CvPoint2(float x, float y)
        {
            X = x;
            Y = y;
        }
    }

    /// <summary>
    /// 空間中の点。x と y と z を持つ読み取り専用の値。
    /// </summary>
    /// <remarks>
    /// UnityEngine の Vector3 を使わないのは、<c>Runtime/Core</c> が
    /// UnityEngine を参照してはならないためである（<see cref="CvPoint2"/> と同じ理由）。
    /// 校正パターンの 3D 座標を渡すのに使う。
    /// </remarks>
    public readonly struct CvPoint3
    {
        /// <summary>横方向の位置。</summary>
        public float X { get; }

        /// <summary>縦方向の位置。</summary>
        public float Y { get; }

        /// <summary>奥行き方向の位置。</summary>
        public float Z { get; }

        /// <summary>x と y と z から点を作る。</summary>
        public CvPoint3(float x, float y, float z)
        {
            X = x;
            Y = y;
            Z = z;
        }
    }

    /// <summary>
    /// 射影変換の求め方。
    /// </summary>
    /// <remarks>
    /// 値は C の <c>OCVU_HOMOGRAPHY_METHOD_*</c> の写しである。C# から C の
    /// <c>#define</c> は読めないので複製しており、<c>GeometryTests</c> の
    /// <c>TheManagedMethodValuesMatchWhatNativeAccepts</c> が両側を native に
    /// 問うことで同期を守っている。
    /// </remarks>
    public enum CvHomographyMethod
    {
        /// <summary>
        /// 全部の点を使う最小二乗。**外れ値があると引きずられる。**
        /// 対応が確実なとき（QR の 4 隅など）に使う。
        /// </summary>
        Default = 0,

        /// <summary>誤差の中央値を最小にする。外れ値が半分未満なら効く。</summary>
        LeastMedianOfSquares = 4,

        /// <summary>
        /// 外れ値を捨てながら当てはめる。**特徴点の対応のように誤対応が
        /// 混ざる入力ではこれを使う。**
        /// </summary>
        Ransac = 8,
    }

    /// <summary>
    /// 点の対応から変換を求める（OpenCV の geometry）。
    /// </summary>
    /// <remarks>
    /// <c>CvOps</c> は imgproc、<c>CvCodecs</c> は imgcodecs の範囲である。
    /// クラスを分けてあるので、この plugin がどの OpenCV モジュールを
    /// リンクしているかが C# 側から読み取れる。
    /// </remarks>
    public static class CvGeometry
    {
        /// <summary>射影変換を決めるのに要る最小の点数。</summary>
        private const int MinPoints = 4;

        /// <summary>RANSAC のしきい値の既定（画素）。OpenCV の既定と同じ。</summary>
        private const double DefaultRansacThreshold = 3.0;

        /// <summary>
        /// 2 組の点の対応から射影変換（3x3）を求めて <paramref name="dst"/> に入れる。
        /// 求まったら true、点が退化していて求まらなければ false を返す。
        /// </summary>
        /// <remarks>
        /// <paramref name="dst"/> は結果に応じて丸ごと置き換わり、64 bit 1 channel の
        /// 3x3 になる —— 呼び出し前に持っていた形状・型・内容は保持されない。
        /// **false を返すのは誤りではない** —— 点が退化していて解が存在しない
        /// だけである（入力の形が誤っている場合は例外になる）。
        /// **どの入力で false になるかは OpenCV が決める** —— 実測では
        /// 全部同じ点と軸に平行な直線が false で、**斜めの直線は true を返す**
        /// （rank 不足の行列がそのまま返る）。共線判定はしていない。
        /// 求めた変換は imgproc の透視変換に渡して使う。
        /// </remarks>
        /// <param name="srcPoints">変換前の点。4 点以上。</param>
        /// <param name="dstPoints">対応する変換後の点。<paramref name="srcPoints"/> と同じ長さ。</param>
        /// <param name="dst">結果を受け取る Mat。</param>
        /// <param name="method">求め方。既定は全点を使う最小二乗。</param>
        /// <param name="ransacThreshold"><see cref="CvHomographyMethod.Ransac"/> のときだけ使うしきい値（画素）。</param>
        public static bool FindHomography(
            CvPoint2[] srcPoints,
            CvPoint2[] dstPoints,
            CvMat dst,
            CvHomographyMethod method = CvHomographyMethod.Default,
            double ransacThreshold = DefaultRansacThreshold)
        {
            if (srcPoints == null) { throw new ArgumentNullException(nameof(srcPoints)); }
            if (dstPoints == null) { throw new ArgumentNullException(nameof(dstPoints)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }

            if (srcPoints.Length < MinPoints)
            {
                throw new ArgumentException(
                    $"射影変換には {MinPoints} 点以上が要ります（渡されたのは {srcPoints.Length} 点）。",
                    nameof(srcPoints));
            }

            // **2 つの点列が同じ長さであることは、ここでしか見られない。**
            // native は各配列の長さを個別に受け取って point_count と突き合わせるので、
            // 「短すぎる」は境界で断られる。**だが「片方だけ長い」は native から見て
            // 正常であり、呼ぶ側の意図と食い違っていることは分からない** ——
            // 対応の付いていない点を黙って無視するより、ここで断るほうがよい。
            if (srcPoints.Length != dstPoints.Length)
            {
                throw new ArgumentException(
                    $"2 つの点列は同じ長さでなければなりません（{srcPoints.Length} と {dstPoints.Length}）。",
                    nameof(dstPoints));
            }

            // 長さは native にも渡す（**バイト数** —— この ABI の length は
            // 全部そうなっている）。**C# が正しく詰めたことを native は
            // 信用しない。** 直接 C ABI を叩く呼び手（他の言語、テスト）が
            // 短い配列に大きな点数を渡しても、境界で断られる。
            var src = Flatten(srcPoints);
            var dstFlat = Flatten(dstPoints);

            var status = (CvStatus)NativeMethods.ocvu_find_homography(
                src, (long)src.Length * sizeof(float),
                dstFlat, (long)dstFlat.Length * sizeof(float), srcPoints.Length,
                (int)method, ransacThreshold, dst.Handle);

            // **解が無いのは失敗ではない。** 呼ぶ側には false で返す。
            if (status == CvStatus.NotFound) { return false; }

            CvNative.ThrowIfFailed(status);
            return true;
        }

        /// <summary>x と y が交互に並ぶ配列にする。native が読む形である。</summary>
        private static float[] Flatten(CvPoint2[] points)
        {
            var flat = new float[points.Length * 2];
            for (int i = 0; i < points.Length; i++)
            {
                flat[i * 2] = points[i].X;
                flat[(i * 2) + 1] = points[i].Y;
            }
            return flat;
        }
    }
}
