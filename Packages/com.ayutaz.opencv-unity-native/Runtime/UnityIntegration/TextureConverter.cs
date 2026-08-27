using System;
using Unity.Collections;
using Unity.Collections.LowLevel.Unsafe;
using UnityEngine;

namespace CvUnity.Unity
{
    /// <summary>Texture2D と CvMat の相互変換。</summary>
    public static class TextureConverter
    {
        /// <summary>
        /// Texture2D の内容を新しい CvMat に写す。
        ///
        /// テクスチャの生データを**コピー無しで**渡す。GetRawTextureData が返す
        /// NativeArray からポインタを取り、その呼び出しの内側だけで native に
        /// 読ませる。戻った時点で借用は終わり、native 側は一切保持しない
        /// （docs/abi-ownership-and-versioning.md §1）。
        ///
        /// この NativeArray はテクスチャの更新や破棄で無効になるので、跨いで
        /// 保持してはならない。ここでは同一の呼び出し内で読み切るので、その
        /// 危険は構造的に存在しない。
        /// </summary>
        public static unsafe CvMat ToMat(Texture2D texture)
        {
            if (texture == null) { throw new ArgumentNullException(nameof(texture)); }
            if (texture.format != TextureFormat.RGBA32)
            {
                throw new NotSupportedException(
                    "M2 supports RGBA32 only; got " + texture.format);
            }

            var raw = texture.GetRawTextureData<byte>();
            var mat = CvMat.Create(texture.height, texture.width, CvMatType.Bgra32);
            try
            {
                // NativeArray の先頭アドレスをそのまま渡す。ToArray() を挟むと
                // managed 配列への写しが 1 回増え、Texture2D -> Mat がコピー
                // 2 回になる。長さと stride は native 側が検証する。
                var ptr = (IntPtr)NativeArrayUnsafeUtility.GetUnsafeReadOnlyPtr(raw);
                mat.CopyFrom(ptr, raw.Length, texture.width * 4);
                return mat;
            }
            catch
            {
                mat.Dispose();
                throw;
            }
        }

        /// <summary>CvMat の内容を既存の Texture2D に書き戻し、Apply する。</summary>
        public static unsafe void ToTexture(CvMat mat, Texture2D texture)
        {
            if (mat == null) { throw new ArgumentNullException(nameof(mat)); }
            if (texture == null) { throw new ArgumentNullException(nameof(texture)); }
            if (mat.Cols != texture.width || mat.Rows != texture.height)
            {
                throw new ArgumentException(
                    $"size mismatch: mat is {mat.Cols}x{mat.Rows}, texture is {texture.width}x{texture.height}");
            }

            // 戻りも同じくコピー無しで書く。LoadRawTextureData(byte[]) を使うと
            // 中間配列が 1 つ増えるので、テクスチャの生データへ直接書き込む。
            var raw = texture.GetRawTextureData<byte>();
            var ptr = (IntPtr)NativeArrayUnsafeUtility.GetUnsafePtr(raw);
            mat.CopyTo(ptr, raw.Length, mat.Cols * mat.Channels);

            // 書いた内容を GPU 側へ反映する。これを忘れると CPU 側だけが
            // 新しい状態になり、描画結果が変わらない。
            texture.Apply();
        }
    }
}
