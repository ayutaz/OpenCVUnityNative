using Ocvu.Generator;

var repoRoot = Directory.GetCurrentDirectory();
var check = false;
var listOutputs = false;
for (var i = 0; i < args.Length; i++)
{
    if (args[i] == "--repo-root" && i + 1 < args.Length) { repoRoot = args[++i]; }
    else if (args[i] == "--check") { check = true; }
    // **生成器に自分の出力を申告させる。** 検査する側が名前を並べると、
    // 11 個目を足したときにその 1 つだけが静かに網から外れる（実測で
    // AbiReachabilityChecks.g.cs がそうなっていた —— 名指しで守られて
    // いたのは 10 個のうち 2 つだけで、配線を外しても全部 PASS した）。
    else if (args[i] == "--list-outputs") { listOutputs = true; }
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

// **module ごとではなく 1 ファイル。** 全 entry point を横断して 1 回ずつ
// 呼ぶので、module に分けると「全部呼んだ」を 1 箇所で数えられなくなる。
outputs.Add((Path.Combine(repoRoot, ReachabilityEmitter.OutputPath),
             ReachabilityEmitter.Emit(specs)));

// **文書も生成物にする。** 手で書いた対応表は関数を足すと必ず古くなる
// （M3.5 では docs/api-reference.md の冒頭の数えと末尾の一覧が同時に
// 古くなった）。ここを spec から出しておけば、古いまま commit すると
// --check が赤くなる。
outputs.Add((Path.Combine(repoRoot, "docs", "api-map.md"),
             ApiMapEmitter.Emit(specs)));

if (listOutputs)
{
    // 区切りは '/' に固定する。検査する側が platform で別の文字列を見ないため。
    foreach (var (path, _) in outputs)
    {
        Console.WriteLine(Path.GetRelativePath(repoRoot, path).Replace('\\', '/'));
    }
    return 0;
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
