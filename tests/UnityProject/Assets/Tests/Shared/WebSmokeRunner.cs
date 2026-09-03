using System;
using System.Reflection;
using UnityEngine;

/// <summary>
/// Web Player の中で、**他の platform と同じ検証本体**を走らせて結果を出す（M6）。
///
/// **なぜ MonoBehaviour なのか。** Unity Test Framework は WebGL の Player を
/// batchmode から直接走らせられない（EditMode / Standalone と違い、
/// 実行にはブラウザが要る）。**だから Player 自身に走らせて、結果を
/// ブラウザのコンソールへ出す。** それを外から読むのが
/// <c>tools/run-web-e2e.ps1</c> である。
///
/// **検証本体を写さない。** <see cref="AbiSurfaceChecks"/> と
/// <see cref="AbiReachabilityChecks"/> は EditMode / Standalone が使っている
/// ものと同じで、ここは呼ぶだけである —— **写して 3 つ目を作ると
/// 「Editor と Player と Web で同じ結果」を確かめられなくなる。**
///
/// **出す形を固定する。** 1 行の目印つきで出すので、外から機械的に読める:
///
///     OCVU_WEB_RESULT: passed=N failed=M reachable=R
///     OCVU_WEB_FAIL: &lt;検査名&gt;: &lt;例外&gt;
///
/// **0 件で緑にしない** —— passed が 0 なら failed が 0 でも失敗として出す。
/// </summary>
public sealed class WebSmokeRunner : MonoBehaviour
{
    /// <summary>外から grep する目印。**C# 側の正本はここ 1 箇所。**</summary>
    public const string ResultMarker = "OCVU_WEB_RESULT:";

    /// <summary>失敗 1 件ごとの目印。</summary>
    public const string FailureMarker = "OCVU_WEB_FAIL:";

    private void Start()
    {
        Run();
    }

    private void Run()
    {
        int passed = 0;
        int failed = 0;

        // AbiSurfaceChecks の public static void メソッドを全部呼ぶ。
        //
        // **名前を並べない。** ただし **EditMode / PlayMode 側は名前を並べている**
        // （`AbiSurfaceTests.cs` が `[Test] public void X() => AbiSurfaceChecks.X();`
        // を 1 行ずつ持つ）—— NUnit にテストとして見せるにはそれが要る。
        //
        // **したがって、検査を 1 つ足したときに追随するのは Web だけである。**
        // EditMode / PlayMode は名指しなので、足し忘れるとそちらだけ走らない。
        // **その差は tools/run-web-e2e.ps1 が埋める** —— 共有本体の
        // `public static void` を数え、**Web で走った件数と完全一致**することを
        // 要求するので、**片方だけ古くなれば Web のレーンが赤くなる。**
        var methods = typeof(AbiSurfaceChecks).GetMethods(
            BindingFlags.Public | BindingFlags.Static);
        foreach (var m in methods)
        {
            if (m.ReturnType != typeof(void) || m.GetParameters().Length != 0)
            {
                continue;
            }

            try
            {
                m.Invoke(null, null);
                passed++;
            }
            catch (Exception e)
            {
                failed++;
                var inner = e is TargetInvocationException tie && tie.InnerException != null
                    ? tie.InnerException
                    : e;
                Debug.Log($"{FailureMarker} {m.Name}: {inner.GetType().Name}: {inner.Message}");
            }
        }

        // **到達性は別に数える。** stripping が消せるのは呼ばれない宣言なので、
        // これを確かめられるのは Player だけである。
        int reachable = -1;
        try
        {
            reachable = AbiReachabilityChecks.CallEveryEntryPoint();
        }
        catch (Exception e)
        {
            failed++;
            Debug.Log($"{FailureMarker} CallEveryEntryPoint: {e.GetType().Name}: {e.Message}");
        }

        // **走った件数が 0 なら、それは成功ではない。**
        // 呼ぶ相手を 1 つも見つけられなかった状態が緑になると、
        // 「検査が在る」だけで「検査が働いた」ことにされる。
        if (passed == 0)
        {
            failed++;
            Debug.Log($"{FailureMarker} (no checks ran): AbiSurfaceChecks に呼べる検査が 1 つもありませんでした");
        }

        Debug.Log($"{ResultMarker} passed={passed} failed={failed} reachable={reachable}");
    }
}
