using System;
using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>
    /// 最小値・最大値と、それぞれが最初に現れた位置。
    /// </summary>
    /// <remarks>
    /// C の <c>ocvu_min_max_loc</c> は 6 つの出力を個別に NULL にできる
    /// （最大値だけ欲しいことは普通にある）が、**C# ではまとめて 1 つ返す** ——
    /// 部分的に受け取る形を出すと、呼ぶ側に「今回はどれが有効か」という
    /// 分岐が増えるためである。
    /// <para>
    /// 位置に <see cref="CvPoint2"/> を使うのは、この層が UnityEngine の
    /// Vector2 を参照できないためである（<see cref="CvPoint2"/> の説明を参照）。
    /// 値そのものは画素の索引なので整数だが、他の点と同じ型で受け取れるほうが
    /// 呼ぶ側で詰め替えずに済む。
    /// </para>
    /// </remarks>
    public readonly struct CvMinMax
    {
        /// <summary>最小値。複数 channel の src では全 channel を通した最小である。</summary>
        public double MinValue { get; }

        /// <summary>最大値。複数 channel の src では全 channel を通した最大である。</summary>
        public double MaxValue { get; }

        /// <summary>最小値が最初に現れた位置（画素）。</summary>
        public CvPoint2 MinLocation { get; }

        /// <summary>最大値が最初に現れた位置（画素）。</summary>
        public CvPoint2 MaxLocation { get; }

        /// <summary>4 つの値から結果を作る。</summary>
        public CvMinMax(double minValue, double maxValue,
                        CvPoint2 minLocation, CvPoint2 maxLocation)
        {
            MinValue = minValue;
            MaxValue = maxValue;
            MinLocation = minLocation;
            MaxLocation = maxLocation;
        }
    }

    /// <summary>
    /// 正規化の仕方。
    /// </summary>
    /// <remarks>
    /// 値は C の <c>OCVU_NORM_*</c> の写しである。C# から C の <c>#define</c> は
    /// 読めないので複製しており、<c>CoreOpsTests</c> の
    /// <c>TheManagedEnumValuesMatchWhatNativeAccepts</c> が両側を native に
    /// 問うことで同期を守っている。
    /// <para>
    /// **<c>OCVU_NORM_HAMMING</c> はここに無い。** あれは記述子どうしの距離を
    /// 測るためのもので、正規化の仕方ではない —— native も
    /// <c>ocvu_normalize</c> の引数としては拒否する。
    /// </para>
    /// </remarks>
    public enum CvNormType
    {
        /// <summary>絶対値の最大が <c>alpha</c> になるように割る。</summary>
        Inf = 1,

        /// <summary>絶対値の総和が <c>alpha</c> になるように割る。</summary>
        L1 = 2,

        /// <summary>二乗和の平方根が <c>alpha</c> になるように割る。</summary>
        L2 = 4,

        /// <summary>
        /// 値域を <c>alpha</c> と <c>beta</c> の間へ線形に写す。
        /// **画像を見えるようにするのはふつうこれである。**
        /// </summary>
        MinMax = 32,
    }

    /// <summary>
    /// 2 つの画像のビット演算。
    /// </summary>
    /// <remarks>
    /// 値は C の <c>OCVU_BITWISE_*</c> の写しである。
    /// <para>
    /// **ビット反転（NOT）はここに無い。** C の ABI は 4 つ目の <c>op</c> として
    /// 持っているが、NOT だけは 2 つ目の入力を見ない ——
    /// <c>Bitwise(src, null, dst, Not)</c> と書かせないために、C# では
    /// <see cref="CvCoreOps.BitwiseNot(CvMat, CvMat)"/> という別のメソッドにしてある。
    /// </para>
    /// </remarks>
    public enum CvBitwiseOp
    {
        /// <summary>両方が 1 のビットだけ 1 にする。</summary>
        And = 0,

        /// <summary>どちらかが 1 のビットを 1 にする。</summary>
        Or = 1,

        /// <summary>片方だけが 1 のビットを 1 にする。</summary>
        Xor = 2,
    }

    /// <summary>
    /// 画素に対する基本演算（OpenCV の core）。
    /// </summary>
    /// <remarks>
    /// <c>CvMat</c> が Mat のライフサイクルと buffer の受け渡しを持ち、
    /// こちらは画素そのものに対する演算を持つ。<c>CvOps</c> は imgproc、
    /// <c>CvCodecs</c> は imgcodecs の範囲である —— クラスを分けてあるので、
    /// この plugin がどの OpenCV モジュールをリンクしているかが C# 側から
    /// 読み取れる。
    /// <para>
    /// **9 本のうち <see cref="InsertChannel(CvMat, CvMat, int)"/> だけが
    /// <c>dst</c> を丸ごと置き換えない。** 他はすべて、呼び出し前に
    /// <c>dst</c> が持っていた形状・型・内容を保持しない ——
    /// <c>dst</c> に何を渡しても結果に応じて作り直されるので、
    /// 1x1 の Mat を渡してよい。
    /// </para>
    /// </remarks>
    public static class CvCoreOps
    {
        /// <summary>
        /// 無効な handle。<see cref="BitwiseNot(CvMat, CvMat)"/> が
        /// 見られない側の引数に渡す。
        /// </summary>
        /// <remarks>
        /// **これは手抜きではなく契約である。** <c>ocvu_bitwise</c> は
        /// <c>OCVU_BITWISE_NOT</c> のとき 2 つ目の入力を一切見ないと
        /// spec に書いてあり、L1 が無効な handle を渡して成功することを
        /// 実証している。ここで有効な Mat をわざわざ作ると、
        /// 「見ていない」ことが偶然に見えてしまう。
        /// </remarks>
        private const ulong NoHandle = 0UL;

        /// <summary>
        /// C の <c>OCVU_BITWISE_NOT</c> の写し。
        /// </summary>
        /// <remarks>
        /// **<see cref="CvBitwiseOp"/> には入れていない。** あの enum は
        /// 「2 つの入力に対する演算」を表すもので、NOT はそこに属さない ——
        /// 入れると <c>Bitwise(a, null, dst, Not)</c> と書けてしまう。
        /// 値が native と一致していることは <c>CoreOpsTests</c> の
        /// <c>BitwiseNotInvertsEveryBit</c> が実際に反転結果を見ることで
        /// 分かる（別の値を渡せば AND / OR / XOR になるか、拒否される）。
        /// </remarks>
        private const int BitwiseNotOp = 3;

        /// <summary>
        /// <paramref name="src"/> の 1 つの channel を取り出して
        /// <paramref name="dst"/> に入れる。
        /// </summary>
        /// <remarks>
        /// <paramref name="dst"/> は結果に応じて丸ごと置き換わり、
        /// <paramref name="src"/> と同じ大きさの 1 channel になる。
        /// <paramref name="src"/> と <paramref name="dst"/> に同じ
        /// <see cref="CvMat"/> を渡してはならない（自分自身から channel を
        /// 取り出す意味が無いので native が断る）。
        /// </remarks>
        /// <param name="src">取り出す元。</param>
        /// <param name="dst">結果を受け取る Mat。</param>
        /// <param name="channelIndex">
        /// 0 以上かつ <paramref name="src"/> の channel 数未満。
        /// 範囲外なら native が <see cref="CvStatus.InvalidArgument"/> を返す。
        /// </param>
        public static void ExtractChannel(CvMat src, CvMat dst, int channelIndex)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }

            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_extract_channel(
                src.Handle, dst.Handle, channelIndex));
        }

        /// <summary>
        /// 1 channel の <paramref name="src"/> を <paramref name="dst"/> の
        /// 1 つの channel へ差し込む。
        /// </summary>
        /// <remarks>
        /// **このクラスで <paramref name="dst"/> を丸ごと置き換えない唯一の
        /// メソッドである。** 指定した channel だけが書き換わり、他の channel は
        /// そのまま残る。<paramref name="src"/> は 1 channel で、
        /// <paramref name="dst"/> と同じ大きさ・同じ要素型でなければならない
        /// （違えば OpenCV が例外を投げるので
        /// <see cref="CvStatus.OpenCvError"/> になる）。
        /// 失敗したときは <paramref name="dst"/> を 1 バイトも書き換えない。
        /// </remarks>
        /// <param name="src">差し込む 1 channel の Mat。</param>
        /// <param name="dst">差し込まれる Mat。</param>
        /// <param name="channelIndex">
        /// 0 以上かつ <paramref name="dst"/> の channel 数未満。
        /// </param>
        public static void InsertChannel(CvMat src, CvMat dst, int channelIndex)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }

            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_insert_channel(
                src.Handle, dst.Handle, channelIndex));
        }

        /// <summary>
        /// <paramref name="src"/> の最小値・最大値と、それぞれが最初に現れた
        /// 位置を返す。
        /// </summary>
        /// <remarks>
        /// **<paramref name="src"/> は 1 channel でなければならない。**
        /// このメソッドは位置も必ず受け取るので、複数 channel の Mat を渡すと
        /// 位置が一意に決まらず、OpenCV が拒んで
        /// <see cref="CvStatus.OpenCvError"/> になる（値だけを取る経路は
        /// C の ABI には在るが、C# には出していない ——
        /// <see cref="CvMinMax"/> の説明を参照）。
        /// </remarks>
        /// <param name="src">調べる Mat。</param>
        /// <returns>最小値・最大値とその位置。</returns>
        public static CvMinMax MinMaxLoc(CvMat src)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }

            double minValue;
            double maxValue;
            int minX;
            int minY;
            int maxX;
            int maxY;
            var status = (CvStatus)NativeMethods.ocvu_min_max_loc(
                src.Handle, out minValue, out maxValue,
                out minX, out minY, out maxX, out maxY);
            CvNative.ThrowIfFailed(status);

            return new CvMinMax(
                minValue, maxValue,
                new CvPoint2(minX, minY),
                new CvPoint2(maxX, maxY));
        }

        /// <summary>
        /// <paramref name="src"/> の各画素が <paramref name="lower"/> と
        /// <paramref name="upper"/> の間（両端を含む）にあるかを調べ、
        /// 入っていれば 255、外れていれば 0 を <paramref name="dst"/> に書く。
        /// </summary>
        /// <remarks>
        /// <paramref name="dst"/> は結果に応じて丸ごと置き換わり、
        /// <paramref name="src"/> と同じ大きさの 8 bit 1 channel になる。
        /// 複数 channel の場合は、**すべての channel が範囲に入っている画素だけ**が
        /// 255 になる。<paramref name="src"/> と <paramref name="dst"/> に
        /// 同じ <see cref="CvMat"/> を渡してもよい。
        /// <para>
        /// <paramref name="lower"/> と <paramref name="upper"/> は
        /// <paramref name="src"/> の channel 数ぶんの要素を持たなければならない。
        /// **足りなければ native が断る** —— C# 側では数えない。
        /// channel 数は native が handle を引いてからでないと分からず、
        /// ここで先回りして数えると、native の門と 2 か所で同じ規則を
        /// 持つことになるためである。
        /// </para>
        /// </remarks>
        /// <param name="src">調べる Mat。</param>
        /// <param name="dst">結果を受け取る Mat。</param>
        /// <param name="lower">channel ごとの下限。</param>
        /// <param name="upper">channel ごとの上限。</param>
        public static void InRange(CvMat src, CvMat dst, double[] lower, double[] upper)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }
            if (lower == null) { throw new ArgumentNullException(nameof(lower)); }
            if (upper == null) { throw new ArgumentNullException(nameof(upper)); }

            // 長さは **バイト数** で渡す —— この ABI の *_length は全部そうである。
            // **C# が正しく詰めたことを native は信用しない。** 直接 C ABI を
            // 叩く呼び手（他の言語、テスト）が短い配列を渡しても境界で断られる。
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_in_range(
                src.Handle, dst.Handle,
                lower, (long)lower.Length * sizeof(double),
                upper, (long)upper.Length * sizeof(double)));
        }

        /// <summary>
        /// <paramref name="src"/> の値域を正規化して <paramref name="dst"/> に入れる。
        /// </summary>
        /// <remarks>
        /// <paramref name="dst"/> は結果に応じて丸ごと置き換わり、
        /// <paramref name="src"/> と**同じ型**になる（この ABI は型変換を
        /// 持ち込まないので、出力の型を選ぶ引数を出していない）。
        /// <see cref="CvNormType.MinMax"/> のときは値域を
        /// <paramref name="alpha"/> と <paramref name="beta"/> の間へ線形に写す。
        /// 他の 3 つのときは指定したノルムが <paramref name="alpha"/> に
        /// なるように割り、<paramref name="beta"/> は使わない。
        /// <paramref name="src"/> と <paramref name="dst"/> に同じ
        /// <see cref="CvMat"/> を渡してもよい。
        /// </remarks>
        /// <param name="src">正規化する Mat。</param>
        /// <param name="dst">結果を受け取る Mat。</param>
        /// <param name="alpha">
        /// <see cref="CvNormType.MinMax"/> なら写す先の一方の端、
        /// それ以外なら目標のノルム。
        /// </param>
        /// <param name="beta">
        /// <see cref="CvNormType.MinMax"/> のときだけ使う、写す先のもう一方の端。
        /// </param>
        /// <param name="normType">正規化の仕方。</param>
        public static void Normalize(CvMat src, CvMat dst, double alpha, double beta, CvNormType normType)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }

            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_normalize(
                src.Handle, dst.Handle, alpha, beta, (int)normType));
        }

        /// <summary>
        /// <paramref name="src1"/> と <paramref name="src2"/> のビット演算を
        /// <paramref name="dst"/> に入れる。
        /// </summary>
        /// <remarks>
        /// <paramref name="dst"/> は結果に応じて丸ごと置き換わり、
        /// <paramref name="src1"/> と同じ形状・型になる。
        /// 2 つの入力は同じ形状・同じ型でなければならず、違えば OpenCV が
        /// 例外を投げるので <see cref="CvStatus.OpenCvError"/> になる。
        /// <paramref name="dst"/> に入力と同じ <see cref="CvMat"/> を
        /// 渡してもよい。
        /// <para>
        /// **ビット反転は <see cref="BitwiseNot(CvMat, CvMat)"/> である** ——
        /// 入力が 1 つしか無いので、ここに混ぜていない。
        /// </para>
        /// </remarks>
        /// <param name="src1">1 つ目の入力。</param>
        /// <param name="src2">2 つ目の入力。</param>
        /// <param name="dst">結果を受け取る Mat。</param>
        /// <param name="op">行う演算。</param>
        public static void Bitwise(CvMat src1, CvMat src2, CvMat dst, CvBitwiseOp op)
        {
            if (src1 == null) { throw new ArgumentNullException(nameof(src1)); }
            if (src2 == null) { throw new ArgumentNullException(nameof(src2)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }

            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_bitwise(
                src1.Handle, src2.Handle, dst.Handle, (int)op));
        }

        /// <summary>
        /// <paramref name="src"/> のビットを反転して <paramref name="dst"/> に入れる。
        /// </summary>
        /// <remarks>
        /// <paramref name="dst"/> は結果に応じて丸ごと置き換わり、
        /// <paramref name="src"/> と同じ形状・型になる。
        /// <paramref name="src"/> と <paramref name="dst"/> に同じ
        /// <see cref="CvMat"/> を渡してもよい。
        /// </remarks>
        /// <param name="src">反転する Mat。</param>
        /// <param name="dst">結果を受け取る Mat。</param>
        public static void BitwiseNot(CvMat src, CvMat dst)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }

            // C の ABI では 4 つ目の op である。**2 つ目の入力は見られない**ので、
            // 無効な handle を渡す（NoHandle の説明を参照）。
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_bitwise(
                src.Handle, NoHandle, dst.Handle, BitwiseNotOp));
        }

        /// <summary>
        /// <paramref name="src"/> の各画素の値を <paramref name="table"/> で
        /// 引いた値に置き換えて <paramref name="dst"/> に入れる。
        /// </summary>
        /// <remarks>
        /// <paramref name="dst"/> は結果に応じて丸ごと置き換わり、
        /// <paramref name="src"/> と同じ形状・型になる。
        /// <paramref name="src"/> は 8 bit でなければならず、そうでなければ
        /// OpenCV が例外を投げるので <see cref="CvStatus.OpenCvError"/> になる。
        /// 複数 channel の <paramref name="src"/> には同じ表がすべての channel に
        /// 適用される。<paramref name="src"/> と <paramref name="dst"/> に
        /// 同じ <see cref="CvMat"/> を渡してもよい。
        /// <para>
        /// <paramref name="table"/> は 8 bit の値域（0 から 255）を全部覆う
        /// 256 要素以上でなければならない。**短ければ native が
        /// <see cref="CvStatus.InvalidArgument"/> で断る** —— C# 側では
        /// 数えない（表の要件は native が持つ 1 つの規則であり、
        /// ここに写すと 2 か所で同じことを言うことになる）。
        /// </para>
        /// </remarks>
        /// <param name="src">引く元の Mat。</param>
        /// <param name="dst">結果を受け取る Mat。</param>
        /// <param name="table">256 要素以上の変換表。</param>
        public static void Lut(CvMat src, CvMat dst, byte[] table)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }
            if (table == null) { throw new ArgumentNullException(nameof(table)); }

            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_lut(
                src.Handle, dst.Handle, table, table.LongLength));
        }

        /// <summary>
        /// <paramref name="src"/> の周囲に余白を足して <paramref name="dst"/> に入れる。
        /// </summary>
        /// <remarks>
        /// <paramref name="dst"/> は結果に応じて丸ごと置き換わり、高さが
        /// <paramref name="src"/> の高さ + <paramref name="top"/> +
        /// <paramref name="bottom"/>、幅が <paramref name="src"/> の幅 +
        /// <paramref name="left"/> + <paramref name="right"/> で、
        /// <paramref name="src"/> と同じ型になる。
        /// 4 つの余白はいずれも 0 以上でなければならず、負なら native が
        /// <see cref="CvStatus.InvalidArgument"/> で断る。
        /// <paramref name="src"/> と <paramref name="dst"/> に同じ
        /// <see cref="CvMat"/> を渡してもよい。
        /// </remarks>
        /// <param name="src">余白を足す元。</param>
        /// <param name="dst">結果を受け取る Mat。</param>
        /// <param name="top">上に足す画素数。</param>
        /// <param name="bottom">下に足す画素数。</param>
        /// <param name="left">左に足す画素数。</param>
        /// <param name="right">右に足す画素数。</param>
        /// <param name="borderType">余白の埋め方。</param>
        /// <param name="borderValue">
        /// <c>CvBorderMode.Constant</c> のときにだけ使う埋め値。
        /// 全 channel に同じ値が入る（channel ごとに違う値を入れる経路は
        /// 出していない）。
        /// </param>
        public static void CopyMakeBorder(CvMat src, CvMat dst,
                                          int top, int bottom, int left, int right,
                                          CvBorderMode borderType, double borderValue = 0.0)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }

            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_copy_make_border(
                src.Handle, dst.Handle, top, bottom, left, right,
                (int)borderType, borderValue));
        }
    }
}
