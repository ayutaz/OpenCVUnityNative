using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using Xunit;

namespace Ocvu.Generator.Tests;

public class ApiMapEmitterTests
{
    private static IReadOnlyList<ModuleSpec> Sample() => new[]
    {
        new ModuleSpec("imgproc", new[]
        {
            new FunctionSpec("ocvu_resize", "大きさを変える。", "ocvu_status", "int", true,
                Array.Empty<ParamSpec>()),
        }),
    };

    [Fact]
    public void ListsEveryFunctionWithItsModule()
    {
        Assert.Contains("| `imgproc` | `ocvu_resize` | `ocvu_resize` | 呼ぶ | 大きさを変える。 |",
                        ApiMapEmitter.Emit(Sample()));
    }

    // **総数を書く。** 「全対応」ではなく数を出すのがこの表の役目である。
    [Fact]
    public void StatesTheCount()
    {
        Assert.Contains("**公開している C ABI は 1 本**", ApiMapEmitter.Emit(Sample()));
    }

    [Fact]
    public void SaysItIsGenerated()
    {
        Assert.Contains("このファイルは生成物である", ApiMapEmitter.Emit(Sample()));
    }

    // --- entryPoint を持つ entry は C の関数を増やさない ---

    private static IReadOnlyList<ModuleSpec> WithOverload() => new[]
    {
        new ModuleSpec("core", new[]
        {
            new FunctionSpec("ocvu_mat_copy_from_buffer", "buffer から写す。", "ocvu_status", "int", true,
                Array.Empty<ParamSpec>()),
            new FunctionSpec("ocvu_mat_copy_from_buffer_ptr", "アドレスを直接渡す入口。",
                "ocvu_status", "int", true, Array.Empty<ParamSpec>(),
                EntryPoint: "ocvu_mat_copy_from_buffer"),
        }),
    };

    // **C 側は空欄になる。** この行は C の関数を 1 本も増やさない ——
    // 名前を書くと、C ABI の本数を表から数えたときに 1 本多くなる。
    [Fact]
    public void LeavesTheCColumnEmptyForAnOverload()
    {
        Assert.Contains("| `core` |  | `ocvu_mat_copy_from_buffer_ptr` | 呼ぶ | アドレスを直接渡す入口。 |",
                        ApiMapEmitter.Emit(WithOverload()));
    }

    // **C の本数と C# の本数は別に数える。** 一致していないことがこの表の
    // 事実であって、片方だけを書くと読む側がもう片方を推測することになる。
    [Fact]
    public void CountsTheCAbiAndTheCsDeclarationsSeparately()
    {
        var text = ApiMapEmitter.Emit(WithOverload());
        Assert.Contains("**公開している C ABI は 1 本**", text);
        Assert.Contains("C# の P/Invoke 宣言は 2 本", text);
    }

    // **内訳も spec から出ていること。** 本数は導出しているのに内訳だけ
    // 「`byte[]` を渡す版とアドレスを渡す版」のような固定文にすると、
    // 3 本目が別の形で入った瞬間に、数は正しく中身が嘘の文になる。
    [Fact]
    public void NamesTheOverloadsAndWhereTheyGoInsteadOfDescribingThemByHand()
    {
        Assert.Contains("- `ocvu_mat_copy_from_buffer_ptr` → `ocvu_mat_copy_from_buffer`",
                        ApiMapEmitter.Emit(WithOverload()));
    }

    // **知らない形の overload でも名前が出ること。** 上の 1 件は現行 spec の
    // 2 本と同じ形なので、名前を決め打ちした実装でも通ってしまう。
    [Fact]
    public void NamesAnOverloadItHasNeverSeenBefore()
    {
        var spec = new[]
        {
            new ModuleSpec("imgproc", new[]
            {
                new FunctionSpec("ocvu_resize", "大きさを変える。", "ocvu_status", "int", true,
                    Array.Empty<ParamSpec>()),
                new FunctionSpec("ocvu_resize_span", "まだ無い 3 本目の形。", "ocvu_status", "int", true,
                    Array.Empty<ParamSpec>(), EntryPoint: "ocvu_resize"),
            }),
        };
        var text = ApiMapEmitter.Emit(spec);
        Assert.Contains("- `ocvu_resize_span` → `ocvu_resize`", text);
        Assert.Contains("**公開している C ABI は 1 本**", text);
    }

    // --- 到達性 ---

    private static IReadOnlyList<ModuleSpec> WithUnreachable() => new[]
    {
        new ModuleSpec("infra", new[]
        {
            new FunctionSpec("ocvu_debug_crash", "意図的に落ちる。", "void", "void", false,
                Array.Empty<ParamSpec>(),
                Reachable: false, ReachableNote: "呼ぶと戻ってこない。"),
            new FunctionSpec("ocvu_get_abi_version", "版を返す。", "int32_t", "int", false,
                Array.Empty<ParamSpec>()),
        }),
    };

    // **「呼ばれない関数が在る」ことが表から読み取れること。**
    [Fact]
    public void MarksTheFunctionsTheReachabilityTestDoesNotCall()
    {
        var text = ApiMapEmitter.Emit(WithUnreachable());
        Assert.Contains("| `infra` | `ocvu_debug_crash` | `ocvu_debug_crash` | 呼ばない | 意図的に落ちる。 |", text);
        Assert.Contains("| `infra` | `ocvu_get_abi_version` | `ocvu_get_abi_version` | 呼ぶ | 版を返す。 |", text);
    }

    // **理由まで出す。** 印だけでは、意図なのか事故なのかが読む側に分からない。
    [Fact]
    public void GivesTheReasonFromTheSpec()
    {
        var text = ApiMapEmitter.Emit(WithUnreachable());
        Assert.Contains("到達性テストが呼ばない関数は 1 本ある", text);
        Assert.Contains("- `ocvu_debug_crash` —— 呼ぶと戻ってこない。", text);
    }

    // 1 本も無いときに「1 本ある」と書かない。
    [Fact]
    public void SaysSoWhenEveryFunctionIsReachable()
    {
        var text = ApiMapEmitter.Emit(Sample());
        Assert.Contains("到達性テストが呼ばない関数は無い", text);
        Assert.DoesNotContain("到達性テストが呼ばない関数は 0 本ある", text);
    }

    // --- 表を壊す入力 ---

    // **summary の `|` が列を増やさないこと。** spec には今のところ 1 つも
    // 無いが、1 つ入った時点で表の形が黙って崩れる（Markdown は文句を言わない）。
    [Fact]
    public void EscapesPipesInSummaries()
    {
        var spec = new[]
        {
            new ModuleSpec("sample", new[]
            {
                new FunctionSpec("ocvu_sample", "a | b を取る。", "ocvu_status", "int", true,
                    Array.Empty<ParamSpec>()),
            }),
        };
        var row = ApiMapEmitter.Emit(spec)
            .Split('\n').Single(l => l.Contains("ocvu_sample"));
        Assert.Contains(@"a \| b を取る。", row);

        // **数えるのは列の区切りであって `|` の個数ではない。** 逃がした
        // `\|` も文字としては `|` なので、素朴に数えると 5 列の行は 6 ではなく
        // 7 になり、正しい実装のほうが落ちる。区切りは「直前が `\` でない `|`」
        // で、5 列なら 6 個。逃がさない実装では summary の `|` が 7 個目の
        // 区切りとして数えられ、この assertion がそれを捕まえる。
        var delimiters = Regex.Matches(row.TrimEnd('\r'), @"(?<!\\)\|").Count;
        Assert.Equal(6, delimiters);
    }

    // **`\` を逃がさないと `\|` が壊れる。** summary が `\` で終わったところで
    // `|` が来ると、逃がした結果は `\\|` になる —— Markdown はこれを
    // 「逃がした `\`」+「素の `|`」と読み、列が割れる。**区切りの数を数える
    // 検査ではこれを捕まえられない**（直前が `\` なので逃がされたように
    // 見える）ので、逃がした後の形そのものを見る。
    [Fact]
    public void EscapesBackslashesBeforePipesSoThePipeEscapeSurvives()
    {
        var spec = new[]
        {
            new ModuleSpec("sample", new[]
            {
                new FunctionSpec("ocvu_sample", @"a\|b を取る。", "ocvu_status", "int", true,
                    Array.Empty<ParamSpec>()),
            }),
        };
        var row = ApiMapEmitter.Emit(spec)
            .Split('\n').Single(l => l.Contains("ocvu_sample"));
        // `\` -> `\\`、`|` -> `\|` の順。合わせて `\\` + `\|` になる。
        Assert.Contains(@"a\\\|b を取る。", row);
    }

    // `|` を含まない `\` も逃がす（`\\` が Markdown の「1 個の `\`」である）。
    [Fact]
    public void EscapesALoneBackslash()
    {
        var spec = new[]
        {
            new ModuleSpec("sample", new[]
            {
                new FunctionSpec("ocvu_sample", @"C:\tmp に書く。", "ocvu_status", "int", true,
                    Array.Empty<ParamSpec>()),
            }),
        };
        Assert.Contains(@"C:\\tmp に書く。", ApiMapEmitter.Emit(spec));
    }

    // **到達性テストの置き場所を写さない。** 散文のパスと Program.cs の出力先が
    // 別々に書かれていると、片方を動かしても誰も落ちない。同じ 1 つを見て
    // いること、かつそれが実在することを見る。
    [Fact]
    public void PointsAtTheReachabilityFileThatActuallyExists()
    {
        Assert.Contains(ReachabilityEmitter.OutputPath, ApiMapEmitter.Emit(Sample()));
        var onDisk = Path.Combine(RepoRoot(), ReachabilityEmitter.OutputPath);
        Assert.True(File.Exists(onDisk), $"{ReachabilityEmitter.OutputPath} が実在しません");
    }

    // **区切りは platform で変わってはならない。** Path.Combine の結果を文書へ
    // 書くと Windows は `\`、Linux は `/` になり、生成物が OS ごとに別物に
    // なって verify-generated が CI でだけ赤くなる。
    [Fact]
    public void TheReachabilityPathUsesForwardSlashesOnEveryPlatform()
    {
        Assert.DoesNotContain(@"\", ReachabilityEmitter.OutputPath);
        Assert.Contains("/", ReachabilityEmitter.OutputPath);
    }

    // --- 実物の spec ---

    // **手で書いた期待値ではなく spec 自身が数えた値と突き合わせる。**
    // ABI が 1 本増えれば期待値も勝手に増える。
    [Fact]
    public void CountsTheRealSpec()
    {
        var specs = SpecModel.Load(Path.Combine(RepoRoot(), "bindings", "spec"));
        var fns = specs.SelectMany(s => s.Functions).ToList();
        var cCount = fns.Count(f => string.IsNullOrEmpty(f.EntryPoint));

        Assert.True(cCount > 10, "spec が空だと 0 本になる");
        Assert.True(fns.Count > cCount, "entryPoint を持つ entry が spec から消えている");

        var text = ApiMapEmitter.Emit(specs);
        Assert.Contains($"**公開している C ABI は {cCount} 本**", text);
        Assert.Contains($"C# の P/Invoke 宣言は {fns.Count} 本", text);
        foreach (var fn in fns)
        {
            Assert.Contains($"| `{fn.Name}` |", text);
        }
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
