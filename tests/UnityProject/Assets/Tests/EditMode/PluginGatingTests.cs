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

        var expected = new Dictionary<string, string>
        {
            { "opencv_unity_native.dll", "Windows" },
            { "libopencv_unity_native.dylib", "OSX" },
            { "libopencv_unity_native.so", "Linux" },
        };

        foreach (var importer in importers)
        {
            var fileName = System.IO.Path.GetFileName(importer.assetPath);
            Assert.IsTrue(expected.ContainsKey(fileName),
                $"知らない native plugin が入っている: {importer.assetPath}");

            Assert.AreEqual(expected[fileName], importer.GetEditorData("OS"),
                $"{fileName} のエディタ向け OS 指定が違う。" +
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

        // ファイル名から、その plugin が属するべき platform を決める。
        // **名前で判断するのは、それが Unity の解決とも一致する軸だからである。**
        var expected = new Dictionary<string, BuildTarget>
        {
            { "opencv_unity_native.dll", BuildTarget.StandaloneWindows64 },
            { "libopencv_unity_native.dylib", BuildTarget.StandaloneOSX },
            { "libopencv_unity_native.so", BuildTarget.StandaloneLinux64 },
        };

        var allTargets = expected.Values.Distinct().ToList();

        foreach (var importer in importers)
        {
            var fileName = System.IO.Path.GetFileName(importer.assetPath);
            if (!expected.TryGetValue(fileName, out var mine))
            {
                Assert.Fail($"知らない native plugin が入っている: {importer.assetPath}");
                continue;
            }

            foreach (var target in allTargets)
            {
                var isCompatible = importer.GetCompatibleWithPlatform(target);
                if (target == mine)
                {
                    Assert.IsTrue(isCompatible,
                        $"{fileName} は {target} で有効であるべき");
                }
                else
                {
                    Assert.IsFalse(isCompatible,
                        $"{fileName} が {target} でも有効になっている。" +
                        "全部入りの package では、これが取り違えの原因になる。");
                }
            }
        }
    }
}
