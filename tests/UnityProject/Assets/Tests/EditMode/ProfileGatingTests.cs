using System;
using System.Linq;
using NUnit.Framework;
using UnityEngine;
using UnityEditor;
using UnityEditorInternal;
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
///
/// **ただしこの一群が自動で見られるのは「切れている」方向だけである。**
/// define が立っていない状態で assembly が現れないことは毎回確かめるが、
/// **define を立てれば現れること（正の方向）は、ここでは確かめていない**
/// —— それには define を変えて Unity をもう一度走らせる必要があり、
/// 1 回の EditMode 実行では原理的に届かない。正の方向は人が手で確かめる:
/// `ProjectSettings.asset` の `scriptingDefineSymbols` に
/// `Standalone: OCVU_PROFILE_DNN` を置いて `dev.ps1 test-unity-editmode` を
/// 走らせ、`tests/UnityProject/Library/ScriptAssemblies/` に
/// `CvUnity.Interop.Dnn.dll` / `CvUnity.Tests.Shared.Dnn.dll` /
/// `CvUnity.Dnn.dll` が現れることを見る（最後の実測は 2026-09-09、**本物の
/// `bindings/spec/dnn.json` から生成した公開 API を含む** —— この 3 つ目は
/// M7c Task 4 で足した。この実行では上の「切れている」方向の 3 件が
/// 前提を欠いて赤くなる ―― defines が既に `OCVU_PROFILE_DNN` を含むため
/// 意図どおりで、それ以外の全テストは緑のままだった。確認後は
/// `scriptingDefineSymbols` を空 `{}` へ戻す）。
///
/// **「切れている」だけを見る検査は、綴り間違いと区別が付かない。**
/// `defineConstraints` の値を打ち間違えても、この 5 件は全部緑になる ——
/// その 1 点だけは <see cref="TheGatedAsmdefsSpellTheDefineTheseTestsCheckFor"/>
/// が塞ぐ（asmdef が実際に綴っている値と、この class が使う定数を比べる）。
/// </summary>
public class ProfileGatingTests
{
    private const string DnnAssembly = "CvUnity.Interop.Dnn";
    private const string StandardAssembly = "CvUnity.Interop";
    private const string DnnSharedTestAssembly = "CvUnity.Tests.Shared.Dnn";

    /// <summary>
    /// 公開 API 層（Runtime/Dnn/、M7c Task 4）。<see cref="DnnAssembly"/> と
    /// 同じ define で切ってある —— こちらだけを切り忘れると、
    /// Interop.Dnn が消えたときに参照先を失って利用者のプロジェクトが
    /// コンパイルエラーになる。
    /// </summary>
    private const string DnnPublicApiAssembly = "CvUnity.Dnn";

    /// <summary>
    /// **この define の綴りは、下の各テストと asmdef の両方が使う。**
    /// 片方だけ変わると `TheGatedAsmdefsSpellTheDefineTheseTestsCheckFor` が落ちる。
    /// </summary>
    private const string DnnDefine = "OCVU_PROFILE_DNN";

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
        Assert.That(defines, Does.Not.Contain(DnnDefine),
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
        Assert.That(defines, Does.Not.Contain(DnnDefine),
            "このテストは OCVU_PROFILE_DNN が立っていないことを前提にしている");

        var names = CompilationPipeline.GetAssemblies(AssembliesType.Editor)
            .Select(a => a.name).ToList();
        Assert.That(names, Does.Not.Contain(DnnSharedTestAssembly),
            "define が無いのに CvUnity.Tests.Shared.Dnn がコンパイルされている。" +
            "defineConstraints が効いていない");
    }

    /// <summary>
    /// **dnn の公開 API 層も、define が無ければコンパイルされない。**
    ///
    /// Interop.Dnn だけを切っても足りない —— それを参照する
    /// CvUnity.Dnn が残ると、参照先を失って**利用者のプロジェクトが
    /// コンパイルエラーになる。**
    /// </summary>
    [Test]
    public void TheDnnPublicApiAssemblyIsAlsoAbsentWithoutItsDefine()
    {
        var names = CompilationPipeline.GetAssemblies(AssembliesType.Editor)
            .Select(a => a.name).ToList();
        Assert.That(names, Does.Not.Contain(DnnPublicApiAssembly),
            "define が無いのに dnn の公開 API assembly がコンパイルされている");
    }

    /// <summary>
    /// **綴りを見る。**
    ///
    /// 上の 4 件はどれも「define が立っていない状態で assembly が現れない」を
    /// 見ている。**`defineConstraints` の値を打ち間違えても、それは全部真である**
    /// —— 存在しない define は決して立たないので、その assembly は
    /// **どんな define を立てても永久に現れない。** 「切ってある」と
    /// 「壊れている」の区別が付かない。
    ///
    /// ここは asmdef が実際に綴っている値を読み、この class が使う定数と
    /// 突き合わせる。**Unity 自身のパーサ（<see cref="JsonUtility"/>）に読ませる**
    /// ので、asmdef の JSON を自前で解釈することはしない。
    /// </summary>
    [Test]
    public void TheGatedAsmdefsSpellTheDefineTheseTestsCheckFor()
    {
        var all = AssetDatabase.FindAssets("t:AssemblyDefinitionAsset")
            .Select(AssetDatabase.GUIDToAssetPath)
            .Select(AssetDatabase.LoadAssetAtPath<AssemblyDefinitionAsset>)
            .Where(a => a != null)
            .Select(a => JsonUtility.FromJson<AsmdefShape>(a.text))
            .Where(a => a != null)
            .ToList();

        // **0 件を「違反なし」と読まない。** 走査が効いていなければ、
        // 下の foreach は 1 度も回らずに緑になる。
        Assert.IsNotEmpty(all, "asmdef が 1 つも拾えていない。走査が壊れている");

        foreach (var wanted in new[] { DnnAssembly, DnnSharedTestAssembly, DnnPublicApiAssembly })
        {
            var matches = all.Where(a => a.name == wanted).ToList();
            Assert.AreEqual(1, matches.Count,
                $"'{wanted}' という名前の asmdef がちょうど 1 つであるべき（{matches.Count} 件）");

            Assert.That(matches[0].defineConstraints, Is.EqualTo(new[] { DnnDefine }),
                $"'{wanted}' の defineConstraints が、このテストが見ている define と違う。" +
                "綴りが違えばこの assembly はどんな define を立てても現れず、" +
                "「切ってある」検査は全部緑のまま何も見ていない");
        }
    }

    /// <summary>
    /// asmdef の JSON のうち、この検査が読む 2 つのキーだけ。
    /// <see cref="JsonUtility"/> が埋める（それ以外のキーは無視される）。
    /// </summary>
    [Serializable]
    private class AsmdefShape
    {
#pragma warning disable CS0649 // JsonUtility がリフレクションで埋める
        public string name;
        public string[] defineConstraints;
#pragma warning restore CS0649
    }
}
