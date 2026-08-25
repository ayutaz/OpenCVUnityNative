using System;
using System.Text;
using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>ネイティブ層のバージョン照会とエラー取得。</summary>
    public static class CvNative
    {
        /// <summary>ロードされているネイティブライブラリの C ABI バージョン。</summary>
        public static int AbiVersion => NativeMethods.ocvu_get_abi_version();

        /// <summary>呼び出しスレッドの直近のエラー status。</summary>
        public static CvStatus GetLastErrorStatus()
        {
            return ToStatus(NativeMethods.ocvu_get_last_error_status());
        }

        /// <summary>呼び出しスレッドの直近のエラーメッセージ。無ければ空文字列。</summary>
        public static string GetLastErrorMessage()
        {
            // 1 回目は必要サイズの問い合わせ。BufferTooSmall が返るのが正常であって、
            // 失敗ではない（native/include/opencv_unity_native.h の契約）。
            int required;
            NativeMethods.ocvu_get_last_error_message(null, 0, out required);
            if (required <= 1)
            {
                return string.Empty;
            }

            var buffer = new byte[required];
            var status = ToStatus(NativeMethods.ocvu_get_last_error_message(
                buffer, buffer.Length, out required));
            if (status != CvStatus.Ok)
            {
                return string.Empty;
            }

            // required は NUL を含むバイト数なので、終端を除いて復号する。
            return Encoding.UTF8.GetString(buffer, 0, required - 1);
        }

        /// <summary>
        /// 失敗を示す status を <see cref="CvNativeException"/> に変換する。
        /// <see cref="CvStatus.Ok"/> と <see cref="CvStatus.BufferTooSmall"/> は
        /// 失敗ではないので送出しない。後者はサイズ問い合わせの正常な結果である。
        /// </summary>
        public static void ThrowIfFailed(CvStatus status)
        {
            if (!IsFailure(status))
            {
                return;
            }

            var message = GetLastErrorMessage();
            if (message.Length == 0)
            {
                message = "native call failed with status " + (int)status;
            }

            throw new CvNativeException(status, message);
        }

        /// <summary>その status が失敗を表すか。Ok と BufferTooSmall は失敗ではない。</summary>
        public static bool IsFailure(CvStatus status)
        {
            return status != CvStatus.Ok && status != CvStatus.BufferTooSmall;
        }

        /// <summary>conformance test 用。ネイティブ層に意図的に例外を投げさせる。</summary>
        public static CvStatus DebugThrow(int kind)
        {
            return ToStatus(NativeMethods.ocvu_debug_throw(kind));
        }

        /// <summary>
        /// ネイティブが返した生の値を <see cref="CvStatus"/> にする。
        /// C# の enum は未定義の数値でもキャストが通ってしまい、名前の無い値が
        /// 黙って流れる。ここで検査して <see cref="CvStatus.UnknownError"/> に倒し、
        /// 元の数値は last-error 側に残っているメッセージから追える状態にしておく。
        /// native と C# の対応そのものは L3 の StatusCodeSyncTests が守る。
        /// </summary>
        private static CvStatus ToStatus(int status)
        {
            return Enum.IsDefined(typeof(CvStatus), status)
                ? (CvStatus)status
                : CvStatus.UnknownError;
        }
    }
}
