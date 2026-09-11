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
/// **両方向を見る。1 回の実行では届かないので、レーンを 2 つに分けてある。**
/// define が立っていない状態で assembly が現れないことは既定のレーンが、
/// **define を立てれば現れること（正の方向）は `ci-unity.yml` の
/// `DnnEditMode` レーン**が確かめる —— あちらは
/// `ProjectSettings.asset` の `scriptingDefineSymbols` に
/// `Standalone: OCVU_PROFILE_DNN` を書いてから Unity を走らせる。
/// **1 回の EditMode 実行では原理的に届かない**というのは正しく、
/// 届かせる方法は実行を分けることだけである。
///
/// **「どちらの分岐を通ったか」は出力で要求する。** 判定を
/// 「無ければ無い／有れば有る」にすると、**どちらのレーンでもテスト名は
/// 同じように Passed で並ぶ** —— 名前だけを要求する検査は、define を
/// 立て損ねたレーンを緑のまま通す。だから
/// <see cref="AssertTheAssemblyMatchesTheDefine"/> が通った側を
/// `TestContext.WriteLine` に書き、CI は
/// `assert-unity-results.ps1 -RequireOutput` でその行を要求する。
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
    /// **dnn の assembly が、define の有無と一致していること。**
    ///
    /// これが roadmap の決定 2（「dnn が入らないビルドで参照が壊れない」）の
    /// 実体である —— 実行時に EntryPointNotFoundException が出ないことではなく、
    /// **参照するコードがそもそもビルドに入らないこと。**
    ///
    /// **両方向を見る。** 以前この一群は「define が立っていない状態で
    /// assembly が現れない」だけを見ており、同 class の docstring が
    /// 「define を立てれば現れること（正の方向）は 1 回の EditMode 実行では
    /// 原理的に届かない」と正しく断っていた。**届かせる方法は実行を 2 つに
    /// 分けることだけで**、`ci-unity.yml` の `DnnEditMode` レーンがそれを担う
    /// （ProjectSettings.asset に define を書いてからもう一度走らせる）。
    /// 判定を「無ければ無い／有れば有る」に変えたことで、**同じテストが
    /// どちらのレーンでも load-bearing になる。**
    /// </summary>
    private static bool DnnDefineIsOn
    {
        get
        {
            var raw = UnityEditor.PlayerSettings.GetScriptingDefineSymbols(
                UnityEditor.Build.NamedBuildTarget.Standalone);
            // **部分一致で見ない。** OCVU_PROFILE_DNN_SOMETHING のような別の
            // 記号を立てただけで「立っている」と読んでしまう。
            return raw.Split(';').Select(d => d.Trim()).Contains(DnnDefine);
        }
    }

    /// <summary>
    /// define の状態に応じて、その assembly が在る／無いことを要求する。
    /// **どちらの分岐を通ったかを出力に残す** —— テストが通ったことと、
    /// 意図した側を確かめたことは別である（`assert-unity-results.ps1` の
    /// -RequireOutput が CI でこれを要求する）。
    /// </summary>
    private static void AssertTheAssemblyMatchesTheDefine(string assembly, string what)
    {
        var names = CompilationPipeline.GetAssemblies(AssembliesType.Editor)
            .Select(a => a.name).ToList();
        // **0 件を「違反なし」と読まない。** 走査が壊れていれば
        // Does.Not.Contain は常に真になる。
        Assert.IsNotEmpty(names, "assembly が 1 つも拾えていない。走査が壊れている");

        if (DnnDefineIsOn)
        {
            Assert.Contains(assembly, names,
                $"OCVU_PROFILE_DNN を立てたのに {what} がコンパイルされていない。" +
                "defineConstraints の綴りか、profile の配線が壊れている");
            TestContext.WriteLine(
                $"OCVU_PROFILE_DNN is defined and the dnn assemblies are compiled [{assembly}]");
        }
        else
        {
            Assert.That(names, Does.Not.Contain(assembly),
                $"define が無いのに {what} がコンパイルされている。defineConstraints が効いていない");
            TestContext.WriteLine(
                $"OCVU_PROFILE_DNN is not defined and {assembly} is absent");
        }
    }

    [Test]
    public void TheDnnInteropAssemblyMatchesTheDefine()
        => AssertTheAssemblyMatchesTheDefine(DnnAssembly, "dnn の Interop assembly");

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
    public void TheDnnSharedTestAssemblyMatchesTheDefine()
        => AssertTheAssemblyMatchesTheDefine(DnnSharedTestAssembly, "CvUnity.Tests.Shared.Dnn");

    /// <summary>
    /// **dnn の公開 API 層も、同じ define と一致していること。**
    ///
    /// Interop.Dnn だけを切っても足りない —— それを参照する
    /// CvUnity.Dnn が残ると、参照先を失って**利用者のプロジェクトが
    /// コンパイルエラーになる。**
    /// </summary>
    [Test]
    public void TheDnnPublicApiAssemblyMatchesTheDefine()
        => AssertTheAssemblyMatchesTheDefine(DnnPublicApiAssembly, "dnn の公開 API assembly");

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
