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

    // 実物の schema.json を temp ディレクトリへ複製する。SpecModel.Load は
    // specDir の中に schema.json があることを要求するため、schema 検証とは
    // 無関係のことを確かめたいテスト（未知フィールド・空ディレクトリ）でも、
    // それ以外の理由で落ちてしまわないようこれを呼ぶ。
    private static void CopyRealSchemaInto(string tmpDir)
    {
        File.Copy(
            Path.Combine(RepoRoot(), "bindings", "spec", "schema.json"),
            Path.Combine(tmpDir, "schema.json"));
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
            CopyRealSchemaInto(tmp);
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
        try
        {
            CopyRealSchemaInto(tmp);
            Assert.Throws<SpecFormatException>(() => SpecModel.Load(tmp));
        }
        finally { Directory.Delete(tmp, recursive: true); }
    }

    // **schema.json を実際に読んでいることの検証、1/4。** returns の enum は
    // 3 値しか許さない。SpecModel が schema を読んでいなければ何でも通る
    // （レビューで指摘された欠陥そのもの）。
    [Fact]
    public void FunctionWithReturnsOutsideTheSchemaEnumIsRejected()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "ocvu-spec-" + Path.GetRandomFileName());
        Directory.CreateDirectory(tmp);
        try
        {
            CopyRealSchemaInto(tmp);
            File.WriteAllText(Path.Combine(tmp, "bad.json"), """
                {
                  "module": "badreturns",
                  "functions": [
                    {
                      "name": "ocvu_test_fn",
                      "summary": "test",
                      "returns": "float",
                      "csReturns": "int",
                      "wrapInTryBarrier": false,
                      "params": []
                    }
                  ]
                }
                """);
            Assert.Throws<SpecFormatException>(() => SpecModel.Load(tmp));
        }
        finally { Directory.Delete(tmp, recursive: true); }
    }

    // 2/4: direction の enum。
    [Fact]
    public void ParamWithDirectionOutsideTheSchemaEnumIsRejected()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "ocvu-spec-" + Path.GetRandomFileName());
        Directory.CreateDirectory(tmp);
        try
        {
            CopyRealSchemaInto(tmp);
            File.WriteAllText(Path.Combine(tmp, "bad.json"), """
                {
                  "module": "baddirection",
                  "functions": [
                    {
                      "name": "ocvu_test_fn",
                      "summary": "test",
                      "returns": "void",
                      "csReturns": "void",
                      "wrapInTryBarrier": false,
                      "params": [
                        { "name": "x", "cType": "int32_t", "csType": "int", "direction": "sideways" }
                      ]
                    }
                  ]
                }
                """);
            Assert.Throws<SpecFormatException>(() => SpecModel.Load(tmp));
        }
        finally { Directory.Delete(tmp, recursive: true); }
    }

    // 3/4: 関数名の pattern（ocvu_ prefix）。
    [Fact]
    public void FunctionNameNotMatchingTheSchemaPatternIsRejected()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "ocvu-spec-" + Path.GetRandomFileName());
        Directory.CreateDirectory(tmp);
        try
        {
            CopyRealSchemaInto(tmp);
            File.WriteAllText(Path.Combine(tmp, "bad.json"), """
                {
                  "module": "badname",
                  "functions": [
                    {
                      "name": "not_ocvu_prefixed",
                      "summary": "test",
                      "returns": "void",
                      "csReturns": "void",
                      "wrapInTryBarrier": false,
                      "params": []
                    }
                  ]
                }
                """);
            Assert.Throws<SpecFormatException>(() => SpecModel.Load(tmp));
        }
        finally { Directory.Delete(tmp, recursive: true); }
    }

    // 4/4、**これが本題。** schema.json の構造が変わって enum が読めなく
    // なったとき、検証が黙って無効化されてはならない —— Load 自体が
    // 落ちることを確かめる。1〜3 だけでは、検証をハードコードしても
    // 通ってしまう。
    [Fact]
    public void SchemaWithAnUnreadableEnumFailsTheLoadRatherThanSkippingValidation()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "ocvu-spec-" + Path.GetRandomFileName());
        Directory.CreateDirectory(tmp);
        try
        {
            var schemaText = File.ReadAllText(Path.Combine(RepoRoot(), "bindings", "spec", "schema.json"));
            // "returns" の "enum" キーだけを別名にし、読めなくする。
            const string needle = "\"returns\": { \"type\": \"string\", \"enum\":";
            const string replacement = "\"returns\": { \"type\": \"string\", \"enumRenamed\":";
            Assert.Contains(needle, schemaText); // 置換対象が実在することを確認する
            var broken = schemaText.Replace(needle, replacement);
            Assert.NotEqual(schemaText, broken); // 置換が空振りしていないことを確認する
            File.WriteAllText(Path.Combine(tmp, "schema.json"), broken);

            // returns に本来通らないはずの値を意図的に置く。schema.json の
            // enum を読む段階で落ちるのが正しい挙動であり、ここに来る前に
            // 落ちるはずなので、この値が「たまたま有効かどうか」で
            // このテストの成否が左右されてはならない —— もし検証が
            // 黙って無効化される壊れ方をしたら、この無効な値がそのまま
            // 通ってしまうことでそれが露呈する。
            File.WriteAllText(Path.Combine(tmp, "invalid.json"), """
                {
                  "module": "invalid",
                  "functions": [
                    {
                      "name": "ocvu_invalid_fn",
                      "summary": "test",
                      "returns": "float",
                      "csReturns": "void",
                      "wrapInTryBarrier": false,
                      "params": []
                    }
                  ]
                }
                """);

            var ex = Assert.Throws<SpecFormatException>(() => SpecModel.Load(tmp));
            Assert.Contains("enum", ex.Message);
        }
        finally { Directory.Delete(tmp, recursive: true); }
    }

    // --- summary が生成物を壊さないこと（M5 Task 7）---

    // summary は 3 つの生成物へ**生のまま**入る。壊れ方はどれも
    // 「読みにくい」ではなく「ビルドが通らない」か「黙って別物になる」。
    //
    // - Markdown の表のセル（docs/api-map.md）    -> 改行が行を割る
    // - C のブロックコメント（ocvu/*.h）          -> `*/` がそこでコメントを終わらせ、
    //   残りが top-level の C コードになる（**実測でコンパイルエラー C2143**）
    // - C# の XML doc（NativeMethods.*.g.cs）     -> `<` `>` `&` が壊す。
    //   **実測: いまは落ちない** —— Shim は TreatWarningsAsErrors だが
    //   GenerateDocumentationFile が無いので compiler は doc comment を読まず、
    //   `<T>` と `&` を入れてもビルドは成功する。**壊れたまま緑になる**ほうで、
    //   doc の生成を有効にした時点で一斉にエラーになる。
    [Theory]
    [InlineData(@"1 行目\n2 行目", "改行 (LF)")]
    [InlineData(@"1 行目\r\n2 行目", "改行 (CRLF)")]
    [InlineData(@"a */ b を取る。", "C のコメントを終わらせる")]
    [InlineData(@"Mat<T> を取る。", "XML doc を壊す <>")]
    [InlineData(@"a > b のとき。", "XML doc を壊す >")]
    [InlineData(@"a & b を取る。", "XML doc を壊す &")]
    public void SummaryContainingSomethingThatBreaksAGeneratedFileIsRejected(
        string summaryLiteral, string why)
    {
        var tmp = Path.Combine(Path.GetTempPath(), "ocvu-spec-" + Path.GetRandomFileName());
        Directory.CreateDirectory(tmp);
        try
        {
            CopyRealSchemaInto(tmp);
            File.WriteAllText(Path.Combine(tmp, "bad.json"), $$"""
                {
                  "module": "breaks",
                  "functions": [
                    {
                      "name": "ocvu_test_fn",
                      "summary": "{{summaryLiteral}}",
                      "returns": "void",
                      "csReturns": "void",
                      "wrapInTryBarrier": false,
                      "params": []
                    }
                  ]
                }
                """);
            var ex = Assert.Throws<SpecFormatException>(() => SpecModel.Load(tmp));
            // **「何かが落ちた」で満足しない。** JSON の構文など手前の門ではなく、
            // schema の pattern が拒んだことまで見る —— 前回、生の改行を入れた
            // ときは System.Text.Json が先に落としており、この検査は 1 度も
            // 動いていなかった（prove-a-check-works の「手前に別の門がある」）。
            Assert.True(ex.Message.Contains("summary") && ex.Message.Contains("pattern"),
                        $"{why} を schema の pattern が拒んだのではない: {ex.Message}");
        }
        finally { Directory.Delete(tmp, recursive: true); }
    }

    // **`*` 単体は通ること。** 実物の summary が `OCVU_IMREAD_*` を含むので、
    // `*` ごと禁じると現行の spec が読めなくなる。禁じたのは `*/` である。
    [Fact]
    public void AStarThatIsNotClosingACommentIsAccepted()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "ocvu-spec-" + Path.GetRandomFileName());
        Directory.CreateDirectory(tmp);
        try
        {
            CopyRealSchemaInto(tmp);
            File.WriteAllText(Path.Combine(tmp, "ok.json"), """
                {
                  "module": "star",
                  "functions": [
                    {
                      "name": "ocvu_test_fn",
                      "summary": "flags は OCVU_IMREAD_* である。",
                      "returns": "void",
                      "csReturns": "void",
                      "wrapInTryBarrier": false,
                      "params": []
                    }
                  ]
                }
                """);
            Assert.Equal("flags は OCVU_IMREAD_* である。",
                         SpecModel.Load(tmp).Single().Functions.Single().Summary);
        }
        finally { Directory.Delete(tmp, recursive: true); }
    }

    // **barrierNote も C ヘッダの同じブロックコメントへ入る。**
    [Fact]
    public void BarrierNoteContainingACommentTerminatorIsRejected()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "ocvu-spec-" + Path.GetRandomFileName());
        Directory.CreateDirectory(tmp);
        try
        {
            CopyRealSchemaInto(tmp);
            File.WriteAllText(Path.Combine(tmp, "bad.json"), """
                {
                  "module": "badnote",
                  "functions": [
                    {
                      "name": "ocvu_test_fn",
                      "summary": "1 行に収まっている。",
                      "returns": "void",
                      "csReturns": "void",
                      "wrapInTryBarrier": false,
                      "barrierNote": "a */ b",
                      "params": []
                    }
                  ]
                }
                """);
            var ex = Assert.Throws<SpecFormatException>(() => SpecModel.Load(tmp));
            Assert.Contains("barrierNote", ex.Message);
            Assert.Contains("pattern", ex.Message);
        }
        finally { Directory.Delete(tmp, recursive: true); }
    }

    // **実物の 22 本がこの pattern を通ること。** 禁じた文字が現行 spec に
    // 1 つでもあれば、この検査ではなく spec の文言を直すのが正しい。
    [Fact]
    public void EveryRealSummaryAndBarrierNotePassesThePattern()
    {
        var fns = SpecModel.Load(Path.Combine(RepoRoot(), "bindings", "spec"))
            .SelectMany(s => s.Functions)
            .ToList();
        Assert.True(fns.Count > 10, "spec が空だと素通りする");
        foreach (var fn in fns)
        {
            Assert.DoesNotContain("*/", fn.Summary);
            Assert.DoesNotContain('<', fn.Summary);
            Assert.DoesNotContain('>', fn.Summary);
            Assert.DoesNotContain('&', fn.Summary);
        }
    }

    // 素直な summary は通ること（上の検査が summary を一律に拒んでいない確認）。
    [Fact]
    public void SummaryOnASingleLineIsAccepted()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "ocvu-spec-" + Path.GetRandomFileName());
        Directory.CreateDirectory(tmp);
        try
        {
            CopyRealSchemaInto(tmp);
            File.WriteAllText(Path.Combine(tmp, "ok.json"), """
                {
                  "module": "singleline",
                  "functions": [
                    {
                      "name": "ocvu_test_fn",
                      "summary": "1 行に収まっている。",
                      "returns": "void",
                      "csReturns": "void",
                      "wrapInTryBarrier": false,
                      "params": []
                    }
                  ]
                }
                """);
            Assert.Equal("1 行に収まっている。", SpecModel.Load(tmp).Single().Functions.Single().Summary);
        }
        finally { Directory.Delete(tmp, recursive: true); }
    }

    // **schema.json から読んでいることの検証。** summary の pattern を読めなく
    // したら、検証を諦めるのではなく Load 自体が落ちること。
    [Fact]
    public void SchemaWithAnUnreadableSummaryPatternFailsTheLoad()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "ocvu-spec-" + Path.GetRandomFileName());
        Directory.CreateDirectory(tmp);
        try
        {
            var schemaText = File.ReadAllText(Path.Combine(RepoRoot(), "bindings", "spec", "schema.json"));
            const string needle = "\"summary\": { \"type\": \"string\", \"minLength\": 1, \"pattern\":";
            const string replacement = "\"summary\": { \"type\": \"string\", \"minLength\": 1, \"patternRenamed\":";
            Assert.Contains(needle, schemaText);          // 置換対象が実在すること
            var broken = schemaText.Replace(needle, replacement);
            Assert.NotEqual(schemaText, broken);          // 置換が空振りしていないこと
            File.WriteAllText(Path.Combine(tmp, "schema.json"), broken);
            File.WriteAllText(Path.Combine(tmp, "any.json"), """
                {
                  "module": "any",
                  "functions": [
                    {
                      "name": "ocvu_test_fn",
                      "summary": "1 行。",
                      "returns": "void",
                      "csReturns": "void",
                      "wrapInTryBarrier": false,
                      "params": []
                    }
                  ]
                }
                """);
            var ex = Assert.Throws<SpecFormatException>(() => SpecModel.Load(tmp));
            Assert.Contains("summary", ex.Message);
        }
        finally { Directory.Delete(tmp, recursive: true); }
    }

    // --- reachable（M5 Task 6）---

    // **既定は true である。** spec が reachable を書いていない関数は
    // 到達性テストが呼ぶ。書き忘れが静かな除外にならないようにするため。
    [Fact]
    public void FunctionsWithoutTheReachableFlagDefaultToReachable()
    {
        var fns = SpecModel.Load(Path.Combine(RepoRoot(), "bindings", "spec"))
            .SelectMany(s => s.Functions)
            .ToDictionary(f => f.Name);

        Assert.Null(fns["ocvu_mat_create"].Reachable);   // spec に書かれていない
        Assert.True(fns["ocvu_mat_create"].IsReachable); // それでも到達可能
    }

    // **実物の spec で「呼べない」と印が付いているのは crash probe だけ。**
    // 増えたら、増やした本人がここを直しながら「なぜ呼べないか」を考える。
    [Fact]
    public void OnlyTheCrashProbeIsMarkedUnreachable()
    {
        var unreachable = SpecModel.Load(Path.Combine(RepoRoot(), "bindings", "spec"))
            .SelectMany(s => s.Functions)
            .Where(f => !f.IsReachable)
            .Select(f => f.Name)
            .ToList();

        Assert.Equal(new[] { "ocvu_debug_crash" }, unreachable);
    }

    // **「なぜ呼ばないか」を書かせる。** 印だけ付けて理由が無いと、
    // 次に読む人は spec を読んでも分からない。
    [Fact]
    public void MarkingAFunctionUnreachableWithoutSayingWhyIsRejected()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "ocvu-spec-" + Path.GetRandomFileName());
        Directory.CreateDirectory(tmp);
        try
        {
            CopyRealSchemaInto(tmp);
            File.WriteAllText(Path.Combine(tmp, "bad.json"), """
                {
                  "module": "noreason",
                  "functions": [
                    {
                      "name": "ocvu_test_fn",
                      "summary": "test",
                      "returns": "void",
                      "csReturns": "void",
                      "wrapInTryBarrier": false,
                      "reachable": false,
                      "params": []
                    }
                  ]
                }
                """);
            var ex = Assert.Throws<SpecFormatException>(() => SpecModel.Load(tmp));
            Assert.Contains("reachableNote", ex.Message);
        }
        finally { Directory.Delete(tmp, recursive: true); }
    }

    // 理由を書けば通ること（上の検査が「reachable: false を一律に拒む」
    // だけになっていないことの確認）。
    [Fact]
    public void MarkingAFunctionUnreachableWithAReasonIsAccepted()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "ocvu-spec-" + Path.GetRandomFileName());
        Directory.CreateDirectory(tmp);
        try
        {
            CopyRealSchemaInto(tmp);
            File.WriteAllText(Path.Combine(tmp, "ok.json"), """
                {
                  "module": "withreason",
                  "functions": [
                    {
                      "name": "ocvu_test_fn",
                      "summary": "test",
                      "returns": "void",
                      "csReturns": "void",
                      "wrapInTryBarrier": false,
                      "reachable": false,
                      "reachableNote": "呼ぶと戻ってこないため",
                      "params": []
                    }
                  ]
                }
                """);
            var loaded = SpecModel.Load(tmp);
            Assert.False(loaded.Single().Functions.Single().IsReachable);
        }
        finally { Directory.Delete(tmp, recursive: true); }
    }
}
