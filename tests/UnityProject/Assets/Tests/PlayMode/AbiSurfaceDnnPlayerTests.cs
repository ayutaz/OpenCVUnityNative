using System.Collections;
using NUnit.Framework;
using UnityEngine.TestTools;

/// <summary>
/// dnn profile の到達性を Player (IL2CPP) から確かめる、手で書いた唯一の入口。
///
/// **レビュー指摘（I1）。** 生成物 <c>AbiReachabilityChecksDnn.CallEveryEntryPoint()</c>
/// （<c>tests/UnityProject/Assets/Tests/Shared.Dnn/AbiReachabilityChecks.Dnn.g.cs</c>）は
/// spec が載せる dnn の 4 宣言を 1 回ずつ呼ぶために生成されているが、
/// **どこからも呼ばれていなかった。** 標準 profile の同じ仕組みは
/// <c>AbiSurfaceTests.cs</c> / <c>AbiSurfacePlayerTests.cs</c> / <c>WebSmokeRunner.cs</c>
/// の 3 箇所から呼ばれているのに対し、dnn 側は 0 箇所だった。
///
/// **呼ばれない宣言そのものが strip の対象になる**ので、この穴は
/// 「検査が無い」以上に悪い —— 検査を足しても、消える宣言が消えたことに
/// 気づけない。M4 が手書きの 19 本のうち 7 本で実際に踏んだのと
/// 同じ形の欠落が、dnn の 4 本にそのまま開いていた。
///
/// **`CvUnity.Tests.PlayMode` 自体は `OCVU_PROFILE_DNN` で切られていない**
/// （dnn を使わない利用者の Player を壊さないため）。したがって
/// `CvUnity.Tests.Shared.Dnn` への参照は asmdef に足すが、使う側は
/// この `#if` で自分を守る —— define が立っていなければ、このクラスは
/// テストを 1 つも持たない空のクラスになる。
///
/// **`ci-unity.yml` の `DnnStandalone` レーンがこれを走らせる。**
/// そのレーンだけが `ProjectSettings.asset` に `OCVU_PROFILE_DNN` を書いてから
/// IL2CPP Player を建てる。**このテストが自動実行されるようになったのは
/// そのレーンを足してからで**、それまでは人が手で 1 回確かめたきりだった
/// （M7c が残した穴。`docs/roadmap.md` の `### M7c の判定`）。
/// レーンは `-RequireTest` でこのテスト名を名指ししているので、
/// **assembly から外れれば CI が赤くなる。**
/// </summary>
public class AbiSurfaceDnnPlayerTests
{
#if OCVU_PROFILE_DNN
    [UnityTest]
    public IEnumerator EveryDnnEntryPointIsReachable()
    {
        var called = AbiReachabilityChecksDnn.CallEveryEntryPoint();
        // **0 件で緑にしない。** spec が空でも「呼び終えた」と言えてしまう。
        // dnn の spec は 4 entry なので、ちょうど 4 であることまで見る
        // （標準側の Assert.Greater(called, 10) より厳しくできるのは、
        // dnn の本数が固定で小さいため）。
        Assert.AreEqual(4, called, "dnn の宣言は 4 本のはず");
        yield return null;
    }
#endif
}
