using System;
using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>
    /// 視差の求め方。
    /// </summary>
    /// <remarks>
    /// 値は C の <c>OCVU_STEREO_*</c> の写しである。C# から C の <c>#define</c> は
    /// 読めないので複製しており、<c>StereoTests</c> の
    /// <c>TheManagedAlgorithmValuesMatchWhatNativeAccepts</c> が両側を native に
    /// 問うことで同期を守っている。
    /// <para>
    /// **この 2 つは OpenCV のクラスであって定数ではない**ので、native 側にも
    /// 突き合わせる相手が無い（<c>OCVU_MAT_TYPE_*</c> や <c>OCVU_NORM_*</c> は
    /// OpenCV の値の写しなので native が <c>static_assert</c> で固定できるが、
    /// こちらの値はこの ABI が決めたものである）。
    /// </para>
    /// </remarks>
    public enum CvStereoAlgorithm
    {
        /// <summary>ブロック照合。速いが粗い。</summary>
        BlockMatching = 0,

        /// <summary>準大域照合。遅いが滑らかである。</summary>
        SemiGlobal = 1,
    }

    /// <summary>
    /// 平行に並べた 2 枚から視差を求める（OpenCV の stereo）。
    /// </summary>
    /// <remarks>
    /// <see cref="CvOps"/> は imgproc、<see cref="CvCodecs"/> は imgcodecs、
    /// <see cref="CvGeometry"/> は geometry の範囲である。クラスを分けてあるので、
    /// この plugin がどの OpenCV モジュールをリンクしているかが C# 側から読み取れる。
    /// </remarks>
    public static class CvStereo
    {
        /// <summary>
        /// 平行に並べた左右の画像から視差の画像を作って <paramref name="dst"/> に入れる。
        /// </summary>
        /// <remarks>
        /// <paramref name="dst"/> は結果に応じて丸ごと置き換わり、入力と同じ大きさの
        /// <see cref="CvMatType.Disparity16"/>（16 bit 符号つき 1 channel）になる ——
        /// 呼び出し前に持っていた形状・型・内容は保持されない。
        /// <para>
        /// **値は実際の視差の 16 倍である。** OpenCV が固定小数で返すためで、
        /// 画素の値を 16 で割ったものが視差（画素）になる。視差が求まらなかった
        /// 画素には負の値が入る。**1 画素は 2 バイトなので、
        /// <see cref="CvMat.CopyTo(byte[], long)"/> で読み出すときの stride は
        /// <c>Cols * 2</c> である**（<c>Cols</c> ではない）。
        /// </para>
        /// <para>
        /// **左右の画像はあらかじめ平行化（rectify）されていなければならない。**
        /// つまり、同じ点が左右で同じ行に写っている必要がある。
        /// **この package は平行化を持っていない** —— 守らなくても誰も止めないが、
        /// 返る視差は無意味になる。平行化は呼ぶ側の仕事である。
        /// </para>
        /// <para>
        /// 2 枚はどちらも <see cref="CvMatType.Gray8"/> でなければならず、
        /// 大きさも揃っている必要がある。
        /// </para>
        /// <para>
        /// **<paramref name="numDisparities"/> と <paramref name="blockSize"/> の
        /// 制限は OpenCV の要求ではなく、この ABI が自分で決めた、より厳しい契約で
        /// ある。** OpenCV が同じ制限を課すのは
        /// <see cref="CvStereoAlgorithm.BlockMatching"/> だけで、
        /// <see cref="CvStereoAlgorithm.SemiGlobal"/> はどちらも検査しない（実測）。
        /// 両方に同じ制限をかけてあるので、<paramref name="algorithm"/> を
        /// 差し替えても呼ぶ側の引数の作り方は変わらない。
        /// </para>
        /// <para>
        /// 引数が契約に合わない場合は <see cref="CvNativeException"/> になり、
        /// その <c>Status</c> は <see cref="CvStatus.InvalidArgument"/> である。
        /// **その場合 <paramref name="dst"/> は 1 バイトも書き換わらない。**
        /// </para>
        /// </remarks>
        /// <param name="left">左の画像。<see cref="CvMatType.Gray8"/>。</param>
        /// <param name="right">右の画像。左と同じ大きさ・同じ型。</param>
        /// <param name="dst">視差を受け取る Mat。</param>
        /// <param name="algorithm">使う照合の方法。</param>
        /// <param name="numDisparities">探索する視差の幅。正の 16 の倍数。</param>
        /// <param name="blockSize">照合する窓の 1 辺。5 以上の奇数。</param>
        public static void ComputeDisparity(
            CvMat left,
            CvMat right,
            CvMat dst,
            CvStereoAlgorithm algorithm,
            int numDisparities = 16,
            int blockSize = 21)
        {
            if (left == null) { throw new ArgumentNullException(nameof(left)); }
            if (right == null) { throw new ArgumentNullException(nameof(right)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }

            // **numDisparities / blockSize / algorithm はここで検査しない。**
            // 契約の正本は native 側にあり（bindings/spec/stereo.json の summary と
            // native/src/ocvu_stereo.cpp）、そこが理由つきの last-error を残す。
            // ここに写すと同じ規則が 2 つになり、**片方だけが古くなる** ——
            // このリポジトリが繰り返し記録している壊れ方である。
            // 2 つの引数の関係でしか見えないもの（CvGeometry の「点列の長さが
            // 揃っているか」）だけが C# の入口に置く価値を持つが、ここには無い。
            var status = (CvStatus)NativeMethods.ocvu_compute_disparity(
                left.Handle, right.Handle, dst.Handle,
                (int)algorithm, numDisparities, blockSize);
            CvNative.ThrowIfFailed(status);
        }
    }
}
