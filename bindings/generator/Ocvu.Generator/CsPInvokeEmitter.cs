using System.Text;

namespace Ocvu.Generator;

public static class CsPInvokeEmitter
{
    public static string Emit(ModuleSpec spec)
    {
        var sb = new StringBuilder();
        sb.AppendLine("// このファイルは生成物である。手で編集しないこと。");
        sb.AppendLine($"// 正本: bindings/spec/{spec.Module}.json");
        sb.AppendLine("// 生成: ./tools/dev.ps1 generate");
        sb.AppendLine();
        sb.AppendLine("using System.Runtime.InteropServices;");
        sb.AppendLine();
        sb.AppendLine("namespace CvUnity.Interop");
        sb.AppendLine("{");
        sb.AppendLine("    internal static partial class NativeMethods");
        sb.AppendLine("    {");

        foreach (var fn in spec.Functions)
        {
            sb.AppendLine($"        /// <summary>{fn.Summary}</summary>");
            var entry = string.IsNullOrEmpty(fn.EntryPoint)
                ? ""
                : $"EntryPoint = \"{fn.EntryPoint}\", ";
            sb.AppendLine($"        [DllImport(LibraryName, {entry}CallingConvention = CallingConvention.Cdecl)]");
            var ps = string.Join(", ", fn.Params.Select(p => $"{p.CsType} {p.Name}"));
            sb.AppendLine($"        internal static extern {fn.CsReturns} {fn.Name}({ps});");
            sb.AppendLine();
        }

        sb.AppendLine("    }");
        sb.AppendLine("}");
        return sb.ToString();
    }
}
