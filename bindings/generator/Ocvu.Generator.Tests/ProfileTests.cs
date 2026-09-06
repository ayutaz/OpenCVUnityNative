using System;
using System.IO;
using System.Linq;
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

    // --- レビュー Minor 3: 空文字列の profile ---
    //
    // Pascalize は「profile 名は schema の enum で閉じている」ことを前提に
    // profile[0] を直接インデックスしていたが、ModuleSpec はここまでの
    // テストがまさにやっているとおり schema 検証を経ずに直接組み立てられる。
    // 空文字列を渡すと IndexOutOfRangeException という、原因の分からない
    // 例外になっていた。
    [Fact]
    public void AnEmptyProfileFailsWithAClearMessageRatherThanAnIndexError()
    {
        var spec = new ModuleSpec("probe", new[]
        {
            new FunctionSpec("ocvu_probe_thing", "空 profile を試す。", "ocvu_status", "int", true,
                Array.Empty<ParamSpec>()),
        })
        {
            Profile = "",
        };

        var ex1 = Assert.Throws<ArgumentException>(() => CsPInvokeEmitter.Emit(spec));
        Assert.Contains("profile", ex1.Message);

        var specs = new[] { spec };
        var ex2 = Assert.Throws<ArgumentException>(() => ReachabilityEmitter.Emit(specs, ""));
        Assert.Contains("profile", ex2.Message);

        var ex3 = Assert.Throws<ArgumentException>(() => ReachabilityEmitter.OutputPathFor(""));
        Assert.Contains("profile", ex3.Message);
    }

    // **SpecModel.Load(tmpDir) を使う。専用の 1 ファイル入口は足さない。**
    // SpecSchemaTests.cs が既に同じ形（CopyRealSchemaInto + 一時ディレクトリ）
    // で合成 spec を検証しており、それで用は足りる —— 生産コードに新しい
    // 公開 API（cwd から repo root を歩いて探す、という Program.cs が
    // --repo-root で意図的に避けている依存）を足す理由が無い。
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

        var tmp = Path.Combine(Path.GetTempPath(), "ocvu-spec-" + Path.GetRandomFileName());
        Directory.CreateDirectory(tmp);
        try
        {
            CopyRealSchemaInto(tmp);
            File.WriteAllText(Path.Combine(tmp, "probe.json"), json);
            return SpecModel.Load(tmp).Single();
        }
        finally { Directory.Delete(tmp, recursive: true); }
    }

    // SpecSchemaTests.cs の同名メソッドと同じ形。SpecModel.Load は spec と
    // 同じディレクトリに schema.json があることを要求するため、合成 spec を
    // 単独で検証したいテストは実物の schema.json をそこへ複製する。
    private static void CopyRealSchemaInto(string tmpDir)
    {
        File.Copy(
            Path.Combine(RepoRoot(), "bindings", "spec", "schema.json"),
            Path.Combine(tmpDir, "schema.json"));
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
