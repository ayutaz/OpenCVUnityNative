using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Ocvu.Generator;

public sealed class SpecFormatException : Exception
{
    public SpecFormatException(string message) : base(message) { }
}

public sealed record ParamSpec(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("cType")] string CType,
    [property: JsonPropertyName("csType")] string CsType,
    [property: JsonPropertyName("direction")] string Direction);

public sealed record FunctionSpec(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("summary")] string Summary,
    [property: JsonPropertyName("returns")] string Returns,
    [property: JsonPropertyName("csReturns")] string CsReturns,
    [property: JsonPropertyName("wrapInTryBarrier")] bool WrapInTryBarrier,
    [property: JsonPropertyName("params")] IReadOnlyList<ParamSpec> Params,
    [property: JsonPropertyName("barrierNote")] string? BarrierNote = null,
    [property: JsonPropertyName("entryPoint")] string? EntryPoint = null,
    [property: JsonPropertyName("reachable")] bool? Reachable = null,
    [property: JsonPropertyName("reachableNote")] string? ReachableNote = null)
{
    /// <summary>
    /// 到達性テスト（<c>ReachabilityEmitter</c>）がこの関数を呼ぶか。
    /// </summary>
    /// <remarks>
    /// **既定は true である。** spec が <c>reachable</c> を書いていない関数は
    /// 呼ぶ側に回る —— 「呼べる」が普通で、「呼べない」ほうが例外だからで、
    /// 書き忘れが静かな除外にならないようにするためでもある。
    ///
    /// **nullable にしてあるのは、既定値の解釈を JSON 実装に委ねないため。**
    /// bool の必須でない値をそのまま受けると「書かれていない」と「false と
    /// 書かれている」が区別できず、既定が false 側に倒れれば到達性テストは
    /// 1 本も呼ばないまま緑になる。ここで null と false を分けておけば、
    /// どちらに転んでも既定は true のままである。
    /// </remarks>
    public bool IsReachable => Reachable != false;
}

public sealed record ModuleSpec(
    [property: JsonPropertyName("module")] string Module,
    [property: JsonPropertyName("functions")] IReadOnlyList<FunctionSpec> Functions);

public static class SpecModel
{
    private static readonly JsonSerializerOptions Options = new()
    {
        // **知らないフィールドを黙って捨てない。** 綴り間違いは形の誤りである。
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        ReadCommentHandling = JsonCommentHandling.Disallow,
    };

    public static IReadOnlyList<ModuleSpec> Load(string specDir)
    {
        // **schema.json を実際に読む。** C# レコードの必須引数と
        // UnmappedMemberHandling.Disallow はフィールド名の綴りと必須性しか
        // カバーしない。enum / pattern を強制するのはここから先の役目で、
        // その enum / pattern 自体は schema.json から読み取る（手で複製しない）。
        var schemaConstraints = SchemaConstraints.ReadFrom(Path.Combine(specDir, "schema.json"));

        var files = Directory.GetFiles(specDir, "*.json")
            .Where(f => Path.GetFileName(f) != "schema.json")
            .OrderBy(f => f, StringComparer.Ordinal)
            .ToList();

        if (files.Count == 0)
        {
            throw new SpecFormatException($"spec が 1 件も見つかりません: {specDir}");
        }

        var result = new List<ModuleSpec>();
        foreach (var file in files)
        {
            ModuleSpec? spec;
            try
            {
                spec = JsonSerializer.Deserialize<ModuleSpec>(File.ReadAllText(file), Options);
            }
            catch (JsonException ex)
            {
                throw new SpecFormatException($"{Path.GetFileName(file)} を読めません: {ex.Message}");
            }
            if (spec is null)
            {
                throw new SpecFormatException($"{Path.GetFileName(file)} が null になりました");
            }
            ValidateAgainstSchema(Path.GetFileName(file), spec, schemaConstraints);
            result.Add(spec);
        }
        return result;
    }

    private static void ValidateAgainstSchema(string fileName, ModuleSpec spec, SchemaConstraints c)
    {
        if (!Regex.IsMatch(spec.Module, c.ModulePattern))
        {
            throw new SpecFormatException(
                $"{fileName}: module '{spec.Module}' が schema の pattern '{c.ModulePattern}' に一致しません");
        }

        foreach (var fn in spec.Functions)
        {
            if (!Regex.IsMatch(fn.Name, c.FunctionNamePattern))
            {
                throw new SpecFormatException(
                    $"{fileName}: 関数名 '{fn.Name}' が schema の pattern '{c.FunctionNamePattern}' に一致しません");
            }
            // **改行は逃がすのではなく禁じる。** summary は Markdown の表の
            // セルへ入る（docs/api-map.md）。表の 1 行の中で改行を表現する
            // 方法は無いので、入れば行そのものが割れる —— Markdown は
            // 文句を言わないので、気づけるのは読む人だけである。
            // 規約で禁じるのではなく、spec の側で表現できなくする
            // （docs/abi-ownership-and-versioning.md §1 と同じ考え方）。
            if (!Regex.IsMatch(fn.Summary, c.SummaryPattern))
            {
                throw new SpecFormatException(
                    $"{fileName}: {fn.Name}.summary が schema の pattern '{c.SummaryPattern}' に" +
                    "一致しません（改行は表のセルに入れられないので禁じています）");
            }
            if (!c.ReturnsEnum.Contains(fn.Returns))
            {
                throw new SpecFormatException(
                    $"{fileName}: {fn.Name}.returns '{fn.Returns}' は schema の enum" +
                    $"（{string.Join(", ", c.ReturnsEnum)}）のいずれでもありません");
            }
            if (!c.CsReturnsEnum.Contains(fn.CsReturns))
            {
                throw new SpecFormatException(
                    $"{fileName}: {fn.Name}.csReturns '{fn.CsReturns}' は schema の enum" +
                    $"（{string.Join(", ", c.CsReturnsEnum)}）のいずれでもありません");
            }
            if (fn.EntryPoint is not null && !Regex.IsMatch(fn.EntryPoint, c.EntryPointPattern))
            {
                throw new SpecFormatException(
                    $"{fileName}: {fn.Name}.entryPoint '{fn.EntryPoint}' が schema の pattern " +
                    $"'{c.EntryPointPattern}' に一致しません");
            }
            // **「呼べない」と印を付けるなら理由を書かせる。** reachable: false は
            // 到達性テストの網から 1 本を外すので、なぜ外すのかが spec を読んで
            // 分からなければ、次に読む人はそれが意図か事故かを判定できない。
            if (!fn.IsReachable && string.IsNullOrWhiteSpace(fn.ReachableNote))
            {
                throw new SpecFormatException(
                    $"{fileName}: {fn.Name} は reachable: false だが reachableNote がありません。" +
                    "到達性テストから外す理由を書いてください。");
            }

            foreach (var p in fn.Params)
            {
                if (!Regex.IsMatch(p.Name, c.ParamNamePattern))
                {
                    throw new SpecFormatException(
                        $"{fileName}: {fn.Name} の param 名 '{p.Name}' が schema の pattern " +
                        $"'{c.ParamNamePattern}' に一致しません");
                }
                if (!c.DirectionEnum.Contains(p.Direction))
                {
                    throw new SpecFormatException(
                        $"{fileName}: {fn.Name}.{p.Name}.direction '{p.Direction}' は schema の enum" +
                        $"（{string.Join(", ", c.DirectionEnum)}）のいずれでもありません");
                }
            }
        }
    }
}
