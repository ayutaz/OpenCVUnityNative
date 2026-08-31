using System;
using System.IO;
using System.Linq;
using Xunit;

namespace Ocvu.Generator.Tests;

public class SpecSchemaTests
{
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

    [Fact]
    public void EverySpecFileLoads()
    {
        var specs = SpecModel.Load(Path.Combine(RepoRoot(), "bindings", "spec"));
        Assert.NotEmpty(specs);
        Assert.All(specs, s => Assert.NotEmpty(s.Functions));
    }

    // **囲ってはならない関数を spec が知っていること。**
    // native/src/ocvu_error.h が「囲まない関数」を列挙している。spec がそれと
    // 食い違うと、生成した宣言は正しくても実装のレビューが誤誘導される。
    [Fact]
    public void LastErrorAccessorsAreNotWrappedInTheBarrier()
    {
        var fns = SpecModel.Load(Path.Combine(RepoRoot(), "bindings", "spec"))
            .SelectMany(s => s.Functions)
            .ToDictionary(f => f.Name);

        Assert.False(fns["ocvu_get_last_error_status"].WrapInTryBarrier);
        Assert.False(fns["ocvu_get_abi_version"].WrapInTryBarrier);
        Assert.False(fns["ocvu_get_status_count"].WrapInTryBarrier);
    }

    // **知らないフィールドを黙って捨てない。**
    [Fact]
    public void UnknownFieldsAreRejected()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "ocvu-spec-" + Path.GetRandomFileName());
        Directory.CreateDirectory(tmp);
        try
        {
            File.WriteAllText(Path.Combine(tmp, "bad.json"),
                "{ \"module\": \"bad\", \"functions\": [], \"typoField\": 1 }");
            Assert.Throws<SpecFormatException>(() => SpecModel.Load(tmp));
        }
        finally { Directory.Delete(tmp, recursive: true); }
    }

    // **0 件で通さない。** spec が消えても「空で成功」しては困る。
    [Fact]
    public void AnEmptySpecDirectoryIsRejected()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "ocvu-spec-" + Path.GetRandomFileName());
        Directory.CreateDirectory(tmp);
        try { Assert.Throws<SpecFormatException>(() => SpecModel.Load(tmp)); }
        finally { Directory.Delete(tmp, recursive: true); }
    }
}
