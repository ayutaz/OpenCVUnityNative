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
        /// テクスチャのメモリを借りたまま保持しない。GetRawTextureData が返す
        /// NativeArray はテクスチャの更新や破棄で無効になり、それを跨いで
        /// 保持すると存在しないメモリを触ることになる。ここでは 1 回の
        /// コピーで native 側へ移し、呼び出しが戻った時点で借用を終える
        /// （docs/abi-ownership-and-versioning.md §1）。
        /// </summary>
        public static CvMat ToMat(Texture2D texture)
        {
            if (texture == null) { throw new ArgumentNullException(nameof(texture)); }
            if (texture.format != TextureFormat.RGBA32)
            {
                throw new NotSupportedException(
                    "M2 supports RGBA32 only; got " + texture.format);
            }

            // NativeArray からポインタを取って直接渡す経路は、M2 では作っていない。
            // ここは ToArray() で managed 配列へ 1 回コピーしてから Mat へ渡すので、
            // Texture2D -> Mat はコピー 2 回になる（実装計画はポインタ経路を指示して
            // いたが、実装は byte[] 経路のままで、その差分が記録されていなかった）。
            //
            // 「Unity データとの低コピー連携」を名乗るならポインタ経路が要る。
            // 現状はそう名乗れない。M3 以降で NativeMethods に IntPtr overload を
            // 足し、GetRawTextureData の NativeArray から直接渡す形にする。
            // asmdef の allowUnsafeCode と下の using はそのとき使う。
            var raw = texture.GetRawTextureData<byte>();
            var mat = CvMat.Create(texture.height, texture.width, CvMatType.Bgra32);
            try
            {
                var managed = raw.ToArray();
                mat.CopyFrom(managed, texture.width * 4);
                return mat;
            }
            catch
            {
                mat.Dispose();
                throw;
            }
        }

        /// <summary>CvMat の内容を既存の Texture2D に書き戻し、Apply する。</summary>
        public static void ToTexture(CvMat mat, Texture2D texture)
        {
            if (mat == null) { throw new ArgumentNullException(nameof(mat)); }
            if (texture == null) { throw new ArgumentNullException(nameof(texture)); }
            if (mat.Cols != texture.width || mat.Rows != texture.height)
            {
                throw new ArgumentException(
                    $"size mismatch: mat is {mat.Cols}x{mat.Rows}, texture is {texture.width}x{texture.height}");
            }

            var bytes = new byte[mat.Rows * mat.Cols * mat.Channels];
            mat.CopyTo(bytes, mat.Cols * mat.Channels);
            texture.LoadRawTextureData(bytes);
            texture.Apply();
        }
    }
}
