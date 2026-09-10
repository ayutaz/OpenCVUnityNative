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

        // **非 standard profile には LibraryName を複製する。**
        //
        // 既定 profile の生成物は `CvUnity.Interop` の `NativeMethods` の
        // partial なので、手書き側（Runtime/Interop/NativeMethods.cs）が持つ
        // `LibraryName` がそのまま見える。**非 standard は別 assembly・別型
        // なので見えない** —— `CvUnity.Interop.Dnn` の asmdef は
        // `references: []` で、`Runtime/Interop/AssemblyInfo.cs` は
        // `InternalsVisibleTo` を意図的に出していない。複製しないと
        // `[DllImport(LibraryName, ...)]` が CS0103 でコンパイルできない
        // （合成した dnn profile の spec から生成してコンパイルし、実測した）。
        //
        // **platform の分岐ごと複製する。** 値だけを写すと、静的リンクする
        // platform（iOS / WebGL）で "__Internal" にならず、Player の中で
        // 最初の呼び出しが落ちる —— これは M6 で既定 profile 側が実際に
        // 踏んだ壊れ方である。
        //
        // **写しを 2 つ持つので、機械が突き合わせる** ——
        // Ocvu.Generator.Tests の ProfileTests が、手書き側の #if ブロックと
        // ここが出すブロックを読み比べる（どちらかが空なら落ちる）。
        // 共有 assembly へ切り出す案を採らなかった理由は
        // docs/abi-ownership-and-versioning.md §4 にある。
        if (!isStandard)
        {
            foreach (var line in LibraryNameBlock)
            {
                sb.AppendLine(line);
            }
            sb.AppendLine();
        }

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

    /// <summary>
    /// 手書きの <c>Runtime/Interop/NativeMethods.cs</c> が持つ
    /// <c>LibraryName</c> の宣言と、**1 文字も違わない**行の並び。
    /// 非 standard profile のクラスへそのまま複製する。
    /// </summary>
    /// <remarks>
    /// **ここを直したら手書き側も直す（逆も同じ）。** 2 つが食い違うことは
    /// ProfileTests が両方を読んで突き合わせる —— 片方だけ読めなかった場合も
    /// 落ちる（読めなかったことを「一致」と読まない）。
    /// </remarks>
    public static readonly string[] LibraryNameBlock =
    {
        "#if (UNITY_IOS || UNITY_WEBGL) && !UNITY_EDITOR",
        "        internal const string LibraryName = \"__Internal\";",
        "#else",
        "        internal const string LibraryName = \"opencv_unity_native\";",
        "#endif",
    };

    // "dnn" -> "Dnn"。**この前提は schema 経由の spec にしか成立しない。**
    // ModuleSpec はテスト等から schema 検証を経ずに直接組み立てられるので、
    // 空文字列が来ることがありうる —— そのまま profile[0] を読むと
    // IndexOutOfRangeException という意味の分からない例外になるので、
    // ここで明示的に拒む。
    private static string Pascalize(string profile)
    {
        if (string.IsNullOrEmpty(profile))
        {
            throw new ArgumentException(
                "profile が空文字列です。ModuleSpec.Profile は空であってはなりません。",
                nameof(profile));
        }
        return char.ToUpperInvariant(profile[0]) + profile[1..];
    }
}
