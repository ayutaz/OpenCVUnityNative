using System;
using Unity.Collections;
using Unity.Collections.LowLevel.Unsafe;
using UnityEngine;

namespace CvUnity.Unity
{
    /// <summary>RenderTexture から CvMat を作る。</summary>
    /// <remarks>
    /// <para>
    /// <b>RenderTexture には GetRawTextureData が無い。</b> 中身は GPU 側に
    /// あり、CPU から読むには GPU → CPU の転送が要る。ここが Texture2D との
    /// 決定的な違いである（Texture2D は CPU 側にも実体を持ちうる）。
    /// </para>
    /// <para>
    /// <b>この同期経路は GPU を待たせる。</b> <c>ReadPixels</c> は転送が済むまで
    /// 戻らないので、毎フレーム呼ぶとフレーム時間に直接乗る。毎フレームの用途では
    /// <see cref="ToMatAsync"/> を使うこと。
    /// </para>
    /// <para>
    /// <b>上下を反転する。</b> Unity は左下原点、OpenCV は左上原点である。
    /// <c>WebCamTextureConverter</c> と同じ規約に揃えてある。
    /// </para>
    /// </remarks>
    public static class RenderTextureConverter
    {
        /// <summary>
        /// RenderTexture の内容を新しい CvMat（Bgra32）に写す。
        /// GPU の転送が済むまで戻らない。
        /// </summary>
        /// <exception cref="ArgumentNullException"><paramref name="source"/> が null。</exception>
        /// <exception cref="NotSupportedException">読み出せる形式でない。</exception>
        public static unsafe CvMat ToMat(RenderTexture source)
        {
            if (source == null) { throw new ArgumentNullException(nameof(source)); }

            var prev = RenderTexture.active;
            var staging = new Texture2D(
                source.width, source.height, TextureFormat.RGBA32, mipChain: false);
            try
            {
                RenderTexture.active = source;
                staging.ReadPixels(new Rect(0, 0, source.width, source.height), 0, 0);
                staging.Apply(updateMipmaps: false);

                // ここから先は Texture2D の経路と同じ。**写しを増やさない** ——
                // GetRawTextureData が返す NativeArray のポインタをそのまま渡す。
                var raw = staging.GetRawTextureData<byte>();
                var mat = CvMat.Create(source.height, source.width, CvMatType.Bgra32);
                try
                {
                    FillFlipped(mat, raw, source.width, source.height);
                    return mat;
                }
                catch { mat.Dispose(); throw; }
            }
            finally
            {
                RenderTexture.active = prev;
                UnityEngine.Object.DestroyImmediate(staging);
            }
        }

        /// <summary>
        /// NativeArray の内容を上下反転して Mat に書く。
        /// </summary>
        /// <remarks>
        /// <b>行ごとに渡す案は採らない。</b> 一括で渡して native 側で反転させる案も
        /// 採らない —— それは新しい ABI 関数を要求し、この計画は公開 ABI を
        /// 1 本も増やさない。反転済みの buffer を 1 つ組んでから
        /// <see cref="CvMat.CopyFrom(IntPtr, long, long)"/> へ 1 回で渡す。
        /// </remarks>
        internal static unsafe void FillFlipped(
            CvMat mat, NativeArray<byte> raw, int width, int height)
        {
            long rowBytes = (long)width * 4;
            long total = rowBytes * height;
            var basePtr = (byte*)NativeArrayUnsafeUtility.GetUnsafeReadOnlyPtr(raw);

            // **反転した写しを 1 つ作る。**
            //
            // ここで 1 回コピーが増えることは、benchmark で公開する数字に
            // そのまま出る。避けるには「native 側で反転する ABI 関数」を足すか、
            // 「反転しない」ことを選ぶかで、**どちらもこの計画の範囲外である**
            // （前者は公開 ABI を増やす、後者は WebCamTextureConverter と規約が割れる）。
            var flipped = new NativeArray<byte>(
                (int)total, Allocator.Temp, NativeArrayOptions.UninitializedMemory);
            try
            {
                var dst = (byte*)NativeArrayUnsafeUtility.GetUnsafePtr(flipped);
                for (int y = 0; y < height; y++)
                {
                    Buffer.MemoryCopy(
                        basePtr + (long)y * rowBytes,
                        dst + (long)(height - 1 - y) * rowBytes,
                        rowBytes, rowBytes);
                }
                mat.CopyFrom((IntPtr)dst, total, rowBytes);
            }
            finally { flipped.Dispose(); }
        }
    }
}
