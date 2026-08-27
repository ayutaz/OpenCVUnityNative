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

            // HarnessProbeTests は ocvu_debug_crash を CvUnity.Runtime を介さず
            // 直接 P/Invoke する（意図的に落とす関数を通常の API 表に出したくない
            // ため）。resolver はアセンブリ単位でしか効かないので、このテスト
            // アセンブリ自身にも同じ resolver を登録しておく。
            var thisAssembly = typeof(NativeLibraryResolver).Assembly;
            if (!ReferenceEquals(thisAssembly, runtimeAssembly))
            {
                NativeLibrary.SetDllImportResolver(thisAssembly, Resolve);
            }
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

            // ファイル名は platform で変わる。決め打ちにすると macOS / Linux で
            // L3 が FileNotFoundException になる（M3 のレビューで発見）。
            var fileName =
                RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "opencv_unity_native.dll" :
                RuntimeInformation.IsOSPlatform(OSPlatform.OSX) ? "libopencv_unity_native.dylib" :
                "libopencv_unity_native.so";
            var path = Path.Combine(directory, fileName);
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
