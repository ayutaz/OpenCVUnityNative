using System;
using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>
    /// カメラの歪み補正と、較正パターンの検出(OpenCV の imgproc と objdetect)。
    /// </summary>
    /// <remarks>
    /// **calib module は使っていない。** 歪みを当てる undistort は imgproc、
    /// 較正パターンを見つける findChessboardCorners は objdetect にあり、
    /// どちらも既にリンク済みである。**係数を求める calibrateCamera だけが
    /// calib にあり、それはまだ出していない**(構成ハッシュが変わるため。
    /// 詳細は docs/roadmap.md の M5 節)。
    /// </remarks>
    public static class CvCalibration
    {
        /// <summary>カメラ行列の要素数。3x3 で固定である。</summary>
        private const int CameraMatrixLength = 9;

        /// <summary>
        /// src の歪みを補正して <paramref name="dst"/> に入れる。
        /// </summary>
        /// <remarks>
        /// <paramref name="dst"/> は結果に応じて丸ごと置き換わり、
        /// <paramref name="src"/> と同じ形状・型になる —— 呼び出し前に持っていた
        /// 形状・型・内容は保持されない。
        /// <paramref name="distCoeffs"/> は OpenCV が受ける長さ(4 / 5 / 8 / 12 / 14)
        /// でなければならない。**この一覧は OpenCV の都合であって、こちらの判断ではない。**
        /// </remarks>
        /// <param name="src">補正する画像。</param>
        /// <param name="cameraMatrix">行優先の 3x3(9 要素)。</param>
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
                    $"カメラ行列は 3x3({CameraMatrixLength} 要素)でなければなりません(渡されたのは {cameraMatrix.Length} 要素)。",
                    nameof(cameraMatrix));
            }

            if (!IsAcceptedCoefficientCount(distCoeffs.Length))
            {
                throw new ArgumentException(
                    $"歪み係数は 4 / 5 / 8 / 12 / 14 要素のいずれかでなければなりません(渡されたのは {distCoeffs.Length} 要素)。",
                    nameof(distCoeffs));
            }

            // 長さは native にも渡す(**バイト数** —— この ABI の length は全部そうである)。
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
        /// (入力の形が誤っている場合は例外になる)。
        /// 返る点は <c>patternCols * patternRows</c> 個で、
        /// <see cref="CvGeometry.FindHomography"/> にそのまま渡せる形である。
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

            // 必要量は事前に分かっているので 1 回で済む。
            // **capacity も out_count も float の個数である**(点の個数ではない)。
            // x と y の 2 つで 1 点なので、点数の 2 倍が float 数になる。
            // この単位は `ocvu_orb_detect` と同じ「capacity == 配列長」であり、
            // **要素数で数える規則がこの ABI 全体で 1 つだけになるようにしてある。**
            int expectedFloats = patternCols * patternRows * 2;
            var flat = new float[expectedFloats];

            var status = (CvStatus)NativeMethods.ocvu_find_chessboard_corners(
                src.Handle, patternCols, patternRows, flat, expectedFloats, out int floatCount);

            // **見つからないのは失敗ではない。** 呼ぶ側には空配列で返す。
            if (status == CvStatus.NotFound) { return Array.Empty<CvPoint2>(); }

            CvNative.ThrowIfFailed(status);

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
    }
}
