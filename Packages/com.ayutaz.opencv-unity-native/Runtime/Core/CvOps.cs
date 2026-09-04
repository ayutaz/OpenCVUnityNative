using System;
using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>
    /// 二値化の仕方。native の <c>OCVU_THRESH_*</c> の写しである。
    /// </summary>
    /// <remarks>
    /// <b>本当のビットは <see cref="Otsu"/> だけである。</b>
    /// <see cref="Binary"/> から <see cref="ToZeroInv"/> までの 5 つは 0 から 4 までの
    /// 連番であって、独立したビットではない —— <see cref="ToZero"/>（3）は
    /// <c>BinaryInv | Trunc</c>（1 | 2）と同じ数になる。**5 つのうち 1 つだけを選び、
    /// 必要なら <see cref="Otsu"/> を or して渡す**、という使い方が正しく、
    /// 5 つを互いに or してはならない。
    /// <para>
    /// <see cref="FlagsAttribute"/> を付けてあるのは、この or を型の上で表現するため
    /// である（OpenCV の <c>cv::ThresholdTypes</c> がそういう形をしている）。
    /// </para>
    /// <para>
    /// <b><see cref="Otsu"/> には入力の型の制約がある</b> —— 8 bit 1 channel と
    /// 16 bit 1 channel でしか動かない。複数 channel の画像に or して渡すと
    /// OpenCV が例外を投げ、<see cref="CvStatus.OpenCvError"/> になる。
    /// </para>
    /// </remarks>
    [Flags]
    public enum CvThresholdType
    {
        /// <summary>しきい値より大きければ maxValue、そうでなければ 0。</summary>
        Binary = 0,

        /// <summary><see cref="Binary"/> の逆。</summary>
        BinaryInv = 1,

        /// <summary>しきい値より大きい画素をしきい値まで下げる。</summary>
        Trunc = 2,

        /// <summary>しきい値以下の画素を 0 にする。それ以外はそのまま。</summary>
        ToZero = 3,

        /// <summary><see cref="ToZero"/> の逆。</summary>
        ToZeroInv = 4,

        /// <summary>
        /// しきい値を画像から自動で選ぶ。上の 5 つのいずれかと <b>or して</b>渡す。
        /// 渡した threshold は無視され、実際に選ばれた値が
        /// <see cref="CvOps.Threshold"/> の返り値になる。
        /// </summary>
        Otsu = 8,
    }

    /// <summary>形態素演算の種類。native の <c>OCVU_MORPH_*</c> の写しである。</summary>
    public enum CvMorphOp
    {
        /// <summary>収縮。明るい領域が縮む。</summary>
        Erode = 0,

        /// <summary>膨張。明るい領域が広がる。</summary>
        Dilate = 1,

        /// <summary>開。収縮してから膨張する（小さな明点を消す）。</summary>
        Open = 2,

        /// <summary>閉。膨張してから収縮する（小さな穴を埋める）。</summary>
        Close = 3,

        /// <summary>勾配。膨張と収縮の差（輪郭が残る）。</summary>
        Gradient = 4,

        /// <summary>トップハット。元と開の差。</summary>
        TopHat = 5,

        /// <summary>ブラックハット。閉と元の差。</summary>
        BlackHat = 6,
    }

    /// <summary>形態素演算の構造要素の形。native の <c>OCVU_MORPH_SHAPE_*</c> の写しである。</summary>
    public enum CvMorphShape
    {
        /// <summary>矩形。</summary>
        Rect = 0,

        /// <summary>十字。</summary>
        Cross = 1,

        /// <summary>楕円。</summary>
        Ellipse = 2,
    }

    /// <summary>
    /// テンプレート照合の測り方。native の <c>OCVU_TM_*</c> の写しである。
    /// </summary>
    /// <remarks>
    /// <b>最も似た位置を探すとき、最小と最大のどちらを取るかが方法によって逆になる。</b>
    /// <see cref="SquaredDifference"/> と <see cref="SquaredDifferenceNormed"/> は
    /// <b>小さいほど似ており</b>、残る 4 つは大きいほど似ている。
    /// </remarks>
    public enum CvTemplateMatchMethod
    {
        /// <summary>差の二乗和。<b>小さいほど似ている。</b></summary>
        SquaredDifference = 0,

        /// <summary>差の二乗和を正規化したもの。<b>小さいほど似ている。</b></summary>
        SquaredDifferenceNormed = 1,

        /// <summary>相互相関。大きいほど似ている。</summary>
        CrossCorrelation = 2,

        /// <summary>相互相関を正規化したもの。大きいほど似ている。</summary>
        CrossCorrelationNormed = 3,

        /// <summary>相関係数。大きいほど似ている。</summary>
        CorrelationCoefficient = 4,

        /// <summary>相関係数を正規化したもの。大きいほど似ている。</summary>
        CorrelationCoefficientNormed = 5,
    }

    /// <summary>
    /// 輪郭の取り出し方。native の <c>OCVU_RETR_*</c> の写しである。
    /// </summary>
    /// <remarks>
    /// <b>階層は返らない。</b> <see cref="ConnectedComponents"/> と
    /// <see cref="Tree"/> は OpenCV では入れ子の関係も返す指定だが、この ABI は
    /// 階層を境界の外へ出していないので、返るのは輪郭の一覧だけである
    /// （どれが外側でどれが穴かは、この API からは分からない）。
    /// <para>
    /// <c>cv::RETR_FLOODFILL</c> に当たる値は出していない —— 32 bit のラベル画像を
    /// 要求するので、<see cref="CvOps.FindContours"/> が受ける 8 bit の 2 値画像では
    /// 使えない。
    /// </para>
    /// </remarks>
    public enum CvRetrievalMode
    {
        /// <summary>いちばん外側の輪郭だけを返す。</summary>
        External = 0,

        /// <summary>全部の輪郭を平らに返す。</summary>
        List = 1,

        /// <summary>外側と穴の 2 段に分けて拾う。</summary>
        ConnectedComponents = 2,

        /// <summary>入れ子の全段を拾う。</summary>
        Tree = 3,
    }

    /// <summary>
    /// 輪郭の点の間引き方。native の <c>OCVU_CHAIN_APPROX_*</c> の写しである。
    /// </summary>
    /// <remarks>
    /// Teh-Chin 系の 2 つは出していない。値が 0 から始まらないのは
    /// <c>cv::ContourApproximationModes</c> の 0 が別の指定だからで、写し間違いではない。
    /// </remarks>
    public enum CvChainApproxMethod
    {
        /// <summary>輪郭上の画素を 1 つも間引かない。</summary>
        None = 1,

        /// <summary>直線部分の中間点を落とす。軸に平行な矩形なら 4 点になる。</summary>
        Simple = 2,
    }

    /// <summary>
    /// 画像の外側をどう埋めるか。native の <c>OCVU_BORDER_*</c> の写しである。
    /// </summary>
    /// <remarks>
    /// <b>OpenCV が <see cref="CvOps.WarpPerspective"/> について文書で挙げているのは
    /// <see cref="Constant"/> と <see cref="Replicate"/> の 2 つだけである。</b>
    /// 残る 3 つは C ABI が受け付けるが、変換後に元の画像の外を参照する画素が
    /// 実際に出たときの挙動は OpenCV の実装に委ねている。
    /// </remarks>
    public enum CvBorderMode
    {
        /// <summary>外側を 0 で埋める。</summary>
        Constant = 0,

        /// <summary>いちばん端の画素を引き伸ばす。</summary>
        Replicate = 1,

        /// <summary>端で折り返す（端の画素も繰り返す）。</summary>
        Reflect = 2,

        /// <summary>反対側へ回り込む。</summary>
        Wrap = 3,

        /// <summary>端で折り返す（端の画素は繰り返さない）。</summary>
        Reflect101 = 4,
    }

    /// <summary>
    /// 線分。始点と終点の 2 点を持つ読み取り専用の値。
    /// </summary>
    /// <remarks>
    /// <see cref="CvOps.HoughLinesP"/> が返す形である。UnityEngine の型を使わない
    /// 理由は <see cref="CvPoint2"/> と同じ（<c>Runtime/Core</c> は UnityEngine を
    /// 参照してはならない）。
    /// </remarks>
    public readonly struct CvLine
    {
        /// <summary>線分の始点。</summary>
        public CvPoint2 Start { get; }

        /// <summary>線分の終点。</summary>
        public CvPoint2 End { get; }

        /// <summary>始点と終点から線分を作る。</summary>
        public CvLine(CvPoint2 start, CvPoint2 end)
        {
            Start = start;
            End = end;
        }
    }

    /// <summary>imgproc の薄い wrapper。status を例外に変換する。</summary>
    public static class CvOps
    {
        public const int Bgra2Bgr = 1;
        public const int Rgba2Bgra = 5;
        public const int Bgr2Gray = 6;
        public const int InterNearest = 0;
        public const int InterLinear = 1;

        /// <summary>線分 1 本が占める float の個数（x1, y1, x2, y2）。native の契約である。</summary>
        private const int LineElements = 4;

        /// <summary>点 1 つが占める float の個数（x, y）。native の契約である。</summary>
        private const int PointElements = 2;

        /// <summary>射影変換をちょうど決めるのに要る点数。</summary>
        private const int PerspectivePoints = 4;

        /// <summary>
        /// C の <c>OCVU_CORNER_MAX_POINTS</c> の写しである。C# から C の <c>#define</c> は
        /// 読めないので複製しており、<c>ImgprocOpsTests</c> の
        /// <c>TheManagedCornerPointLimitMatchesWhatNativeAccepts</c> が両側を native に
        /// 問うことで同期を守っている（<c>CvFeatures.MaxFeatures</c> と同じ形）。
        /// </summary>
        private const int MaxCornerPoints = 10000;

        /// <summary>
        /// C の <c>OCVU_CORNER_MAX_WINDOW</c> の写しである。
        /// </summary>
        /// <remarks>
        /// <b>この上限が無いと、1 呼び出しでプロセスが落ちる。</b>
        /// <c>cv::cornerSubPix</c> は窓の半径を <c>int</c> のまま 2 倍して寸法に
        /// するので、大きな値は符号あり整数のオーバーフローになる ——
        /// 2026-09-05 の実測で、<c>zeroZone</c> に 2 の 30 乗を渡すと
        /// アクセス違反でプロセスが即死した。native 側も同じ上限で断るが、
        /// <b>ここでも断るのは、その 1 呼び出しが Unity の Editor や Player を
        /// 落とすからである</b>（Unity のレーンではクラッシュは赤いテストにならない）。
        /// <c>ImgprocOpsTests</c> が両側を native に問うことで同期を守っている。
        /// </remarks>
        private const int MaxCornerWindow = 256;

        /// <summary>
        /// <see cref="FindContours"/> が最初に用意する輪郭の本数。
        /// <b>上限ではない</b> —— 超えたぶんは 2 回目の呼び出しで受け取る。
        /// </summary>
        private const int DefaultContourCapacity = 256;

        /// <summary>
        /// <see cref="FindContours"/> が最初に用意する点の総数。
        /// <b>上限ではない</b> —— <see cref="DefaultContourCapacity"/> と同じ扱いである。
        /// </summary>
        private const int DefaultContourPointCapacity = 4096;

        public static void CvtColor(CvMat src, CvMat dst, int code) =>
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_cvt_color(
                src.Handle, dst.Handle, code));

        public static void Resize(CvMat src, CvMat dst, int width, int height, int interpolation) =>
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_resize(
                src.Handle, dst.Handle, width, height, interpolation));

        public static void GaussianBlur(CvMat src, CvMat dst,
                                        int ksizeWidth, int ksizeHeight,
                                        double sigmaX, double sigmaY) =>
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_gaussian_blur(
                src.Handle, dst.Handle, ksizeWidth, ksizeHeight, sigmaX, sigmaY));

        /// <summary>
        /// <paramref name="src"/> を二値化して <paramref name="dst"/> に入れ、
        /// <b>実際に使われたしきい値</b>を返す。
        /// </summary>
        /// <remarks>
        /// <paramref name="dst"/> は結果に応じて丸ごと置き換わり、
        /// <paramref name="src"/> と同じ形状・型になる —— 呼び出し前に持っていた
        /// 形状・型・内容は保持されない。
        /// <para>
        /// <b>返り値が意味を持つのは <see cref="CvThresholdType.Otsu"/> を or した
        /// ときである。</b> それ以外では渡した <paramref name="threshold"/> がそのまま
        /// 返る。Otsu が選んだ値を知る手段はこの返り値だけである。
        /// </para>
        /// <para>
        /// <paramref name="src"/> と <paramref name="dst"/> に同じ
        /// <see cref="CvMat"/> を渡してもよい。
        /// </para>
        /// </remarks>
        /// <param name="src">二値化する画像。32 bit 符号つき整数は OpenCV が拒否する。</param>
        /// <param name="dst">結果を受け取る Mat。</param>
        /// <param name="threshold">しきい値。<see cref="CvThresholdType.Otsu"/> を or したときは無視される。</param>
        /// <param name="maxValue">しきい値を超えた画素に入れる値。</param>
        /// <param name="type">二値化の仕方。</param>
        /// <returns>実際に使われたしきい値。</returns>
        public static double Threshold(CvMat src, CvMat dst,
                                       double threshold, double maxValue,
                                       CvThresholdType type)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }

            var status = (CvStatus)NativeMethods.ocvu_threshold(
                src.Handle, dst.Handle, threshold, maxValue, (int)type,
                out double computed);
            CvNative.ThrowIfFailed(status);
            return computed;
        }

        /// <summary>
        /// <paramref name="src"/> に Canny のエッジ検出を掛けて
        /// <paramref name="dst"/> に入れる。
        /// </summary>
        /// <remarks>
        /// <paramref name="dst"/> は結果に応じて丸ごと置き換わり、
        /// <paramref name="src"/> と同じ大きさの 8 bit 1 channel になる
        /// （エッジが 255、それ以外が 0）。
        /// <para>
        /// 小さいほうのしきい値が弱いエッジをつなぐ下限、大きいほうが強いエッジの
        /// 下限として使われる。<b>どちらが大きいかを入れ替えても OpenCV は断らない。</b>
        /// </para>
        /// </remarks>
        /// <param name="src">エッジを探す画像。8 bit でなければならない。</param>
        /// <param name="dst">結果を受け取る Mat。</param>
        /// <param name="threshold1">しきい値その 1。負であってはならない。</param>
        /// <param name="threshold2">しきい値その 2。負であってはならない。</param>
        /// <param name="apertureSize">Sobel の窓の大きさ。3 / 5 / 7 のいずれか。</param>
        /// <param name="l2Gradient">勾配の大きさを L2 ノルムで測るか（false なら L1 で、速いが粗い）。</param>
        public static void Canny(CvMat src, CvMat dst,
                                 double threshold1, double threshold2,
                                 int apertureSize = 3, bool l2Gradient = false)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }

            // **境界に bool を出さない。** 表現の大きさが処理系で決まる型を
            // ABI に載せないための約束で、native は 0 / 1 の int32_t で受ける。
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_canny(
                src.Handle, dst.Handle, threshold1, threshold2,
                apertureSize, l2Gradient ? 1 : 0));
        }

        /// <summary>
        /// <paramref name="src"/> に形態素演算を掛けて <paramref name="dst"/> に入れる。
        /// </summary>
        /// <remarks>
        /// <paramref name="dst"/> は結果に応じて丸ごと置き換わり、
        /// <paramref name="src"/> と同じ形状・型になる。構造要素の中心は OpenCV が
        /// 自動で決める。<paramref name="src"/> と <paramref name="dst"/> に同じ
        /// <see cref="CvMat"/> を渡してもよい。
        /// </remarks>
        /// <param name="src">元の画像。</param>
        /// <param name="dst">結果を受け取る Mat。</param>
        /// <param name="op">演算の種類。</param>
        /// <param name="shape">構造要素の形。</param>
        /// <param name="kernelWidth">構造要素の幅（画素）。1 以上。</param>
        /// <param name="kernelHeight">構造要素の高さ（画素）。1 以上。</param>
        /// <param name="iterations">演算を繰り返す回数。1 以上。</param>
        public static void MorphologyEx(CvMat src, CvMat dst,
                                        CvMorphOp op, CvMorphShape shape,
                                        int kernelWidth, int kernelHeight,
                                        int iterations = 1)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }

            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_morphology_ex(
                src.Handle, dst.Handle, (int)op, (int)shape,
                kernelWidth, kernelHeight, iterations));
        }

        /// <summary>
        /// <paramref name="image"/> の中で <paramref name="templ"/> に似ている場所の
        /// 応答画像を作って <paramref name="dst"/> に入れる。
        /// </summary>
        /// <remarks>
        /// <paramref name="dst"/> は結果に応じて丸ごと置き換わり、大きさは
        /// <c>image - templ + 1</c>、型は <see cref="CvMatType.Response32"/>
        /// （32 bit 浮動小数 1 channel）になる。<b>読み出すときの stride は
        /// <c>Cols * 4</c> である</b> —— <see cref="CvMat.CopyTo(byte[], long)"/> は
        /// byte 列しか受けないので、値に戻すのは呼ぶ側の仕事になる。
        /// <para>
        /// <b>最も似た位置は、方法によって最小か最大かが逆になる</b>
        /// （<see cref="CvTemplateMatchMethod"/> を見ること）。
        /// </para>
        /// <para>
        /// <paramref name="image"/> と <paramref name="templ"/> は 8 bit か 32 bit
        /// 浮動小数で、しかも同じ型でなければならない。<paramref name="templ"/> が
        /// <paramref name="image"/> より大きければ拒否される —— OpenCV に任せると
        /// 例外にならず 2 つを入れ替えて計算するので、この境界が自分で断る。
        /// </para>
        /// </remarks>
        /// <param name="image">探される側の画像。</param>
        /// <param name="templ">探す小さな画像。</param>
        /// <param name="dst">応答画像を受け取る Mat。</param>
        /// <param name="method">似ている度合いの測り方。</param>
        public static void MatchTemplate(CvMat image, CvMat templ, CvMat dst,
                                         CvTemplateMatchMethod method)
        {
            if (image == null) { throw new ArgumentNullException(nameof(image)); }
            if (templ == null) { throw new ArgumentNullException(nameof(templ)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }

            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_match_template(
                image.Handle, templ.Handle, dst.Handle, (int)method));
        }

        /// <summary>
        /// ちょうど 4 点の対応から射影変換（3x3）を求めて
        /// <paramref name="transform"/> に入れる。
        /// </summary>
        /// <remarks>
        /// <paramref name="transform"/> は結果に応じて丸ごと置き換わり、
        /// <see cref="CvMatType.Transform64"/> の 3x3 になる。そのまま
        /// <see cref="WarpPerspective"/> に渡せる。
        /// <para>
        /// <see cref="CvGeometry.FindHomography"/> との違いは、<b>こちらがちょうど
        /// 4 点を厳密に通す</b>のに対し、あちらは 4 点以上から当てはめる点である。
        /// 誤対応が混ざりうる入力には <see cref="CvGeometry.FindHomography"/> を使うこと。
        /// </para>
        /// <para>
        /// <b>4 点より多い配列は断る。</b> native は先頭の 4 点だけを読んで残りを
        /// 黙って捨てるので、呼ぶ側の意図と食い違ったまま成功してしまう ——
        /// 気づける場所はここしかない。
        /// </para>
        /// </remarks>
        /// <param name="src">変換前の 4 点。</param>
        /// <param name="dst">対応する変換後の 4 点。</param>
        /// <param name="transform">求めた 3x3 を受け取る Mat。</param>
        public static void GetPerspectiveTransform(CvPoint2[] src, CvPoint2[] dst, CvMat transform)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }
            if (transform == null) { throw new ArgumentNullException(nameof(transform)); }

            if (src.Length != PerspectivePoints)
            {
                throw new ArgumentException(
                    $"射影変換にはちょうど {PerspectivePoints} 点が要ります（渡されたのは {src.Length} 点）。",
                    nameof(src));
            }
            if (dst.Length != PerspectivePoints)
            {
                throw new ArgumentException(
                    $"射影変換にはちょうど {PerspectivePoints} 点が要ります（渡されたのは {dst.Length} 点）。",
                    nameof(dst));
            }

            var flatSrc = Flatten(src);
            var flatDst = Flatten(dst);

            // 長さは native にも渡す（**バイト数** —— この ABI の length は全部そうである）。
            // **C# が正しく詰めたことを native は信用しない。**
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_get_perspective_transform(
                flatSrc, (long)flatSrc.Length * sizeof(float),
                flatDst, (long)flatDst.Length * sizeof(float),
                transform.Handle));
        }

        /// <summary>
        /// <paramref name="src"/> を射影変換で変形して <paramref name="dst"/> に入れる。
        /// </summary>
        /// <remarks>
        /// <paramref name="dst"/> は結果に応じて丸ごと置き換わり、
        /// <paramref name="height"/> 行 <paramref name="width"/> 列で
        /// <paramref name="src"/> と同じ型になる。
        /// <para>
        /// <paramref name="transform"/> は 3x3 の Mat である ——
        /// <see cref="GetPerspectiveTransform"/> や
        /// <see cref="CvGeometry.FindHomography"/> の出力をそのまま渡せる。
        /// </para>
        /// <para>
        /// <paramref name="interpolation"/> が <c>int</c> なのは、
        /// <see cref="Resize"/> と揃えてあるためである（<see cref="InterNearest"/> か
        /// <see cref="InterLinear"/> を渡す）。<b>専用の enum を作っていない</b> ——
        /// 同じ意味の指定が 2 つの型で表されると、どちらを渡すのかが呼ぶ側の
        /// 判断になる。
        /// </para>
        /// </remarks>
        /// <param name="src">変形する画像。</param>
        /// <param name="dst">結果を受け取る Mat。</param>
        /// <param name="transform">3x3 の変換行列を持つ Mat。</param>
        /// <param name="width">出力の幅（画素）。1 以上。</param>
        /// <param name="height">出力の高さ（画素）。1 以上。</param>
        /// <param name="interpolation"><see cref="InterNearest"/> か <see cref="InterLinear"/>。</param>
        /// <param name="borderMode">元の画像の外を参照した画素の埋め方。</param>
        public static void WarpPerspective(CvMat src, CvMat dst, CvMat transform,
                                           int width, int height,
                                           int interpolation, CvBorderMode borderMode)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }
            if (transform == null) { throw new ArgumentNullException(nameof(transform)); }

            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_warp_perspective(
                src.Handle, dst.Handle, transform.Handle,
                width, height, interpolation, (int)borderMode));
        }

        /// <summary>
        /// 確率的 Hough 変換で <paramref name="src"/> から線分を検出する。
        /// 1 本も見つからなければ<b>空配列</b>を返す。
        /// </summary>
        /// <remarks>
        /// <b>空配列は誤りではない</b> —— 線分が写っていなかっただけである
        /// （入力の形が誤っている場合は例外になる）。
        /// <para>
        /// <paramref name="src"/> は書き換えない。OpenCV は入力を書き換えることが
        /// あると宣言しているので、native 側が写しを渡している。
        /// </para>
        /// <para>
        /// <b><paramref name="maxLines"/> は上限ではない。</b> 最初に用意する本数で
        /// あって、それより多く見つかった場合は必要な量で確保し直して 1 度だけ
        /// 呼び直す —— 呼ぶ側から見ると、この値は速さの調整でしかない。
        /// </para>
        /// </remarks>
        /// <param name="src">線分を探す画像。8 bit 1 channel の 2 値画像（<see cref="Canny"/> の出力など）。</param>
        /// <param name="rho">距離の刻み（画素）。0 より大きい。</param>
        /// <param name="theta">角度の刻み（ラジアン）。0 より大きい。</param>
        /// <param name="threshold">投票数の下限。1 以上。</param>
        /// <param name="minLineLength">これより短い線分は捨てる。</param>
        /// <param name="maxLineGap">これ以下の切れ目はつなぐ。</param>
        /// <param name="maxLines">最初に用意する本数。上限ではない。</param>
        public static CvLine[] HoughLinesP(CvMat src,
                                           double rho, double theta, int threshold,
                                           double minLineLength, double maxLineGap,
                                           int maxLines = 256)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (maxLines < 1)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(maxLines), maxLines, "maxLines は 1 以上でなければなりません。");
            }
            // **int のまま掛けない。** 4 倍が符号付き整数の乗算オーバーフロー
            // （未定義動作）にならないよう、long で先に見る。
            if ((long)maxLines * LineElements > int.MaxValue)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(maxLines), maxLines,
                    $"maxLines は {int.MaxValue / LineElements} 以下でなければなりません。");
            }

            var buffer = new float[maxLines * LineElements];
            var status = (CvStatus)NativeMethods.ocvu_hough_lines_p(
                src.Handle, rho, theta, threshold, minLineLength, maxLineGap,
                buffer, buffer.Length, out int count);

            if (status == CvStatus.BufferTooSmall)
            {
                // **溢れたときの count は本数である**（要素数ではない）。
                // native は 1 バイトも書いていないので、必要な量で確保し直して
                // **1 度だけ**呼び直す。
                buffer = new float[RequiredElements(count, LineElements, "ocvu_hough_lines_p")];
                status = (CvStatus)NativeMethods.ocvu_hough_lines_p(
                    src.Handle, rho, theta, threshold, minLineLength, maxLineGap,
                    buffer, buffer.Length, out count);

                // **2 度目も溢れたら諦める。** 1 度目と 2 度目の間に src が
                // 変わった場合にしか起きないが、黙って空配列を返すと呼ぶ側は
                // 「線分が無かった」と読んでしまう。
                // **BufferTooSmall は失敗として扱われないので、載せる status を
                // 変える**（そうしないと ThrowIfFailed 側の規約と食い違う）。
                if (status == CvStatus.BufferTooSmall)
                {
                    throw new CvNativeException(
                        CvStatus.UnknownError,
                        "ocvu_hough_lines_p still reported a too-small buffer after resizing " +
                        $"to {buffer.Length} elements (the source Mat likely changed between the two calls)");
                }
            }

            CvNative.ThrowIfFailed(status);

            // 契約どおりに動く限りここは通らない。**それでも見るのは、native が
            // 誤った量を報告した場合に、添字例外ではなく原因の読める例外で
            // 止めるためである**（CvCalibration と同じ理由）。
            if (count < 0 || (long)count * LineElements > buffer.Length)
            {
                throw new CvNativeException(
                    CvStatus.UnknownError,
                    $"ocvu_hough_lines_p reported {count} lines but the buffer only holds " +
                    $"{buffer.Length / LineElements}");
            }

            var lines = new CvLine[count];
            for (int i = 0; i < count; i++)
            {
                int b = i * LineElements;
                lines[i] = new CvLine(
                    new CvPoint2(buffer[b], buffer[b + 1]),
                    new CvPoint2(buffer[b + 2], buffer[b + 3]));
            }
            return lines;
        }

        /// <summary>
        /// 既に見つけてある角点の位置を副画素精度へ精緻化して、<b>新しい配列で</b>返す。
        /// </summary>
        /// <remarks>
        /// <b>渡した配列は書き換えない。</b> C ABI の
        /// <c>ocvu_corner_sub_pix</c> は buffer を入出力兼用にしているが、
        /// その形をここから外へ出さない —— 呼ぶ側が持っている「検出したままの位置」が
        /// 気づかないうちに消えるのを防ぐためである。
        /// <para>
        /// 返る配列は <paramref name="points"/> と同じ長さ・同じ順である。
        /// </para>
        /// </remarks>
        /// <param name="src">角点が写っている画像。1 channel で、8 bit か 32 bit 浮動小数。</param>
        /// <param name="points">精緻化したい位置。1 点以上、10000 点以下。</param>
        /// <param name="winSize">探索窓の半径（画素）。1 以上 256 以下。</param>
        /// <param name="zeroZone">窓の中央で無視する領域の半径。-1 なら無視しない。0 以上 256 以下。</param>
        /// <param name="maxIterations">打ち切るまでの繰り返し回数。1 以上。</param>
        /// <param name="epsilon">移動量がこれを下回ったら打ち切る。</param>
        public static CvPoint2[] CornerSubPix(CvMat src, CvPoint2[] points,
                                              int winSize = 5, int zeroZone = -1,
                                              int maxIterations = 30, double epsilon = 0.01)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (points == null) { throw new ArgumentNullException(nameof(points)); }

            if (points.Length < 1)
            {
                throw new ArgumentException("精緻化する点が 1 つもありません。", nameof(points));
            }
            if (points.Length > MaxCornerPoints)
            {
                throw new ArgumentException(
                    $"点は {MaxCornerPoints} 個以下でなければなりません（渡されたのは {points.Length} 個）。",
                    nameof(points));
            }

            if (winSize < 1 || winSize > MaxCornerWindow)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(winSize), winSize,
                    $"winSize は 1 以上 {MaxCornerWindow} 以下でなければなりません。");
            }
            if (zeroZone < -1 || zeroZone > MaxCornerWindow)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(zeroZone), zeroZone,
                    $"zeroZone は -1、または 0 以上 {MaxCornerWindow} 以下でなければなりません。");
            }
            if (maxIterations < 1)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(maxIterations), maxIterations,
                    "maxIterations は 1 以上でなければなりません。");
            }

            // **写しを渡す。** native はこの配列をその場で書き換えるので、
            // 呼ぶ側の配列を直接渡すと入力が失われる。
            var flat = Flatten(points);

            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_corner_sub_pix(
                src.Handle, flat, (long)flat.Length * sizeof(float), points.Length,
                winSize, zeroZone, maxIterations, epsilon));

            var refined = new CvPoint2[points.Length];
            for (int i = 0; i < refined.Length; i++)
            {
                refined[i] = new CvPoint2(flat[i * PointElements], flat[(i * PointElements) + 1]);
            }
            return refined;
        }

        /// <summary>
        /// <paramref name="src"/> から輪郭を検出する。1 本も見つからなければ<b>空配列</b>を返す。
        /// </summary>
        /// <remarks>
        /// <b>空配列は誤りではない</b> —— 白い塊が無かっただけである
        /// （入力の形が誤っている場合は例外になる）。
        /// <para>
        /// 返るのは輪郭ごとの点列である。<b>階層は返らない</b> ——
        /// どれが外側でどれが穴かは、この API からは分からない
        /// （<see cref="CvRetrievalMode"/> を見ること）。
        /// </para>
        /// <para>
        /// C ABI は平らな 2 本の配列（全点と、輪郭ごとの点数）で入れ子を表しているが、
        /// <b>その形はここから外へ出さない。</b> 容量が足りなければ必要な量で確保し直して
        /// 1 度だけ呼び直すので、呼ぶ側は容量を知らなくてよい。
        /// </para>
        /// </remarks>
        /// <param name="src">輪郭を探す画像。8 bit 1 channel の 2 値画像（0 でない画素を 1 と見なす）。</param>
        /// <param name="mode">輪郭の取り出し方。</param>
        /// <param name="method">点の間引き方。</param>
        public static CvPoint2[][] FindContours(CvMat src, CvRetrievalMode mode,
                                                CvChainApproxMethod method)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }

            var points = new float[DefaultContourPointCapacity * PointElements];
            var counts = new int[DefaultContourCapacity];

            var status = (CvStatus)NativeMethods.ocvu_find_contours(
                src.Handle, (int)mode, (int)method,
                points, points.Length, counts, counts.Length,
                out int contourCount, out int totalPoints);

            if (status == CvStatus.BufferTooSmall)
            {
                // **溢れたときの 2 つの out は必要量である。** native はどちらの
                // 配列にも 1 バイトも書いていないので、その量で確保し直して
                // **1 度だけ**呼び直す。
                if (contourCount < 0)
                {
                    throw new CvNativeException(
                        CvStatus.UnknownError,
                        $"ocvu_find_contours reported a negative contour count ({contourCount})");
                }
                points = new float[RequiredElements(totalPoints, PointElements, "ocvu_find_contours")];
                counts = new int[contourCount];

                status = (CvStatus)NativeMethods.ocvu_find_contours(
                    src.Handle, (int)mode, (int)method,
                    points, points.Length, counts, counts.Length,
                    out contourCount, out totalPoints);

                // **2 度目も溢れたら諦める**（HoughLinesP と同じ理由。
                // BufferTooSmall は失敗として扱われないので status を差し替える）。
                if (status == CvStatus.BufferTooSmall)
                {
                    throw new CvNativeException(
                        CvStatus.UnknownError,
                        "ocvu_find_contours still reported a too-small buffer after resizing to " +
                        $"{counts.Length} contours / {points.Length / PointElements} points " +
                        "(the source Mat likely changed between the two calls)");
                }
            }

            CvNative.ThrowIfFailed(status);

            if (contourCount < 0 || contourCount > counts.Length ||
                totalPoints < 0 || (long)totalPoints * PointElements > points.Length)
            {
                throw new CvNativeException(
                    CvStatus.UnknownError,
                    $"ocvu_find_contours reported {contourCount} contours / {totalPoints} points " +
                    $"but the buffers only hold {counts.Length} / {points.Length / PointElements}");
            }

            var contours = new CvPoint2[contourCount][];
            long offset = 0;
            for (int c = 0; c < contourCount; c++)
            {
                int n = counts[c];
                // 各輪郭の点数も native 由来なので、足し合わせが buffer を
                // はみ出さないことをここで見る。
                if (n < 0 || (offset + n) * PointElements > points.Length)
                {
                    throw new CvNativeException(
                        CvStatus.UnknownError,
                        $"ocvu_find_contours reported {n} points for contour {c}, " +
                        $"which runs past the {points.Length / PointElements} points it wrote");
                }

                var contour = new CvPoint2[n];
                for (int i = 0; i < n; i++)
                {
                    long b = (offset + i) * PointElements;
                    contour[i] = new CvPoint2(points[b], points[b + 1]);
                }
                contours[c] = contour;
                offset += n;
            }
            return contours;
        }

        /// <summary>
        /// native が報告した個数を、確保し直す配列の要素数に変える。
        /// <b>掛け算は long で行う</b> —— int のままだと符号付き整数の乗算
        /// オーバーフロー（未定義動作）になりうる。
        /// </summary>
        private static int RequiredElements(int count, int elementsPerItem, string function)
        {
            if (count < 0)
            {
                throw new CvNativeException(
                    CvStatus.UnknownError,
                    $"{function} reported a negative count ({count})");
            }

            long elements = (long)count * elementsPerItem;
            if (elements > int.MaxValue)
            {
                throw new CvNativeException(
                    CvStatus.UnknownError,
                    $"{function} needs {elements} elements, which does not fit in a .NET array index");
            }
            return (int)elements;
        }

        /// <summary>x と y が交互に並ぶ配列にする。native が読む形である。</summary>
        private static float[] Flatten(CvPoint2[] points)
        {
            var flat = new float[points.Length * PointElements];
            for (int i = 0; i < points.Length; i++)
            {
                flat[i * PointElements] = points[i].X;
                flat[(i * PointElements) + 1] = points[i].Y;
            }
            return flat;
        }
    }
}
