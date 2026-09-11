using System.Linq;
using System.Reflection;
using NUnit.Framework;

/// <summary>
/// [Category("Graphics")] が付いたテストの集合を、**merge を止めないレーンに
/// しか居ないテスト**の台帳として名指しで固定する（M7a Task 2 のレビュー指摘）。
///
/// **`Graphics` と `!Graphics` は補集合なので、実行時の和集合は常に完全である。**
/// `test-unity-editmode` と `test-unity-tarball` が `-testCategory '!Graphics'`、
/// `test-unity-graphics` が `-testCategory 'Graphics'` で走る限り、振り分け
/// 自体に穴は無い（`!Graphics` 側が 2 レーンに増えても、補集合の性質は
/// 変わらない）。
///
/// **本当の穴は「一方のレーン（graphics）の側が弱いこと」である。**
///
/// **2026-09-11 に穴は 1 段小さくなった。** それまで `test-unity-graphics` は
/// ローカル専用で `ci-unity.yml` からは呼ばれず、`[Category("Graphics")]` を
/// 付けた瞬間そのテストは **CI から完全に見えなくなっていた**。いまは
/// `ci-unity.yml` に `Graphics` レーンが在るので、CI は見る。
///
/// **しかし `Unity Graphics (Linux)` は必須チェックではない。** したがって
/// `[Category("Graphics")]` を付ける行為は、いまも **必須レーン
/// （`Unity EditMode (Linux)`）から、赤くても merge を止めないレーンへ
/// そのテストを無言で移す。** 「CI から消える」から「CI が止めなくなる」に
/// 程度が下がっただけで、**性質は残っている** ——
/// `CLAUDE.md` の「CI が『見ている』ことと『止める』ことは別である」。
///
/// **この一覧は「merge を止めないレーンにしか居ない EditMode のテスト」である。**
/// **列挙そのものが契約である** —— 短いほうがよく、伸びたときに人が
/// 気づくべきものだから、あえて名前で持つ。**`Unity Graphics (Linux)` を
/// 必須チェックへ昇格できたら、この一覧は空にでき、そのときこの検査ごと
/// 消してよい** —— 削除の条件は「CI に配線されること」ではなく
/// **「merge を止めるようになること」**である（2026-09-11 に、配線だけを
/// 根拠に 1 度消してレビューに差し戻された）。
///
/// **走査するのはこの assembly（EditMode）だけである。** 他の test
/// assembly に `[Category("Graphics")]` が付いても、ここは気づかない ——
/// **それでこの検査の目的は満たされる。** カテゴリで振り分けているのは
/// EditMode のレーンだけで（`test-unity-editmode` と `test-unity-tarball` が
/// `!Graphics`、`test-unity-graphics` が `Graphics`）、PlayMode / Standalone
/// のレーンは `-testCategory` を渡さない。つまり **他所でカテゴリを付けても、その
/// テストは CI から消えない。** 消えるのはここに在るものだけなので、
/// 台帳もここだけを見る。**振り分けの前提が変われば、この段は嘘になる。**
///
/// （このリポジトリは一般に列挙を嫌う。`check-generated-file-edit.sh` が
/// 対象を名指しせず規約で拾うのがその例である。ここは例外で、
/// 上の理由がその根拠である。）
/// </summary>
public class CiVisibilityTests
{
    private const string GraphicsCategoryName = "Graphics";

    /// <summary>
    /// [Category("Graphics")] を持つ（= merge を止めないレーンにしか居ない）テストの全量。
    /// </summary>
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
