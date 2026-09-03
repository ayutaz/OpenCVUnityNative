using System;
using UnityEditor;
using UnityEngine;
using UnityEditor.Build;

/// <summary>
/// batchmode から呼ばれ、Player テストを IL2CPP で走らせるための設定を入れる。
///
/// Mono のまま走らせると M2 の完了条件を満たさない。EditMode との違いは
/// backend そのものであり、stripping が P/Invoke 宣言を消す問題は IL2CPP で
/// しか再現しないからである。
/// </summary>
public static class BuildPlayer
{
    public static void ConfigureIl2cpp()
    {
        var target = NamedBuildTarget.Standalone;
        PlayerSettings.SetScriptingBackend(target, ScriptingImplementation.IL2CPP);
        // stripping を有効にしたまま走らせる。無効にすると link.xml が効いているか
        // 確かめられず、配布時の構成と違うものをテストすることになる。
        PlayerSettings.SetManagedStrippingLevel(target, ManagedStrippingLevel.Medium);
        AssetDatabase.SaveAssets();
    }

    /// <summary>
    /// native plugin の import 設定を platform ごとに明示して固定する
    /// （M3 Task 6 完了条件: 3 つの binary が同時に有効だと衝突する）。
    ///
    /// Unity は native plugin の既定を「全 platform で有効」にする。Windows /
    /// macOS / Linux の 3 binary が全部この既定のまま同じ UPM パッケージに
    /// 同梱されると、Unity がどれを読み込むか決まらず、実機の Player でだけ
    /// 失敗が表面化する。GUI の Inspector で設定するのが通常の手順だが、
    /// batchmode にはそれが無いので PluginImporter API で同じことをする
    /// （ConfigureIl2cpp と同じ -executeMethod の使い方）。
    ///
    /// このマシンでは Windows 分の .dll しか生成できないため、ここで設定
    /// するのも Windows 分だけである。macOS / Linux の .meta は同じ形の
    /// 設定を実機（CI）側で行う必要があり、このメソッドはそれを保証しない。
    /// </summary>
    public static void ConfigureNativePluginImportSettings()
    {
        const string path = "Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/x86_64/opencv_unity_native.dll";
        var importer = AssetImporter.GetAtPath(path) as PluginImporter;
        if (importer == null)
        {
            UnityEngine.Debug.LogError($"PluginImporter not found at {path}");
            EditorApplication.Exit(1);
            return;
        }

        importer.SetCompatibleWithAnyPlatform(false);
        importer.SetCompatibleWithEditor(true);
        importer.SetEditorData("OS", "Windows");
        importer.SetEditorData("CPU", "X86_64");
        importer.SetCompatibleWithPlatform(BuildTarget.StandaloneWindows64, true);
        importer.SetCompatibleWithPlatform(BuildTarget.StandaloneWindows, false);
        importer.SetCompatibleWithPlatform(BuildTarget.StandaloneOSX, false);
        importer.SetCompatibleWithPlatform(BuildTarget.StandaloneLinux64, false);
        importer.SaveAndReimport();
        AssetDatabase.SaveAssets();
    }

    /// <summary>
    /// WebGL の Player をビルドする（M6）。
    ///
    /// **stripping を有効のまま出す。** 無効にすると、
    /// <c>AbiReachabilityChecks.g.cs</c> が確かめたいこと ——
    /// 「stripping が消せるのは呼ばれない宣言だけである」——
    /// が確かめられなくなり、**配布時の構成と違う物をテストすることになる**
    /// （IL2CPP の Player と同じ理由）。
    ///
    /// **単一スレッド。** threads profile は M6 の非ゴールで、別 profile として
    /// 後続する。ここで有効にすると、SharedArrayBuffer を要求する Player に
    /// なり、ブラウザ側の要件（COOP/COEP ヘッダ）まで巻き込む。
    ///
    /// 出力先は環境変数 OCVU_WEB_BUILD_DIR（無ければ build/web-player）。
    /// </summary>
    public static void BuildWebGL()
    {
        // **active build target を先に切り替える。**
        //
        // 切り替えないと BuildPipeline.BuildPlayer は
        // `BuildResult.Unknown` / 0 バytes を返し、**理由を言わない**
        // （2026-09-03 に実測。ログに error は 1 行も出なかった）。
        if (EditorUserBuildSettings.activeBuildTarget != BuildTarget.WebGL)
        {
            UnityEngine.Debug.Log("switching active build target to WebGL...");
            if (!EditorUserBuildSettings.SwitchActiveBuildTarget(
                    BuildTargetGroup.WebGL, BuildTarget.WebGL))
            {
                UnityEngine.Debug.LogError(
                    "WebGL への切り替えに失敗しました。WebGL Build Support が入っていない可能性があります。");
                EditorApplication.Exit(1);
                return;
            }
        }

        var target = NamedBuildTarget.WebGL;
        PlayerSettings.SetManagedStrippingLevel(target, ManagedStrippingLevel.Medium);
        // threads を使わない（非ゴール）。既定でもそうだが、明示しておく。
        PlayerSettings.WebGL.threadsSupport = false;
        // **例外の情報を残す。**
        //
        // 当初は `None`（配る形に近いほう）にしていたが、**Player が落ちても
        // `Uncaught exception from main loop: undefined` としか出ず、
        // 原因が一切分からなかった**（2026-09-03 に実測）。
        //
        // **このレーンの目的は「動くことを確かめる」ことであって、
        // 「配る形をそのまま測る」ことではない。** 落ちたときに理由が
        // 分からない構成でそれをやると、**赤くはなるが直せない。**
        //
        // 配る形との差はここ 1 つで、**差があること自体を記録しておく。**
        PlayerSettings.WebGL.exceptionSupport = WebGLExceptionSupport.FullWithStacktrace;
        AssetDatabase.SaveAssets();

        var outDir = System.Environment.GetEnvironmentVariable("OCVU_WEB_BUILD_DIR");
        if (string.IsNullOrEmpty(outDir))
        {
            outDir = System.IO.Path.Combine(
                System.IO.Directory.GetCurrentDirectory(), "build", "web-player");
        }
        System.IO.Directory.CreateDirectory(outDir);

        // **scene が 1 つも要らない、ということにはならない。**
        //
        // 空の配列を渡すと Unity は「いま開いている名前の無い scene」を
        // 建てようとして落ちる:
        //
        //     [build step] Build player: Error: Cannot build untitled scene.
        //
        // **この理由は report.steps[].messages にしか出ない**
        // （summary は Unknown、ログには error 1 行も無し。2026-09-03 に実測）。
        //
        // このプロジェクトはテストの土台で scene を持たないので、
        // **ビルドのたびに空の scene を作り、終わったら消す。**
        // 置きっぱなしにしないのは、生成物をリポジトリに commit しないためである。
        var scenePath = "Assets/__WebGLBuild.unity";
        var scene = UnityEditor.SceneManagement.EditorSceneManager.NewScene(
            UnityEditor.SceneManagement.NewSceneSetup.EmptyScene,
            UnityEditor.SceneManagement.NewSceneMode.Single);
        // **検証本体を載せる。** 空の scene のままだと、Player は起動するが
        // こちらのコードが 1 行も走らない ——「ビルドできた」を「動く」と
        // 取り違える最短経路である。
        var go = new UnityEngine.GameObject("OcvuWebSmoke");
        go.AddComponent<WebSmokeRunner>();
        UnityEditor.SceneManagement.EditorSceneManager.MoveGameObjectToScene(go, scene);

        if (!UnityEditor.SceneManagement.EditorSceneManager.SaveScene(scene, scenePath))
        {
            UnityEngine.Debug.LogError($"空の scene を保存できませんでした: {scenePath}");
            EditorApplication.Exit(1);
            return;
        }

        var scenes = new[] { scenePath };
        var options = new BuildPlayerOptions
        {
            scenes = scenes,
            locationPathName = outDir,
            target = BuildTarget.WebGL,
            targetGroup = BuildTargetGroup.WebGL,
            options = BuildOptions.None,
        };

        // **同梱 Emscripten の版を書き出す。**
        //
        // 版の照合を **runner 側でやろうとして失敗した**（M6 の 3 回目の
        // レビュー）—— game-ci の action は docker を使うので、
        // **Unity はコンテナの中にしか無く、step が終われば消える。**
        // `/opt/unity/Editor` は runner に存在しない。
        //
        // **Unity の中でしか読めないものは、Unity の中で読んで書き出す。**
        // 突き合わせは runner 側が `-VersionFile` で行う。
        try
        {
            var emVersion = System.IO.Path.Combine(
                EditorApplication.applicationContentsPath,
                "PlaybackEngines/WebGLSupport/BuildTools/Emscripten/emscripten/emscripten-version.txt");
            if (System.IO.File.Exists(emVersion))
            {
                System.IO.File.Copy(emVersion,
                    System.IO.Path.Combine(outDir, "emscripten-version.txt"), true);
                UnityEngine.Debug.Log($"recorded Emscripten version from {emVersion}");
            }
            else
            {
                UnityEngine.Debug.LogError($"同梱 Emscripten の版ファイルがありません: {emVersion}");
                EditorApplication.Exit(1);
                return;
            }
        }
        catch (Exception e)
        {
            UnityEngine.Debug.LogError($"版ファイルを書き出せませんでした: {e.Message}");
            EditorApplication.Exit(1);
            return;
        }

        var report = BuildPipeline.BuildPlayer(options);
        var summary = report.summary;

        // **後始末は結果に関わらず行う。** 失敗したときこそ残りやすい。
        AssetDatabase.DeleteAsset(scenePath);
        UnityEngine.Debug.Log(
            $"WebGL build: {summary.result}, {summary.totalSize} bytes, " +
            $"errors={summary.totalErrors}, warnings={summary.totalWarnings}, out={outDir}");

        // **理由を吐かせる。** BuildResult.Unknown は「理由を言わずに終わった」
        // という意味で、**ログに error が 1 行も出ないことがある**
        // （2026-09-03 に実測）。report の中の message を全部並べる ——
        // **「失敗した」だけ分かっても次の手が決まらない。**
        foreach (var step in report.steps)
        {
            foreach (var msg in step.messages)
            {
                if (msg.type == LogType.Error || msg.type == LogType.Exception ||
                    msg.type == LogType.Assert || msg.type == LogType.Warning)
                {
                    UnityEngine.Debug.Log($"[build step] {step.name}: {msg.type}: {msg.content}");
                }
            }
        }

        if (summary.result != UnityEditor.Build.Reporting.BuildResult.Succeeded)
        {
            UnityEngine.Debug.LogError($"WebGL build failed: {summary.result}");
            EditorApplication.Exit(1);
            return;
        }
        EditorApplication.Exit(0);
    }
}
