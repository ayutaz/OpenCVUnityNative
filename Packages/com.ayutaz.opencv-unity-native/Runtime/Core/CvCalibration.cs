using System;
using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>
    /// 1 枚の view に対するカメラの姿勢。回転（軸角ベクトル）と並進を持つ。
    /// </summary>
    /// <remarks>
    /// 回転は Rodrigues の軸角ベクトルである —— 向きが回転軸、長さが回転角
    /// （ラジアン）を表す。行列でも四元数でもない。**この形は OpenCV が
    /// 返すものをそのまま出している。**
    /// <para>
    /// 座標系は OpenCV のもの（右手系、y が下向き、z が奥）である。
    /// Unity で使うには変換が要る —— **その変換はこの package が持っていない。**
    /// </para>
    /// </remarks>
    public readonly struct CvViewPose
    {
        /// <summary>回転ベクトルの x 成分。</summary>
        public double RotationX { get; }

        /// <summary>回転ベクトルの y 成分。</summary>
        public double RotationY { get; }

        /// <summary>回転ベクトルの z 成分。</summary>
        public double RotationZ { get; }

        /// <summary>並進の x 成分。単位は object 座標に渡したものと同じである。</summary>
        public double TranslationX { get; }

        /// <summary>並進の y 成分。</summary>
        public double TranslationY { get; }

        /// <summary>並進の z 成分。</summary>
        public double TranslationZ { get; }

        /// <summary>回転と並進から姿勢を作る。</summary>
        public CvViewPose(
            double rotationX, double rotationY, double rotationZ,
            double translationX, double translationY, double translationZ)
        {
            RotationX = rotationX;
            RotationY = rotationY;
            RotationZ = rotationZ;
            TranslationX = translationX;
            TranslationY = translationY;
            TranslationZ = translationZ;
        }
    }

    /// <summary>
    /// カメラ校正の結果。
    /// </summary>
    public sealed class CvCalibrationResult
    {
        /// <summary>
        /// カメラ行列（3x3 を行優先で並べた 9 個）。
        /// [0] が fx、[4] が fy、[2] が cx、[5] が cy である。
        /// </summary>
        public double[] CameraMatrix { get; }

        /// <summary>
        /// 歪み係数。**個数は OpenCV が決める**（4 / 5 / 8 / 12 / 14 のいずれか）。
        /// <see cref="CvCalibration.Undistort"/> にそのまま渡せる形である。
        /// </summary>
        public double[] DistortionCoefficients { get; }

        /// <summary>各 view のカメラ姿勢。渡した view と同じ順・同じ数で返る。</summary>
        public CvViewPose[] ViewPoses { get; }

        /// <summary>
        /// 再投影誤差（RMS、画素）。**小さいほど良い** —— 実用上は 1 画素を
        /// 大きく超えるなら、盤の検出か撮り方を疑う。
        /// </summary>
        public double ReprojectionError { get; }

        /// <summary>結果を作る。</summary>
        public CvCalibrationResult(
            double[] cameraMatrix,
            double[] distortionCoefficients,
            CvViewPose[] viewPoses,
            double reprojectionError)
        {
            CameraMatrix = cameraMatrix;
            DistortionCoefficients = distortionCoefficients;
            ViewPoses = viewPoses;
            ReprojectionError = reprojectionError;
        }
    }

    /// <summary>
    /// カメラ校正（OpenCV の imgproc / objdetect / calib）。
    /// </summary>
    /// <remarks>
    /// **校正は 3 段からなり、この 1 クラスがその全部を持つ。**
    /// (1) <see cref="FindChessboardCorners"/> で盤の格子点を見つけ、
    /// (2) <see cref="CalibrateCamera"/> で係数を求め、
    /// (3) <see cref="Undistort"/> でその係数を当てる。
    /// <para>
    /// 3 つの OpenCV module にまたがる（順に objdetect / calib / imgproc）が、
    /// **用途が 1 つなので C# 側では 1 クラスにまとめてある。**
    /// </para>
    /// </remarks>
    public static class CvCalibration
    {
        /// <summary>カメラ行列の要素数。3x3 で固定である。</summary>
        private const int CameraMatrixLength = 9;

        /// <summary>校正に要る view の最小数。平面パターンは 1 枚では解けない。</summary>
        private const int MinViews = 2;

        /// <summary>1 view に要る点の最小数。</summary>
        private const int MinPointsPerView = 4;

        /// <summary>
        /// 1 view ぶんの姿勢が占める double の個数。回転ベクトル 3 個のあとに
        /// 並進ベクトル 3 個が続く（native の契約がその並びである）。
        /// </summary>
        private const int PoseStride = 6;

        /// <summary>
        /// OpenCV が返しうる歪み係数の最大個数。受け取る buffer をこの大きさで
        /// 確保しておけば、実際に返る個数がいくつでも足りる。
        /// </summary>
        private const int MaxDistortionCoefficients = 14;

        /// <summary>
        /// C の OCVU_CALIB_MAX_POINTS の写しである。C# から C の #define は読めないので
        /// 複製しており、CalibrationTests の
        /// TheManagedCalibrationPointLimitMatchesWhatNativeAccepts が両側を native に
        /// 問うことで同期を守っている（MaxCorners と同じ形）。
        /// </summary>
        private const int MaxCalibrationPoints = 100000;

        /// <summary>
        /// C の OCVU_CHESSBOARD_MAX_CORNERS の写しである。C# から C の #define は読めないので
        /// 複製しており、CalibrationTests の TheManagedCornerLimitMatchesWhatNativeAccepts が
        /// 両側を native に問うことで同期を守っている（CvFeatures.MaxFeatures と同じ形）。
        /// </summary>
        private const int MaxCorners = 10000;

        /// <summary>
        /// src の歪みを補正して <paramref name="dst"/> に入れる。
        /// </summary>
        /// <remarks>
        /// <paramref name="dst"/> は結果に応じて丸ごと置き換わり、
        /// <paramref name="src"/> と同じ形状・型になる —— 呼び出し前に持っていた
        /// 形状・型・内容は保持されない。
        /// <paramref name="distCoeffs"/> は OpenCV が受ける長さ（4 / 5 / 8 / 12 / 14）
        /// でなければならない。**この一覧は OpenCV の都合であって、こちらの判断ではない。**
        /// </remarks>
        /// <param name="src">補正する画像。</param>
        /// <param name="cameraMatrix">行優先の 3x3（9 要素）。</param>
        /// <param name="distCoeffs">歪み係数。4 / 5 / 8 / 12 / 14 要素。</param>
        /// <param name="dst">結果を受け取る Mat。</param>
        public static void Undistort(CvMat src, double[] cameraMatrix, double[] distCoeffs, CvMat dst)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (cameraMatrix == null) { throw new ArgumentNullException(nameof(cameraMatrix)); }
            if (distCoeffs == null) { throw new ArgumentNullException(nameof(distCoeffs)); }
            if (dst == null) { throw new ArgumentNullException(nameof(dst)); }

            if (cameraMatrix.Length != CameraMatrixLength)
            {
                throw new ArgumentException(
                    $"カメラ行列は 3x3（{CameraMatrixLength} 要素）でなければなりません（渡されたのは {cameraMatrix.Length} 要素）。",
                    nameof(cameraMatrix));
            }

            if (!IsAcceptedCoefficientCount(distCoeffs.Length))
            {
                throw new ArgumentException(
                    $"歪み係数は 4 / 5 / 8 / 12 / 14 要素のいずれかでなければなりません（渡されたのは {distCoeffs.Length} 要素）。",
                    nameof(distCoeffs));
            }

            // 長さは native にも渡す（**バイト数** —— この ABI の length は全部そうである）。
            // **C# が正しく詰めたことを native は信用しない。**
            var status = (CvStatus)NativeMethods.ocvu_undistort(
                src.Handle,
                cameraMatrix, (long)cameraMatrix.Length * sizeof(double),
                distCoeffs, (long)distCoeffs.Length * sizeof(double),
                dst.Handle);
            CvNative.ThrowIfFailed(status);
        }

        /// <summary>
        /// src に写っているチェスボードの内側の格子点を見つける。
        /// 写っていなければ**空配列**を返す。
        /// </summary>
        /// <remarks>
        /// **空配列は誤りではない** —— 格子が写っていなかっただけである
        /// （入力の形が誤っている場合は例外になる）。
        /// 見つかったときは、返る点は <c>patternCols * patternRows</c> 個で、
        /// <see cref="CvGeometry.FindHomography"/> にそのまま渡せる形である。
        /// <paramref name="patternCols"/> * <paramref name="patternRows"/> は
        /// 10000 以下でなければならない（native の上限の写し）。
        /// </remarks>
        /// <param name="src">探す画像。</param>
        /// <param name="patternCols">内側の格子点の列数。2 以上。</param>
        /// <param name="patternRows">内側の格子点の行数。2 以上。</param>
        public static CvPoint2[] FindChessboardCorners(CvMat src, int patternCols, int patternRows)
        {
            if (src == null) { throw new ArgumentNullException(nameof(src)); }
            if (patternCols < 2)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(patternCols), patternCols, "格子の列数は 2 以上でなければなりません。");
            }
            if (patternRows < 2)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(patternRows), patternRows, "格子の行数は 2 以上でなければなりません。");
            }

            // **int のまま掛けない。** patternCols * patternRows を int で計算すると
            // 符号付き整数の乗算オーバーフロー（未定義動作）になりうる —— native 側で
            // 同じ危険を int64_t 化して塞いだのに（レビュー I3）、C# 側は int のまま
            // 残っていた（レビュー I4）。long で先に見て、native の門に届く前に断る。
            long pointCount = (long)patternCols * patternRows;
            if (pointCount > MaxCorners)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(patternRows), patternRows,
                    $"patternCols * patternRows は {MaxCorners} 以下でなければなりません" +
                    $"（渡されたのは {patternCols} x {patternRows} = {pointCount}）。");
            }

            // 必要量は事前に分かっているので 1 回で済む。
            // **capacity も out_count も float の個数である**（点の個数ではない）。
            // x と y の 2 つで 1 点なので、点数の 2 倍が float 数になる。
            // この単位は `ocvu_orb_detect` と同じ「capacity == 配列長」であり、
            // **要素数で数える規則がこの ABI 全体で 1 つだけになるようにしてある。**
            // pointCount は上で MaxCorners（10000）以下と確かめてあるので、
            // *2 と int への変換はここで安全に行える。
            int expectedFloats = (int)(pointCount * 2);
            var flat = new float[expectedFloats];

            var status = (CvStatus)NativeMethods.ocvu_find_chessboard_corners(
                src.Handle, patternCols, patternRows, flat, expectedFloats, out int floatCount);

            // **見つからないのは失敗ではない。** 呼ぶ側には空配列で返す。
            if (status == CvStatus.NotFound) { return Array.Empty<CvPoint2>(); }

            CvNative.ThrowIfFailed(status);

            // **BufferTooSmall は「失敗」ではないので ThrowIfFailed は素通しする**
            // （CvCodecs.cs と同じ理由）。capacity には常に flat.Length ちょうどを
            // 渡しているので、native が契約どおりに動く限り floatCount が
            // flat.Length を超えることは構造上ない —— **それでもここで見るのは、
            // native が誤った量を報告した場合や、この見積もりが将来変わった場合に、
            // 添字例外（IndexOutOfRangeException）ではなく原因の読める例外で
            // 止めるためである。** 公開 API 経由でこの分岐には到達できない。
            if (floatCount > flat.Length)
            {
                throw new CvNativeException(
                    status,
                    $"ocvu_find_chessboard_corners reported {floatCount} floats " +
                    $"but the buffer only holds {flat.Length}");
            }

            // native が返すのは float の個数なので、点に戻すのはここの仕事である。
            var corners = new CvPoint2[floatCount / 2];
            for (int i = 0; i < corners.Length; i++)
            {
                corners[i] = new CvPoint2(flat[i * 2], flat[(i * 2) + 1]);
            }
            return corners;
        }

        /// <summary>OpenCV が受け付ける歪み係数の個数か。</summary>
        private static bool IsAcceptedCoefficientCount(int count)
        {
            return count == 4 || count == 5 || count == 8 || count == 12 || count == 14;
        }

        /// <summary>
        /// 複数の view から撮った既知のパターンの対応点から、カメラの内部パラメータと
        /// 歪み係数、および各 view の姿勢を求める。
        /// </summary>
        /// <remarks>
        /// **これが校正の輪を閉じる段である。**
        /// <see cref="FindChessboardCorners"/> で格子点を見つけ、この関数で係数を求め、
        /// <see cref="Undistort"/> でその係数を当てる、という 3 段になる。
        /// <para>
        /// 平面のパターン（チェスボードなど）を使う場合、**view ごとに盤の向きを
        /// 変えて撮る必要がある。** 全部同じ向きだと解が定まらない。
        /// </para>
        /// <para>
        /// <paramref name="objectPoints"/> と <paramref name="imagePoints"/> は
        /// view ごとの配列で、**view の数も、view ごとの点の数も一致していなければ
        /// ならない。** 揃っていなければ例外になる —— native は点数を 1 つしか
        /// 受け取らないので、食い違いは C# の入口でしか見えない。
        /// </para>
        /// </remarks>
        /// <param name="objectPoints">view ごとのパターンの 3D 座標。</param>
        /// <param name="imagePoints">view ごとの、対応する画像上の座標。</param>
        /// <param name="imageWidth">画像の幅（画素）。1 以上。</param>
        /// <param name="imageHeight">画像の高さ（画素）。1 以上。</param>
        public static CvCalibrationResult CalibrateCamera(
            CvPoint3[][] objectPoints,
            CvPoint2[][] imagePoints,
            int imageWidth,
            int imageHeight)
        {
            if (objectPoints == null) { throw new ArgumentNullException(nameof(objectPoints)); }
            if (imagePoints == null) { throw new ArgumentNullException(nameof(imagePoints)); }

            if (imageWidth < 1)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(imageWidth), imageWidth, "画像の幅は 1 以上でなければなりません。");
            }
            if (imageHeight < 1)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(imageHeight), imageHeight, "画像の高さは 1 以上でなければなりません。");
            }

            if (objectPoints.Length != imagePoints.Length)
            {
                throw new ArgumentException(
                    $"view の数が一致していません（{objectPoints.Length} と {imagePoints.Length}）。",
                    nameof(imagePoints));
            }

            int viewCount = objectPoints.Length;
            if (viewCount < MinViews)
            {
                throw new ArgumentException(
                    $"校正には {MinViews} 枚以上の view が要ります（渡されたのは {viewCount} 枚）。" +
                    "平面のパターンは 1 枚では解けません。",
                    nameof(objectPoints));
            }

            // **view ごとの点数が揃っていることは、ここでしか見られない。**
            // native は points_per_view を 1 つしか受け取らないので、
            // ばらばらの配列を渡されても食い違いが見えない。
            if (objectPoints[0] == null)
            {
                throw new ArgumentException("view 0 の 3D 座標が null です。", nameof(objectPoints));
            }
            int pointsPerView = objectPoints[0].Length;
            if (pointsPerView < MinPointsPerView)
            {
                throw new ArgumentException(
                    $"1 view につき {MinPointsPerView} 点以上が要ります（渡されたのは {pointsPerView} 点）。",
                    nameof(objectPoints));
            }

            for (int v = 0; v < viewCount; v++)
            {
                if (objectPoints[v] == null)
                {
                    throw new ArgumentException($"view {v} の 3D 座標が null です。", nameof(objectPoints));
                }
                if (imagePoints[v] == null)
                {
                    throw new ArgumentException($"view {v} の画像座標が null です。", nameof(imagePoints));
                }
                if (objectPoints[v].Length != pointsPerView)
                {
                    throw new ArgumentException(
                        $"view {v} の点数が view 0 と違います（{objectPoints[v].Length} と {pointsPerView}）。",
                        nameof(objectPoints));
                }
                if (imagePoints[v].Length != pointsPerView)
                {
                    throw new ArgumentException(
                        $"view {v} の画像座標の点数が 3D 座標と違います（{imagePoints[v].Length} と {pointsPerView}）。",
                        nameof(imagePoints));
                }
            }

            // **long で先に掛けてから見る。** int のまま掛けると、門に届く前に
            // 溢れる（native 側も同じ理由で int64_t を使っている）。
            long totalPoints = (long)viewCount * pointsPerView;
            if (totalPoints > MaxCalibrationPoints)
            {
                throw new ArgumentException(
                    $"点の総数が上限を超えています（{totalPoints} > {MaxCalibrationPoints}）。",
                    nameof(objectPoints));
            }

            var flatObject = new float[totalPoints * 3];
            var flatImage = new float[totalPoints * 2];
            for (int v = 0; v < viewCount; v++)
            {
                for (int i = 0; i < pointsPerView; i++)
                {
                    long index = ((long)v * pointsPerView) + i;
                    CvPoint3 o = objectPoints[v][i];
                    flatObject[(index * 3) + 0] = o.X;
                    flatObject[(index * 3) + 1] = o.Y;
                    flatObject[(index * 3) + 2] = o.Z;

                    CvPoint2 p = imagePoints[v][i];
                    flatImage[(index * 2) + 0] = p.X;
                    flatImage[(index * 2) + 1] = p.Y;
                }
            }

            var cameraMatrix = new double[CameraMatrixLength];
            var distCoeffs = new double[MaxDistortionCoefficients];
            var viewPoses = new double[(long)viewCount * PoseStride];

            // **長さは byte、capacity は要素数。** この ABI では 2 つの単位が
            // 引数の役割で決まっている（in-buffer は byte、out-buffer は要素数）。
            var status = (CvStatus)NativeMethods.ocvu_calibrate_camera(
                flatObject, (long)flatObject.Length * sizeof(float),
                flatImage, (long)flatImage.Length * sizeof(float),
                viewCount, pointsPerView, imageWidth, imageHeight,
                cameraMatrix, cameraMatrix.Length,
                distCoeffs, distCoeffs.Length,
                out int distCount,
                viewPoses, viewPoses.Length,
                out double rms);

            CvNative.ThrowIfFailed(status);

            // **BufferTooSmall は「失敗」ではないので ThrowIfFailed は素通しする**
            // （CvCodecs.cs と同じ理由）。capacity には native が受け付ける最大の
            // 係数の個数を渡しているので、契約どおりに動く限りここには来ない ——
            // **それでも見るのは、native が誤った量を報告した場合に、添字例外では
            // なく原因の読める例外で止めるためである。**
            if (status == CvStatus.BufferTooSmall || distCount < 0 || distCount > distCoeffs.Length)
            {
                throw new CvNativeException(
                    status,
                    $"ocvu_calibrate_camera reported {distCount} coefficients " +
                    $"but the buffer only holds {distCoeffs.Length}");
            }

            var coefficients = new double[distCount];
            Array.Copy(distCoeffs, coefficients, distCount);

            var poses = new CvViewPose[viewCount];
            for (int v = 0; v < viewCount; v++)
            {
                int b = v * PoseStride;
                // **回転が先、並進が後。** native の契約がその並びである。
                poses[v] = new CvViewPose(
                    viewPoses[b + 0], viewPoses[b + 1], viewPoses[b + 2],
                    viewPoses[b + 3], viewPoses[b + 4], viewPoses[b + 5]);
            }

            return new CvCalibrationResult(cameraMatrix, coefficients, poses, rms);
        }

    }
}
