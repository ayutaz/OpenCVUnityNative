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

        // **standard 以外は別 namespace・別クラスへ出す。** partial class は
        // assembly を跨げないので、同じ型にはできない（internal のままにする
        // 理由と合わせて AssemblyInfo.cs 側に書いてある）。
        var isStandard = spec.Profile == "standard";
        var suffix = isStandard ? "" : Pascalize(spec.Profile);

        sb.AppendLine(isStandard
            ? "namespace CvUnity.Interop"
            : $"namespace CvUnity.Interop.{suffix}");
        sb.AppendLine("{");
        sb.AppendLine($"    internal static partial class NativeMethods{suffix}");
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

    // "dnn" -> "Dnn"。profile 名は schema の enum で閉じているので先頭 1 文字は
    // 必ず存在する（空文字列にはなり得ない）。
    private static string Pascalize(string profile) =>
        char.ToUpperInvariant(profile[0]) + profile[1..];
}
