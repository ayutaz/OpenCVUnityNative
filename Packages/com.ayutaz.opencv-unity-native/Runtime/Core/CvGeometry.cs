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
    /// 1 枚ぶんの姿勢の求め方。
    /// </summary>
    /// <remarks>
    /// 値は C の <c>OCVU_SOLVEPNP_*</c> の写しである。C# から C の
    /// <c>#define</c> は読めないので複製しており、<c>PoseTests</c> の
    /// <c>TheManagedMethodValuesMatchWhatNativeAccepts</c> が両側を native に
    /// 問うことで同期を守っている（<see cref="CvHomographyMethod"/> と同じ形）。
    /// <para>
    /// **どれを選ぶかで受け付ける入力が変わる。** <see cref="P3p"/> と
    /// <see cref="Ap3p"/> は**ちょうど 4 点**しか受け付けず、
    /// <see cref="IppeSquare"/> は 1 辺が既知の正方形専用で**点の並び順が
    /// 決まっている**（左上・右上・右下・左下）。決まっていないなら
    /// <see cref="Iterative"/> でよい。
    /// </para>
    /// </remarks>
    public enum CvSolvePnPMethod
    {
        /// <summary>既定。平面上の 4 点でも非平面の 6 点でも解ける。</summary>
        Iterative = 0,

        /// <summary>EPnP。点数が多いときに速い。</summary>
        Epnp = 1,

        /// <summary>P3P。**ちょうど 4 点**しか受け付けない。</summary>
        P3p = 2,

        /// <summary>AP3P。**ちょうど 4 点**しか受け付けない。</summary>
        Ap3p = 3,

        /// <summary>平面上の点専用（4 点以上）。</summary>
        Ippe = 4,

        /// <summary>
        /// 1 辺が既知の正方形マーカー専用。**点の並び順が決まっている** ——
        /// 左上・右上・右下・左下である。ArUco の 4 隅はその順で返るので
        /// そのまま渡せる（<see cref="CvAruco.EstimateMarkerPose"/> がそうしている）。
        /// </summary>
        IppeSquare = 5,

        /// <summary>SQPnP。</summary>
        SqPnp = 6,
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

        /// <summary>1 枚ぶんの姿勢を決めるのに要る最小の点数。</summary>
        private const int MinPnpPoints = 4;

        /// <summary>
        /// C の OCVU_PNP_MAX_POINTS の写しである。C# から C の #define は読めないので
        /// 複製しており、PoseTests の TheManagedPointLimitMatchesWhatNativeAccepts が
        /// 両側を native に問うことで同期を守っている
        /// （CvCalibration.MaxCalibrationPoints と同じ形）。
        /// </summary>
        private const int MaxPnpPoints = 10000;

        /// <summary>カメラ行列の要素数。3x3 で固定である。</summary>
        private const int CameraMatrixLength = 9;

        /// <summary>回転ベクトル・並進ベクトルの要素数。</summary>
        private const int Vector3Length = 3;

        /// <summary>3x3 の回転行列の要素数。</summary>
        private const int Matrix3x3Length = 9;

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

        /// <summary>
        /// 既知の 3D 点と、その画像上の対応点、カメラの内部パラメータから
        /// 1 枚ぶんの姿勢を求める。
        /// </summary>
        /// <remarks>
        /// 返る回転は Rodrigues の軸角ベクトルである（<see cref="CvViewPose"/> の
        /// 説明を参照）。行列が要るなら <see cref="RodriguesToMatrix"/> に渡す。
        /// <para>
        /// **姿勢が求まらなかったときは例外になる** —— <see cref="CvNativeException"/> の
        /// <see cref="CvNativeException.Status"/> が <see cref="CvStatus.NotFound"/> に
        /// なる。<see cref="FindHomography"/> が false を返すのと違って戻り値で
        /// 区別できないのは、姿勢を表す「解が無い」値がこの型に無いためである。
        /// </para>
        /// <para>
        /// <paramref name="distCoeffs"/> は <c>null</c> か空配列で「歪み無し」を
        /// 指定できる。それ以外は OpenCV が受ける長さ（4 / 5 / 8 / 12 / 14）で
        /// なければならない。**<see cref="CvCalibration.Undistort"/> は空を
        /// 受け付けない** —— 向こうは歪みを当てるのが仕事なので、係数が無いと
        /// 問いが成立しないからである。
        /// </para>
        /// <para>
        /// <paramref name="cameraMatrix"/> の [0] と [4]（fx と fy）は 0 で
        /// あってはならない。**OpenCV は焦点距離が 0 のカメラ行列を検出せず、
        /// 有限だが無意味な姿勢を成功として返す**（native 側の実測）ので、
        /// 境界がそこだけを見て断る。
        /// </para>
        /// </remarks>
        /// <param name="objectPoints">既知の 3D 点。4 点以上 10000 点以下。</param>
        /// <param name="imagePoints">対応する画像上の点。同じ数・同じ順。</param>
        /// <param name="cameraMatrix">行優先の 3x3（9 要素）。</param>
        /// <param name="distCoeffs">歪み係数。<c>null</c> か空で歪み無し。</param>
        /// <param name="method">求め方。既定は <see cref="CvSolvePnPMethod.Iterative"/>。</param>
        public static CvViewPose SolvePnP(
            CvPoint3[] objectPoints,
            CvPoint2[] imagePoints,
            double[] cameraMatrix,
            double[] distCoeffs,
            CvSolvePnPMethod method = CvSolvePnPMethod.Iterative)
        {
            if (objectPoints == null) { throw new ArgumentNullException(nameof(objectPoints)); }
            if (imagePoints == null) { throw new ArgumentNullException(nameof(imagePoints)); }

            // **2 つの点列が同じ長さであることは、ここでしか見られない。**
            // native は point_count を 1 つしか受け取らないので、片方だけが
            // 長い入力は向こうから見て正常である（FindHomography と同じ理由）。
            if (objectPoints.Length != imagePoints.Length)
            {
                throw new ArgumentException(
                    $"2 つの点列は同じ長さでなければなりません（{objectPoints.Length} と {imagePoints.Length}）。",
                    nameof(imagePoints));
            }
            if (objectPoints.Length < MinPnpPoints)
            {
                throw new ArgumentException(
                    $"姿勢推定には {MinPnpPoints} 点以上が要ります（渡されたのは {objectPoints.Length} 点）。",
                    nameof(objectPoints));
            }
            if (objectPoints.Length > MaxPnpPoints)
            {
                throw new ArgumentException(
                    $"点の数は {MaxPnpPoints} 以下でなければなりません（渡されたのは {objectPoints.Length} 点）。",
                    nameof(objectPoints));
            }

            ValidateCameraMatrix(cameraMatrix);
            double[] coefficients = NormalizeDistCoefficients(distCoeffs, nameof(distCoeffs));

            var flatObject = Flatten(objectPoints);
            var flatImage = Flatten(imagePoints);

            var rotation = new double[Vector3Length];
            var translation = new double[Vector3Length];

            // **長さは byte、capacity は要素数。** この ABI では 2 つの単位が
            // 引数の役割で決まっている（CvCalibration と同じ）。
            var status = (CvStatus)NativeMethods.ocvu_solve_pnp(
                flatObject, (long)flatObject.Length * sizeof(float),
                flatImage, (long)flatImage.Length * sizeof(float),
                objectPoints.Length,
                cameraMatrix, (long)cameraMatrix.Length * sizeof(double),
                coefficients, CoefficientBytes(coefficients),
                (int)method,
                rotation, rotation.Length,
                translation, translation.Length);

            CvNative.ThrowIfFailed(status);
            ThrowIfBufferTooSmall(status, "ocvu_solve_pnp", Vector3Length);

            return new CvViewPose(
                rotation[0], rotation[1], rotation[2],
                translation[0], translation[1], translation[2]);
        }

        /// <summary>
        /// 姿勢が持つ Rodrigues の回転ベクトルを 3x3 の回転行列に直す。
        /// 返るのは行優先に並べた 9 要素である。
        /// </summary>
        /// <remarks>
        /// **並進は見ない。** 変換するのは回転だけである。
        /// </remarks>
        /// <param name="pose">回転ベクトルを持つ姿勢。</param>
        public static double[] RodriguesToMatrix(CvViewPose pose)
        {
            var rotation = new[] { pose.RotationX, pose.RotationY, pose.RotationZ };
            var matrix = new double[Matrix3x3Length];

            var status = (CvStatus)NativeMethods.ocvu_rodrigues_to_matrix(
                rotation, (long)rotation.Length * sizeof(double),
                matrix, matrix.Length);

            CvNative.ThrowIfFailed(status);
            ThrowIfBufferTooSmall(status, "ocvu_rodrigues_to_matrix", Matrix3x3Length);
            return matrix;
        }

        /// <summary>
        /// 3x3 の回転行列（行優先の 9 要素）を Rodrigues の回転ベクトル（3 要素）に直す。
        /// </summary>
        /// <remarks>
        /// **入力が回転行列でないときの扱いは OpenCV に委ねている。**
        /// この境界は要素数しか見ない。
        /// </remarks>
        /// <param name="rotationMatrix">行優先の 3x3（9 要素）。</param>
        public static double[] RodriguesToVector(double[] rotationMatrix)
        {
            if (rotationMatrix == null) { throw new ArgumentNullException(nameof(rotationMatrix)); }
            if (rotationMatrix.Length != Matrix3x3Length)
            {
                throw new ArgumentException(
                    $"回転行列は 3x3（{Matrix3x3Length} 要素）でなければなりません（渡されたのは {rotationMatrix.Length} 要素）。",
                    nameof(rotationMatrix));
            }

            var vector = new double[Vector3Length];

            var status = (CvStatus)NativeMethods.ocvu_rodrigues_to_vector(
                rotationMatrix, (long)rotationMatrix.Length * sizeof(double),
                vector, vector.Length);

            CvNative.ThrowIfFailed(status);
            ThrowIfBufferTooSmall(status, "ocvu_rodrigues_to_vector", Vector3Length);
            return vector;
        }

        /// <summary>
        /// 3D の点を、与えた姿勢とカメラの内部パラメータで画像平面へ投影する。
        /// </summary>
        /// <remarks>
        /// **<see cref="SolvePnP"/> の逆である。** 同じ姿勢を渡せば、
        /// 姿勢を求めるのに使った画像点が返ってくる。
        /// <paramref name="distCoeffs"/> の扱いは <see cref="SolvePnP"/> と同じで、
        /// <c>null</c> か空で歪み無しになる。
        /// </remarks>
        /// <param name="objectPoints">投影する 3D 点。1 点以上 10000 点以下。</param>
        /// <param name="pose">カメラから見た姿勢。</param>
        /// <param name="cameraMatrix">行優先の 3x3（9 要素）。</param>
        /// <param name="distCoeffs">歪み係数。<c>null</c> か空で歪み無し。</param>
        public static CvPoint2[] ProjectPoints(
            CvPoint3[] objectPoints,
            CvViewPose pose,
            double[] cameraMatrix,
            double[] distCoeffs)
        {
            if (objectPoints == null) { throw new ArgumentNullException(nameof(objectPoints)); }

            // **姿勢は与えられているので 4 点は要らない。** 1 点でも投影できる。
            if (objectPoints.Length < 1)
            {
                throw new ArgumentException("投影する点が 1 つもありません。", nameof(objectPoints));
            }
            if (objectPoints.Length > MaxPnpPoints)
            {
                throw new ArgumentException(
                    $"点の数は {MaxPnpPoints} 以下でなければなりません（渡されたのは {objectPoints.Length} 点）。",
                    nameof(objectPoints));
            }

            ValidateCameraMatrix(cameraMatrix);
            double[] coefficients = NormalizeDistCoefficients(distCoeffs, nameof(distCoeffs));

            var flatObject = Flatten(objectPoints);
            var rotation = new[] { pose.RotationX, pose.RotationY, pose.RotationZ };
            var translation = new[] { pose.TranslationX, pose.TranslationY, pose.TranslationZ };

            // 点数は上で MaxPnpPoints 以下と確かめてあるので、2 倍しても int に収まる。
            var flatImage = new float[objectPoints.Length * 2];

            var status = (CvStatus)NativeMethods.ocvu_project_points(
                flatObject, (long)flatObject.Length * sizeof(float),
                objectPoints.Length,
                rotation, (long)rotation.Length * sizeof(double),
                translation, (long)translation.Length * sizeof(double),
                cameraMatrix, (long)cameraMatrix.Length * sizeof(double),
                coefficients, CoefficientBytes(coefficients),
                flatImage, flatImage.Length);

            CvNative.ThrowIfFailed(status);
            ThrowIfBufferTooSmall(status, "ocvu_project_points", flatImage.Length);

            var projected = new CvPoint2[objectPoints.Length];
            for (int i = 0; i < projected.Length; i++)
            {
                projected[i] = new CvPoint2(flatImage[i * 2], flatImage[(i * 2) + 1]);
            }
            return projected;
        }

        /// <summary>カメラ行列が 3x3 として渡せる形かを見る。</summary>
        private static void ValidateCameraMatrix(double[] cameraMatrix)
        {
            if (cameraMatrix == null) { throw new ArgumentNullException(nameof(cameraMatrix)); }
            if (cameraMatrix.Length != CameraMatrixLength)
            {
                throw new ArgumentException(
                    $"カメラ行列は 3x3（{CameraMatrixLength} 要素）でなければなりません（渡されたのは {cameraMatrix.Length} 要素）。",
                    nameof(cameraMatrix));
            }
        }

        /// <summary>
        /// 歪み係数を native に渡せる形にする。<c>null</c> と空配列はどちらも
        /// 「歪み無し」を意味し、<c>null</c> に揃える（長さ 0 が正規の指定である）。
        /// </summary>
        private static double[] NormalizeDistCoefficients(double[] distCoeffs, string parameterName)
        {
            if (distCoeffs == null || distCoeffs.Length == 0) { return null; }

            if (!(distCoeffs.Length == 4 || distCoeffs.Length == 5 || distCoeffs.Length == 8 ||
                  distCoeffs.Length == 12 || distCoeffs.Length == 14))
            {
                throw new ArgumentException(
                    "歪み係数は 4 / 5 / 8 / 12 / 14 要素のいずれか、または空でなければなりません" +
                    $"（渡されたのは {distCoeffs.Length} 要素）。",
                    parameterName);
            }
            return distCoeffs;
        }

        /// <summary>歪み係数のバイト数。歪み無し（null）なら 0 である。</summary>
        private static long CoefficientBytes(double[] coefficients)
        {
            return coefficients == null ? 0L : (long)coefficients.Length * sizeof(double);
        }

        /// <summary>
        /// **BufferTooSmall は「失敗」ではないので <see cref="CvNative.ThrowIfFailed"/> は
        /// 素通しする**（CvCodecs.cs と同じ理由）。この 4 本はどれも必要量を事前に
        /// 知って capacity ちょうどを渡しているので、native が契約どおりに動く限り
        /// ここには来ない —— **それでも見るのは、native が容量を誤って判定した
        /// 場合に、初期化されていない配列を黙って返さないためである。**
        /// </summary>
        private static void ThrowIfBufferTooSmall(CvStatus status, string who, int capacity)
        {
            if (status != CvStatus.BufferTooSmall) { return; }

            // **CvStatus.BufferTooSmall を載せて投げない。** あれは
            // CvNative.IsFailure から外してある「失敗ではない」status なので、
            // 例外の Status に載せると受け取った側の判定と食い違う。
            throw new CvNativeException(
                CvStatus.UnknownError,
                $"{who} reported that {capacity} elements do not fit in a {capacity} element array");
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

        /// <summary>x と y と z が順に並ぶ配列にする。native が読む形である。</summary>
        private static float[] Flatten(CvPoint3[] points)
        {
            var flat = new float[points.Length * 3];
            for (int i = 0; i < points.Length; i++)
            {
                flat[i * 3] = points[i].X;
                flat[(i * 3) + 1] = points[i].Y;
                flat[(i * 3) + 2] = points[i].Z;
            }
            return flat;
        }
    }
}
