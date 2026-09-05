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
        /// RenderTexture の読み出しを GPU に依頼し、待たずに戻る。
        /// </summary>
        /// <remarks>
        /// <b>GPU を待たせない。</b> <see cref="ToMat"/> は転送が済むまで戻らないので
        /// 毎フレームの用途ではフレーム時間に直接乗るが、こちらは依頼だけして戻る。
        /// 完了は <see cref="MatRequest.IsDone"/> で見る。
        /// <para>
        /// <b>読み出し結果の NativeArray を外へ出さない。</b> Unity が渡す
        /// NativeArray は次の readback で無効になるので、外へ出すと寿命の管理が
        /// 利用者の責任になる。<see cref="MatRequest.TakeMat"/> は
        /// <b>受け取った時点で CvMat に写して</b>返す
        /// （docs/abi-ownership-and-versioning.md §1 の「借用は呼び出しの内側で
        /// 完結する」を Unity 層でも保つ）。
        /// </para>
        /// </remarks>
        /// <exception cref="ArgumentNullException"><paramref name="source"/> が null。</exception>
        public static MatRequest RequestMat(RenderTexture source)
        {
            if (source == null) { throw new ArgumentNullException(nameof(source)); }
            return new MatRequest(source);
        }

        /// <summary>読み出し中の依頼。完了したら <see cref="TakeMat"/> で Mat を取る。</summary>
        public sealed class MatRequest
        {
            private UnityEngine.Rendering.AsyncGPUReadbackRequest _request;
            private readonly int _width;
            private readonly int _height;
            private bool _taken;

            internal MatRequest(RenderTexture source)
            {
                _width = source.width;
                _height = source.height;
                _request = UnityEngine.Rendering.AsyncGPUReadback.Request(
                    source, 0, TextureFormat.RGBA32);
            }

            /// <summary>GPU の転送が終わったか。エラーで終わった場合も true になる。</summary>
            public bool IsDone => _request.done;

            /// <summary>転送が失敗したか。</summary>
            public bool HasError => _request.hasError;

            /// <summary>
            /// 読み出した内容を新しい CvMat（Bgra32、上下反転済み）にして返す。
            /// </summary>
            /// <exception cref="InvalidOperationException">
            /// まだ完了していない、失敗した、または既に 1 度取り出した。
            /// </exception>
            public unsafe CvMat TakeMat()
            {
                if (!_request.done)
                {
                    throw new InvalidOperationException("readback がまだ完了していない");
                }
                if (_request.hasError)
                {
                    throw new InvalidOperationException("readback が失敗した");
                }
                if (_taken)
                {
                    // **2 度目は必ず失敗させる。** Unity の NativeArray は
                    // 次の readback で無効になるので、2 度目に取れた「ように見える」
                    // 状態は、解放済みメモリを読んでいる可能性がある。
                    throw new InvalidOperationException("この依頼からは既に Mat を取り出した");
                }
                _taken = true;

                var raw = _request.GetData<byte>();
                var mat = CvMat.Create(_height, _width, CvMatType.Bgra32);
                try
                {
                    FillFlipped(mat, raw, _width, _height);
                    return mat;
                }
                catch { mat.Dispose(); throw; }
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
