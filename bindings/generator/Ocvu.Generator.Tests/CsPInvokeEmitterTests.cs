using Xunit;

namespace Ocvu.Generator.Tests;

public class CsPInvokeEmitterTests
{
    private static ModuleSpec Sample() => new(
        Module: "sample",
        Functions: new[]
        {
            new FunctionSpec("ocvu_sample_do", "何かする。", "ocvu_status", "int", true,
                new[]
                {
                    new ParamSpec("handle", "ocvu_mat_handle", "ulong", "in"),
                    new ParamSpec("outValue", "int32_t*", "out int", "out"),
                }),
        });

    // **partial にする。** module ごとにファイルが分かれるので、
    // partial でないと 2 つ目のクラス定義が衝突する。
    [Fact]
    public void EmitsAPartialClassSoModulesCanCoexist()
    {
        Assert.Contains("internal static partial class NativeMethods",
                        CsPInvokeEmitter.Emit(Sample()));
    }

    // **CallingConvention.Cdecl を必ず付ける。** 付け忘れるとスタックが壊れる
    // （add-abi-function skill の「よくある取りこぼし」）。
    [Fact]
    public void AlwaysDeclaresCdecl()
    {
        Assert.Contains("CallingConvention = CallingConvention.Cdecl",
                        CsPInvokeEmitter.Emit(Sample()));
    }

    [Fact]
    public void EmitsTheSignature()
    {
        Assert.Contains("internal static extern int ocvu_sample_do(ulong handle, out int outValue);",
                        CsPInvokeEmitter.Emit(Sample()));
    }

    // **entryPoint を指定した場合はそれを出す。** C 側 1 本に対して C# の宣言が
    // 2 つある場合（byte[] 版と IntPtr 版）に要る。
    [Fact]
    public void HonoursAnExplicitEntryPoint()
    {
        var spec = new ModuleSpec("sample", new[]
        {
            new FunctionSpec("ocvu_sample_do_ptr", "ポインタ版。", "ocvu_status", "int", true,
                new[] { new ParamSpec("p", "void*", "System.IntPtr", "in") },
                BarrierNote: null, EntryPoint: "ocvu_sample_do"),
        });
        var text = CsPInvokeEmitter.Emit(spec);
        Assert.Contains("EntryPoint = \"ocvu_sample_do\"", text);
        // entryPoint を出しても Cdecl は落とさない。
        Assert.Contains("CallingConvention = CallingConvention.Cdecl", text);
    }

    [Fact]
    public void SaysItIsGenerated()
    {
        Assert.Contains("このファイルは生成物である", CsPInvokeEmitter.Emit(Sample()));
    }
}
