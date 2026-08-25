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
            return (CvStatus)NativeMethods.ocvu_get_last_error_status();
        }

        /// <summary>呼び出しスレッドの直近のエラーメッセージ。無ければ空文字列。</summary>
        public static string GetLastErrorMessage()
        {
            int required;
            NativeMethods.ocvu_get_last_error_message(null, 0, out required);
            if (required <= 1)
            {
                return string.Empty;
            }

            var buffer = new byte[required];
            var status = NativeMethods.ocvu_get_last_error_message(
                buffer, buffer.Length, out required);
            if (status != (int)CvStatus.Ok)
            {
                return string.Empty;
            }

            return Encoding.UTF8.GetString(buffer, 0, required - 1);
        }

        /// <summary>非 OK status を <see cref="CvNativeException"/> に変換する。</summary>
        public static void ThrowIfFailed(int status)
        {
            if (status == (int)CvStatus.Ok)
            {
                return;
            }

            var message = GetLastErrorMessage();
            if (message.Length == 0)
            {
                message = "native call failed with status " + status;
            }

            throw new CvNativeException((CvStatus)status, message);
        }

        /// <summary>conformance test 用。ネイティブ層に意図的に例外を投げさせる。</summary>
        public static int DebugThrow(int kind)
        {
            return NativeMethods.ocvu_debug_throw(kind);
        }
    }
}
