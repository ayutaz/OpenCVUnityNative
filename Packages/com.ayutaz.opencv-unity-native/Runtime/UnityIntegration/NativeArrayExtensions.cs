using System;
using Unity.Collections;
using Unity.Collections.LowLevel.Unsafe;

namespace CvUnity.Unity
{
    /// <summary>
    /// <see cref="NativeArray{T}"/> を直接受け渡すための入口。
    ///
    /// ポインタ版（<see cref="CvMat.CopyFrom(IntPtr, long, long)"/>）でも同じことは
    /// できるが、それには利用者側の asmdef に <c>allowUnsafeCode</c> が要り、
    /// アドレスの取得とバイト長の計算も自分で書くことになる。パッケージの利用者に
    /// <c>unsafe</c> を要求する API は「NativeArray から入力できる」の自然な読みでは
    /// ないので、その手間をここで引き受ける。
    ///
    /// <para><b>バイト長は要素数ではない。</b> <c>NativeArray&lt;T&gt;.Length</c> は
    /// 要素数を返すので、<c>Color32</c> のような多バイト要素では 4 倍ずれる。
    /// ここで <c>UnsafeUtility.SizeOf&lt;T&gt;()</c> を掛けて計算するのは、
    /// この取り違えが呼ぶ側で起きると任意アドレスへの書き込みになるからである。</para>
    ///
    /// <para><b>借用は呼び出しの内側で完結する。</b> 渡した領域は native 側が
    /// 呼び出し中だけ読み書きし、戻った後は一切保持しない
    /// （docs/abi-ownership-and-versioning.md §1）。呼ぶ側は、呼び出しが戻るまで
    /// その <see cref="NativeArray{T}"/> を Dispose しないこと。</para>
    /// </summary>
    public static class NativeArrayExtensions
    {
        /// <summary>
        /// <paramref name="source"/> の内容を <paramref name="mat"/> へ写す。
        /// <paramref name="stride"/> は 1 行のバイト数。長さと stride の整合は
        /// native 側が検証し、合わなければ 1 バイトも書かれない。
        /// </summary>
        public static unsafe void CopyFrom<T>(this CvMat mat, NativeArray<T> source, long stride)
            where T : struct
        {
            if (mat == null) { throw new ArgumentNullException(nameof(mat)); }
            if (!source.IsCreated) { throw new ArgumentException("source is not created", nameof(source)); }

            var bytes = (long)source.Length * UnsafeUtility.SizeOf<T>();
            var ptr = (IntPtr)NativeArrayUnsafeUtility.GetUnsafeReadOnlyPtr(source);
            mat.CopyFrom(ptr, bytes, stride);
        }

        /// <summary>
        /// <paramref name="mat"/> の内容を <paramref name="destination"/> へ写す。
        /// 契約は <see cref="CopyFrom{T}"/> と同じ。
        /// </summary>
        public static unsafe void CopyTo<T>(this CvMat mat, NativeArray<T> destination, long stride)
            where T : struct
        {
            if (mat == null) { throw new ArgumentNullException(nameof(mat)); }
            if (!destination.IsCreated) { throw new ArgumentException("destination is not created", nameof(destination)); }

            var bytes = (long)destination.Length * UnsafeUtility.SizeOf<T>();
            var ptr = (IntPtr)NativeArrayUnsafeUtility.GetUnsafePtr(destination);
            mat.CopyTo(ptr, bytes, stride);
        }
    }
}
