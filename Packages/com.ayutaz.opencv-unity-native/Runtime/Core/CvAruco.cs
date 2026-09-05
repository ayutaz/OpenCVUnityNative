using System;
using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>
    /// ArUco の辞書。
    /// </summary>
    /// <remarks>
    /// 値は C の <c>OCVU_ARUCO_DICT_*</c> の写しである。C# から C の
    /// <c>#define</c> は読めないので複製しており、<c>ArucoTests</c> の
    /// <c>TheManagedDictionaryValuesMatchWhatNativeAccepts</c> が両側を native に
    /// 問うことで同期を守っている（<see cref="CvHomographyMethod"/> と同じ形）。
    /// <para>
    /// 名前の 4X4 / 5X5 / 6X6 / 7X7 はマーカー内部の格子の細かさ、後ろの数字は
    /// その辞書が持つ ID の個数である。**細かいほど遠くから読みにくく、
    /// 個数が多いほど誤検出しやすい。** 決まっていないなら
    /// <see cref="Dict4X4_50"/> でよい。
    /// </para>
    /// <para>
    /// **AprilTag 系は出していない。** <c>cv::aruco</c> には在るが、この plugin
    /// では検証していない。
    /// </para>
    /// </remarks>
    public enum CvArucoDictionary
    {
        /// <summary>4x4 の格子、ID は 50 個。</summary>
        Dict4X4_50 = 0,

        /// <summary>4x4 の格子、ID は 100 個。</summary>
        Dict4X4_100 = 1,

        /// <summary>4x4 の格子、ID は 250 個。</summary>
        Dict4X4_250 = 2,

        /// <summary>4x4 の格子、ID は 1000 個。</summary>
        Dict4X4_1000 = 3,

        /// <summary>5x5 の格子、ID は 50 個。</summary>
        Dict5X5_50 = 4,

        /// <summary>5x5 の格子、ID は 100 個。</summary>
        Dict5X5_100 = 5,

        /// <summary>5x5 の格子、ID は 250 個。</summary>
        Dict5X5_250 = 6,

        /// <summary>5x5 の格子、ID は 1000 個。</summary>
        Dict5X5_1000 = 7,

        /// <summary>6x6 の格子、ID は 50 個。</summary>
        Dict6X6_50 = 8,

        /// <summary>6x6 の格子、ID は 100 個。</summary>
        Dict6X6_100 = 9,

        /// <summary>6x6 の格子、ID は 250 個。</summary>
        Dict6X6_250 = 10,

        /// <summary>6x6 の格子、ID は 1000 個。</summary>
        Dict6X6_1000 = 11,

        /// <summary>7x7 の格子、ID は 50 個。</summary>
        Dict7X7_50 = 12,

        /// <summary>7x7 の格子、ID は 100 個。</summary>
        Dict7X7_100 = 13,

        /// <summary>7x7 の格子、ID は 250 個。</summary>
        Dict7X7_250 = 14,

        /// <summary>7x7 の格子、ID は 1000 個。</summary>
        Dict7X7_1000 = 15,

        /// <summary>もとの ArUco 論文が定義した辞書。</summary>
        ArucoOriginal = 16,
    }

    /// <summary>
    /// 検出された ArUco マーカー 1 つ。ID と 4 隅を持つ読み取り専用の値。
    /// </summary>
    /// <remarks>
    /// 隅は OpenCV の <c>detectMarkers</c> が返す順、すなわち**マーカーの左上から
    /// 時計回り**である。**この並びは <see cref="CvSolvePnPMethod.IppeSquare"/> が
    /// 要求する並びと一致している**ので、そのまま姿勢推定に渡せる
    /// （<see cref="CvAruco.EstimateMarkerPose"/> がそうしている）。
    /// <para>
    /// 「左上」はマーカー自身から見た左上であって、画像の左上ではない ——
    /// マーカーが回っていれば、画像の中では別の位置に来る。
    /// </para>
    /// </remarks>
    public readonly struct CvArucoMarker
    {
        /// <summary>辞書の中でのマーカー ID。</summary>
        public int Id { get; }

        /// <summary>マーカーの左上の隅。</summary>
        public CvPoint2 TopLeft { get; }

        /// <summary>マーカーの右上の隅。</summary>
        public CvPoint2 TopRight { get; }

        /// <summary>マーカーの右下の隅。</summary>
        public CvPoint2 BottomRight { get; }

        /// <summary>マーカーの左下の隅。</summary>
        public CvPoint2 BottomLeft { get; }

        /// <summary>ID と 4 隅からマーカーを作る。</summary>
        public CvArucoMarker(
            int id,
            CvPoint2 topLeft,
            CvPoint2 topRight,
            CvPoint2 bottomRight,
            CvPoint2 bottomLeft)
        {
            Id = id;
            TopLeft = topLeft;
            TopRight = topRight;
            BottomRight = bottomRight;
            BottomLeft = bottomLeft;
        }
    }

    /// <summary>
    /// ArUco マーカーの生成・検出・姿勢推定（OpenCV の objdetect）。
    /// </summary>
    /// <remarks>
    /// **<see cref="CvQrCode"/> と分けてある。** どちらも objdetect だが、
    /// 用途も引数の形も別である。
    /// <para>
    /// <see cref="EstimateMarkerPose"/> だけは C ABI 関数を 1 本も足していない ——
    /// <see cref="CvGeometry.SolvePnP"/> の上に立つ純粋な C# である。
    /// </para>
    /// </remarks>
    public static class CvAruco
    {
        /// <summary>1 マーカーが占める float の個数。x と y が交互に 4 隅ぶん。</summary>
        private const int FloatsPerMarker = 8;

        /// <summary>
        /// 辞書とマーカー ID からマーカーの画像を作る。
        /// </summary>
        /// <remarks>
        /// 返る <see cref="CvMat"/> は <paramref name="sidePixels"/> 四方の
        /// 8 bit 1 channel で、**呼ぶ側が <see cref="CvMat.Dispose"/> する**。
        /// <para>
        /// <paramref name="borderBits"/> はマーカーの**内側**に置く黒い枠の太さ
        /// （格子単位）である。**検出にはこの枠のさらに外側に白い余白が要るが、
        /// それを付けるのは呼ぶ側の仕事である** —— 黒い海に貼ると輪郭が取れない。
        /// </para>
        /// <para>
        /// <paramref name="sidePixels"/> は「その辞書の格子の一辺 +
        /// <paramref name="borderBits"/> の 2 倍」以上でなければならない
        /// （それより小さいと格子 1 つが 1 画素に満たない）。**割り切れる大きさを
        /// 選ぶとよい** —— 割り切れないと最近傍で引き伸ばすときにセルの幅が
        /// 1 画素ずつずれる。
        /// </para>
        /// <para>
        /// **引数の検証は native が持つ。** 辞書・ID の範囲・大きさのどれが
        /// 違っていても <see cref="CvNativeException"/> になり、
        /// <see cref="CvNativeException.Status"/> は
        /// <see cref="CvStatus.InvalidArgument"/> である。C# 側で先回りして
        /// 断らないのは、**辞書ごとに違う下限を 2 箇所に書くと片方だけ古くなる**
        /// からである。
        /// </para>
        /// </remarks>
        /// <param name="dictionary">使う辞書。</param>
        /// <param name="markerId">辞書の中での ID。0 以上、辞書の持つ個数未満。</param>
        /// <param name="sidePixels">出来上がる画像の一辺（画素）。</param>
        /// <param name="borderBits">内側の黒枠の太さ（格子単位）。1 以上。</param>
        public static CvMat GenerateMarker(
            CvArucoDictionary dictionary,
            int markerId,
            int sidePixels,
            int borderBits = 1)
        {
            var dst = CvMat.Create(1, 1, CvMatType.Gray8);
            try
            {
                // dst の形と型は結果に応じて丸ごと置き換わる。1x1 で作るのは
                // 「入れ物を先に用意する」ためだけである。
                var status = (CvStatus)NativeMethods.ocvu_aruco_generate_marker(
                    (int)dictionary, markerId, sidePixels, borderBits, dst.Handle);
                CvNative.ThrowIfFailed(status);
                return dst;
            }
            catch
            {
                // **失敗したら自分で片付ける。** 例外で戻る道に handle を
                // 置き去りにすると、呼ぶ側には解放する手段が無い。
                dst.Dispose();
                throw;
            }
        }

        /// <summary>
        /// <paramref name="src"/> に写っている ArUco マーカーを検出する。
        /// 1 つも写っていなければ**空配列**を返す。
        /// </summary>
        /// <remarks>
        /// **空配列は誤りではない** —— 写っていなかっただけである。
        /// <para>
        /// <paramref name="src"/> は 8 bit の 1 / 3 / 4 channel でなければならない
        /// （3 と 4 は native がグレースケールへ落としてから検出するので、
        /// Unity のテクスチャをそのまま渡せる）。
        /// </para>
        /// <para>
        /// <paramref name="maxMarkers"/> は**上限ではなく最初の見積もりである。**
        /// それより多く写っていたら、native が報告した実際の個数で確保し直して
        /// **1 度だけ**呼び直す —— 呼ぶ側から見れば 2 回呼びは隠れている。
        /// 見積もりを大きくしておけば 1 回で済むだけである。
        /// </para>
        /// </remarks>
        /// <param name="src">探す画像。</param>
        /// <param name="dictionary">使う辞書。</param>
        /// <param name="maxMarkers">最初に確保する個数。0 以上。</param>
        public static CvArucoMarker[] DetectMarkers(
            CvMat src,
            CvArucoDictionary dictionary,
            int maxMarkers = 64)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (maxMarkers < 0)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(maxMarkers), maxMarkers, "確保する個数は 0 以上でなければなりません。");
            }

            // **long で先に掛けてから見る。** int のまま掛けると、配列を
            // 確保する手前で符号が反転する（CvCalibration が同じ理由で
            // long を使っている）。
            if ((long)maxMarkers * FloatsPerMarker > int.MaxValue)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(maxMarkers), maxMarkers,
                    $"確保する個数が大きすぎます（隅の配列が {(long)maxMarkers * FloatsPerMarker} 要素になります）。");
            }

            var ids = new int[maxMarkers];
            var corners = new float[maxMarkers * FloatsPerMarker];

            var status = (CvStatus)NativeMethods.ocvu_aruco_detect_markers(
                src.Handle, (int)dictionary, ids, ids.Length, corners, corners.Length, out int count);

            if (status == CvStatus.BufferTooSmall)
            {
                // **溢れは失敗ではない。** native は 1 バイトも書かずに、実際に
                // 見つかった個数だけを返している。その量ちょうどで確保し直す。
                if (count < 0 || (long)count * FloatsPerMarker > int.MaxValue)
                {
                    throw new CvNativeException(
                        CvStatus.UnknownError,
                        $"ocvu_aruco_detect_markers reported {count} markers, which cannot be allocated");
                }

                ids = new int[count];
                corners = new float[count * FloatsPerMarker];

                status = (CvStatus)NativeMethods.ocvu_aruco_detect_markers(
                    src.Handle, (int)dictionary, ids, ids.Length, corners, corners.Length, out count);

                if (status == CvStatus.BufferTooSmall)
                {
                    // 2 度目も溢れるのは、1 回目との間に src が変わった場合である。
                    // **ここで見ないと、呼ぶ側は例外も無しに全部 0 の配列を受け取る**
                    // （CvQrCode.Decode と同じ形）。
                    //
                    // **CvStatus.BufferTooSmall を載せて投げない。** あれは
                    // CvNative.IsFailure から外してある「失敗ではない」status なので、
                    // 例外の Status に載せると受け取った側の判定と食い違う。
                    throw new CvNativeException(
                        CvStatus.UnknownError,
                        $"ocvu_aruco_detect_markers still reported {count} markers after growing the buffers " +
                        "(the source Mat likely changed between the two calls)");
                }
            }

            CvNative.ThrowIfFailed(status);

            // native が契約どおりに動く限りここには来ない —— **それでも見るのは、
            // 誤った個数を報告されたときに添字例外ではなく原因の読める例外で
            // 止めるためである**（CvCalibration と同じ形）。
            if (count < 0 || count > ids.Length)
            {
                throw new CvNativeException(
                    CvStatus.UnknownError,
                    $"ocvu_aruco_detect_markers reported {count} markers " +
                    $"but the buffer only holds {ids.Length}");
            }

            var markers = new CvArucoMarker[count];
            for (int i = 0; i < count; i++)
            {
                int b = i * FloatsPerMarker;
                markers[i] = new CvArucoMarker(
                    ids[i],
                    new CvPoint2(corners[b + 0], corners[b + 1]),
                    new CvPoint2(corners[b + 2], corners[b + 3]),
                    new CvPoint2(corners[b + 4], corners[b + 5]),
                    new CvPoint2(corners[b + 6], corners[b + 7]));
            }
            return markers;
        }

        /// <summary>
        /// 1 辺の長さが分かっているマーカーの、カメラから見た姿勢を求める。
        /// </summary>
        /// <remarks>
        /// **新しい C ABI 関数は使わない。** マーカーの中心を原点に置いた正方形を
        /// <see cref="CvGeometry.SolvePnP"/> に
        /// <see cref="CvSolvePnPMethod.IppeSquare"/> で渡すだけの純粋な C# である。
        /// <para>
        /// 座標系はマーカーの中心が原点、x が右、y が上、z が面から手前
        /// （OpenCV の <c>estimatePoseSingleMarkers</c> と同じ取り方）である。
        /// **正面から撮った 1 枚では、回転はほぼ x 軸まわりの半回転になる** ——
        /// OpenCV のカメラ座標系は y が下向きだからで、誤りではない。
        /// </para>
        /// <para>
        /// 返る並進の単位は <paramref name="markerLength"/> に渡したものと同じで
        /// ある（メートルで渡せばメートルで返る）。
        /// </para>
        /// <para>
        /// <paramref name="distCoeffs"/> の扱いは <see cref="CvGeometry.SolvePnP"/> と
        /// 同じで、<c>null</c> か空で歪み無しになる。
        /// </para>
        /// </remarks>
        /// <param name="marker">検出したマーカー。</param>
        /// <param name="markerLength">マーカーの 1 辺の長さ。0 より大きいこと。</param>
        /// <param name="cameraMatrix">行優先の 3x3（9 要素）。</param>
        /// <param name="distCoeffs">歪み係数。<c>null</c> か空で歪み無し。</param>
        public static CvViewPose EstimateMarkerPose(
            CvArucoMarker marker,
            float markerLength,
            double[] cameraMatrix,
            double[] distCoeffs)
        {
            // **NaN を素通しにしない。** markerLength <= 0 だけを見ると
            // NaN が両方の比較で false になって通ってしまう。
            if (float.IsNaN(markerLength) || markerLength <= 0f)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(markerLength), markerLength, "マーカーの 1 辺は 0 より大きくなければなりません。");
            }

            float half = markerLength / 2f;

            // **この並びは OCVU_SOLVEPNP_IPPE_SQUARE が要求するものである。**
            // 左上・右上・右下・左下の順で、中心が原点、y が上を向く。
            // 順を変えると OpenCV 側が「点の並びが違う」として投げる。
            var objectPoints = new[]
            {
                new CvPoint3(-half, half, 0f),
                new CvPoint3(half, half, 0f),
                new CvPoint3(half, -half, 0f),
                new CvPoint3(-half, -half, 0f),
            };

            // detectMarkers が返す 4 隅は、まさにその順に並んでいる。
            var imagePoints = new[]
            {
                marker.TopLeft,
                marker.TopRight,
                marker.BottomRight,
                marker.BottomLeft,
            };

            return CvGeometry.SolvePnP(
                objectPoints, imagePoints, cameraMatrix, distCoeffs, CvSolvePnPMethod.IppeSquare);
        }
    }
}
