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
}
