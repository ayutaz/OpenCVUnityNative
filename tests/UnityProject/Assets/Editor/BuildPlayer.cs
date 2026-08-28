using UnityEditor;
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
}
