using System.Text;

namespace Ocvu.Generator;

/// <summary>
/// spec に載っている P/Invoke 宣言を 1 つ残らず 1 回ずつ呼ぶ C# を書き出す。
/// </summary>
/// <remarks>
/// **なぜ在るか。** IL2CPP の stripping は、呼ばれない P/Invoke 宣言を消せる。
/// M4 の点検では、手書きの 19 本のうち 7 本が Editor でも Player でも
/// 一度も呼ばれていなかった。呼ばれない宣言は、消えても誰も気づかない。
///
/// **除外は spec の reachable だけが決める。** 生成器が特定の関数名を
/// 知る形にしない —— 名前で外すと、次に同種の関数が増えたときに黙って
/// 呼ばれる（そして戻ってこない）。
/// </remarks>
public static class ReachabilityEmitter
{
    // 型ごとの無害な実引数。**結果は見ない。呼べることだけを見る。**
    // 引数はすべて native 側の入口の検査に捕まる値で、status を返して戻る。
    private static string Argument(ParamSpec p) => p.CsType switch
    {
        "ulong" => "0UL",
        "int" => "0",
        "long" => "0L",
        "double" => "0.0",
        "byte[]" => "null",
        var t when t.StartsWith("out ") => "out _",
        // 知らない csType は default で埋める。**呼ばないのではなく呼ぶ** ——
        // 型が増えたときに、その 1 本だけが静かに網から外れることのないように。
        _ => "default",
    };

    public static string Emit(IReadOnlyList<ModuleSpec> specs)
    {
        var fns = specs.SelectMany(s => s.Functions)
            .Where(f => f.IsReachable)
            .ToList();

        var sb = new StringBuilder();
        sb.AppendLine("// このファイルは生成物である。手で編集しないこと。");
        sb.AppendLine("// 正本: bindings/spec/*.json");
        sb.AppendLine("// 生成: ./tools/dev.ps1 generate");
        sb.AppendLine("//");
        sb.AppendLine("// **なぜ在るか。** IL2CPP の stripping は、呼ばれない P/Invoke 宣言を");
        sb.AppendLine("// 消せる。M4 の点検では、手書きの 19 本のうち 7 本が Editor でも");
        sb.AppendLine("// Player でも一度も呼ばれていなかった。**呼ばれない宣言は、消えても");
        sb.AppendLine("// 誰も気づかない。** ここは spec が載せる宣言を 1 つ残らず 1 回ずつ");
        sb.AppendLine("// 呼ぶ。結果は見ない —— 呼べたことだけを見る。");
        sb.AppendLine("//");
        sb.AppendLine("// 呼ばないのは spec が reachable: false と書いた関数だけで、");
        sb.AppendLine("// 理由は spec の reachableNote にある（印だけ付けて理由が");
        sb.AppendLine("// 無い spec は SpecModel が拒む）。");
        sb.AppendLine();
        sb.AppendLine("using CvUnity.Interop;");
        sb.AppendLine();
        sb.AppendLine("public static class AbiReachabilityChecks");
        sb.AppendLine("{");
        sb.AppendLine("    /// <summary>");
        sb.AppendLine("    /// 呼んだ宣言の本数を返す。C の entry point 1 本に対して C# の宣言が");
        sb.AppendLine("    /// 2 つある場合（byte[] 版とポインタ版）は 2 本と数える —— 消えるのは");
        sb.AppendLine("    /// entry point ではなく宣言のほうだからである。");
        sb.AppendLine("    /// </summary>");
        sb.AppendLine("    public static int CallEveryEntryPoint()");
        sb.AppendLine("    {");

        foreach (var fn in fns)
        {
            var args = string.Join(", ", fn.Params.Select(Argument));
            sb.AppendLine($"        NativeMethods.{fn.Name}({args});");
        }

        sb.AppendLine($"        return {fns.Count};");
        sb.AppendLine("    }");
        sb.AppendLine("}");
        return sb.ToString();
    }
}
