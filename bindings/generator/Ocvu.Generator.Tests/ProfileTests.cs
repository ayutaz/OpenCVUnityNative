using System;
using System.IO;
using Xunit;

namespace Ocvu.Generator.Tests;

public class ProfileTests
{
    /// <summary>
    /// **profile を書かない spec は "standard" になる。**
    /// 既存の 9 つの spec はどれも profile を書いていないので、
    /// これが崩れると全部が別 assembly へ動く。
    /// </summary>
    [Fact]
    public void AProfileIsStandardWhenTheSpecDoesNotSayOtherwise()
    {
        var spec = LoadSynthetic(profile: null);
        Assert.Equal("standard", spec.Profile);
    }

    [Fact]
    public void AnExplicitProfileIsRead()
    {
        var spec = LoadSynthetic(profile: "dnn");
        Assert.Equal("dnn", spec.Profile);
    }

    /// <summary>
    /// **standard は今までどおりの場所・今までどおりのクラス名。**
    /// ここが変わると、既存の 10 個の生成物が全部動く。
    /// </summary>
    [Fact]
    public void StandardEmitsIntoTheExistingClass()
    {
        var spec = LoadSynthetic(profile: null);
        var text = CsPInvokeEmitter.Emit(spec);

        Assert.Contains("namespace CvUnity.Interop", text);
        Assert.Contains("internal static partial class NativeMethods", text);
        Assert.DoesNotContain("NativeMethodsDnn", text);
    }

    /// <summary>
    /// **非 standard は別 namespace・別クラス。**
    /// partial class は assembly を跨げないので、同じ型にはできない。
    /// </summary>
    [Fact]
    public void ANonStandardProfileEmitsIntoItsOwnClass()
    {
        var spec = LoadSynthetic(profile: "dnn");
        var text = CsPInvokeEmitter.Emit(spec);

        Assert.Contains("namespace CvUnity.Interop.Dnn", text);
        Assert.Contains("internal static partial class NativeMethodsDnn", text);
    }

    /// <summary>
    /// **知らない profile は落とす。**
    /// 綴り間違いを黙って新しい profile として受けると、
    /// その module の宣言がどこからも参照されない assembly へ静かに消える。
    /// </summary>
    [Fact]
    public void AnUnknownProfileIsRejected()
    {
        var ex = Assert.Throws<SpecFormatException>(() => LoadSynthetic(profile: "dnnn"));
        Assert.Contains("dnnn", ex.Message);
    }

    // --- Step 4b: ReachabilityEmitter を profile ごとに分ける負の対照 ---
    //
    // **「既定側が変わらない」だけを見ない。** それは分岐が丸ごと死んでいても
    // 真になる。ここでは (1) 2 ファイル出ること（既定と非既定で出力先が違う）、
    // (2) 既定側のファイルに非既定 profile の関数が 1 本も現れないこと、
    // (3) 非既定側のファイルに既定 profile の関数が 1 本も現れないこと、
    // の 3 つを一度に見る。
    //
    // **enum を通さない。** ここは SpecModel.Load を経由しないので schema の
    // enum チェックには掛からない —— ModuleSpec を直接組み立てて
    // ReachabilityEmitter.Emit の分岐だけを見る（CsPInvokeEmitterTests など
    // 既存の emitter テストと同じやり方）。
    [Fact]
    public void EmitSeparatesFilesAndFunctionsPerProfile()
    {
        var specs = new[]
        {
            new ModuleSpec("probe", new[]
            {
                new FunctionSpec("ocvu_probe_thing", "既定側の関数。", "ocvu_status", "int", true,
                    Array.Empty<ParamSpec>()),
            }),
            new ModuleSpec("testmod", new[]
            {
                new FunctionSpec("ocvu_test_thing", "test profile 側の関数。", "ocvu_status", "int", true,
                    Array.Empty<ParamSpec>()),
            })
            {
                Profile = "test",
            },
        };

        // (1) 2 ファイル出ること。
        Assert.NotEqual(
            ReachabilityEmitter.OutputPathFor("standard"),
            ReachabilityEmitter.OutputPathFor("test"));
        Assert.Equal(ReachabilityEmitter.OutputPath, ReachabilityEmitter.OutputPathFor("standard"));

        var standardText = ReachabilityEmitter.Emit(specs, "standard");
        var testText = ReachabilityEmitter.Emit(specs, "test");

        // (2) 既定側に test profile の関数が現れないこと。
        Assert.Contains("NativeMethods.ocvu_probe_thing(", standardText);
        Assert.DoesNotContain("ocvu_test_thing", standardText);

        // (3) test 側に既定 profile の関数が現れないこと。
        Assert.Contains("NativeMethodsTest.ocvu_test_thing(", testText);
        Assert.DoesNotContain("ocvu_probe_thing", testText);
    }

    private static ModuleSpec LoadSynthetic(string profile)
    {
        var profileLine = profile is null ? "" : $"\"profile\": \"{profile}\",";
        var json = $$"""
        {
          "module": "probe",
          {{profileLine}}
          "functions": [
            {
              "name": "ocvu_probe_thing",
              "summary": "合成した spec。生成器の分岐を見るためだけに存在する。",
              "returns": "ocvu_status",
              "csReturns": "int",
              "wrapInTryBarrier": true,
              "params": []
            }
          ]
        }
        """;

        var path = Path.Combine(
            Path.GetTempPath(), Guid.NewGuid().ToString() + ".json");
        File.WriteAllText(path, json);
        try { return SpecModel.LoadFile(path); }
        finally { File.Delete(path); }
    }
}
