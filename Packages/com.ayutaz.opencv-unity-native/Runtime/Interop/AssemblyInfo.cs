using System.Runtime.CompilerServices;

// Runtime/Interop の internal は、同じパッケージの Core 層と L3 のテストからだけ見える。
// public にはしない — P/Invoke 宣言は実装詳細であり、利用者向けの API ではない。
[assembly: InternalsVisibleTo("CvUnity.Core")]
[assembly: InternalsVisibleTo("CvUnity.Tests.Managed")]
[assembly: InternalsVisibleTo("CvUnity.Runtime.Shim")]
