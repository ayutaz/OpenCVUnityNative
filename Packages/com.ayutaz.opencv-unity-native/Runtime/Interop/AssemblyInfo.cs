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

// **CvUnity.Interop.Dnn には InternalsVisibleTo を出さない。**
//
// dnn の宣言は CvUnity.Interop.Dnn の中で完結し、そこから
// CvUnity.Interop の internal を見る必要は無い —— 見たくなったら、
// それは共通の何かが Interop 側に在るということなので、
// **そちらを別の場所へ切り出す合図である。**
//
// **その合図は 2026-09-06 に出た。** `[DllImport(LibraryName, ...)]` の
// `LibraryName`（NativeMethods.cs の #if ブロック）が、まさに「profile 側が Interop に
// 見たい共通の何か」だった —— 見えないので、非既定 profile の生成物は
// CS0103 でコンパイルできなかった（実測）。
//
// **切り出さずに、機械の監視つきの複製で答えた。** 切り出すと
// LibraryName を public にする（実装詳細のために公開 API を恒久的に
// 広げる）か、profile ごとに InternalsVisibleTo を並べる（このリポジトリが
// 繰り返し拒んできた形）かのどちらかになるためである。生成器が
// #if 分岐ごと複製し、Ocvu.Generator.Tests の ProfileTests が
// 2 つの写しを読み比べる。**切り出しは M7c の判断である** ——
// 理由と条件は docs/abi-ownership-and-versioning.md §4 が正本。
//
// 逆向き（Interop が Dnn を見る）も出さない。既定 profile が
// opt-in profile を知っていたら、切り離せていない。
