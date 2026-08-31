using Ocvu.Generator;

var repoRoot = Directory.GetCurrentDirectory();
var check = false;
for (var i = 0; i < args.Length; i++)
{
    if (args[i] == "--repo-root" && i + 1 < args.Length) { repoRoot = args[++i]; }
    else if (args[i] == "--check") { check = true; }
    else { Console.Error.WriteLine($"unknown argument: {args[i]}"); return 2; }
}

var specs = SpecModel.Load(Path.Combine(repoRoot, "bindings", "spec"));

var outputs = new List<(string Path, string Text)>();
foreach (var spec in specs)
{
    outputs.Add((Path.Combine(repoRoot, "native", "include", "ocvu", $"{spec.Module}.h"),
                 CHeaderEmitter.Emit(spec)));
    var pascal = char.ToUpperInvariant(spec.Module[0]) + spec.Module[1..];
    outputs.Add((Path.Combine(repoRoot, "Packages", "com.ayutaz.opencv-unity-native",
                              "Runtime", "Interop", $"NativeMethods.{pascal}.g.cs"),
                 CsPInvokeEmitter.Emit(spec)));
}

var stale = new List<string>();
foreach (var (path, text) in outputs)
{
    var existing = File.Exists(path) ? File.ReadAllText(path) : null;
    // 改行を正規化して比べる。CRLF / LF の差で赤くしない。
    var same = existing is not null
        && existing.Replace("\r\n", "\n") == text.Replace("\r\n", "\n");
    if (same) { continue; }

    stale.Add(Path.GetRelativePath(repoRoot, path));
    if (!check)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text);
    }
}

if (check && stale.Count > 0)
{
    Console.Error.WriteLine("生成物が spec と食い違っています:");
    foreach (var s in stale) { Console.Error.WriteLine($"  - {s}"); }
    Console.Error.WriteLine("./tools/dev.ps1 generate を実行してコミットしてください。");
    return 1;
}

Console.WriteLine(check
    ? $"==> 生成物は spec と一致しています（{outputs.Count} ファイル）"
    : $"==> {outputs.Count} ファイルを生成しました（更新 {stale.Count} 件）");
return 0;
