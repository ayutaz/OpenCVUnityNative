using System.Text;

namespace Ocvu.Generator;

/// <summary>
/// spec に載っている entry を 1 行ずつ並べた API 対応表（Markdown）を書き出す。
/// </summary>
/// <remarks>
/// **なぜ在るか。** 手で書いた対応表は、関数を足すと必ず古くなる。M3.5 では
/// <c>docs/api-reference.md</c> の「冒頭の関数の数え」と「末尾のまだ無い機能の
/// 一覧」が同時に古くなった。数も一覧も spec から出せば、ABI が 1 本増えた
/// 時点でこの表も増える —— 増えないまま commit すれば
/// <c>verify-generated</c> が赤くなる。
///
/// **「OpenCV 全対応」と書かないための表でもある。** 何が在って何が無いかを、
/// 曖昧な形容ではなく数と名前で示す。
/// </remarks>
public static class ApiMapEmitter
{
    // Markdown の表は、セルの中の `|` を列の区切りとして読む。**spec には今の
    // ところ 1 つも無いが、1 つ入った時点で表の形が黙って崩れる** ——
    // Markdown は文句を言わないので、崩れたことに気づけるのは読む人だけである。
    private static string EscapeCell(string text) => text.Replace("|", @"\|");

    public static string Emit(IReadOnlyList<ModuleSpec> specs)
    {
        // **spec の並びを保つ。** 名前で並べ替えると overload が元の関数から
        // 離れ、C の列が空欄の行だけが表のどこかに単独で現れる。並びが
        // 決定的であることは Program.cs の --check が要求するが、それは
        // spec の順でも満たされる（file は ordinal 順、関数は記述順）。
        var entries = specs
            .SelectMany(s => s.Functions.Select(f => (Module: s.Module, Fn: f)))
            .ToList();

        // **C の本数と C# の本数は別に数える。** entryPoint を持つ entry は
        // 既にある C の関数へ別の引数の形で入る C# 側の入口であって、C ABI を
        // 1 本も増やさない。片方だけを書くと、読む側がもう片方を推測する
        // ことになる。
        var cAbiCount = entries.Count(e => string.IsNullOrEmpty(e.Fn.EntryPoint));
        var overloadCount = entries.Count - cAbiCount;
        var unreachable = entries.Where(e => !e.Fn.IsReachable).ToList();

        var sb = new StringBuilder();
        sb.AppendLine("# API 対応表");
        sb.AppendLine();
        sb.AppendLine("<!-- このファイルは生成物である。手で編集しないこと。 -->");
        sb.AppendLine("<!-- 正本: bindings/spec/*.json  生成: ./tools/dev.ps1 generate -->");
        sb.AppendLine();
        sb.AppendLine($"**公開している C ABI は {cAbiCount} 本**である。" +
                      $"C# の P/Invoke 宣言は {entries.Count} 本ある。");
        sb.AppendLine();

        if (overloadCount > 0)
        {
            sb.AppendLine($"**差の {overloadCount} 本は C ABI を増やさない。** 同じ C の entry point へ");
            sb.AppendLine("別の引数の形で入る C# 側の入口（`byte[]` を渡す版と、アドレスを直接渡す版）で、");
            sb.AppendLine("C 側に対応する宣言が無い。下の表ではその行の **C ABI** の列が空欄になる。");
            sb.AppendLine();
        }

        sb.AppendLine("**「OpenCV 全対応」とは書かない。** 何が在って何が無いかは、この表が示す。");
        sb.AppendLine("ここに無い関数は**まだ無い**のであって、隠れているのではない。");
        sb.AppendLine("範囲を決めているのは [C ABI の所有権と versioning](./abi-ownership-and-versioning.md)、");
        sb.AppendLine("使い方は [API リファレンス](./api-reference.md) にある。");
        sb.AppendLine();
        sb.AppendLine("| module | C ABI | C# の宣言 | 到達性 | 内容 |");
        sb.AppendLine("| --- | --- | --- | --- | --- |");

        foreach (var (module, fn) in entries)
        {
            var cCell = string.IsNullOrEmpty(fn.EntryPoint) ? $"`{fn.Name}`" : string.Empty;
            var reach = fn.IsReachable ? "呼ぶ" : "呼ばない";
            sb.AppendLine($"| `{EscapeCell(module)}` | {cCell} | `{EscapeCell(fn.Name)}` " +
                          $"| {reach} | {EscapeCell(fn.Summary)} |");
        }

        sb.AppendLine();
        sb.AppendLine("## 到達性");
        sb.AppendLine();
        sb.AppendLine("**到達性** の列は、spec から生成される到達性テスト");
        sb.AppendLine("（`tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs`）が");
        sb.AppendLine("その宣言を実際に呼ぶかを示す。IL2CPP の stripping は呼ばれない P/Invoke");
        sb.AppendLine("宣言を消せるので、**呼ばれない宣言は消えても誰も気づかない。**");
        sb.AppendLine();

        if (unreachable.Count == 0)
        {
            sb.AppendLine("**到達性テストが呼ばない関数は無い。** spec に載っている宣言は 1 つ残らず");
            sb.AppendLine("1 回ずつ呼ばれる。");
        }
        else
        {
            sb.AppendLine($"**到達性テストが呼ばない関数は {unreachable.Count} 本ある。** 理由は spec の");
            sb.AppendLine("`reachableNote` にある（印だけ付けて理由が無い spec は生成器が拒む）。");
            sb.AppendLine();
            foreach (var (_, fn) in unreachable)
            {
                sb.AppendLine($"- `{fn.Name}` —— {fn.ReachableNote}");
            }
        }

        return sb.ToString();
    }
}
