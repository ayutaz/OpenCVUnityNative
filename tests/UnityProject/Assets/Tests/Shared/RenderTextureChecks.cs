using CvUnity;
using CvUnity.Unity;
using Unity.Collections;
using UnityEngine;

namespace CvUnity.Tests.Shared
{
    /// <summary>
    /// RenderTexture から CvMat を作る経路を、Unity の中で検証する。
    ///
    /// **本体はここにしか無い。** EditMode / PlayMode が写しを持つと、
    /// 片方だけ直って「Editor と Player で同じ結果」を確かめられなくなる。
    ///
    /// **件数はここに書かない** —— 数えるのは各入口の
    /// EveryCheckInTheSharedBodyIsWiredIntoThisEntryPoint である。
    ///
    /// **GPU に依らない検査だけをここに置く。** `RenderTextureConverter.ToMat`
    /// 自体が RenderTexture を経由するので既存レーン（`-nographics`）では
    /// 確かめられない —— `FillFlipped` を内部関数として切り出し、
    /// `NativeArray&lt;byte&gt;` を直接渡す形でここから検証する。
    /// GPU に依る検査は `GraphicsChecks`（`test-unity-graphics` レーン）にある。
    /// </summary>
    public static class RenderTextureChecks
    {
        /// <summary>
        /// FillFlipped が Unity の並び（y=0 が下端）を、OpenCV の並び
        /// （行 0 が上端）へ正しく入れ替えること。**全画素で確かめる。**
        /// </summary>
        public static void FillFlippedPutsTheTopRowFirst()
        {
            const int width = 4;
            const int height = 4;
            var raw = new NativeArray<byte>(
                width * height * 4, Allocator.Temp,
                NativeArrayOptions.UninitializedMemory);
            try
            {
                // Unity の向き: y=0 は下端。上半分（y >= height/2）を赤、
                // 下半分（y < height/2）を青で埋める。
                for (int y = 0; y < height; y++)
                {
                    var color = y >= height / 2
                        ? new Color32(200, 0, 0, 255)
                        : new Color32(0, 0, 200, 255);
                    for (int x = 0; x < width; x++)
                    {
                        int i = (y * width + x) * 4;
                        raw[i + 0] = color.r;
                        raw[i + 1] = color.g;
                        raw[i + 2] = color.b;
                        raw[i + 3] = color.a;
                    }
                }

                using var mat = CvMat.Create(height, width, CvMatType.Bgra32);
                RenderTextureConverter.FillFlipped(mat, raw, width, height);

                var got = new byte[width * height * 4];
                mat.CopyTo(got, width * 4);

                // Mat の行 0 は画像の上端。Unity では上半分が赤なので、
                // 反転が掛かっていれば行 0 は赤である。
                for (int x = 0; x < width; x++)
                {
                    int i = (0 * width + x) * 4;
                    Check.AreEqual((byte)200, got[i + 0], $"行 0 列 {x} は赤(R)であること");
                    Check.AreEqual((byte)0, got[i + 2], $"行 0 列 {x} は赤(B=0)であること");
                }
                // Mat の最終行は画像の下端。Unity では下半分が青。
                for (int x = 0; x < width; x++)
                {
                    int i = ((height - 1) * width + x) * 4;
                    Check.AreEqual((byte)0, got[i + 0], $"最終行 列 {x} は青(R=0)であること");
                    Check.AreEqual((byte)200, got[i + 2], $"最終行 列 {x} は青(B)であること");
                }
            }
            finally { raw.Dispose(); }
        }

        /// <summary>
        /// FillFlipped が反転の途中で 1 バイトも取りこぼさないこと。
        /// 「1 行だけ書いて残りは 0」を排除する。
        /// </summary>
        public static void FillFlippedPreservesEveryByte()
        {
            const int width = 8;
            const int height = 8;
            int total = width * height * 4;

            var raw = new NativeArray<byte>(
                total, Allocator.Temp,
                NativeArrayOptions.UninitializedMemory);
            try
            {
                // 0..255 を順に詰める（256 を超えたら折り返す）。
                for (int i = 0; i < total; i++) { raw[i] = (byte)i; }

                using var mat = CvMat.Create(height, width, CvMatType.Bgra32);
                RenderTextureConverter.FillFlipped(mat, raw, width, height);

                var got = new byte[total];
                mat.CopyTo(got, width * 4);

                long rowBytes = width * 4;
                for (int y = 0; y < height; y++)
                {
                    // Unity の y 行目は、OpenCV では (height - 1 - y) 行目に
                    // **1 バイトも欠けずに**現れる。
                    int dstRow = height - 1 - y;
                    for (int b = 0; b < rowBytes; b++)
                    {
                        byte expected = raw[(int)(y * rowBytes + b)];
                        byte actual = got[(int)(dstRow * rowBytes + b)];
                        Check.AreEqual(expected, actual,
                            $"y={y} の byte {b} が行 {dstRow} に欠けずに在ること");
                    }
                }
            }
            finally { raw.Dispose(); }
        }

        /// <summary>
        /// 引数検証は GPU に触る前に行われるので、既存レーンで確かめられる。
        /// </summary>
        public static void ToMatRejectsNull()
        {
            Check.Throws<System.ArgumentNullException>(() => RenderTextureConverter.ToMat(null));
        }
    }
}
