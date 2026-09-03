using System;

/// <summary>
/// 共有の検証本体が使う、**フレームワークに依存しない**主張の道具（M6）。
///
/// **なぜ NUnit を使わないのか。**
///
/// `AbiSurfaceChecks` は EditMode / Standalone Player / **Web Player** の
/// 3 つから呼ばれる。前の 2 つは Unity Test Framework が用意する
/// 「テスト用 Player」で走るので NUnit が同梱されるが、**Web は通常の
/// Player なので入らない。** 実測（2026-09-03）:
///
///     Fatal error in Unity CIL Linker
///     Mono.Cecil.AssemblyResolutionException:
///       Failed to resolve assembly: 'nunit.framework, Version=3.5.0.0'
///
/// **検証本体を写して 3 つ目を作るわけにはいかない**（写すと
/// 「Editor と Player と Web で同じ結果」を確かめられなくなる）ので、
/// **本体の側をフレームワーク非依存にする。**
///
/// 失敗は例外で表す。NUnit も xUnit も「例外が飛んだらそのテストは失敗」
/// なので、**呼ぶ側の枠組みを問わない。**
/// </summary>
public static class Check
{
    /// <summary>主張が破れたことを表す例外。</summary>
    public sealed class Failed : Exception
    {
        public Failed(string message) : base(message) { }
    }

    public static void AreEqual<T>(T expected, T actual, string because = null)
    {
        if (!Equals(expected, actual))
        {
            Fail($"expected <{Describe(expected)}> but was <{Describe(actual)}>", because);
        }
    }

    public static void AreNotEqual<T>(T notExpected, T actual, string because = null)
    {
        if (Equals(notExpected, actual))
        {
            Fail($"expected something other than <{Describe(notExpected)}>", because);
        }
    }

    public static void Greater(long actual, long threshold, string because = null)
    {
        if (actual <= threshold)
        {
            Fail($"expected greater than <{threshold}> but was <{actual}>", because);
        }
    }

    public static void Contains(string haystack, string needle, string because = null)
    {
        if (haystack == null || !haystack.Contains(needle))
        {
            Fail($"expected to contain <{needle}>", because);
        }
    }

    /// <summary>
    /// 並びが同じであることを主張する（NUnit の CollectionAssert.AreEqual に相当）。
    ///
    /// **最初に食い違った位置を言う。** 「違う」だけだと、長い byte 列で
    /// どこが壊れたのか分からない。
    /// </summary>
    public static void SequenceEqual<T>(System.Collections.Generic.IList<T> expected,
                                        System.Collections.Generic.IList<T> actual,
                                        string because = null)
    {
        if (expected == null || actual == null)
        {
            if (!ReferenceEquals(expected, actual)) { Fail("one side was null", because); }
            return;
        }
        if (expected.Count != actual.Count)
        {
            Fail($"length differs: expected {expected.Count}, was {actual.Count}", because);
        }
        for (int i = 0; i < expected.Count; i++)
        {
            if (!Equals(expected[i], actual[i]))
            {
                Fail($"differs at [{i}]: expected <{Describe(expected[i])}> but was <{Describe(actual[i])}>", because);
            }
        }
    }

    public static void IsTrue(bool condition, string because = null)
    {
        if (!condition) { Fail("expected true", because); }
    }

    /// <summary>
    /// 指定した例外が飛ぶことを主張し、その例外を返す。
    ///
    /// **飛ばなかったことも失敗である** —— 「例外を投げるはず」の検査で
    /// 何も起きないまま通ると、契約が壊れたことに気づけない。
    /// </summary>
    public static TException Throws<TException>(Action action, string because = null)
        where TException : Exception
    {
        try
        {
            action();
        }
        catch (TException e)
        {
            return e;
        }
        catch (Exception e)
        {
            Fail($"expected {typeof(TException).Name} but got {e.GetType().Name}: {e.Message}", because);
        }

        Fail($"expected {typeof(TException).Name} but nothing was thrown", because);
        return null; // Fail が必ず投げるので到達しない
    }

    private static void Fail(string what, string because)
    {
        throw new Failed(string.IsNullOrEmpty(because) ? what : $"{what} ({because})");
    }

    private static string Describe(object value)
    {
        if (value == null) { return "null"; }
        var s = value.ToString();
        return s.Length > 120 ? s.Substring(0, 120) + "..." : s;
    }
}
