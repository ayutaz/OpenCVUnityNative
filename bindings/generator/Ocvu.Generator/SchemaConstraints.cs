using System.Text.Json;

namespace Ocvu.Generator;

// bindings/spec/schema.json から実際に読み取った enum / pattern の集合。
//
// **値をここへ書き写さない。** schema.json が「形の正本」であるためには、
// C# 側が起動のたびにその正本を読んで検証しなければならない —— 値を
// このクラスへ手書きすると、正本と実装の 2 箇所が食い違いうる二重管理に
// なる（`tools/package-release.ps1` が `tools/pack-upm-tarball.ps1` の
// ソースから `$PlatformBinaries` を読む形と同じ考え方。CLAUDE.md の
// 「写して 2 つ持たない」原則）。
//
// **読めなかったら（キーの綴りが変わった等）例外を投げる。** 「無ければ
// その項目の検証を諦める」にすると、schema.json が壊れたときに検証が
// 黙って無効化される —— それが最悪の壊れ方である。
internal sealed class SchemaConstraints
{
    public required string ModulePattern { get; init; }
    public required string FunctionNamePattern { get; init; }
    public required string EntryPointPattern { get; init; }
    public required string ParamNamePattern { get; init; }
    public required IReadOnlyList<string> ReturnsEnum { get; init; }
    public required IReadOnlyList<string> CsReturnsEnum { get; init; }
    public required IReadOnlyList<string> DirectionEnum { get; init; }

    public static SchemaConstraints ReadFrom(string schemaPath)
    {
        if (!File.Exists(schemaPath))
        {
            throw new SpecFormatException($"schema.json が見つかりません: {schemaPath}");
        }

        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(File.ReadAllText(schemaPath));
        }
        catch (JsonException ex)
        {
            throw new SpecFormatException($"schema.json を読めません: {ex.Message}");
        }

        using (doc)
        {
            var root = doc.RootElement;
            return new SchemaConstraints
            {
                ModulePattern = ExtractPattern(root, "properties.module"),
                FunctionNamePattern = ExtractPattern(root, "properties.functions.items.properties.name"),
                EntryPointPattern = ExtractPattern(root, "properties.functions.items.properties.entryPoint"),
                ParamNamePattern = ExtractPattern(
                    root, "properties.functions.items.properties.params.items.properties.name"),
                ReturnsEnum = ExtractEnum(root, "properties.functions.items.properties.returns"),
                CsReturnsEnum = ExtractEnum(root, "properties.functions.items.properties.csReturns"),
                DirectionEnum = ExtractEnum(
                    root, "properties.functions.items.properties.params.items.properties.direction"),
            };
        }
    }

    // `path` はドット区切りの property 名の列（例: "properties.module"）。
    // 途中で辿れなくなったら null を返す。「読めなかった」という判定自体は
    // 呼び出し側（ExtractPattern / ExtractEnum）が行い、例外を投げる。
    private static JsonElement? Navigate(JsonElement root, string path)
    {
        var current = root;
        foreach (var segment in path.Split('.'))
        {
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out var next))
            {
                return null;
            }
            current = next;
        }
        return current;
    }

    private static string ExtractPattern(JsonElement root, string path)
    {
        var node = Navigate(root, path);
        if (node is null
            || !node.Value.TryGetProperty("pattern", out var patternEl)
            || patternEl.ValueKind != JsonValueKind.String)
        {
            throw new SpecFormatException($"schema.json の {path}.pattern を読めません");
        }
        return patternEl.GetString()!;
    }

    private static IReadOnlyList<string> ExtractEnum(JsonElement root, string path)
    {
        var node = Navigate(root, path);
        if (node is null
            || !node.Value.TryGetProperty("enum", out var enumEl)
            || enumEl.ValueKind != JsonValueKind.Array)
        {
            throw new SpecFormatException($"schema.json の {path}.enum を読めません");
        }
        return enumEl.EnumerateArray()
            .Select(e => e.GetString()
                ?? throw new SpecFormatException($"schema.json の {path}.enum に文字列でない要素があります"))
            .ToList();
    }
}
