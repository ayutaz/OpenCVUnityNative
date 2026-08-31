namespace Ocvu.Generator;

// **Task 1 時点のプレースホルダ。** `Ocvu.Generator.csproj` は
// `OutputType=Exe` を持つため、エントリポイントが無いとビルドが通らない
// （CS5001）。実際の生成処理（spec を読み、C ABI header / P/Invoke /
// API 対応表 / conformance test を書き出す）は後続タスクで `Program.cs`
// を実装として置き換える。ここでは Task 1 の目的（SpecModel と schema の
// 検証）をビルド可能にするための最小限にとどめる。
internal static class Program
{
    private static void Main()
    {
    }
}
