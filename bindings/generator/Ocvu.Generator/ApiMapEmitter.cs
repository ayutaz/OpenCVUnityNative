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
    private const string TableHeader = "| module | C ABI | C# の宣言 | 到達性 | 内容 |";
    private const string TableSeparator = "| --- | --- | --- | --- | --- |";

    /// <summary>
    /// Markdown の表のセルへ入れられる形に逃がす。
    /// </summary>
    /// <remarks>
    /// **<c>\</c> を先に逃がす。** 順序を逆にすると、<c>|</c> を <c>\|</c> に
    /// した後の <c>\</c> まで二重化してしまう。そして <c>\</c> を逃がさないと、
    /// summary が <c>\</c> で終わるところで <c>\|</c> が <c>\\|</c> になり、
    /// Markdown はこれを「逃がした <c>\</c>」+「素の <c>|</c>」と読んで列が割れる。
    ///
    /// **改行は逃がさない。禁じてある。** 表の 1 行の中で改行を表現する方法は
    /// 無いので、逃がしようがない —— <c>bindings/spec/schema.json</c> の
    /// summary の pattern が改行を含む spec を拒む
    /// （<c>docs/abi-ownership-and-versioning.md</c> §1 の「規約で禁じるのでは
    /// なく表現できなくする」）。
    /// </remarks>
    private static string EscapeCell(string text) => text.Replace(@"\", @"\\").Replace("|", @"\|");

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
        var overloads = entries.Where(e => !string.IsNullOrEmpty(e.Fn.EntryPoint)).ToList();
        var cAbiCount = entries.Count - overloads.Count;
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

        if (overloads.Count > 0)
        {
            // **内訳も spec から出す。** ここに「`byte[]` を渡す版とポインタ版」
            // のような固定文を置くと、3 本目が別の形で入った瞬間に、本数だけ
            // 正しく中身が嘘の文になる。名前と向き先を並べておけば、増えても
            // 減っても勝手に追随する。
            sb.AppendLine($"**差の {overloads.Count} 本は C ABI を増やさない。** 既にある C の entry point へ");
            sb.AppendLine("別の引数の形で入る C# 側の入口で、C 側に対応する宣言が無い。");
            sb.AppendLine("下の表ではその行の **C ABI** の列が空欄になる。");
            sb.AppendLine();
            foreach (var (_, fn) in overloads)
            {
                sb.AppendLine($"- `{fn.Name}` → `{fn.EntryPoint}`");
            }
            sb.AppendLine();
        }

        sb.AppendLine("**「OpenCV 全対応」とは書かない。** 何が在って何が無いかは、この表が示す。");
        sb.AppendLine("ここに無い関数は**まだ無い**のであって、隠れているのではない。");
        sb.AppendLine("範囲を決めているのは [C ABI の所有権と versioning](./abi-ownership-and-versioning.md)、");
        sb.AppendLine("使い方は [API リファレンス](./api-reference.md) にある。");
        sb.AppendLine();
        sb.AppendLine(TableHeader);
        sb.AppendLine(TableSeparator);

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
        // **パスを写さない。** 出力先を決めているのは ReachabilityEmitter で、
        // ここが写すと片方を動かしたときにもう片方だけが残る。
        sb.AppendLine($"（`{ReachabilityEmitter.OutputPath}`）が");
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

        // **出したものを、出す前に自分で読み直す。** 入口（schema の pattern）は
        // 「表を壊す文字」の**列挙**であって、書いた人が思いつかなかった文字は
        // 通る。ここは出来上がった表の**構造**だけを見るので、**どの文字が
        // 原因かに依存しない** —— 将来どんな値が列を割っても、割れたことが分かる。
        var text = sb.ToString();
        RequireTheTableIsWellFormed(text, entries.Count);
        return text;
    }

    /// <summary>
    /// 出来上がった Markdown の表が、見出しと同じ列数の行を
    /// <paramref name="expectedRowCount"/> 行だけ持つことを確かめる。
    /// </summary>
    /// <remarks>
    /// **中間のデータではなく、出来上がった文字列を読む。** 行を組み立てた側と
    /// 同じ数え方をすると、両方が同じ間違いをしたときに素通りする。
    /// </remarks>
    public static void RequireTheTableIsWellFormed(string markdown, int expectedRowCount)
    {
        var lines = markdown.Replace("\r\n", "\n").Split('\n');
        var head = Array.IndexOf(lines, TableHeader);
        if (head < 0 || head + 1 >= lines.Length || lines[head + 1] != TableSeparator)
        {
            throw new SpecFormatException(
                "生成した API 対応表に、期待した見出しと区切りの 2 行が見つかりません。");
        }

        // 見出しと区切りに続く「`|` で始まる行」を表の本体とみなす。**途切れたら
        // そこで終わる** —— セルの中で行が割れると、割れた後ろは `|` で始まらない
        // ので本体から外れ、下の行数の照合に引っかかる。
        var body = new List<string>();
        for (var i = head + 2; i < lines.Length && lines[i].StartsWith("|"); i++)
        {
            body.Add(lines[i]);
        }

        var expected = CountTableDelimiters(TableHeader);
        foreach (var line in new[] { lines[head], lines[head + 1] }.Concat(body))
        {
            var actual = CountTableDelimiters(line);
            if (actual != expected)
            {
                throw new SpecFormatException(
                    $"生成した API 対応表の列数が揃っていません（区切りが {expected} 個であるべきところ " +
                    $"{actual} 個）。逃がし損ねた '|' か、セルの中で割れた行があります: {line}");
            }
        }

        if (body.Count != expectedRowCount)
        {
            throw new SpecFormatException(
                $"生成した API 対応表の行数が spec の entry 数と一致しません" +
                $"（表 {body.Count} 行 / spec {expectedRowCount} 件）。" +
                "セルの中で行が割れると、割れた後ろは表の本体から外れます。");
        }
    }

    /// <summary>
    /// Markdown の表の 1 行が持つ<b>列の区切り</b>の個数。
    /// </summary>
    /// <remarks>
    /// **<c>|</c> を数えるのでも、直前の 1 文字を見るのでもない。** Markdown は
    /// <c>\</c> が次の 1 文字を逃がす規則なので、**逃がした <c>\</c> の直後の
    /// <c>|</c> は区切りである**。<c>a\\|b</c> を「逃がされた <c>|</c>」と読む
    /// 数え方は、<c>\</c> を逃がし損ねた欠陥をそのまま見逃す（1 波目に書いた
    /// 正規表現 <c>(?&lt;!\\)\|</c> がまさにそれだった）。ここは Markdown と
    /// 同じ規則で 1 文字ずつ走査する。
    /// </remarks>
    public static int CountTableDelimiters(string line)
    {
        var count = 0;
        var escaped = false;
        foreach (var ch in line)
        {
            if (escaped) { escaped = false; continue; }
            if (ch == '\\') { escaped = true; continue; }
            if (ch == '|') { count++; }
        }
        return count;
    }
}
