using System.Linq;
using NUnit.Framework;
using UnityEditor.Compilation;

/// <summary>
/// **profile の切り替えが Unity のコンパイル単位として効いていること。**
///
/// PluginGatingTests が「Unity が自分の platform の plugin だけを有効にする」
/// ことを PluginImporter に問うのと同じ形で、こちらは
/// **assembly の定義を Unity 自身に問う。**
///
/// 自分で asmdef の JSON をパースする案は採らない ——
/// **自分でパースする検査は本物の解釈を代理できない**
/// （prove-a-check-works skill。M4 で .meta のキー名がまさにこれで、
/// 自前パースは通り、Unity に問う検査だけが落とした）。
/// </summary>
public class ProfileGatingTests
{
    private const string DnnAssembly = "CvUnity.Interop.Dnn";
    private const string StandardAssembly = "CvUnity.Interop";
    private const string DnnSharedTestAssembly = "CvUnity.Tests.Shared.Dnn";

    [Test]
    public void TheStandardInteropAssemblyIsAlwaysCompiled()
    {
        var names = CompilationPipeline.GetAssemblies(AssembliesType.Editor)
            .Select(a => a.name).ToList();
        Assert.Contains(StandardAssembly, names,
            "既定の Interop assembly がコンパイルされていない");
    }

    /// <summary>
    /// **define が無ければ dnn の assembly はコンパイルされない。**
    ///
    /// これが roadmap の決定 2（「dnn が入らないビルドで参照が壊れない」）の
    /// 実体である —— 実行時に EntryPointNotFoundException が出ることではなく、
    /// **参照するコードがビルドを通らないこと。**
    /// </summary>
    [Test]
    public void TheDnnInteropAssemblyIsAbsentWithoutItsDefine()
    {
        var defines = UnityEditor.PlayerSettings.GetScriptingDefineSymbols(
            UnityEditor.Build.NamedBuildTarget.Standalone);

        // このプロジェクトは既定で OCVU_PROFILE_DNN を立てていない。
        // **前提が崩れたら、この検査は何も見ていないので落とす。**
        Assert.That(defines, Does.Not.Contain("OCVU_PROFILE_DNN"),
            "このテストは OCVU_PROFILE_DNN が立っていないことを前提にしている");

        var names = CompilationPipeline.GetAssemblies(AssembliesType.Editor)
            .Select(a => a.name).ToList();
        Assert.That(names, Does.Not.Contain(DnnAssembly),
            "define が無いのに dnn の assembly がコンパイルされている。" +
            "defineConstraints が効いていない");
    }

    /// <summary>
    /// **asmdef のファイル自体は在ること。**
    ///
    /// 上の検査は「コンパイルされていない」を見るが、
    /// **asmdef を消しても同じ結果になる。** 在ることを別に要求しないと、
    /// 機構ごと消えたのか制約が効いているのか区別できない。
    /// </summary>
    [Test]
    public void TheDnnAsmdefExistsOnDisk()
    {
        var guids = UnityEditor.AssetDatabase.FindAssets("CvUnity.Interop.Dnn t:AssemblyDefinitionAsset");
        Assert.IsNotEmpty(guids,
            "dnn の asmdef がプロジェクトに無い。制約が効いているのではなく、機構ごと無い");
    }

    /// <summary>
    /// **到達性テストの受け皿（`CvUnity.Tests.Shared.Dnn`）も、同じ define で切れていること。**
    ///
    /// D8 の目的は「非 default profile の到達性テストが既定ビルドを壊さないこと」で、
    /// それを直接見るのはこちらである —— 上の 2 件は `CvUnity.Interop.Dnn` だけを見ており、
    /// D8 が新設した 2 つ目の define 制約付き assembly を見ていない。
    /// </summary>
    [Test]
    public void TheDnnSharedTestAssemblyIsAbsentWithoutItsDefine()
    {
        var defines = UnityEditor.PlayerSettings.GetScriptingDefineSymbols(
            UnityEditor.Build.NamedBuildTarget.Standalone);

        // このプロジェクトは既定で OCVU_PROFILE_DNN を立てていない。
        // **前提が崩れたら、この検査は何も見ていないので落とす。**
        Assert.That(defines, Does.Not.Contain("OCVU_PROFILE_DNN"),
            "このテストは OCVU_PROFILE_DNN が立っていないことを前提にしている");

        var names = CompilationPipeline.GetAssemblies(AssembliesType.Editor)
            .Select(a => a.name).ToList();
        Assert.That(names, Does.Not.Contain(DnnSharedTestAssembly),
            "define が無いのに CvUnity.Tests.Shared.Dnn がコンパイルされている。" +
            "defineConstraints が効いていない");
    }
}
