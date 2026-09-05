using System;
using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>
    /// 特徴点 1 つ。native の ocvu_keypoint に対応する読み取り専用の値。
    /// </summary>
    public readonly struct CvKeyPoint
    {
        public float X { get; }
        public float Y { get; }
        public float Size { get; }
        public float Angle { get; }
        public float Response { get; }
        public int Octave { get; }
        public int ClassId { get; }

        internal CvKeyPoint(float x, float y, float size, float angle,
                            float response, int octave, int classId)
        {
            X = x; Y = y; Size = size; Angle = angle;
            Response = response; Octave = octave; ClassId = classId;
        }
    }

    /// <summary>
    /// 記述子どうしの対応 1 つ。native の ocvu_dmatch に対応する読み取り専用の値。
    /// </summary>
    /// <remarks>
    /// native の ocvu_dmatch は image_index も持つが、**この ABI が出しているのは
    /// 1 対 1 の照合だけ**なので常に 0 である。意味を持たない値を公開面に置くと、
    /// 呼ぶ側が「複数の train 画像をまとめて渡せる」と読み違えるので出していない。
    /// </remarks>
    public readonly struct CvMatch
    {
        /// <summary>query 側の特徴点の索引。</summary>
        public int QueryIndex { get; }

        /// <summary>train 側の特徴点の索引。</summary>
        public int TrainIndex { get; }

        /// <summary>記述子どうしの距離。**小さいほど似ている。**</summary>
        public float Distance { get; }

        internal CvMatch(int queryIndex, int trainIndex, float distance)
        {
            QueryIndex = queryIndex;
            TrainIndex = trainIndex;
            Distance = distance;
        }
    }

    /// <summary>
    /// 特徴点の検出器。
    /// </summary>
    /// <remarks>
    /// 値は C の <c>OCVU_FEATURE_*</c> の写しである。C# から C の <c>#define</c> は
    /// 読めないので複製しており、<c>MatchingTests</c> の
    /// <c>TheManagedDetectorValuesMatchWhatNativeAccepts</c> が両側を native に
    /// 問うことで同期を守っている。
    /// <para>
    /// **記述子の型と幅が検出器で違う** —— ORB は 32 列の 8 bit、SIFT は 128 列の
    /// 32 bit 浮動小数である。<see cref="CvDescriptorNorm"/> はこれに合わせること
    /// （合っていないと OpenCV が例外を投げる）。
    /// </para>
    /// </remarks>
    public enum CvFeatureDetector
    {
        /// <summary>
        /// ORB。2 値の記述子を作るので <see cref="CvDescriptorNorm.Hamming"/> と組む。
        /// </summary>
        Orb = 0,

        /// <summary>
        /// SIFT。32 bit 浮動小数の記述子を作るので <see cref="CvDescriptorNorm.L2"/> と組む。
        /// </summary>
        Sift = 1,
    }

    /// <summary>
    /// 記述子どうしの距離の測り方。
    /// </summary>
    /// <remarks>
    /// 値は C の <c>OCVU_NORM_*</c>（= OpenCV の <c>cv::NORM_*</c>）の写しである。
    /// <c>MatchingTests</c> の <c>TheManagedNormValuesMatchWhatNativeAccepts</c> が
    /// 両側を native に問うことで同期を守っている。
    /// </remarks>
    public enum CvDescriptorNorm
    {
        /// <summary>ユークリッド距離。SIFT の 32 bit 浮動小数の記述子に使う。</summary>
        L2 = 4,

        /// <summary>ハミング距離。ORB の 2 値の記述子に使う。</summary>
        Hamming = 6,
    }

    /// <summary>
    /// 特徴点の検出（OpenCV の features）。
    /// </summary>
    public static class CvFeatures
    {
        /// <summary>
        /// C の OCVU_ORB_MAX_FEATURES の写しである。C# から C の #define は読めないので
        /// 複製しており、FeaturesTests の TheManagedUpperBoundMatchesWhatNativeAccepts が
        /// 両側を native に問うことで同期を守っている。
        /// </summary>
        private const int MaxFeatures = 10000;

        /// <summary>
        /// MatchDescriptors が最初に確保する対応の数の既定。
        /// **上限ではない** —— 足りなければ実際の数で確保し直して呼び直す。
        /// </summary>
        private const int DefaultMatchCapacity = 1024;

        /// <summary>
        /// src から ORB の特徴点を最大 maxFeatures 個検出する。
        /// </summary>
        public static CvKeyPoint[] DetectOrb(CvMat src, int maxFeatures)
        {
            if (src == null) throw new ArgumentNullException(nameof(src));
            if (maxFeatures <= 0 || maxFeatures > MaxFeatures)
                throw new ArgumentOutOfRangeException(
                    nameof(maxFeatures), maxFeatures,
                    $"maxFeatures は 1 以上 {MaxFeatures} 以下でなければなりません。");

            // 必要量は maxFeatures と分かっているので 1 回で済む。
            var raw = new OcvuKeyPoint[maxFeatures];
            var status = (CvStatus)NativeMethods.ocvu_orb_detect(
                src.Handle, maxFeatures, raw, maxFeatures, out int count);
            CvNative.ThrowIfFailed(status);

            var result = new CvKeyPoint[count];
            for (int i = 0; i < count; i++)
            {
                result[i] = new CvKeyPoint(
                    raw[i].X, raw[i].Y, raw[i].Size, raw[i].Angle,
                    raw[i].Response, raw[i].Octave, raw[i].ClassId);
            }
            return result;
        }

        /// <summary>
        /// src から特徴点を検出し、同時にその記述子を <paramref name="descriptors"/> に作る。
        /// </summary>
        /// <remarks>
        /// <paramref name="descriptors"/> は結果に応じて丸ごと置き換わり、
        /// 行が特徴点 1 つ、列が記述子の次元になる（ORB は 32 列の 8 bit、
        /// SIFT は 128 列の 32 bit 浮動小数）—— 呼び出し前に持っていた形状・型・
        /// 内容は保持されない。
        /// <para>
        /// **記述子を戻り値にせず引数で受け取るのは、所有権を呼ぶ側に置くためである。**
        /// この package の Mat は必ず呼ぶ側が <see cref="CvMat.Dispose"/> する契約で
        /// （docs/abi-ownership-and-versioning.md §1）、戻り値にすると
        /// 「特徴点の配列を受け取っただけのつもり」で捨て損ねる Mat が生まれる。
        /// 引数なら、作った場所と捨てる場所が同じ <c>using</c> の中に並ぶ。
        /// 記述子が要らないなら <see cref="DetectOrb"/> を使うこと。
        /// </para>
        /// <para>
        /// **<paramref name="maxFeatures"/> は上限ではない。** OpenCV への希望で
        /// あって、ORB も SIFT も指定より多く返すことがある（実測）。
        /// **この関数はその溢れを隠す** —— まず <paramref name="maxFeatures"/> ぶんを
        /// 確保して 1 回で呼び、検出器がそれより多く返したときだけ、
        /// 返ってきた個数で確保し直して 1 度だけ呼び直す。
        /// **問い合わせのためだけに検出器を走らせることはしない** ——
        /// この ABI は検出器を保持しないので、問い合わせも本番も同じだけ計算する。
        /// </para>
        /// <para>
        /// **1 つも見つからないのは誤りではない** —— 空配列が返る。
        /// </para>
        /// </remarks>
        /// <param name="src">探す画像。</param>
        /// <param name="detector">使う検出器。</param>
        /// <param name="maxFeatures">検出器に伝える希望の個数。1 以上 10000 以下。</param>
        /// <param name="descriptors">記述子を受け取る Mat。**src と同じものを渡さないこと。**</param>
        public static CvKeyPoint[] DetectAndCompute(
            CvMat src, CvFeatureDetector detector, int maxFeatures, CvMat descriptors)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (descriptors == null) { throw new ArgumentNullException(nameof(descriptors)); }
            if (maxFeatures <= 0 || maxFeatures > MaxFeatures)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(maxFeatures), maxFeatures,
                    $"maxFeatures は 1 以上 {MaxFeatures} 以下でなければなりません。");
            }

            // **1 回目は maxFeatures ぶんを確保して呼ぶ。**
            //
            // 以前はここを capacity 0 の「個数の問い合わせ」にしていたが、
            // **それだと ORB / SIFT の検出を必ず 2 回走らせることになる** ——
            // この ABI は検出器を保持しないので、問い合わせも本番も同じだけ
            // 計算する。maxFeatures はたいていの入力で足りるので、
            // **溢れたときだけ 2 回目を払う**ほうが安い（兄弟の
            // DetectMarkers / HoughLinesP / FindContours と同じ形である）。
            //
            // **maxFeatures が上限でないことは、この形でも正しく扱える** ——
            // 検出器が多く返せば BufferTooSmall が返り、下で確保し直す
            // （SIFT は 160x160 で create(200) が 240 個を返した。実測）。
            var raw = new OcvuKeyPoint[maxFeatures];
            int count;
            var status = (CvStatus)NativeMethods.ocvu_detect_and_compute(
                src.Handle, (int)detector, maxFeatures, raw, raw.Length,
                descriptors.Handle, out count);

            if (status == CvStatus.BufferTooSmall)
            {
                // **native は out_keypoints にも descriptors にも 1 バイトも
                // 書いていない。** count には実際に見つかった数が入っている。
                if (count <= raw.Length)
                {
                    throw new CvNativeException(
                        CvStatus.UnknownError,
                        $"ocvu_detect_and_compute reported BufferTooSmall for {count} keypoints " +
                        $"into a buffer of {raw.Length}");
                }
                raw = new OcvuKeyPoint[count];
                status = (CvStatus)NativeMethods.ocvu_detect_and_compute(
                    src.Handle, (int)detector, maxFeatures, raw, raw.Length,
                    descriptors.Handle, out count);
            }

            CvNative.ThrowIfFailed(status);

            // **BufferTooSmall は「失敗」ではないので ThrowIfFailed は素通しする**
            // （CvCodecs.cs と同じ理由）。2 度目も溢れるのは、1 回目と 2 回目の間に
            // src が変わって個数が増えたときで、native は out_keypoints にも
            // descriptors にも 1 バイトも書いていない。**ここで見ないと、呼ぶ側は
            // 例外も無しに「全部 0 の特徴点」と「置き換わっていない記述子」を
            // 受け取る** —— 誤りが status ではなく、もっともらしい結果として
            // 現れる形である。
            //
            // **投げる status に BufferTooSmall を載せない。** あれは
            // CvNative.IsFailure から外してあるので、受けた側が Status で分岐すると
            // 「失敗ではない」と読めてしまう。
            if (status != CvStatus.Ok || count < 0 || count > raw.Length)
            {
                throw new CvNativeException(
                    CvStatus.UnknownError,
                    $"ocvu_detect_and_compute reported {count} keypoints for a buffer of {raw.Length} " +
                    "(the source Mat likely changed between the two calls)");
            }

            var result = new CvKeyPoint[count];
            for (int i = 0; i < count; i++)
            {
                result[i] = new CvKeyPoint(
                    raw[i].X, raw[i].Y, raw[i].Size, raw[i].Angle,
                    raw[i].Response, raw[i].Octave, raw[i].ClassId);
            }
            return result;
        }

        /// <summary>
        /// query の各記述子に対して、train の中で最も近いものを 1 つ探す。
        /// </summary>
        /// <remarks>
        /// 渡す 2 つは <see cref="DetectAndCompute"/> が作った記述子の Mat である。
        /// <para>
        /// **<paramref name="norm"/> は検出器に合わせること** —— ORB の 2 値記述子
        /// には <see cref="CvDescriptorNorm.Hamming"/>、SIFT の浮動小数の記述子には
        /// <see cref="CvDescriptorNorm.L2"/>。**取り違えると OpenCV が例外を投げる**
        /// （<see cref="CvNativeException"/> の Status は
        /// <see cref="CvStatus.OpenCvError"/> になる）。query と train の記述子の型が
        /// 食い違う場合も同じである。
        /// </para>
        /// <para>
        /// <paramref name="crossCheck"/> は互いに最近傍である対応だけを残す。
        /// 誤対応が減るかわりに対応の数も減る。**同じ画像から作った記述子どうしでも、
        /// これを false にすると索引は一致しない** —— 繰り返す模様では記述子が重複し、
        /// 同点のとき先に現れたほうが選ばれるためである（実測）。
        /// </para>
        /// <para>
        /// **<paramref name="maxMatches"/> は上限ではなく最初の見積もりである。**
        /// 対応がそれより多ければ、この関数が実際の数で確保し直して**1 度だけ**
        /// 呼び直す —— 溢れても切り捨てない。見積もりが当たれば native の呼び出しは
        /// 1 回で済む。
        /// </para>
        /// <para>
        /// **1 つも見つからないのは誤りではない** —— 空配列が返る。
        /// </para>
        /// </remarks>
        /// <param name="query">照合する側の記述子。</param>
        /// <param name="train">探される側の記述子。</param>
        /// <param name="norm">距離の測り方。検出器に合わせる。</param>
        /// <param name="crossCheck">互いに最近傍である対応だけを残すか。</param>
        /// <param name="maxMatches">最初に確保する対応の数。1 以上。</param>
        public static CvMatch[] MatchDescriptors(
            CvMat query,
            CvMat train,
            CvDescriptorNorm norm,
            bool crossCheck = false,
            int maxMatches = DefaultMatchCapacity)
        {
            if (query == null) { throw new ArgumentNullException(nameof(query)); }
            if (train == null) { throw new ArgumentNullException(nameof(train)); }
            if (maxMatches < 1)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(maxMatches), maxMatches,
                    "maxMatches は 1 以上でなければなりません。");
            }

            // native は 0 以外を真として扱う。
            int crossCheckFlag = crossCheck ? 1 : 0;

            var raw = new OcvuDMatch[maxMatches];
            int count;
            var status = (CvStatus)NativeMethods.ocvu_match_descriptors(
                query.Handle, train.Handle, (int)norm, crossCheckFlag,
                raw, raw.Length, out count);

            if (status == CvStatus.BufferTooSmall)
            {
                // **足りなかったので、返ってきた個数ちょうどで確保して 1 度だけ
                // 呼び直す。** native は溢れた経路で 1 バイトも書いていないので、
                // ここで捨てて確保し直してよい。
                if (count <= 0)
                {
                    throw new CvNativeException(
                        CvStatus.UnknownError,
                        $"ocvu_match_descriptors reported {count} matches when the buffer was too small");
                }

                raw = new OcvuDMatch[count];
                status = (CvStatus)NativeMethods.ocvu_match_descriptors(
                    query.Handle, train.Handle, (int)norm, crossCheckFlag,
                    raw, raw.Length, out count);
            }

            CvNative.ThrowIfFailed(status);

            // **BufferTooSmall は「失敗」ではないので ThrowIfFailed は素通しする。**
            // 2 度目も溢れるのは、間に query か train が変わって対応の数が増えた
            // ときである。**見ないと、呼ぶ側は例外も無しに全部 0 の対応を受け取る。**
            // DetectAndCompute と同じ理由で、投げる status に BufferTooSmall を
            // 載せない（あれは失敗として扱われない）。
            if (status != CvStatus.Ok || count < 0 || count > raw.Length)
            {
                throw new CvNativeException(
                    CvStatus.UnknownError,
                    $"ocvu_match_descriptors reported {count} matches for a buffer of {raw.Length} " +
                    "(the descriptors likely changed between the two calls)");
            }

            var result = new CvMatch[count];
            for (int i = 0; i < count; i++)
            {
                result[i] = new CvMatch(raw[i].QueryIndex, raw[i].TrainIndex, raw[i].Distance);
            }
            return result;
        }
    }
}
