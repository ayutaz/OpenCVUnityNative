using System;
using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>ABI に出す Mat の型。native の OCVU_MAT_TYPE_* と対応する。</summary>
    public enum CvMatType
    {
        Gray8 = 0,
        Bgr24 = 16,
        Bgra32 = 24,
    }

    /// <summary>
    /// native が所有する Mat への handle を包む。
    ///
    /// この型が指すメモリは常に native 側のものである。Unity が所有する
    /// メモリを指す CvMat は存在しない（docs/abi-ownership-and-versioning.md §1）。
    /// </summary>
    public sealed class CvMat : IDisposable
    {
        private ulong _handle;

        private CvMat(ulong handle) { _handle = handle; }

        public static CvMat Create(int rows, int cols, CvMatType type)
        {
            ulong handle;
            var status = (CvStatus)NativeMethods.ocvu_mat_create(
                rows, cols, (int)type, out handle);
            CvNative.ThrowIfFailed(status);
            return new CvMat(handle);
        }

        internal ulong Handle
        {
            get
            {
                ThrowIfDisposed();
                return _handle;
            }
        }

        public int Rows => GetInfo().Rows;
        public int Cols => GetInfo().Cols;
        public int Channels => GetInfo().Channels;
        public long Step => GetInfo().Step;

        public CvMat Clone()
        {
            ulong handle;
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_mat_clone(Handle, out handle));
            return new CvMat(handle);
        }

        public void CopyFrom(byte[] source, long stride)
        {
            if (source == null) { throw new ArgumentNullException(nameof(source)); }
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_mat_copy_from_buffer(
                Handle, source, source.LongLength, stride));
        }

        public void CopyTo(byte[] destination, long stride)
        {
            if (destination == null) { throw new ArgumentNullException(nameof(destination)); }
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_mat_copy_to_buffer(
                Handle, destination, destination.LongLength, stride));
        }

        /// <summary>
        /// ポインタが指す領域から Mat へ写す。<paramref name="source"/> は
        /// この呼び出しの間だけ借用され、戻った時点で native 側は一切保持しない
        /// （docs/abi-ownership-and-versioning.md §1）。
        /// </summary>
        /// <remarks>
        /// Unity の <c>NativeArray</c> をコピー無しで渡すための入口である。
        /// <c>byte[]</c> 版を経由すると managed 配列への写しが 1 回挟まる。
        ///
        /// <para><b>呼ぶ側が守ること</b>: 領域はこの呼び出しが戻るまで生きて
        /// いなければならない。<c>NativeArray</c> なら Dispose される前、
        /// Texture2D の生データならテクスチャが更新・破棄される前に呼び終える。
        /// ポインタの寿命は型で表現できないので、ここだけは規約に頼る —
        /// だからこそ借用を 1 回の呼び出しに閉じ込めてある。</para>
        ///
        /// <para><paramref name="length"/> と <paramref name="stride"/> は
        /// native 側が検証する。合わなければ 1 バイトも書かれない。</para>
        /// </remarks>
        public void CopyFrom(IntPtr source, long length, long stride)
        {
            if (source == IntPtr.Zero) { throw new ArgumentNullException(nameof(source)); }
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_mat_copy_from_buffer_ptr(
                Handle, source, length, stride));
        }

        /// <summary>
        /// Mat の内容をポインタが指す領域へ写す。借用の契約は
        /// <see cref="CopyFrom(IntPtr, long, long)"/> と同じ。
        /// </summary>
        public void CopyTo(IntPtr destination, long length, long stride)
        {
            if (destination == IntPtr.Zero) { throw new ArgumentNullException(nameof(destination)); }
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_mat_copy_to_buffer_ptr(
                Handle, destination, length, stride));
        }

        public void Dispose()
        {
            if (_handle == 0) { return; }
            NativeMethods.ocvu_mat_release(_handle);
            _handle = 0;
        }

        private OcvuMatInfo GetInfo()
        {
            OcvuMatInfo info;
            CvNative.ThrowIfFailed((CvStatus)NativeMethods.ocvu_mat_get_info(Handle, out info));
            return info;
        }

        private void ThrowIfDisposed()
        {
            if (_handle == 0) { throw new ObjectDisposedException(nameof(CvMat)); }
        }
    }
}
