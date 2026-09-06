using System.Linq;
using System.Reflection;
using NUnit.Framework;

/// <summary>
/// [Category("Graphics")] が付いたテストの集合を、CI から見えないテストの
/// 台帳として名指しで固定する（M7a Task 2 のレビュー指摘）。
///
/// **`Graphics` と `!Graphics` は補集合なので、実行時の和集合は常に完全である。**
/// `test-unity-editmode` が `-testCategory '!Graphics'`、`test-unity-graphics`
/// が `-testCategory 'Graphics'` で走る限り、振り分け自体に穴は無い。
///
/// **本当の穴は「一方のレーン（graphics）が CI に配線されていない」ことである。**
/// `test-unity-graphics` はローカル専用で、`ci-unity.yml` からは呼ばれない。
/// つまり `[Category("Graphics")]` を付けた瞬間、そのテストは CI から
/// 完全に見えなくなる —— 誰も赤くならない。
///
/// **この一覧は「CI で走らないテスト」である。** ここに載っているものは
/// CI から見えない。**列挙そのものが契約である** —— 短いほうがよく、
/// 伸びたときに人が気づくべきものだから、あえて名前で持つ。graphics
/// レーンを CI に配線できたら、この一覧は空にでき、そのときこの検査ごと
/// 消してよい。
///
/// （このリポジトリは一般に列挙を嫌う。`check-generated-file-edit.sh` が
/// 対象を名指しせず規約で拾うのがその例である。ここは例外で、
/// 上の理由がその根拠である。）
/// </summary>
public class CiVisibilityTests
{
    private const string GraphicsCategoryName = "Graphics";

    /// <summary>[Category("Graphics")] を持つ（= CI から見えない）テストの全量。</summary>
    private static readonly string[] ExpectedGraphicsOnlyTests =
    {
        "GraphicsTests.AGraphicsDeviceIsPresent",
        "GraphicsTests.SyncReadbackProducesTheExpectedPixels",
        "GraphicsTests.VerticalFlipIsApplied",
        "GraphicsTests.AsyncMatchesSync",
        "GraphicsTests.TakingTheMatTwiceIsRejected",
        "GraphicsTests.EveryCheckInTheSharedBodyIsWiredIntoThisEntryPoint",
        // M7a Task 4: GPU に依る benchmark も同じ理由で Graphics カテゴリに乗る。
        "GraphicsBenchmarkRunner.MeasureRenderTexturePaths",
    };

    [Test]
    public void TestsMarkedGraphicsOnlyMatchTheDeclaredList()
    {
        var testMethods = Assembly.GetExecutingAssembly()
            .GetTypes()
            .SelectMany(t => t.GetMethods(BindingFlags.Public | BindingFlags.Instance))
            .Where(m => m.GetCustomAttribute<TestAttribute>() != null
                     || m.GetCustomAttribute<UnityEngine.TestTools.UnityTestAttribute>() != null)
            .ToList();

        // **0 件を「一致」と読まない。** 走査が効いていないと、下の集合は
        // いつでも空になり、期待と一致してしまう（偽陰性）。この assembly には
        // [Test] だけで数十件ある（実測に基づく下限。日付つきの実測値を
        // ここに書くと、次に 1 件足すたびにその日付が嘘になる）ので、
        // 大きく下回れば走査そのものが壊れている。
        Assert.Greater(testMethods.Count, 30,
            "テスト assembly から [Test]/[UnityTest] がほとんど拾えていない。走査が壊れている。");

        bool HasGraphicsCategory(MethodInfo m) =>
            m.GetCustomAttributes<CategoryAttribute>().Any(c => c.Name == GraphicsCategoryName)
            || m.DeclaringType.GetCustomAttributes<CategoryAttribute>(true)
                .Any(c => c.Name == GraphicsCategoryName);

        var actual = testMethods
            .Where(HasGraphicsCategory)
            .Select(m => $"{m.DeclaringType.Name}.{m.Name}")
            .OrderBy(n => n)
            .ToList();

        var expected = ExpectedGraphicsOnlyTests.OrderBy(n => n).ToList();

        var unexpectedlyGraphicsOnly = actual.Except(expected).ToList();
        var noLongerGraphicsOnly = expected.Except(actual).ToList();

        Assert.IsEmpty(unexpectedlyGraphicsOnly,
            "一覧に無いものが増えた —— 新たに [Category(\"Graphics\")] が付き、" +
            "CI から見えなくなったテスト: " + string.Join(", ", unexpectedlyGraphicsOnly) +
            "。CI から消えてよいなら ExpectedGraphicsOnlyTests に追記すること。");

        Assert.IsEmpty(noLongerGraphicsOnly,
            "一覧にあるものが消えた —— [Category(\"Graphics\")] が外れたか、" +
            "テスト自体が無くなった: " + string.Join(", ", noLongerGraphicsOnly) +
            "。ExpectedGraphicsOnlyTests から削除すること。");
    }
}
