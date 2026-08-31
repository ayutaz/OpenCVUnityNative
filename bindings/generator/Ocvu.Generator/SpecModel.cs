using System.Text.Json;
using System.Text.Json.Serialization;

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
    [property: JsonPropertyName("entryPoint")] string? EntryPoint = null);

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
            result.Add(spec);
        }
        return result;
    }
}
