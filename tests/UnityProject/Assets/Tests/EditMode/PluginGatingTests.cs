using System.Collections.Generic;
using System.Linq;
using NUnit.Framework;
using UnityEditor;
using UnityEngine;

/// <summary>
/// 全部入りの package で、Unity が自分の platform の plugin だけを有効にしている
/// ことを確かめる。
///
/// **なぜ EditMode のテストが通るだけでは足りないか。**
/// M3.5 の着手前に実測した: macOS の `.meta` を「Windows でも有効」に書き換えても、
/// 既存の EditMode は **10 passed のまま通った**。3 platform で binary の
/// ファイル名が違う（opencv_unity_native.dll / libopencv_unity_native.dylib /
/// libopencv_unity_native.so）ため、`DllImport("opencv_unity_native")` の解決が
/// 名前の時点で分岐し、`.meta` の設定を間違えても取り違えが起きないからである。
///
/// **つまり「緑だから正しい」がこの欠陥には効かない。** そこで、Unity 自身が
/// `.meta` をどう解釈したかを `PluginImporter` に問う。
///
/// `tools/tests/PackageRelease.Tests.ps1` の `.meta` 検査との違いは、
/// **YAML を自分で読むか、Unity に読ませた結果を読むか**である。前者は
/// 「Unity が理解しない書き方」を捕まえられない。
/// </summary>
public class PluginGatingTests
{
    private const string PluginRoot = "Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins";

    /// <summary>
    /// 「いま検査しているのは全部入りである」という合図。**プロジェクト直下の
    /// ファイルで受け取る。環境変数ではない。**
    ///
    /// CI で Unity を起動するのは game-ci の action で、**これがコンテナへ渡す
    /// 環境変数は固定の一覧である**（`ImageEnvironmentFactory.getEnvironmentVariables`。
    /// UNITY_* / GITHUB_* / RUNNER_* など）。任意の名前は渡らないので、workflow の
    /// `env:` に書いても Unity 側には届かない。**届かないと、この検査は「合図が
    /// 無い」分岐に落ちて要素 1 個でも緑になる** —— 塞ごうとしている穴とまったく
    /// 同じ壊れ方を、検査自身がする。
    ///
    /// ワークスペースはコンテナに mount されるので、**ファイルなら CI でも
    /// ローカルでも同じ経路で届く。**
    ///
    /// game-ci には `customParameters` という正規の受け渡し口もあり、Unity の
    /// コマンドライン引数として届く（`Environment.GetCommandLineArgs()` で
    /// 読める）。**それを採らなかったのは、コンテナ側の entrypoint がそれを
    /// 実際に Unity の引数へ渡すかを確かめられなかったからである** ——
    /// 環境変数の一覧は action の dist から実測できたが、entrypoint の
    /// スクリプトは同じ形では読めなかった。mount されたワークスペースは
    /// docker run の引数から直接確かめられるので、そちらに寄せた。
    /// </summary>
    private const string ExpectAllPlatformsMarker = "ocvu-expect-all-platforms";

    private static bool ExpectsAllPlatforms()
    {
        // Application.dataPath は <project>/Assets。合図はその 1 つ上に置く
        // （Assets の下に置くと .meta が要る）。
        var path = System.IO.Path.Combine(Application.dataPath, "..", ExpectAllPlatformsMarker);
        return System.IO.File.Exists(path);
    }

    /// <summary>
    /// 全部入りに入る plugin と、その振り分け先。
    ///
    /// **ファイル名で引かない。** Android と Linux はどちらも
    /// `libopencv_unity_native.so` で、**ファイル名では区別が付かない** ——
    /// 名前で引く辞書だと、Android の binary が現れた瞬間に Linux の期待値と
    /// 突き合わされて落ちる（M4 のレビューで発見）。**パスの一部**で引く。
    /// </summary>
    private sealed class PluginSlot
    {
        public string PathFragment;   // Runtime/Plugins からの相対で一意になる断片
        public string EditorOs;       // GetEditorData("OS")。エディタで動かない platform は null
        public BuildTarget Target;
    }

    private static readonly PluginSlot[] Slots =
    {
        new PluginSlot { PathFragment = "/x86_64/opencv_unity_native.dll",
                         EditorOs = "Windows", Target = BuildTarget.StandaloneWindows64 },
        new PluginSlot { PathFragment = "/macOS/libopencv_unity_native.dylib",
                         EditorOs = "OSX", Target = BuildTarget.StandaloneOSX },
        new PluginSlot { PathFragment = "/Linux/x86_64/libopencv_unity_native.so",
                         EditorOs = "Linux", Target = BuildTarget.StandaloneLinux64 },
        // **モバイルはエディタで動かない。** GetEditorData("OS") は空文字を返す
        // —— エディタ向けの振り分けを持たないことが正しい状態である。
        new PluginSlot { PathFragment = "/Android/arm64-v8a/libopencv_unity_native.so",
                         EditorOs = "", Target = BuildTarget.Android },
        new PluginSlot { PathFragment = "/iOS/libopencv_unity_native.a",
                         EditorOs = "", Target = BuildTarget.iOS },
    };

    private static PluginSlot SlotOf(string assetPath)
    {
        var normalised = assetPath.Replace('\\', '/');
        return Slots.FirstOrDefault(s => normalised.EndsWith(s.PathFragment, System.StringComparison.Ordinal));
    }

    private static List<PluginImporter> LoadImporters()
    {
        // Packages 配下は AssetDatabase から見えるので、GUID 検索で拾える。
        return AssetDatabase.FindAssets(string.Empty, new[] { PluginRoot })
            .Select(AssetDatabase.GUIDToAssetPath)
            .Distinct()
            .Select(path => AssetImporter.GetAtPath(path) as PluginImporter)
            .Where(importer => importer != null)
            .ToList();
    }

    [Test]
    public void EveryNativePluginIsSeenByUnity()
    {
        var importers = LoadImporters();

        // **0 件で緑にしない。** 拾えていないだけの状態を「違反なし」と読むと、
        // 以下の検査がまとめて空振りする。
        Assert.That(importers, Is.Not.Empty,
            $"{PluginRoot} の下に PluginImporter が 1 つも見つからない。" +
            "plugin が置かれていないか、パスが変わっている。");
    }

    /// <summary>
    /// **どちらの構成で走ったかを、結果から区別できるようにする。**
    ///
    /// この検査群が捕まえたい欠陥（別 platform の `.meta` が自分の platform でも
    /// 有効になっている）は、**3 platform 分が同居していないと原理的に現れない。**
    /// ところが通常の EditMode レーンは `dev.ps1 build` が置いた 1 platform 分の
    /// 木で走るので、そこでは要素 1 個の集合を検査しているにすぎない。
    ///
    /// 同じ 5 件が両方の構成で緑になると、**出力からはどちらを確かめたのか
    /// 分からない。** そこで見た数を必ず表に出す。3 つ揃っていることを要求する
    /// のは <see cref="ExpectAllPlatformsMarker"/> が置かれているときだけで、
    /// それを置くのは全部入りを組んだレーン（`dev.ps1 test-unity-tarball` と
    /// `ci-unity.yml` の Unity job）である。
    /// </summary>
    [Test]
    public void ReportsHowManyPlatformsWereActuallyPresent()
    {
        var importers = LoadImporters();
        var names = importers.Select(i => System.IO.Path.GetFileName(i.assetPath)).OrderBy(n => n);
        TestContext.WriteLine($"native plugins present: {importers.Count} [{string.Join(", ", names)}]");

        if (!ExpectsAllPlatforms())
        {
            // 1 platform 分でも構わないが、**何を見たかは記録に残す。**
            Assert.That(importers.Count, Is.GreaterThanOrEqualTo(1));
            return;
        }

        // **数を直書きしない。** Slots が正本で、platform を足したときに
        // 片方だけ古くなるのを避ける。
        Assert.AreEqual(Slots.Length, importers.Count,
            $"{ExpectAllPlatformsMarker} が置かれているのに 3 platform 分が揃っていない。" +
            $"見えたもの: [{string.Join(", ", names)}]");
    }

    /// <summary>
    /// エディタでの振り分けは `GetCompatibleWithEditor()` ではなく `OS` で決まる。
    ///
    /// **実測（2026-08-30）: 3 つとも `GetCompatibleWithEditor()` が true を返す。**
    /// `.meta` は `Editor: enabled: 1` を 3 つとも立てたうえで、その下の
    /// `settings: OS:` で Windows / OSX / Linux に振り分けているためである。
    /// つまり **Editor のチェックだけを見る検査は、常に true で無感になる。**
    /// 見るべきは `GetEditorData("OS")` の方。
    /// </summary>
    [Test]
    public void ExactlyOnePluginTargetsThisEditorOs()
    {
        var importers = LoadImporters();
        Assume.That(importers, Is.Not.Empty);

        var runningOs = Application.platform switch
        {
            RuntimePlatform.WindowsEditor => "Windows",
            RuntimePlatform.OSXEditor => "OSX",
            RuntimePlatform.LinuxEditor => "Linux",
            _ => null,
        };
        Assert.IsNotNull(runningOs, $"想定していないエディタ: {Application.platform}");

        var mine = importers
            .Where(i => i.GetCompatibleWithEditor())
            .Where(i => string.Equals(i.GetEditorData("OS"), runningOs))
            .ToList();

        Assert.AreEqual(1, mine.Count,
            $"この エディタ（OS={runningOs}）向けの native plugin はちょうど 1 つであること。" +
            $"該当: [{string.Join(", ", mine.Select(i => i.assetPath))}] / " +
            $"全体: [{string.Join(", ", importers.Select(i => i.assetPath + " OS=" + i.GetEditorData("OS")))}]");
    }

    /// <summary>
    /// どの plugin も、エディタでは自分の OS 向けにだけ振られていること。
    /// **これが崩れると、全部入りの package で取り違えが起こりうる。**
    /// </summary>
    [Test]
    public void EachPluginTargetsOnlyItsOwnEditorOs()
    {
        var importers = LoadImporters();
        Assume.That(importers, Is.Not.Empty);

        foreach (var importer in importers)
        {
            var slot = SlotOf(importer.assetPath);
            Assert.IsNotNull(slot, $"知らない native plugin が入っている: {importer.assetPath}");

            Assert.AreEqual(slot.EditorOs, importer.GetEditorData("OS"),
                $"{importer.assetPath} のエディタ向け OS 指定が違う。" +
                "全部入りの package では、これが取り違えの原因になる。");
        }
    }

    [Test]
    public void NoPluginIsEnabledForEveryPlatform()
    {
        var importers = LoadImporters();
        Assume.That(importers, Is.Not.Empty);

        // Any（= どの platform でも有効）が立っていると、Unity は取り違えうる。
        // これは .meta の `Any: enabled: 0` に対応する。
        var anyEnabled = importers.Where(i => i.GetCompatibleWithAnyPlatform()).ToList();

        Assert.That(anyEnabled, Is.Empty,
            "「すべての platform で有効」な plugin があってはならない。" +
            $"該当: [{string.Join(", ", anyEnabled.Select(i => i.assetPath))}]");
    }

    [Test]
    public void EachPluginIsEnabledOnlyForItsOwnStandaloneTarget()
    {
        var importers = LoadImporters();
        Assume.That(importers, Is.Not.Empty);

        var allTargets = Slots.Select(s => s.Target).Distinct().ToList();

        // **どの対象を実際に見たかを出力に残す。**
        //
        // `GetCompatibleWithPlatform` は `.meta` の値を返すので、その対象の
        // ビルドサポートがエディタに入っていなくても答えは返る（実測: この
        // Windows 機では StandaloneOSX / StandaloneLinux64 / iOS が
        // supported=False だが、`.meta` どおりの値が返る）。
        //
        // **つまり supported=False は「検査できていない」ではない。** それでも
        // 出しておくのは、将来 Unity の挙動が変わって「モジュールが無いと
        // false を返す」ようになったとき、**この検査が黙って無感になる**のを
        // 出力から見分けられるようにするためである。
        foreach (var t in allTargets)
        {
            var grp = BuildPipeline.GetBuildTargetGroup(t);
            TestContext.WriteLine(
                $"target {t}: supported={BuildPipeline.IsBuildTargetSupported(grp, t)}");
        }

        foreach (var importer in importers)
        {
            var slot = SlotOf(importer.assetPath);
            if (slot == null)
            {
                Assert.Fail($"知らない native plugin が入っている: {importer.assetPath}");
                continue;
            }

            foreach (var target in allTargets)
            {
                var isCompatible = importer.GetCompatibleWithPlatform(target);
                if (target == slot.Target)
                {
                    Assert.IsTrue(isCompatible,
                        $"{importer.assetPath} は {target} で有効であるべき");
                }
                else
                {
                    Assert.IsFalse(isCompatible,
                        $"{importer.assetPath} が {target} でも有効になっている。" +
                        "全部入りの package では、これが取り違えの原因になる。");
                }
            }
        }
    }
}
