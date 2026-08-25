using System;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace CvUnity.Tests.Managed
{
    /// <summary>
    /// ネイティブビルド出力の場所を OCVU_NATIVE_DIR から解決する。
    /// DllImport を宣言しているのは CvUnity.Runtime アセンブリなので、
    /// resolver はそのアセンブリに対して登録する。
    /// </summary>
    internal static class NativeLibraryResolver
    {
        [ModuleInitializer]
        internal static void Initialize()
        {
            var runtimeAssembly = typeof(CvNative).Assembly;
            NativeLibrary.SetDllImportResolver(runtimeAssembly, Resolve);
        }

        private static IntPtr Resolve(
            string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
        {
            if (libraryName != "opencv_unity_native")
            {
                return IntPtr.Zero;
            }

            var directory = Environment.GetEnvironmentVariable("OCVU_NATIVE_DIR");
            if (string.IsNullOrEmpty(directory))
            {
                throw new InvalidOperationException(
                    "OCVU_NATIVE_DIR is not set. Run the managed tests through " +
                    "'tools/dev.ps1 test-managed' so the native build output can be located.");
            }

            var path = Path.Combine(directory, "opencv_unity_native.dll");
            if (!File.Exists(path))
            {
                throw new FileNotFoundException(
                    $"Native library not found at '{path}'. Build it first with 'tools/dev.ps1 build'.",
                    path);
            }

            return NativeLibrary.Load(path);
        }
    }
}
