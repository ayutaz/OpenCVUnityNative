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
    /// 特徴点の検出(OpenCV の features)。
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
    }
}
