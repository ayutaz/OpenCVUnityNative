using System.Runtime.CompilerServices;

// Runtime/Interop の internal は、同じパッケージの Core 層と L3 のテストからだけ見える。
// public にはしない — P/Invoke 宣言は実装詳細であり、利用者向けの API ではない。
[assembly: InternalsVisibleTo("CvUnity.Core")]
[assembly: InternalsVisibleTo("CvUnity.Tests.Managed")]
[assembly: InternalsVisibleTo("CvUnity.Runtime")]

// 到達性テスト（生成物）は NativeMethods を直接呼ぶ。**公開 API 経由では、
// どの entry point が呼ばれたかを spec から機械的に導けない** ——
// CvOps / CvCodecs は宣言と 1 対 1 ではないので、公開 API を全部叩いても
// 「全宣言を 1 回ずつ」にはならない。見えるようにするのは
// tests/UnityProject の test assembly に対してだけで、上の方針は変えない。
[assembly: InternalsVisibleTo("CvUnity.Tests.Shared")]
