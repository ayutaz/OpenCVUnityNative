using CvUnity;
using CvUnity.Unity;
using UnityEngine;

namespace CvUnity.Tests.Shared
{
    /// <summary>
    /// RenderTexture から CvMat を作る経路のうち、**GPU に依る部分**を検証する。
    ///
    /// **本体はここにしか無い。** EditMode / PlayMode が写しを持つと、
    /// 片方だけ直って「Editor と Player で同じ結果」を確かめられなくなる。
    ///
    /// **なぜ `RenderTextureChecks` と別ファイルなのか。** 混ぜると、既存の
    /// EditMode / PlayMode レーン（`-nographics` で走る）が GPU 検査を拾って
    /// しまう。このクラスは `test-unity-graphics` レーン（`-testCategory
    /// 'Graphics'`、`-nographics` を渡さない）だけが走らせる。既存の
    /// `test-unity-editmode` は逆に `-testCategory '!Graphics'` でこの
    /// クラスを除外する（`GraphicsTests` の `[Category("Graphics")]`）。
    ///
    /// **`-nographics` の下では確かめられない。** 実測（2026-09-05、
    /// このマシン、Unity 6000.3.16f1）: `-nographics` では
    /// `SystemInfo.graphicsDeviceType` が Null、`RenderTexture.Create()` は
    /// true を返す（誤解を招く）のに `GL.Clear(10,20,30)` → `ReadPixels` は
    /// 205,205,205 を返す —— 何も描画されていない。グラフィックスを有効に
    /// すると Direct3D11 になり、期待どおり 10,20,30 が返る。
    /// </summary>
    public static class GraphicsChecks
    {
        internal const int Size = 8;

        /// <summary>
        /// このレーンがグラフィックス装置を要求すること。
        ///
        /// **これは SKIP ではない。** 装置が無ければ落ちる。
        /// 「道具が無いから飛ばす」経路を作らないための形である
        /// （`RenderTexture.Create()` が true を返すので、装置の有無は
        /// `graphicsDeviceType` でしか分からない）。
        /// </summary>
        public static void AGraphicsDeviceIsPresent()
        {
            Check.IsTrue(
                SystemInfo.graphicsDeviceType != UnityEngine.Rendering.GraphicsDeviceType.Null,
                "このレーンはグラフィックス装置を要求する。-nographics で起動していないか");
        }

        /// <summary>
        /// 既知の色で塗った RenderTexture が、そのままの画素で Mat になること。
        ///
        /// **Unity は左下原点、OpenCV は左上原点である。** ReadPixels は
        /// Unity の向きで読むので、上下が反転する。ここでは
        /// **単色で塗って向きに依存しない形**にしてある —— 向きそのものは
        /// 下の VerticalFlipIsApplied が縞模様で見る。
        /// </summary>
        public static void SyncReadbackProducesTheExpectedPixels()
        {
            var rt = MakeSolid(new Color32(10, 20, 30, 255));
            try
            {
                using var mat = RenderTextureConverter.ToMat(rt);

                Check.AreEqual(Size, mat.Rows);
                Check.AreEqual(Size, mat.Cols);
                Check.AreEqual(4, mat.Channels, "RGBA32 は 4 channel であること");

                var got = new byte[Size * Size * 4];
                mat.CopyTo(got, Size * 4);

                // **全画素を見る。** 先頭 1 画素だけを見ると、
                // 「1 行だけ書いて残りは 0」でも通ってしまう。
                for (int i = 0; i < Size * Size; i++)
                {
                    Check.AreEqual((byte)10, got[i * 4 + 0], $"画素 {i} の R");
                    Check.AreEqual((byte)20, got[i * 4 + 1], $"画素 {i} の G");
                    Check.AreEqual((byte)30, got[i * 4 + 2], $"画素 {i} の B");
                    Check.AreEqual((byte)255, got[i * 4 + 3], $"画素 {i} の A");
                }
            }
            finally { Release(rt); }
        }

        /// <summary>
        /// **上下反転が実際に掛かっていること。**
        ///
        /// Unity は左下原点、OpenCV は左上原点なので、変換は上下を返す。
        /// 単色では確かめられないので、**上半分と下半分で色を変えて**見る。
        /// WebCamTextureConverter が既定で反転するのと同じ規約である。
        /// </summary>
        public static void VerticalFlipIsApplied()
        {
            var rt = MakeHalves(new Color32(200, 0, 0, 255), new Color32(0, 0, 200, 255));
            try
            {
                using var mat = RenderTextureConverter.ToMat(rt);
                var got = new byte[Size * Size * 4];
                mat.CopyTo(got, Size * 4);

                // Unity では「上半分が赤」。OpenCV の行 0 は画像の上端なので、
                // 反転が掛かっていれば行 0 は赤である。
                Check.AreEqual((byte)200, got[0 * Size * 4 + 0], "Mat の行 0 は赤であること");
                int last = (Size - 1) * Size * 4;
                Check.AreEqual((byte)200, got[last + 2], "Mat の最終行は青であること");
            }
            finally { Release(rt); }
        }

        internal static RenderTexture MakeSolid(Color32 color)
        {
            var rt = new RenderTexture(Size, Size, 0, RenderTextureFormat.ARGB32)
            {
                enableRandomWrite = false,
            };
            rt.Create();

            var prev = RenderTexture.active;
            RenderTexture.active = rt;
            GL.Clear(true, true, color);
            RenderTexture.active = prev;
            return rt;
        }

        internal static RenderTexture MakeHalves(Color32 top, Color32 bottom)
        {
            // GL.Clear では 2 色に塗れないので、Texture2D を作って Blit する。
            var src = new Texture2D(Size, Size, TextureFormat.RGBA32, mipChain: false);
            var pixels = new Color32[Size * Size];
            for (int y = 0; y < Size; y++)
            {
                // Texture2D の y=0 は**下端**である（Unity の規約）。
                var c = y < Size / 2 ? bottom : top;
                for (int x = 0; x < Size; x++) { pixels[y * Size + x] = c; }
            }
            src.SetPixels32(pixels);
            src.Apply();

            var rt = new RenderTexture(Size, Size, 0, RenderTextureFormat.ARGB32);
            rt.Create();
            Graphics.Blit(src, rt);
            Object.DestroyImmediate(src);
            return rt;
        }

        internal static void Release(RenderTexture rt)
        {
            if (rt == null) { return; }
            rt.Release();
            Object.DestroyImmediate(rt);
        }
    }
}
