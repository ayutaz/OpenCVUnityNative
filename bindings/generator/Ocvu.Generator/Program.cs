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

    // **standard 以外は別ディレクトリへ出す。** partial class は assembly を
    // 跨げないので、profile ごとに別 assembly（別ディレクトリの asmdef）へ
    // 分かれる（CsPInvokeEmitter が出す namespace / クラス名と対応する）。
    var interopDir = spec.Profile == "standard"
        ? "Interop"
        : "Interop." + char.ToUpperInvariant(spec.Profile[0]) + spec.Profile[1..];
    outputs.Add((Path.Combine(repoRoot, "Packages", "com.ayutaz.opencv-unity-native",
                              "Runtime", interopDir, $"NativeMethods.{pascal}.g.cs"),
                 CsPInvokeEmitter.Emit(spec)));
}

// **module ごとではなく profile ごとに 1 ファイル。** 全 entry point を
// 横断して 1 回ずつ呼ぶので、module に分けると「全部呼んだ」を 1 箇所で
// 数えられなくなる —— この理由は profile の内側でも変わらず成立する。
//
// **profile をまたいでは 1 ファイルにしない。** partial class は assembly を
// 跨げないので、非既定 profile の宣言は別 assembly（別クラス）に出る。
// 1 ファイルへ #if で同居させると、CvUnity.Tests.Shared が
// CvUnity.Interop.Dnn を参照することになり、define が立っていないとき
// 参照先の assembly がそもそもコンパイルされていない状態になる
// （Unity がその参照をどう扱うかは測っていない）。
foreach (var profile in specs.Select(s => s.Profile).Distinct().OrderBy(p => p, StringComparer.Ordinal))
{
    outputs.Add((Path.Combine(repoRoot, ReachabilityEmitter.OutputPathFor(profile)),
                 ReachabilityEmitter.Emit(specs, profile)));
}

// **文書も生成物にする。** 手で書いた対応表は関数を足すと必ず古くなる
// （M3.5 では docs/api-reference.md の冒頭の数えと末尾の一覧が同時に
// 古くなった）。ここを spec から出しておけば、古いまま commit すると
// --check が赤くなる。
outputs.Add((Path.Combine(repoRoot, "docs", "api-map.md"),
             ApiMapEmitter.Emit(specs)));

var stale = new List<string>();
foreach (var (path, text) in outputs)
{
    // **申告するのは、書き込むのと同じ 1 つの繰り返しである。** 早い return で
    // 別に列挙すると、その下に足した outputs だけが「生成されるのに申告されない」
    // 状態になる（実測で踏んだ）。同じ loop に置けば、**outputs に入れた物が
    // 申告から漏れることは無い。**
    //
    // **これは outputs を通る物だけの保証である。** outputs を経由せず
    // File.WriteAllText で直接書けば、その file は申告にも --check にも現れない
    // —— そこを塞いでいるのは構造ではなく「生成物は冒頭で生成物だと名乗る」
    // 規約で、tools/tests/BindingGenerator.Tests.ps1 がその名乗りを走査している。
    if (listOutputs)
    {
        // 区切りは '/' に固定する。検査する側が platform で別の文字列を見ないため。
        Console.WriteLine(Path.GetRelativePath(repoRoot, path).Replace('\\', '/'));
        continue;
    }

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

if (listOutputs) { return 0; }

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
