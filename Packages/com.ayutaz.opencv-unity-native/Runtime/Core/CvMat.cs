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
