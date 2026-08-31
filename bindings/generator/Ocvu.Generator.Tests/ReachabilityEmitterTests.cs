using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Xunit;

namespace Ocvu.Generator.Tests;

public class ReachabilityEmitterTests
{
    private static IReadOnlyList<ModuleSpec> Sample() => new[]
    {
        new ModuleSpec("sample", new[]
        {
            new FunctionSpec("ocvu_sample_do", "何かする。", "ocvu_status", "int", true,
                new[] { new ParamSpec("handle", "ocvu_mat_handle", "ulong", "in") }),
        }),
    };

    [Fact]
    public void CallsEveryEntryPoint()
    {
        Assert.Contains("NativeMethods.ocvu_sample_do(", ReachabilityEmitter.Emit(Sample()));
    }

    // **数を返すこと。**「呼んだ」ではなく「何本呼んだ」を見たい。
    [Fact]
    public void ReturnsHowManyItCalled()
    {
        var text = ReachabilityEmitter.Emit(Sample());
        Assert.Contains("public static int CallEveryEntryPoint()", text);
        Assert.Contains("return 1;", text);
    }

    // **spec が reachable: false と書いた関数は呼ばない。**
    // ocvu_debug_crash は戻ってこないので、呼べばテストプロセスごと死ぬ。
    [Fact]
    public void SkipsWhatTheSpecMarksUnreachable()
    {
        var spec = new[]
        {
            new ModuleSpec("infra", new[]
            {
                new FunctionSpec("ocvu_debug_crash", "意図的に落ちる。", "void", "void", false,
                    new[] { new ParamSpec("kind", "int32_t", "int", "in") },
                    Reachable: false, ReachableNote: "戻ってこない"),
                new FunctionSpec("ocvu_get_abi_version", "版を返す。", "int32_t", "int", false,
                    Array.Empty<ParamSpec>()),
            }),
        };
        var text = ReachabilityEmitter.Emit(spec);
        Assert.DoesNotContain("ocvu_debug_crash", text);
        Assert.Contains("ocvu_get_abi_version", text);
        Assert.Contains("return 1;", text);
    }

    // **名前で除外していないこと。** 生成器が特定の関数名を知る形にすると、
    // 次に同種の関数が増えたときに黙って呼ばれる。除外を決めるのは
    // spec の reachable だけである —— 同じ名前でも、印が無ければ呼ぶ。
    [Fact]
    public void ExcludesByTheFlagAndNotByTheName()
    {
        var spec = new[]
        {
            new ModuleSpec("infra", new[]
            {
                new FunctionSpec("ocvu_debug_crash", "印を外した同名の関数。", "void", "void", false,
                    new[] { new ParamSpec("kind", "int32_t", "int", "in") }),
            }),
        };
        Assert.Contains("NativeMethods.ocvu_debug_crash(0);", ReachabilityEmitter.Emit(spec));
    }

    // **型ごとの無害な実引数で埋めること。** 目的は呼べることであって
    // 正しい結果ではない。out は捨てる。
    [Fact]
    public void FillsArgumentsFromTheCsType()
    {
        var spec = new[]
        {
            new ModuleSpec("sample", new[]
            {
                new FunctionSpec("ocvu_sample_all", "全種類。", "ocvu_status", "int", true,
                    new[]
                    {
                        new ParamSpec("a", "ocvu_mat_handle", "ulong", "in"),
                        new ParamSpec("b", "int32_t", "int", "in"),
                        new ParamSpec("c", "int64_t", "long", "in"),
                        new ParamSpec("d", "double", "double", "in"),
                        new ParamSpec("e", "const uint8_t*", "byte[]", "in-buffer"),
                        new ParamSpec("f", "uint8_t*", "System.IntPtr", "out-buffer"),
                        new ParamSpec("g", "int32_t*", "out int", "out"),
                    }),
            }),
        };
        Assert.Contains(
            "NativeMethods.ocvu_sample_all(0UL, 0, 0L, 0.0, null, default, out _);",
            ReachabilityEmitter.Emit(spec));
    }

    [Fact]
    public void SaysItIsGenerated()
    {
        Assert.Contains("このファイルは生成物である", ReachabilityEmitter.Emit(Sample()));
    }

    // **実物の spec で数が合うこと。** 手で書いた期待値ではなく、
    // spec 自身が数えた「呼べる関数」の本数と突き合わせる —— ABI が
    // 1 本増えれば期待値も勝手に増える。
    [Fact]
    public void CountsEveryReachableFunctionOfTheRealSpec()
    {
        var specs = SpecModel.Load(Path.Combine(RepoRoot(), "bindings", "spec"));
        var expected = specs.SelectMany(s => s.Functions).Count(f => f.IsReachable);

        Assert.True(expected > 10, "spec が空だと 0 本になる");
        Assert.Contains($"return {expected};", ReachabilityEmitter.Emit(specs));
    }

    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "bindings", "spec")))
        {
            dir = dir.Parent;
        }
        Assert.NotNull(dir);
        return dir!.FullName;
    }
}
