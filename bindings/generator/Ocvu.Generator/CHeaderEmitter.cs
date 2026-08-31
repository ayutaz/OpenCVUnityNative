using System.Text;

namespace Ocvu.Generator;

public static class CHeaderEmitter
{
    public static string Emit(ModuleSpec spec)
    {
        var guard = $"OCVU_{spec.Module.ToUpperInvariant()}_H";
        var sb = new StringBuilder();

        sb.AppendLine("/*");
        sb.AppendLine(" * このファイルは生成物である。手で編集しないこと。");
        sb.AppendLine($" * 正本: bindings/spec/{spec.Module}.json");
        sb.AppendLine(" * 生成: ./tools/dev.ps1 generate");
        sb.AppendLine(" */");
        sb.AppendLine($"#ifndef {guard}");
        sb.AppendLine($"#define {guard}");
        sb.AppendLine();
        sb.AppendLine("#include \"opencv_unity_native.h\"");
        sb.AppendLine();
        sb.AppendLine("#ifdef __cplusplus");
        sb.AppendLine("extern \"C\" {");
        sb.AppendLine("#endif");
        sb.AppendLine();

        foreach (var fn in spec.Functions)
        {
            sb.AppendLine($"/* {fn.Summary} */");
            if (!fn.WrapInTryBarrier && !string.IsNullOrEmpty(fn.BarrierNote))
            {
                sb.AppendLine($"/* 例外バリアで囲まない: {fn.BarrierNote} */");
            }
            var ps = fn.Params.Count == 0
                ? "void"
                : string.Join(", ", fn.Params.Select(p => $"{p.CType} {p.Name}"));
            sb.AppendLine($"OCVU_API {fn.Returns} {fn.Name}({ps});");
            sb.AppendLine();
        }

        sb.AppendLine("#ifdef __cplusplus");
        sb.AppendLine("}  /* extern \"C\" */");
        sb.AppendLine("#endif");
        sb.AppendLine();
        sb.AppendLine($"#endif  /* {guard} */");
        return sb.ToString();
    }
}
