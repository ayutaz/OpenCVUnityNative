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

    // --- C-1: 非 standard profile の生成物がコンパイルできること ---
    //
    // **これが「機構が働く」の中身だった穴である。** `[DllImport(LibraryName, ...)]`
    // の `LibraryName` は手書きの `Runtime/Interop/NativeMethods.cs` にある
    // `internal const` で、既定 profile ではそれと同じ型の partial だから見えて
    // いた。**非 standard は別 assembly・別型なので見えない** ——
    // `CvUnity.Interop.Dnn` の asmdef は `references: []`、`AssemblyInfo.cs` は
    // `InternalsVisibleTo` を意図的に出していない。生成物は名前が解決できず
    // CS0103 になる（合成 spec から生成してコンパイルし、実測した）。
    [Fact]
    public void ANonStandardProfileCarriesItsOwnLibraryName()
    {
        var text = CsPInvokeEmitter.Emit(LoadSynthetic(profile: "dnn"));

        // **値だけでなく platform の分岐ごと在ること。** 値を 1 つに畳むと、
        // 静的リンクする platform（iOS / WebGL）で "__Internal" にならず、
        // Player の中で最初の呼び出しが落ちる（M6 で既定側が踏んだ形）。
        Assert.Contains("#if (UNITY_IOS || UNITY_WEBGL) && !UNITY_EDITOR", text);
        Assert.Contains("internal const string LibraryName = \"__Internal\";", text);
        Assert.Contains("internal const string LibraryName = \"opencv_unity_native\";", text);

        // **宣言より前に在ること。** C# は宣言の順序を問わないので
        // 実害は無いが、順序が入れ替わったら意図が変わっている。
        Assert.True(
            text.IndexOf("LibraryName =", StringComparison.Ordinal)
                < text.IndexOf("[DllImport(", StringComparison.Ordinal),
            "LibraryName の宣言が DllImport より後ろにある");
    }

    /// <summary>
    /// **既定 profile には複製しない。**
    ///
    /// 既定側は手書きの `NativeMethods` と同じ型の partial なので、
    /// 複製すると `LibraryName` が二重定義になってコンパイルが落ちる。
    /// これは「既定の生成物が 1 バイトも変わらない」の裏づけでもある。
    /// </summary>
    [Fact]
    public void TheStandardProfileDoesNotCarryACopyOfLibraryName()
    {
        var text = CsPInvokeEmitter.Emit(LoadSynthetic(profile: null));

        Assert.DoesNotContain("const string LibraryName", text);
        Assert.DoesNotContain("#if", text);
    }

    /// <summary>
    /// **写しが 2 つあるので、機械が突き合わせる。**
    ///
    /// `LibraryName` の宣言は手書き（`Runtime/Interop/NativeMethods.cs`）と
    /// 生成器（<see cref="CsPInvokeEmitter.LibraryNameBlock"/>）の 2 箇所に
    /// 在る。片方だけ直すと、非 standard profile の binding だけが違う
    /// ライブラリ名を指す —— **既定 profile は緑のままである。**
    ///
    /// **どちらかが読めなかったら落とす。** 抽出が空振りしたことを
    /// 「一致した」と読まない（`tools/tests/OpenCvConfig.Tests.ps1` と同じ作法）。
    /// </summary>
    [Fact]
    public void TheEmittedLibraryNameMatchesTheHandWrittenOne()
    {
        var handWrittenPath = Path.Combine(RepoRoot(),
            "Packages", "com.ayutaz.opencv-unity-native", "Runtime", "Interop", "NativeMethods.cs");
        var handWritten = ExtractPreprocessorBlock(
            File.ReadAllLines(handWrittenPath), "LibraryName");

        var emitted = ExtractPreprocessorBlock(
            CsPInvokeEmitter.LibraryNameBlock, "LibraryName");

        // **0 行を「一致」と読まない。** 抽出が空振りしたら、
        // 下の比較は空 == 空 で必ず通る。
        Assert.NotEmpty(handWritten);
        Assert.NotEmpty(emitted);

        Assert.Equal(handWritten, emitted);
    }

    /// <summary>
    /// <c>#if</c> から対応する <c>#endif</c> までを、<paramref name="mustContain"/> を
    /// 含むものだけ返す。行末の空白と行頭・行末の空行だけを正規化する
    /// （字下げは残す —— 手書きと生成物で字下げが違えば、それは食い違いである）。
    /// 見つからなければ空配列を返し、呼ぶ側が落とす。
    /// </summary>
    private static string[] ExtractPreprocessorBlock(string[] lines, string mustContain)
    {
        for (var i = 0; i < lines.Length; i++)
        {
            if (!lines[i].TrimStart().StartsWith("#if", StringComparison.Ordinal)) { continue; }
            for (var j = i + 1; j < lines.Length; j++)
            {
                if (lines[j].TrimStart().StartsWith("#if", StringComparison.Ordinal)) { break; }
                if (!lines[j].TrimStart().StartsWith("#endif", StringComparison.Ordinal)) { continue; }

                var block = lines[i..(j + 1)].Select(l => l.TrimEnd()).ToArray();
                if (block.Any(l => l.Contains(mustContain, StringComparison.Ordinal)))
                {
                    return block;
                }
                break;
            }
        }
        return Array.Empty<string>();
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
